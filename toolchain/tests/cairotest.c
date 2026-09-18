// LINK: -lcairo -lpixman-1 -lfontconfig -lfreetype -lexpat -lpng16 -lz -lm
/* cairo's image backend draws what it draws on Linux.
 *
 * A fixed scene — a gradient, an antialiased circle, a rotated square and a
 * Bézier curve — into a 200×200 image surface, and a CRC-32 of the pixels
 * compared with the one a host build of the same cairo and pixman produces.
 * Between them the four shapes go through gradients, the path rasteriser,
 * transforms and pixman's compositing, which is most of what a program asks
 * cairo for before it asks for text.
 *
 * With an argument, also writes the pixels there as a PPM, for comparing by
 * eye when the checksums disagree.
 *
 * Exits 0 only if the checksum matches.
 */
#include <cairo/cairo.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>

/* From a host build of the same cairo and pixman: see build-cairo.sh. */
#define EXPECTED 0xF0D42355u

static uint32_t crc32(const unsigned char *p, size_t n)
{
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; i++) {
        c ^= p[i];
        for (int k = 0; k < 8; k++)
            c = (c >> 1) ^ (0xEDB88320u & (uint32_t)-(int32_t)(c & 1));
    }
    return ~c;
}

static void write_ppm(const char *path, cairo_surface_t *s)
{
    FILE *f = fopen(path, "wb");
    if (!f) {
        printf("cairo: cannot write %s\n", path);
        return;
    }
    int w = cairo_image_surface_get_width(s);
    int h = cairo_image_surface_get_height(s);
    int stride = cairo_image_surface_get_stride(s);
    const unsigned char *data = cairo_image_surface_get_data(s);
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            /* ARGB32 in native byte order: B, G, R, A on this machine. */
            const unsigned char *px = data + y * stride + x * 4;
            unsigned char rgb[3] = { px[2], px[1], px[0] };
            fwrite(rgb, 1, 3, f);
        }
    }
    fclose(f);
}

int main(int argc, char **argv)
{
    cairo_surface_t *s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 200, 200);
    cairo_t *cr = cairo_create(s);

    cairo_pattern_t *g = cairo_pattern_create_linear(0, 0, 200, 200);
    cairo_pattern_add_color_stop_rgb(g, 0, 0.1, 0.2, 0.5);
    cairo_pattern_add_color_stop_rgb(g, 1, 0.9, 0.4, 0.1);
    cairo_set_source(cr, g);
    cairo_paint(cr);
    cairo_pattern_destroy(g);

    cairo_set_source_rgba(cr, 1, 1, 1, 0.7);
    cairo_arc(cr, 100, 100, 60, 0, 2 * M_PI);
    cairo_set_line_width(cr, 7.5);
    cairo_stroke(cr);

    cairo_save(cr);
    cairo_translate(cr, 100, 100);
    cairo_rotate(cr, M_PI / 7);
    cairo_rectangle(cr, -30, -30, 60, 60);
    cairo_set_source_rgb(cr, 0.2, 0.8, 0.3);
    cairo_fill(cr);
    cairo_restore(cr);

    cairo_move_to(cr, 10, 190);
    cairo_curve_to(cr, 60, 20, 140, 20, 190, 190);
    cairo_set_source_rgb(cr, 0.9, 0.1, 0.5);
    cairo_set_line_width(cr, 3);
    cairo_stroke(cr);

    cairo_surface_flush(s);
    uint32_t sum = crc32(cairo_image_surface_get_data(s),
                         (size_t)cairo_image_surface_get_stride(s) * 200);
    printf("cairo: checksum %08X, expected %08X\n", sum, EXPECTED);
    if (argc > 1)
        write_ppm(argv[1], s);
    cairo_destroy(cr);
    cairo_surface_destroy(s);
    return sum == EXPECTED ? 0 : 1;
}
