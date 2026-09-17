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
    (void)data; (void)t; (void)w; (void)h; (void)states;
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
    cairo_surface_t *s = cairo_image_surface_create_for_data(
        pixels[n], CAIRO_FORMAT_ARGB32, W, H, STRIDE);
    cairo_t *cr = cairo_create(s);

    cairo_pattern_t *g = cairo_pattern_create_linear(0, 0, W, H);
    cairo_pattern_add_color_stop_rgb(g, 0, 0.1, 0.2, 0.5);
    cairo_pattern_add_color_stop_rgb(g, 1, 0.9, 0.4, 0.1);
    cairo_set_source(cr, g);
    cairo_paint(cr);
    cairo_pattern_destroy(g);

    cairo_save(cr);
    cairo_translate(cr, W / 2.0, SCENE / 2.0);
    cairo_scale(cr, SCENE / 200.0, SCENE / 200.0);
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
    cairo_rectangle(cr, 0, SCENE, W, TEXT_H);
    cairo_set_source_rgba(cr, 0, 0, 0, 0.35);
    cairo_fill(cr);
    cairo_font_options_t *o = cairo_font_options_create();
    cairo_font_options_set_antialias(o, CAIRO_ANTIALIAS_GRAY);
    cairo_set_font_options(cr, o);
    cairo_font_options_destroy(o);
    cairo_set_source_rgb(cr, 1, 1, 1);
    cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, 18);
    cairo_move_to(cr, 12, SCENE + 26);
    cairo_show_text(cr, "Quark renders this with cairo, FreeType and fontconfig");
    cairo_select_font_face(cr, "monospace", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, 14);
    cairo_move_to(cr, 12, SCENE + 50);
    cairo_show_text(cr, "DejaVu Sans Mono, from /usr/share/fonts");

    cairo_destroy(cr);
    cairo_surface_flush(s);
    cairo_surface_destroy(s);
}

static void frame_done(void *data, struct wl_callback *c, uint32_t time);
static const struct wl_callback_listener frame_listener = { frame_done };

static void draw(int tick) {
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
    wl_surface_damage(surface, 0, 0, W, H);
    struct wl_callback *cb = wl_surface_frame(surface);
    wl_callback_add_listener(cb, &frame_listener, NULL);
    wl_surface_commit(surface);
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

    int fd = memfd_create("wlcairo", 0);
    if (fd < 0 || ftruncate(fd, POOL_SIZE * BUFFERS) < 0) {
        printf("wlcairo: no memory for a pool\n");
        return 1;
    }
    void *base = mmap(NULL, POOL_SIZE * BUFFERS, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (base == MAP_FAILED) {
        printf("wlcairo: cannot map the pool\n");
        return 1;
    }
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, POOL_SIZE * BUFFERS);
    for (int i = 0; i < BUFFERS; i++) {
        pixels[i] = (char *)base + i * POOL_SIZE;
        buffers[i] = wl_shm_pool_create_buffer(pool, i * POOL_SIZE, W, H, STRIDE,
                                               WL_SHM_FORMAT_XRGB8888);
        wl_buffer_add_listener(buffers[i], &buffer_listener, (void *)(long)i);
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
    while (wl_display_dispatch(d) != -1) {
        ;
    }
    why(d);
    wl_display_disconnect(d);
    return 0;
}
