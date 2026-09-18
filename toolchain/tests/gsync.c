// PKG: glib-2.0
/* What two threads do to each other, at each layer. */
#include <glib.h>
#include <stdio.h>
#include <pthread.h>
#include <semaphore.h>
#include <time.h>
#include <errno.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <linux/futex.h>

static int failures;
static void check(const char *what, int ok) {
    printf("%s: %s\n", ok ? "ok" : "FAILED", what);
    if (!ok) failures++;
}
static long long now_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* 1. a raw futex with a timeout */
static int futex_word;

/* 2. GMutex under contention */
static GMutex gm;
static volatile long gm_count;
static gpointer gm_worker(gpointer d) {
    (void)d;
    for (int i = 0; i < 20000; i++) { g_mutex_lock(&gm); gm_count++; g_mutex_unlock(&gm); }
    return NULL;
}

/* 3. GCond */
static GMutex cm;
static GCond cc;
static int cond_state;
static gpointer cond_worker(gpointer d) {
    (void)d;
    g_mutex_lock(&cm);
    while (cond_state == 0) g_cond_wait(&cc, &cm);
    cond_state = 2;
    g_cond_signal(&cc);
    g_mutex_unlock(&cm);
    return NULL;
}

/* 4. pthread mutex contention, for comparison */
static pthread_mutex_t pm = PTHREAD_MUTEX_INITIALIZER;
static volatile long pm_count;
static void *pm_worker(void *d) {
    (void)d;
    for (int i = 0; i < 20000; i++) { pthread_mutex_lock(&pm); pm_count++; pthread_mutex_unlock(&pm); }
    return NULL;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);

    /* A futex wait with a timeout must come back when the time is up. A
       condition variable with a deadline is built out of this, and so is
       every "wait up to" in a thread pool. */
    struct timespec ts = {0, 200 * 1000 * 1000};
    long long t0 = now_ms();
    long r = syscall(SYS_futex, &futex_word, FUTEX_WAIT_PRIVATE, 0, &ts, NULL, 0);
    long long t1 = now_ms();
    printf("   futex wait returned %ld after %lld ms\n", r, t1 - t0);
    check("timed futex wait comes back", t1 - t0 >= 150 && t1 - t0 < 2000);

    /* A futex wait whose word does not match must not wait at all. */
    futex_word = 9;
    t0 = now_ms();
    r = syscall(SYS_futex, &futex_word, FUTEX_WAIT_PRIVATE, 0, NULL, NULL, 0);
    t1 = now_ms();
    printf("   mismatched futex returned %ld after %lld ms\n", r, t1 - t0);
    check("mismatched futex does not wait", t1 - t0 < 500);

    pthread_t p1, p2;
    check("pthread mutex threads", pthread_create(&p1, NULL, pm_worker, NULL) == 0 &&
                                       pthread_create(&p2, NULL, pm_worker, NULL) == 0);
    pthread_join(p1, NULL);
    pthread_join(p2, NULL);
    check("pthread mutex under contention", pm_count == 40000);

    g_mutex_init(&gm);
    GThread *t1a = g_thread_new("gm1", gm_worker, NULL);
    GThread *t2a = g_thread_new("gm2", gm_worker, NULL);
    g_thread_join(t1a);
    g_thread_join(t2a);
    check("GMutex under contention", gm_count == 40000);

    g_mutex_init(&cm);
    g_cond_init(&cc);
    GThread *t3 = g_thread_new("cond", cond_worker, NULL);
    g_mutex_lock(&cm);
    cond_state = 1;
    g_cond_signal(&cc);
    while (cond_state != 2) g_cond_wait(&cc, &cm);
    g_mutex_unlock(&cm);
    g_thread_join(t3);
    check("GCond both ways", cond_state == 2);

    /* And the timed one, which is what a thread pool waits on. */
    g_mutex_lock(&cm);
    t0 = now_ms();
    gboolean got = g_cond_wait_until(&cc, &cm, g_get_monotonic_time() + 200000);
    t1 = now_ms();
    g_mutex_unlock(&cm);
    printf("   g_cond_wait_until returned %d after %lld ms\n", got, t1 - t0);
    check("g_cond_wait_until gives up", !got && t1 - t0 >= 150 && t1 - t0 < 2000);

    printf("gsync: %d failed\n", failures);
    return failures ? 1 : 0;
}
