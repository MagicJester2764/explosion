// PKG: gio-2.0 gobject-2.0
/* glib on Quark: the parts a toolkit actually stands on.
 *
 * A toolkit does not use glib the way a test does, but everything it does use
 * is here: a hash table and a string, a main loop woken from another thread, a
 * thread pool, a type with a signal and a property, a regular expression
 * (which is PCRE2 with a GLib face), and a file read back through GIO.
 *
 * The main loop is the interesting one. GLib wakes a sleeping loop through
 * `eventfd` where it has one, and glib's build finds `eventfd` in musl's
 * headers — so a loop that never wakes means the call is a lie rather than a
 * missing feature.
 */

#include <gio/gio.h>
#include <glib.h>
#include <glib/gstdio.h>
#include <stdio.h>

static int failures;

static void check(const char *what, int ok) {
    printf("%s: %s\n", ok ? "ok" : "FAILED", what);
    if (!ok) {
        failures++;
    }
}

/* ---- a type of our own, with a signal and a property ---- */

#define TEST_TYPE_THING (test_thing_get_type())
G_DECLARE_FINAL_TYPE(TestThing, test_thing, TEST, THING, GObject)

struct _TestThing {
    GObject parent;
    int count;
};

G_DEFINE_TYPE(TestThing, test_thing, G_TYPE_OBJECT)

enum { PROP_COUNT = 1, N_PROPS };
static GParamSpec *props[N_PROPS];
static guint signal_bumped;

static void test_thing_get_property(GObject *o, guint id, GValue *v, GParamSpec *p) {
    TestThing *t = TEST_THING(o);
    if (id == PROP_COUNT) {
        g_value_set_int(v, t->count);
    } else {
        G_OBJECT_WARN_INVALID_PROPERTY_ID(o, id, p);
    }
}

static void test_thing_set_property(GObject *o, guint id, const GValue *v, GParamSpec *p) {
    TestThing *t = TEST_THING(o);
    if (id == PROP_COUNT) {
        t->count = g_value_get_int(v);
    } else {
        G_OBJECT_WARN_INVALID_PROPERTY_ID(o, id, p);
    }
}

static void test_thing_class_init(TestThingClass *klass) {
    GObjectClass *oc = G_OBJECT_CLASS(klass);
    oc->get_property = test_thing_get_property;
    oc->set_property = test_thing_set_property;
    props[PROP_COUNT] = g_param_spec_int("count", NULL, NULL, 0, 1000, 0, G_PARAM_READWRITE);
    g_object_class_install_properties(oc, N_PROPS, props);
    signal_bumped = g_signal_new("bumped", TEST_TYPE_THING, G_SIGNAL_RUN_LAST, 0, NULL, NULL,
                                 NULL, G_TYPE_NONE, 1, G_TYPE_INT);
}

static void test_thing_init(TestThing *t) { t->count = 0; }

static int bumped_by;

static void on_bumped(TestThing *t, int by, gpointer data) {
    (void)t;
    (void)data;
    bumped_by = by;
}

/* ---- the main loop, woken from a thread ---- */

static GMainLoop *loop;
static int ticks;

static gboolean on_tick(gpointer data) {
    (void)data;
    ticks++;
    return ticks < 3 ? G_SOURCE_CONTINUE : G_SOURCE_REMOVE;
}

static gboolean stop_loop(gpointer data) {
    (void)data;
    g_main_loop_quit(loop);
    return G_SOURCE_REMOVE;
}

static gpointer waker(gpointer data) {
    GMainContext *ctx = data;
    g_usleep(50 * 1000);
    /* An idle added from another thread has to wake the loop that is
       sleeping in poll, which is what glib's wakeup is for. */
    GSource *s = g_idle_source_new();
    g_source_set_callback(s, stop_loop, NULL, NULL);
    g_source_attach(s, ctx);
    g_source_unref(s);
    return GINT_TO_POINTER(42);
}

/* ---- a thread pool ---- */

static int pool_sum;
static GMutex pool_lock;

static void pool_work(gpointer item, gpointer data) {
    (void)data;
    g_mutex_lock(&pool_lock);
    pool_sum += GPOINTER_TO_INT(item);
    g_mutex_unlock(&pool_lock);
}

