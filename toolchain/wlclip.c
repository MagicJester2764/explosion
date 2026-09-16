/* Two halves of a clipboard, in one program.
 *
 * Run as `wm wlclip wlclip`. The compositor passes each session program its
 * index as argv[1] — "1" for the first, "2" for the second — and that is what
 * decides which half this is. Taking the role from the tag the compositor
 * already supplies is deliberate: adding argument plumbing to the compositor so
 * that a test could pass a flag would be changing the thing under test.
 *
 * The first copies: it offers a data source and takes the selection. The second
 * pastes: it waits to be offered one, hands over a pipe, and reads.
 *
 * Two programs rather than one, because a clipboard with a single participant
 * does not exercise the part that matters — the offer is an object the
 * compositor names in the *receiver's* id table while the source lives in the
 * sender's, and with one client those are the same table.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>

#include "xdg-shell-client-protocol.h"

#define W 160
#define H 120
#define STRIDE (W * 4)
#define POOL_SIZE (STRIDE * H)

#define MIME "text/plain;charset=utf-8"
static const char PAYLOAD[] = "hello from the other side";

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm_base;
static struct wl_seat *seat;
static struct wl_data_device_manager *ddm;
static struct wl_data_device *device;
static struct wl_data_offer *offer;
static struct wl_surface *surface;
static int configured;
static int offered_mime;   /* the receiver was told about MIME */
static int have_selection; /* ... and then told it is the selection */

static void global(void *data, struct wl_registry *r, uint32_t name,
                   const char *iface, uint32_t version) {
    (void)data; (void)version;
    if (strcmp(iface, "wl_compositor") == 0) {
        compositor = wl_registry_bind(r, name, &wl_compositor_interface, 1);
    } else if (strcmp(iface, "wl_shm") == 0) {
        shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
    } else if (strcmp(iface, "xdg_wm_base") == 0) {
        wm_base = wl_registry_bind(r, name, &xdg_wm_base_interface, 1);
    } else if (strcmp(iface, "wl_seat") == 0) {
        seat = wl_registry_bind(r, name, &wl_seat_interface, 1);
    } else if (strcmp(iface, "wl_data_device_manager") == 0) {
        ddm = wl_registry_bind(r, name, &wl_data_device_manager_interface, 1);
    }
}

static void global_remove(void *d, struct wl_registry *r, uint32_t n) {
    (void)d; (void)r; (void)n;
}

static const struct wl_registry_listener registry_listener = { global, global_remove };

static void surface_configure(void *d, struct xdg_surface *s, uint32_t serial) {
    (void)d;
    xdg_surface_ack_configure(s, serial);
    configured = 1;
}

static const struct xdg_surface_listener surface_listener = { surface_configure };

static void toplevel_configure(void *d, struct xdg_toplevel *t, int32_t w,
                               int32_t h, struct wl_array *s) {
    (void)d; (void)t; (void)w; (void)h; (void)s;
}
static void toplevel_close(void *d, struct xdg_toplevel *t) { (void)d; (void)t; }
static const struct xdg_toplevel_listener toplevel_listener = {
    toplevel_configure, toplevel_close,
};

/* --- the copying half --- */

static void src_target(void *d, struct wl_data_source *s, const char *mime) {
    (void)d; (void)s; (void)mime;
}

static void src_send(void *d, struct wl_data_source *s, const char *mime, int32_t fd) {
    (void)d; (void)s;
    printf("copy: asked for %s\n", mime);
    ssize_t n = write(fd, PAYLOAD, sizeof PAYLOAD - 1);
    printf("copy: wrote %d\n", (int)n);
    close(fd);
}

static void src_cancelled(void *d, struct wl_data_source *s) {
    (void)d; (void)s;
    printf("copy: cancelled\n");
}

static const struct wl_data_source_listener src_listener = {
    src_target, src_send, src_cancelled,
};

/* --- the pasting half --- */

static void offer_mime(void *d, struct wl_data_offer *o, const char *mime) {
    (void)d; (void)o;
    printf("paste: offered %s\n", mime);
    if (strcmp(mime, MIME) == 0) {
        offered_mime = 1;
    }
}

static const struct wl_data_offer_listener offer_listener = { offer_mime };

static void dev_data_offer(void *d, struct wl_data_device *dev, struct wl_data_offer *o) {
    (void)d; (void)dev;
    offer = o;
    wl_data_offer_add_listener(o, &offer_listener, NULL);
}

static void dev_enter(void *d, struct wl_data_device *dev, uint32_t serial,
                      struct wl_surface *s, wl_fixed_t x, wl_fixed_t y,
                      struct wl_data_offer *o) {
    (void)d; (void)dev; (void)serial; (void)s; (void)x; (void)y; (void)o;
}
static void dev_leave(void *d, struct wl_data_device *dev) { (void)d; (void)dev; }
static void dev_motion(void *d, struct wl_data_device *dev, uint32_t t,
                       wl_fixed_t x, wl_fixed_t y) {
    (void)d; (void)dev; (void)t; (void)x; (void)y;
}
static void dev_drop(void *d, struct wl_data_device *dev) { (void)d; (void)dev; }

