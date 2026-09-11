/* A Wayland client, end to end: connect, bind, make a buffer, become a window,
 * and draw until the compositor stops asking for more.
 *
 * Upstream libwayland, unmodified, plus the xdg-shell stubs generated from
 * wayland-protocols' own XML. That is the whole point of this program — every
 * byte on the wire is written by the same code that writes it on Linux, so
 * anything it finds is a compositor bug rather than a disagreement about what
 * Wayland is.
 *
 * It prints at every stage. A Wayland client that gets something wrong does not
 * fail where it went wrong; it waits, and a stage marker is the difference
 * between knowing which call stopped and guessing.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>

#include "xdg-shell-client-protocol.h"

#define W 320
#define H 240
#define STRIDE (W * 4)
#define POOL_SIZE (STRIDE * H)
/* Two buffers, so that one can be drawn into while the compositor reads the
   other -- which is what wl_buffer.release exists to make safe. */
#define BUFFERS 2

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm_base;
static struct wl_seat *seat;
static struct wl_keyboard *keyboard;
static uint32_t formats;
static int globals;

static struct wl_buffer *buffers[BUFFERS];
static void *pixels[BUFFERS];
static int busy[BUFFERS];

static int configured;
static int frames;
static int releases;

static void global(void *data, struct wl_registry *r, uint32_t name,
                   const char *iface, uint32_t version) {
    (void)data;
    printf("  global %u: %s v%u\n", name, iface, version);
    globals++;
    if (strcmp(iface, "wl_compositor") == 0) {
        compositor = wl_registry_bind(r, name, &wl_compositor_interface, 1);
    } else if (strcmp(iface, "wl_shm") == 0) {
        shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
    } else if (strcmp(iface, "xdg_wm_base") == 0) {
        wm_base = wl_registry_bind(r, name, &xdg_wm_base_interface, 1);
    } else if (strcmp(iface, "wl_seat") == 0) {
        seat = wl_registry_bind(r, name, &wl_seat_interface, 4);
    }
}

static void global_remove(void *data, struct wl_registry *r, uint32_t name) {
    (void)data; (void)r; (void)name;
}

static const struct wl_registry_listener registry_listener = { global, global_remove };

static void shm_format(void *data, struct wl_shm *s, uint32_t format) {
    (void)data; (void)s;
    formats++;
}

static const struct wl_shm_listener shm_listener = { shm_format };

/* Why the connection died. Without printing it, a protocol error looks exactly
   like a hang. */
static void why(struct wl_display *d) {
    int e = wl_display_get_error(d);
    if (!e) {
        return;
    }
    const struct wl_interface *iface = NULL;
    uint32_t id = 0;
    uint32_t code = wl_display_get_protocol_error(d, &iface, &id);
    printf("  error: errno %d, %s id %u code %u\n", e,
           iface ? iface->name : "(none)", id, code);
}

static void surface_configure(void *data, struct xdg_surface *s, uint32_t serial) {
    (void)data;
    xdg_surface_ack_configure(s, serial);
    configured = 1;
    printf("configure: serial %u, acked\n", serial);
}

static const struct xdg_surface_listener surface_listener = { surface_configure };

static void toplevel_configure(void *data, struct xdg_toplevel *t, int32_t w,
                               int32_t h, struct wl_array *states) {
    (void)data; (void)t; (void)states;
    printf("toplevel configure: %dx%d\n", w, h);
}

static void toplevel_close(void *data, struct xdg_toplevel *t) {
    (void)data; (void)t;
}

static const struct xdg_toplevel_listener toplevel_listener = {
    toplevel_configure, toplevel_close,
};

static void buffer_release(void *data, struct wl_buffer *b) {
    (void)b;
    busy[(int)(long)data] = 0;
    releases++;
}

static const struct wl_buffer_listener buffer_listener = { buffer_release };

static void frame_done(void *data, struct wl_callback *c, uint32_t time);
static const struct wl_callback_listener frame_listener = { frame_done };

static struct wl_surface *surface;

/* Fill a buffer with something that moves, so a screendump shows whether the
   compositor is showing this frame or an older one. */
static void paint(int n, int tick) {
    uint32_t *px = pixels[n];
    for (int y = 0; y < H; y++) {
        for (int x = 0; x < W; x++) {
            int v = (x + y + tick * 8) & 0xFF;
            px[y * W + x] = 0xFF000000u | ((uint32_t)v << 16) | ((uint32_t)(255 - v) << 8) | 0x80;
        }
    }
}

static int free_buffer(void) {
    for (int i = 0; i < BUFFERS; i++) {
        if (!busy[i]) {
            return i;
        }
    }
    return -1;
}

static void draw(int tick) {
    int n = free_buffer();
    if (n < 0) {
        return; /* both still held: the compositor has not released one yet */
    }
    paint(n, tick);
    busy[n] = 1;
    wl_surface_attach(surface, buffers[n], 0, 0);
    wl_surface_damage(surface, 0, 0, W, H);
    struct wl_callback *cb = wl_surface_frame(surface);
    wl_callback_add_listener(cb, &frame_listener, NULL);
    wl_surface_commit(surface);
}

static void frame_done(void *data, struct wl_callback *c, uint32_t time) {
    (void)data; (void)time;
    wl_callback_destroy(c);
    frames++;
    /* Periodically rather than at the end: the compositor is drawing over this
       console, so these lines are read in scrollback afterwards -- and there is
       no "afterwards" for a client the session takes with it when it closes. */
    if (frames % 60 == 0) {
        printf("frames: %d releases: %d\n", frames, releases);
    }
    draw(frames);
}

