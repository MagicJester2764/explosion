/* A scroll wheel, seen from the far end of the protocol.
 *
 * Upstream libwayland, unmodified: this binds wl_seat at the highest version
 * the compositor offers, up to 5, takes a pointer from it and prints one line
 * per frame group that carried an axis. Version 5 is the one that matters —
 * before it there is no wl_pointer.frame, and a client has no way to know
 * which events belong together.
 *
 * It needs a window, because a pointer event goes to the surface under the
 * pointer and a client with no surface is not under anything. So it makes one,
 * fills it, and keeps a frame callback going: that is also what lets it wake
 * up regularly enough to notice its own deadline.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>

#include "xdg-shell-client-protocol.h"

#define W 320
#define H 240
#define STRIDE (W * 4)
#define POOL_SIZE (STRIDE * H)

/* Enough to show the sign both ways round and stop; and long enough that a
   human driving it by hand gets a turn, but not so long that a test waits for
   a client with nothing to say. */
#define GROUPS 20
#define SECONDS 10

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm_base;
static struct wl_seat *seat;
static struct wl_pointer *pointer;
static struct wl_surface *surface;
static struct wl_buffer *buffer;
static void *pixels;
static uint32_t seat_version;
static int configured;
static int frames;

/* What this frame group has said so far. A group is everything between two
   wl_pointer.frame events, and printing before the frame would be printing
   half of one. */
static int have_axis, have_discrete, have_source, have_stop;
static uint32_t g_axis, g_source;
static wl_fixed_t g_value;
static int32_t g_discrete;
static int groups;
static int enters;

static const char *axis_name(uint32_t axis) {
    return axis == WL_POINTER_AXIS_VERTICAL_SCROLL ? "vertical" : "horizontal";
}

static const char *source_name(uint32_t source) {
    switch (source) {
    case WL_POINTER_AXIS_SOURCE_WHEEL: return "wheel";
    case WL_POINTER_AXIS_SOURCE_FINGER: return "finger";
    case WL_POINTER_AXIS_SOURCE_CONTINUOUS: return "continuous";
    default: return "other";
    }
}

static void global(void *data, struct wl_registry *r, uint32_t name,
                   const char *iface, uint32_t version) {
    (void)data;
    if (strcmp(iface, "wl_compositor") == 0) {
        compositor = wl_registry_bind(r, name, &wl_compositor_interface, 1);
    } else if (strcmp(iface, "wl_shm") == 0) {
        shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
    } else if (strcmp(iface, "xdg_wm_base") == 0) {
        wm_base = wl_registry_bind(r, name, &xdg_wm_base_interface, 1);
    } else if (strcmp(iface, "wl_seat") == 0) {
        /* No higher than what is offered, which is the rule that makes a
           compositor advertising 4 a compositor this still runs against. */
        seat_version = version < 5 ? version : 5;
        seat = wl_registry_bind(r, name, &wl_seat_interface, seat_version);
    }
}

static void global_remove(void *data, struct wl_registry *r, uint32_t name) {
    (void)data; (void)r; (void)name;
}

static const struct wl_registry_listener registry_listener = { global, global_remove };

static void surface_configure(void *data, struct xdg_surface *s, uint32_t serial) {
    (void)data;
    xdg_surface_ack_configure(s, serial);
    configured = 1;
}

static const struct xdg_surface_listener surface_listener = { surface_configure };

static void toplevel_configure(void *d, struct xdg_toplevel *t, int32_t w,
                               int32_t h, struct wl_array *states) {
    (void)d; (void)t; (void)w; (void)h; (void)states;
}

static void toplevel_close(void *d, struct xdg_toplevel *t) { (void)d; (void)t; }

static const struct xdg_toplevel_listener toplevel_listener = {
    toplevel_configure, toplevel_close,
};

static void wm_base_ping(void *data, struct xdg_wm_base *b, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(b, serial);
}

static const struct xdg_wm_base_listener wm_base_listener = { wm_base_ping };

static void frame_done(void *data, struct wl_callback *c, uint32_t time);
static const struct wl_callback_listener frame_listener = { frame_done };

static void draw(void) {
    struct wl_callback *cb = wl_surface_frame(surface);
    wl_callback_add_listener(cb, &frame_listener, NULL);
    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_damage(surface, 0, 0, W, H);
    wl_surface_commit(surface);
}

static void frame_done(void *data, struct wl_callback *c, uint32_t time) {
    (void)data; (void)time;
    wl_callback_destroy(c);
    frames++;
    draw();
}

static void pt_enter(void *d, struct wl_pointer *p, uint32_t serial,
                     struct wl_surface *s, wl_fixed_t x, wl_fixed_t y) {
    (void)d; (void)p; (void)serial; (void)s;
    enters++;
    printf("pointer enter at %d %d\n", wl_fixed_to_int(x), wl_fixed_to_int(y));
}

static void pt_leave(void *d, struct wl_pointer *p, uint32_t serial,
                     struct wl_surface *s) {
    (void)d; (void)p; (void)serial; (void)s;
    printf("pointer leave\n");
}

static void pt_motion(void *d, struct wl_pointer *p, uint32_t time,
                      wl_fixed_t x, wl_fixed_t y) {
    (void)d; (void)p; (void)time; (void)x; (void)y;
}

static void pt_button(void *d, struct wl_pointer *p, uint32_t serial,
                      uint32_t time, uint32_t button, uint32_t state) {
    (void)d; (void)p; (void)serial; (void)time;
    printf("button %u %s\n", button, state ? "down" : "up");
}