int main(void) {
    /* Unbuffered, so that a line printed before a hang is a line seen. */
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("glibtest: glib %d.%d.%d\n", glib_major_version, glib_minor_version,
           glib_micro_version);

    /* Collections and strings. */
    GHashTable *h = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free);
    for (int i = 0; i < 100; i++) {
        g_hash_table_insert(h, g_strdup_printf("key%d", i), g_strdup_printf("%d", i * i));
    }
    const char *v = g_hash_table_lookup(h, "key7");
    check("hash table", v && g_strcmp0(v, "49") == 0 && g_hash_table_size(h) == 100);
    g_hash_table_destroy(h);

    GString *s = g_string_new("quark");
    g_string_append_printf(s, " %d", 64);
    g_string_prepend(s, "hello ");
    check("string", g_strcmp0(s->str, "hello quark 64") == 0);
    g_string_free(s, TRUE);

    char **parts = g_strsplit("a:b:c:d", ":", -1);
    char *joined = g_strjoinv("-", parts);
    check("split and join", g_strcmp0(joined, "a-b-c-d") == 0);
    g_free(joined);
    g_strfreev(parts);

    /* GObject: a property, and a signal with an argument. */
    TestThing *t = g_object_new(TEST_TYPE_THING, "count", 5, NULL);
    int got = 0;
    g_object_get(t, "count", &got, NULL);
    check("property", got == 5);
    g_signal_connect(t, "bumped", G_CALLBACK(on_bumped), NULL);
    g_signal_emit(t, signal_bumped, 0, 17);
    check("signal", bumped_by == 17);
    g_object_unref(t);

    /* A regular expression, which is PCRE2 underneath. */
    GError *err = NULL;
    GRegex *re = g_regex_new("([a-z]+)([0-9]+)", 0, 0, &err);
    GMatchInfo *mi = NULL;
    int matched = re && g_regex_match(re, "quark64", 0, &mi);
    char *word = matched ? g_match_info_fetch(mi, 1) : NULL;
    char *num = matched ? g_match_info_fetch(mi, 2) : NULL;
    check("regex", matched && g_strcmp0(word, "quark") == 0 && g_strcmp0(num, "64") == 0);
    g_free(word);
    g_free(num);
    if (mi) {
        g_match_info_free(mi);
    }
    if (re) {
        g_regex_unref(re);
    }
    g_clear_error(&err);

    /* Threads: one that joins, and a pool that does not. */
    GThread *th = g_thread_new("waker-probe", waker, g_main_context_default());
    GMainContext *ctx = g_main_context_default();
    (void)ctx;
    loop = g_main_loop_new(NULL, FALSE);
    g_timeout_add(10, on_tick, NULL);
    /* If the wakeup does not work the loop sleeps in poll for good; the
       timeout is the floor under that, and it is also the tick source. */
    g_timeout_add(2000, stop_loop, NULL);
    g_main_loop_run(loop);
    gpointer joined_val = g_thread_join(th);
    check("main loop ran timeouts", ticks == 3);
    check("thread joined", GPOINTER_TO_INT(joined_val) == 42);
    g_main_loop_unref(loop);

    g_mutex_init(&pool_lock);
    GThreadPool *pool = g_thread_pool_new(pool_work, NULL, 4, FALSE, &err);
    for (int i = 1; i <= 100; i++) {
        g_thread_pool_push(pool, GINT_TO_POINTER(i), &err);
    }
    g_thread_pool_free(pool, FALSE, TRUE);
    check("thread pool", pool_sum == 5050);
    g_clear_error(&err);

    /* Files, through GLib and then through GIO. */
    const char *path = "/tmp/glibtest.txt";
    check("set contents", g_file_set_contents(path, "quark\n", -1, &err) && !err);
    g_clear_error(&err);
    char *back = NULL;
    gsize len = 0;
    check("get contents", g_file_get_contents(path, &back, &len, &err) && len == 6 &&
                              g_strcmp0(back, "quark\n") == 0);
    g_free(back);
    g_clear_error(&err);

    GFile *f = g_file_new_for_path(path);
    GFileInfo *info = g_file_query_info(f, G_FILE_ATTRIBUTE_STANDARD_SIZE, 0, NULL, &err);
    check("gio query info", info && g_file_info_get_size(info) == 6);
    if (info) {
        g_object_unref(info);
    }
    g_clear_error(&err);
    char *contents = NULL;
    check("gio load contents",
          g_file_load_contents(f, NULL, &contents, &len, NULL, &err) && len == 6);
    g_free(contents);
    g_clear_error(&err);
    g_object_unref(f);
    g_unlink(path);

    printf("glibtest: %d failed\n", failures);
    return failures ? 1 : 0;
}