static void dev_selection(void *d, struct wl_data_device *dev, struct wl_data_offer *o) {
    (void)d; (void)dev;
    if (o == NULL) {
        printf("paste: selection cleared\n");
        return;
    }
    have_selection = 1;
}

static const struct wl_data_device_listener dev_listener = {
    dev_data_offer, dev_enter, dev_leave, dev_motion, dev_drop, dev_selection,
};

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    int paster = argc > 1 && argv[1][0] == '2';
    const char *who = paster ? "paste" : "copy";

    struct wl_display *d = wl_display_connect(NULL);
    if (!d) {
        printf("%s: no display\n", who);
        return 1;
    }
    struct wl_registry *r = wl_display_get_registry(d);
    wl_registry_add_listener(r, &registry_listener, NULL);
    wl_display_roundtrip(d);
    if (!compositor || !shm || !wm_base || !seat || !ddm) {
        printf("%s: missing a global (ddm %s)\n", who, ddm ? "OK" : "NULL");
        return 1;
    }

    /* A window, because the selection follows keyboard focus and only a
       surface can have it. */
    int fd = memfd_create("wlclip", 0);
    if (fd < 0 || ftruncate(fd, POOL_SIZE) < 0) {
        printf("%s: no memory\n", who);
        return 1;
    }
    void *px = mmap(NULL, POOL_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (px == MAP_FAILED) {
        printf("%s: no mapping\n", who);
        return 1;
    }
    memset(px, paster ? 0x40 : 0x80, POOL_SIZE);
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, POOL_SIZE);
    struct wl_buffer *buf = wl_shm_pool_create_buffer(pool, 0, W, H, STRIDE,
                                                      WL_SHM_FORMAT_XRGB8888);
    surface = wl_compositor_create_surface(compositor);
    struct xdg_surface *xs = xdg_wm_base_get_xdg_surface(wm_base, surface);
    xdg_surface_add_listener(xs, &surface_listener, NULL);
    struct xdg_toplevel *top = xdg_surface_get_toplevel(xs);
    xdg_toplevel_add_listener(top, &toplevel_listener, NULL);
    xdg_toplevel_set_title(top, who);
    wl_surface_commit(surface);
    wl_display_roundtrip(d);
    if (!configured) {
        printf("%s: never configured\n", who);
        return 1;
    }
    wl_surface_attach(surface, buf, 0, 0);
    wl_surface_damage(surface, 0, 0, W, H);
    wl_surface_commit(surface);
    wl_display_roundtrip(d);

    device = wl_data_device_manager_get_data_device(ddm, seat);
    wl_data_device_add_listener(device, &dev_listener, NULL);
    wl_display_roundtrip(d);

    if (!paster) {
        struct wl_data_source *src = wl_data_device_manager_create_data_source(ddm);
        wl_data_source_add_listener(src, &src_listener, NULL);
        wl_data_source_offer(src, MIME);
        wl_data_device_set_selection(device, src, 0);
        printf("copy: selection set\n");
        /* Stay alive to answer: a source whose client has gone is a clipboard
           with nothing behind it. */
        while (wl_display_dispatch(d) != -1) {
            ;
        }
        return 0;
    }

    /* Wait to be offered the selection. The copier may not have set it yet. */
    for (int i = 0; i < 60 && !have_selection; i++) {
        if (wl_display_roundtrip(d) == -1) {
            break;
        }
        usleep(100000);
    }
    printf("paste: selection %s, mime %s\n", have_selection ? "yes" : "no",
           offered_mime ? "yes" : "no");
    if (!have_selection || !offered_mime) {
        return 1;
    }

    int fds[2];
    if (pipe(fds) != 0) {
        printf("paste: no pipe (errno %d)\n", errno);
        return 1;
    }
    wl_data_offer_receive(offer, MIME, fds[1]);
    wl_display_flush(d);
    /* Our own copy of the write end goes now: the pipe ends when the *last*
       writer closes, and holding one here would mean never reaching it. */
    close(fds[1]);

    char in[128];
    int got = 0;
    for (;;) {
        ssize_t n = read(fds[0], in + got, (int)sizeof in - 1 - got);
        if (n <= 0) {
            break;
        }
        got += (int)n;
        if (got >= (int)sizeof in - 1) {
            break;
        }
    }
    in[got] = 0;
    close(fds[0]);
    printf("paste: got %d bytes: %s\n", got, in);
    wl_display_disconnect(d);
    return 0;
}
