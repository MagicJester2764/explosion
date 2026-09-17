/* A Wayland client that draws with cairo.
 *
 * The scene cairotest checksums — a gradient, a ring, a square and a curve —
 * drawn by cairo straight into the client's wl_shm buffers, with the square
 * turning so that a screendump shows the compositor is being handed new
 * frames, and two lines of text under it in the faces fontconfig picks for
 * sans-serif and monospace, rasterised by FreeType from fonts on the disk.
 * Nothing here writes a pixel itself.
 *
 * wlprobe's shape without the parts wlprobe exists to test: no seat, no
 * decoration, and nothing printed unless something failed.
 */
#define _GNU_SOURCE
#include <cairo/cairo.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>

#include "xdg-shell-client-protocol.h"

/* The scene's square, and the band of text under it. The first line is 485
   pixels wide. */
#define SCENE 240
#define TEXT_H 64
#define W 512
#define H (SCENE + TEXT_H)
#define STRIDE (W * 4)
#define POOL_SIZE (STRIDE * H)
/* Two buffers, so that one can be drawn into while the compositor reads the
   other. */
#define BUFFERS 2

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm_base;

static struct wl_surface *surface;
static struct wl_buffer *buffers[BUFFERS];
static void *pixels[BUFFERS];
static int busy[BUFFERS];
static int configured;
static int frames;

/* The size being drawn, and the size the compositor last asked for. A window
   here is whatever size it is told to be: the scene scales to fit it and the
   text band stays at the bottom. */
static int running = 1;
static int cw = W, ch = H;
static int want_w = W, want_h = H;
static int pending_resize;

/* The pool the buffers live in, kept so that a resize can build another one.
   A wl_shm pool cannot grow -- this compositor refuses `wl_shm_pool.resize`
   and says so -- so a new size means a new pool, and the old one goes when the
   compositor has the new buffer. */
static struct wl_shm_pool *pool;
static void *pool_base;
static size_t pool_bytes;
static int pool_fd = -1;
/* The previous set, waiting for the commit that replaces it. */
static struct wl_shm_pool *old_pool;
static struct wl_buffer *old_buffers[BUFFERS];
static void *old_base;
static size_t old_bytes;
static int old_fd = -1;

static void global(void *data, struct wl_registry *r, uint32_t name,
                   const char *iface, uint32_t version) {
    (void)data; (void)version;
    if (strcmp(iface, "wl_compositor") == 0) {
        compositor = wl_registry_bind(r, name, &wl_compositor_interface, 1);
    } else if (strcmp(iface, "wl_shm") == 0) {
        shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
    } else if (strcmp(iface, "xdg_wm_base") == 0) {
        wm_base = wl_registry_bind(r, name, &xdg_wm_base_interface, 1);
    }
}

static void global_remove(void *data, struct wl_registry *r, uint32_t name) {
    (void)data; (void)r; (void)name;
}

static const struct wl_registry_listener registry_listener = { global, global_remove };

/* Why the connection died. Without saying, a protocol error looks exactly like
   a hang. */
static void why(struct wl_display *d) {
    int e = wl_display_get_error(d);
    if (!e) {
        return;
    }
    const struct wl_interface *iface = NULL;
    uint32_t id = 0;
    uint32_t code = wl_display_get_protocol_error(d, &iface, &id);
    printf("wlcairo: errno %d, %s id %u code %u\n", e,
           iface ? iface->name : "(none)", id, code);
}

static void surface_configure(void *data, struct xdg_surface *s, uint32_t serial) {
    (void)data;
    xdg_surface_ack_configure(s, serial);
    configured = 1;
}

static const struct xdg_surface_listener surface_listener = { surface_configure };

static void toplevel_configure(void *data, struct xdg_toplevel *t, int32_t w,
                               int32_t h, struct wl_array *states) {
    (void)data; (void)t; (void)states;
    /* Zero means "you choose", and what this chooses is what it already has. */
    if (w <= 0 || h <= 0) {
        return;
    }
    if (w == want_w && h == want_h) {
        return;
    }
    want_w = w;
    want_h = h;
    /* Not here: the size changes on the next draw, so that the buffer being
       rebuilt is never the one the compositor is reading right now. */
    pending_resize = 1;
}

/* The compositor says somebody clicked the close box. Nothing obliges a
   client to go — a program with unsaved work is entitled to stay and ask —
   but this one has nothing to lose, so it goes. */
static void toplevel_close(void *data, struct xdg_toplevel *t) {
    (void)data; (void)t;
    running = 0;
}