/* The keyboard half of a seat. Printed rather than acted on: what is being
   tested is that the events arrive at all, with the right codes and in the
   right order. */
static void kb_keymap(void *d, struct wl_keyboard *k, uint32_t format,
                      int32_t fd, uint32_t size) {
    (void)d; (void)k;
    printf("keymap: format %u size %u fd %d\n", format, size, fd);
    if (fd < 0) {
        return;
    }
    /* Mapped rather than merely closed: the descriptor arriving proves the
       passing works, and only reading it proves there is a keymap in it. */
    char *map = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (map == MAP_FAILED) {
        printf("keymap: mmap FAILED\n");
    } else {
        int n = 0;
        while (n < (int)size && map[n] != '\n') {
            n++;
        }
        printf("keymap: %.*s\n", n, map);
        printf("keymap: last byte %d\n", map[size - 1]);
        munmap(map, size);
    }
    close(fd);
}

static void kb_enter(void *d, struct wl_keyboard *k, uint32_t serial,
                     struct wl_surface *s, struct wl_array *keys) {
    (void)d; (void)k; (void)s; (void)keys;
    printf("enter: serial %u\n", serial);
}

static void kb_leave(void *d, struct wl_keyboard *k, uint32_t serial,
                     struct wl_surface *s) {
    (void)d; (void)k; (void)s;
    printf("leave: serial %u\n", serial);
}

static void kb_key(void *d, struct wl_keyboard *k, uint32_t serial,
                   uint32_t time, uint32_t key, uint32_t state) {
    (void)d; (void)k; (void)time;
    printf("key: serial %u code %u %s\n", serial, key, state ? "down" : "up");
}

static void kb_modifiers(void *d, struct wl_keyboard *k, uint32_t serial,
                         uint32_t dep, uint32_t lat, uint32_t lck,
                         uint32_t group) {
    (void)d; (void)k; (void)serial; (void)lat; (void)group;
    printf("mods: depressed %u locked %u\n", dep, lck);
}

static void kb_repeat(void *d, struct wl_keyboard *k, int32_t rate,
                      int32_t delay) {
    (void)d; (void)k;
    printf("repeat: %d/s after %dms\n", rate, delay);
}

static const struct wl_keyboard_listener kb_listener = {
    kb_keymap, kb_enter, kb_leave, kb_key, kb_modifiers, kb_repeat,
};

static void wm_base_ping(void *data, struct xdg_wm_base *b, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(b, serial);
}

static const struct xdg_wm_base_listener wm_base_listener = { wm_base_ping };

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);

    struct wl_display *d = wl_display_connect(NULL);
    printf("connect: %s\n", d ? "OK" : "NULL");
    if (!d) {
        return 1;
    }
    struct wl_registry *r = wl_display_get_registry(d);
    wl_registry_add_listener(r, &registry_listener, NULL);
    printf("roundtrip: %d\n", wl_display_roundtrip(d));
    printf("globals: %d compositor:%s shm:%s wm_base:%s seat:%s\n", globals,
           compositor ? "OK" : "NULL", shm ? "OK" : "NULL",
           wm_base ? "OK" : "NULL", seat ? "OK" : "NULL");
    if (!compositor || !shm || !wm_base) {
        return 1;
    }
    xdg_wm_base_add_listener(wm_base, &wm_base_listener, NULL);
    wl_shm_add_listener(shm, &shm_listener, NULL);
    wl_display_roundtrip(d);
    printf("formats: %u\n", formats);

    /* The pool, the way every client makes one. */
    int fd = memfd_create("wlprobe", 0);
    if (fd < 0 || ftruncate(fd, POOL_SIZE * BUFFERS) < 0) {
        printf("memfd: FAILED\n");
        return 1;
    }
    void *base = mmap(NULL, POOL_SIZE * BUFFERS, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (base == MAP_FAILED) {
        printf("mmap: FAILED\n");
        return 1;
    }
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, POOL_SIZE * BUFFERS);
    for (int i = 0; i < BUFFERS; i++) {
        pixels[i] = (char *)base + i * POOL_SIZE;
        buffers[i] = wl_shm_pool_create_buffer(pool, i * POOL_SIZE, W, H, STRIDE,
                                               WL_SHM_FORMAT_XRGB8888);
        wl_buffer_add_listener(buffers[i], &buffer_listener, (void *)(long)i);
    }
    printf("pool: %d buffers\n", BUFFERS);

    /* A surface with a role, and nothing shown until the size is agreed. */
    surface = wl_compositor_create_surface(compositor);
    struct xdg_surface *xs = xdg_wm_base_get_xdg_surface(wm_base, surface);
    xdg_surface_add_listener(xs, &surface_listener, NULL);
    struct xdg_toplevel *top = xdg_surface_get_toplevel(xs);
    xdg_toplevel_add_listener(top, &toplevel_listener, NULL);
    xdg_toplevel_set_title(top, "wlprobe");
    wl_surface_commit(surface);

    printf("configure roundtrip: %d\n", wl_display_roundtrip(d));
    why(d);
    printf("configured: %d\n", configured);
    if (!configured) {
        return 1;
    }

    if (seat) {
        keyboard = wl_seat_get_keyboard(seat);
        wl_keyboard_add_listener(keyboard, &kb_listener, NULL);
        wl_display_roundtrip(d);
    }

    draw(0);
    /* Until the compositor goes away, which is what closing the session does.
       Drawing for a fixed count instead would leave nothing on the screen to
       photograph, and a compositor is a thing you have to look at. */
    while (wl_display_dispatch(d) != -1) {
        ;
    }
    printf("frames: %d releases: %d\n", frames, releases);
    why(d);
    wl_display_disconnect(d);
    return 0;
}