static void pt_axis(void *d, struct wl_pointer *p, uint32_t time,
                    uint32_t axis, wl_fixed_t value) {
    (void)d; (void)p; (void)time;
    have_axis = 1;
    g_axis = axis;
    g_value = value;
    /* A client bound below 5 hears no frame, so there is nothing to wait for:
       the axis is the whole group. */
    if (seat_version < 5) {
        groups++;
        printf("axis %s %d.%02d (no frame: version %u)\n", axis_name(axis),
               wl_fixed_to_int(value), (value & 0xFF) * 100 / 256, seat_version);
        have_axis = 0;
    }
}

static void pt_frame(void *d, struct wl_pointer *p) {
    (void)d; (void)p;
    if (!have_axis && !have_stop) {
        /* A frame ending a group of motions or buttons, which is ordinary and
           not worth a line of its own. */
        have_source = have_discrete = 0;
        return;
    }
    if (have_stop) {
        printf("axis %s stop\n", axis_name(g_axis));
    } else {
        printf("axis %s %d.%02d", axis_name(g_axis), wl_fixed_to_int(g_value),
               (g_value & 0xFF) * 100 / 256);
        if (have_discrete) {
            printf(" discrete %d", g_discrete);
        }
        if (have_source) {
            printf(" source %s", source_name(g_source));
        }
        printf("\n");
    }
    groups++;
    have_axis = have_discrete = have_source = have_stop = 0;
}

static void pt_axis_source(void *d, struct wl_pointer *p, uint32_t source) {
    (void)d; (void)p;
    have_source = 1;
    g_source = source;
}

static void pt_axis_stop(void *d, struct wl_pointer *p, uint32_t time,
                         uint32_t axis) {
    (void)d; (void)p; (void)time;
    have_stop = 1;
    g_axis = axis;
}

static void pt_axis_discrete(void *d, struct wl_pointer *p, uint32_t axis,
                             int32_t discrete) {
    (void)d; (void)p; (void)axis;
    have_discrete = 1;
    g_discrete = discrete;
}

static void pt_axis_value120(void *d, struct wl_pointer *p, uint32_t axis,
                             int32_t value120) {
    (void)d; (void)p; (void)axis; (void)value120;
}

static void pt_axis_relative_direction(void *d, struct wl_pointer *p,
                                       uint32_t axis, uint32_t direction) {
    (void)d; (void)p; (void)axis; (void)direction;
}

static const struct wl_pointer_listener pt_listener = {
    .enter = pt_enter,
    .leave = pt_leave,
    .motion = pt_motion,
    .button = pt_button,
    .axis = pt_axis,
    .frame = pt_frame,
    .axis_source = pt_axis_source,
    .axis_stop = pt_axis_stop,
    .axis_discrete = pt_axis_discrete,
    .axis_value120 = pt_axis_value120,
    .axis_relative_direction = pt_axis_relative_direction,
};

static long now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);

    struct wl_display *d = wl_display_connect(NULL);
    if (!d) {
        printf("wlscroll: no display\n");
        return 1;
    }
    struct wl_registry *r = wl_display_get_registry(d);
    wl_registry_add_listener(r, &registry_listener, NULL);
    wl_display_roundtrip(d);
    if (!compositor || !shm || !wm_base || !seat) {
        printf("wlscroll: missing globals\n");
        return 1;
    }
    xdg_wm_base_add_listener(wm_base, &wm_base_listener, NULL);
    printf("seat: bound version %u\n", seat_version);

    int fd = memfd_create("wlscroll", 0);
    if (fd < 0 || ftruncate(fd, POOL_SIZE) < 0) {
        printf("wlscroll: no memfd\n");
        return 1;
    }
    pixels = mmap(NULL, POOL_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (pixels == MAP_FAILED) {
        printf("wlscroll: no mapping\n");
        return 1;
    }
    for (int i = 0; i < W * H; i++) {
        ((uint32_t *)pixels)[i] = 0xFF204060u;
    }
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, POOL_SIZE);
    buffer = wl_shm_pool_create_buffer(pool, 0, W, H, STRIDE,
                                       WL_SHM_FORMAT_XRGB8888);

    surface = wl_compositor_create_surface(compositor);
    struct xdg_surface *xs = xdg_wm_base_get_xdg_surface(wm_base, surface);
    xdg_surface_add_listener(xs, &surface_listener, NULL);
    struct xdg_toplevel *top = xdg_surface_get_toplevel(xs);
    xdg_toplevel_add_listener(top, &toplevel_listener, NULL);
    xdg_toplevel_set_title(top, "wlscroll");
    wl_surface_commit(surface);
    wl_display_roundtrip(d);
    if (!configured) {
        printf("wlscroll: never configured\n");
        return 1;
    }

    pointer = wl_seat_get_pointer(seat);
    wl_pointer_add_listener(pointer, &pt_listener, NULL);
    wl_display_roundtrip(d);
    printf("pointer: version %u\n", wl_proxy_get_version((struct wl_proxy *)pointer));

    draw();
    long deadline = now_s() + SECONDS;
    /* Blocking dispatch, woken by the frame callbacks this keeps asking for:
       the deadline is checked between events rather than by a timer, because
       a client with nothing to wait for is a client that has stopped drawing. */
    while (groups < GROUPS && now_s() < deadline) {
        if (wl_display_dispatch(d) == -1) {
            break;
        }
    }
    printf("wlscroll: %d axis groups, %d enters, %d frames\n", groups, enters,
           frames);
    wl_display_disconnect(d);
    return 0;
}