static const struct xdg_toplevel_listener toplevel_listener = {
    toplevel_configure, toplevel_close,
};

static void buffer_release(void *data, struct wl_buffer *b) {
    (void)b;
    busy[(int)(long)data] = 0;
}

static const struct wl_buffer_listener buffer_listener = { buffer_release };

static void wm_base_ping(void *data, struct xdg_wm_base *b, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(b, serial);
}

static const struct xdg_wm_base_listener wm_base_listener = { wm_base_ping };

/* cairotest's scene, at cairotest's size and centred over the text, on a
   gradient that fills the window, with the square turning two degrees a
   frame. XRGB8888 is what the pool's buffers are, and cairo's ARGB32 has the
   same layout, so cairo draws into the buffer in place and nothing is
   copied. */
static void paint(int n, int tick) {
    /* The band of text at the bottom, and what is left above it for the scene.
       A window can be dragged down to almost nothing, so the band gives way
       rather than eating the whole window. */
    int band = ch > TEXT_H * 2 ? TEXT_H : ch / 2;
    int scene_h = ch - band;
    double scale = (cw < scene_h ? cw : scene_h) / 200.0;

    cairo_surface_t *s = cairo_image_surface_create_for_data(
        pixels[n], CAIRO_FORMAT_ARGB32, cw, ch, cw * 4);
    cairo_t *cr = cairo_create(s);

    cairo_pattern_t *g = cairo_pattern_create_linear(0, 0, cw, ch);
    cairo_pattern_add_color_stop_rgb(g, 0, 0.1, 0.2, 0.5);
    cairo_pattern_add_color_stop_rgb(g, 1, 0.9, 0.4, 0.1);
    cairo_set_source(cr, g);
    cairo_paint(cr);
    cairo_pattern_destroy(g);

    cairo_save(cr);
    cairo_translate(cr, cw / 2.0, scene_h / 2.0);
    cairo_scale(cr, scale, scale);
    cairo_translate(cr, -100, -100);

    cairo_set_source_rgba(cr, 1, 1, 1, 0.7);
    cairo_arc(cr, 100, 100, 60, 0, 2 * M_PI);
    cairo_set_line_width(cr, 7.5);
    cairo_stroke(cr);

    cairo_save(cr);
    cairo_translate(cr, 100, 100);
    cairo_rotate(cr, tick * M_PI / 90);
    cairo_rectangle(cr, -30, -30, 60, 60);
    cairo_set_source_rgb(cr, 0.2, 0.8, 0.3);
    cairo_fill(cr);
    cairo_restore(cr);

    cairo_move_to(cr, 10, 190);
    cairo_curve_to(cr, 60, 20, 140, 20, 190, 190);
    cairo_set_source_rgb(cr, 0.9, 0.1, 0.5);
    cairo_set_line_width(cr, 3);
    cairo_stroke(cr);
    cairo_restore(cr);

    /* The text, on a band dark enough to read it against either end of the
       gradient. The first frame is where fontconfig reads its cache, or
       scans the fonts if nothing has written one yet. */
    cairo_rectangle(cr, 0, scene_h, cw, band);
    cairo_set_source_rgba(cr, 0, 0, 0, 0.35);
    cairo_fill(cr);
    cairo_font_options_t *o = cairo_font_options_create();
    cairo_font_options_set_antialias(o, CAIRO_ANTIALIAS_GRAY);
    cairo_set_font_options(cr, o);
    cairo_font_options_destroy(o);
    cairo_set_source_rgb(cr, 1, 1, 1);
    cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, 18);
    cairo_move_to(cr, 12, scene_h + 26);
    cairo_show_text(cr, "Quark renders this with cairo, FreeType and fontconfig");
    cairo_select_font_face(cr, "monospace", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, 14);
    cairo_move_to(cr, 12, scene_h + 50);
    cairo_show_text(cr, "DejaVu Sans Mono, from /usr/share/fonts");

    cairo_destroy(cr);
    cairo_surface_flush(s);
    cairo_surface_destroy(s);
}

static void frame_done(void *data, struct wl_callback *c, uint32_t time);
static const struct wl_callback_listener frame_listener = { frame_done };

/* Build a pool and its buffers at a size. The previous set is put aside rather
   than destroyed: the compositor is still reading one of them, and it may go
   only after the commit that hands it the new one. */
static int build_pool(int w, int h) {
    size_t stride = (size_t)w * 4;
    size_t bytes = stride * (size_t)h * BUFFERS;
    int fd = memfd_create("wlcairo", 0);
    if (fd < 0 || ftruncate(fd, (off_t)bytes) < 0) {
        if (fd >= 0) {
            close(fd);
        }
        return 0;
    }
    void *base = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (base == MAP_FAILED) {
        close(fd);
        return 0;
    }
    struct wl_shm_pool *p = wl_shm_create_pool(shm, fd, (int32_t)bytes);
    old_pool = pool;
    old_base = pool_base;
    old_bytes = pool_bytes;
    old_fd = pool_fd;
    for (int i = 0; i < BUFFERS; i++) {
        old_buffers[i] = buffers[i];
    }
    pool = p;
    pool_base = base;
    pool_bytes = bytes;
    pool_fd = fd;
    for (int i = 0; i < BUFFERS; i++) {
        pixels[i] = (char *)base + (size_t)i * stride * (size_t)h;
        buffers[i] = wl_shm_pool_create_buffer(pool, (int32_t)((size_t)i * stride * (size_t)h),
                                               w, h, (int32_t)stride,
                                               WL_SHM_FORMAT_XRGB8888);
        wl_buffer_add_listener(buffers[i], &buffer_listener, (void *)(long)i);
        busy[i] = 0;
    }
    cw = w;
    ch = h;
    return 1;
}

/* Let the previous set go, after the commit that replaced it. Destroying a
   buffer the compositor is showing is allowed -- it keeps the pixels until it
   stops showing them -- and the order is what makes it safe: the attach and
   the commit are already on the wire ahead of these. */
static void drop_old_pool(void) {
    if (!old_pool) {
        return;
    }
    for (int i = 0; i < BUFFERS; i++) {
        if (old_buffers[i]) {
            wl_buffer_destroy(old_buffers[i]);
            old_buffers[i] = NULL;
        }
    }
    wl_shm_pool_destroy(old_pool);
    munmap(old_base, old_bytes);
    close(old_fd);
    old_pool = NULL;
    old_base = NULL;
    old_fd = -1;
}

static void draw(int tick) {
    if (pending_resize) {
        /* A failure here leaves the old size in place, which is a client that
           carries on rather than one that dies for want of memory. */
        if (build_pool(want_w, want_h)) {
            pending_resize = 0;
        } else {
            want_w = cw;
            want_h = ch;
            pending_resize = 0;
        }
    }
    int n = 0;
    while (n < BUFFERS && busy[n]) {
        n++;
    }
    if (n == BUFFERS) {
        return; /* both still held: the compositor has not released one yet */
    }
    paint(n, tick);
    busy[n] = 1;
    wl_surface_attach(surface, buffers[n], 0, 0);
    wl_surface_damage(surface, 0, 0, cw, ch);
    struct wl_callback *cb = wl_surface_frame(surface);
    wl_callback_add_listener(cb, &frame_listener, NULL);
    wl_surface_commit(surface);
    drop_old_pool();
}

static void frame_done(void *data, struct wl_callback *c, uint32_t time) {
    (void)data; (void)time;
    wl_callback_destroy(c);
    draw(++frames);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);

    struct wl_display *d = wl_display_connect(NULL);
    if (!d) {
        printf("wlcairo: no compositor\n");
        return 1;
    }
    struct wl_registry *r = wl_display_get_registry(d);
    wl_registry_add_listener(r, &registry_listener, NULL);
    wl_display_roundtrip(d);
    if (!compositor || !shm || !wm_base) {
        printf("wlcairo: the compositor lacks wl_compositor, wl_shm or xdg_wm_base\n");
        return 1;
    }
    xdg_wm_base_add_listener(wm_base, &wm_base_listener, NULL);

    if (!build_pool(W, H)) {
        printf("wlcairo: no memory for a pool\n");
        return 1;
    }

    surface = wl_compositor_create_surface(compositor);
    struct xdg_surface *xs = xdg_wm_base_get_xdg_surface(wm_base, surface);
    xdg_surface_add_listener(xs, &surface_listener, NULL);
    struct xdg_toplevel *top = xdg_surface_get_toplevel(xs);
    xdg_toplevel_add_listener(top, &toplevel_listener, NULL);
    xdg_toplevel_set_title(top, "wlcairo");
    wl_surface_commit(surface);
    wl_display_roundtrip(d);
    if (!configured) {
        why(d);
        printf("wlcairo: never configured\n");
        return 1;
    }

    draw(0);
    while (running && wl_display_dispatch(d) != -1) {
        ;
    }
    why(d);
    wl_display_disconnect(d);
    return 0;
}
