// PKG: pangocairo
/* Text layout: a paragraph, not a string.
 *
 * harfbuzz shapes a run of one script in one font; pango is the layer that
 * decides what the runs *are* — itemisation, font selection through
 * fontconfig, the bidirectional algorithm, line breaking — and then draws the
 * result through cairo. GTK puts every character it shows through this.
 *
 * The checks are about the layout rather than about a golden image: that a
 * longer string is wider, that a width forces a wrap, that ink sits inside the
 * logical box, that the cursor walks forward through the text, and that
 * something was actually drawn. A checksum of the pixels is printed for a
 * future comparison but not asserted — there is no pango on the build machine
 * to ask.
 */

#include <cairo.h>
#include <pango/pangocairo.h>
#include <stdio.h>
#include <string.h>

static int failures;

static void check(const char *what, int ok) {
    printf("%s: %s\n", ok ? "ok" : "FAILED", what);
    if (!ok) {
        failures++;
    }
}

static unsigned long checksum(cairo_surface_t *s, int *dark) {
    cairo_surface_flush(s);
    const unsigned char *d = cairo_image_surface_get_data(s);
    int w = cairo_image_surface_get_width(s);
    int h = cairo_image_surface_get_height(s);
    int stride = cairo_image_surface_get_stride(s);
    unsigned long sum = 5381;
    *dark = 0;
    for (int y = 0; y < h; y++) {
        const unsigned int *row = (const unsigned int *)(d + (size_t)y * stride);
        for (int x = 0; x < w; x++) {
            sum = sum * 33 + row[x];
            if ((row[x] & 0xFF) < 0x80) {
                (*dark)++;
            }
        }
    }
    return sum & 0xFFFFFFFF;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("pangotest: pango %s\n", pango_version_string());

    cairo_surface_t *surf = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 400, 200);
    cairo_t *cr = cairo_create(surf);
    cairo_set_source_rgb(cr, 1, 1, 1);
    cairo_paint(cr);
    cairo_set_source_rgb(cr, 0, 0, 0);

    PangoLayout *layout = pango_cairo_create_layout(cr);
    check("a layout", layout != NULL);

    PangoFontDescription *desc = pango_font_description_from_string("DejaVu Sans 20");
    check("a font description", desc != NULL &&
                                   !strcmp(pango_font_description_get_family(desc), "DejaVu Sans") &&
                                   pango_font_description_get_size(desc) == 20 * PANGO_SCALE);
    pango_layout_set_font_description(layout, desc);

    /* The font has to be found, or every glyph is a box. */
    PangoContext *ctx = pango_layout_get_context(layout);
    PangoFont *font = pango_context_load_font(ctx, desc);
    check("the font is found", font != NULL);
    if (font) {
        PangoFontDescription *got = pango_font_describe(font);
        const char *family = pango_font_description_get_family(got);
        printf("   loaded \"%s\"\n", family ? family : "(none)");
        check("and it is the one asked for", family && !strcmp(family, "DejaVu Sans"));
        pango_font_description_free(got);
        g_object_unref(font);
    }

    int w1 = 0, h1 = 0, w2 = 0, h2 = 0;
    pango_layout_set_text(layout, "Hello", -1);
    pango_layout_get_pixel_size(layout, &w1, &h1);
    pango_layout_set_text(layout, "Hello, Quark", -1);
    pango_layout_get_pixel_size(layout, &w2, &h2);
    printf("   \"Hello\" is %dx%d, \"Hello, Quark\" is %dx%d\n", w1, h1, w2, h2);
    check("a longer line is wider", w1 > 0 && h1 > 0 && w2 > w1 && h2 == h1);

    /* Ink is inside the box the layout reports. */
    PangoRectangle ink, logical;
    pango_layout_get_pixel_extents(layout, &ink, &logical);
    check("ink sits inside the logical box",
          ink.x >= logical.x && ink.y >= logical.y &&
              ink.x + ink.width <= logical.x + logical.width + 1 &&
              ink.y + ink.height <= logical.y + logical.height + 1);

    /* The cursor walks forward, one character at a time. */
    PangoRectangle pos, prev = {0, 0, 0, 0};
    int forward = 1;
    for (int i = 0; i <= 5; i++) {
        pango_layout_index_to_pos(layout, i, &pos);
        if (i > 0 && pos.x <= prev.x) {
            forward = 0;
        }
        prev = pos;
    }
    check("the cursor moves forward through the text", forward);

    /* A width makes it wrap, which is the whole reason a layout is not a
       string. */
    pango_layout_set_text(layout,
                          "Quark is a microkernel, and this sentence is here to be "
                          "broken into several lines by the layout engine.",
                          -1);
    pango_layout_set_width(layout, 380 * PANGO_SCALE);
    pango_layout_set_wrap(layout, PANGO_WRAP_WORD);
    int lines = pango_layout_get_line_count(layout);
    printf("   wrapped into %d lines\n", lines);
    check("a paragraph wraps", lines >= 3);
    pango_layout_get_pixel_size(layout, &w2, &h2);
    check("and is no wider than it was told", w2 <= 380);

    cairo_move_to(cr, 10, 10);
    pango_cairo_show_layout(cr, layout);
    cairo_surface_flush(surf);

    int dark = 0;
    unsigned long sum = checksum(surf, &dark);
    printf("   %d dark pixels, checksum %lu\n", dark, sum);
    check("something was drawn", dark > 500 && dark < 400 * 200 / 2);

    g_object_unref(layout);
    pango_font_description_free(desc);
    cairo_destroy(cr);
    cairo_surface_destroy(surf);

    printf("pangotest: %d failed\n", failures);
    return failures ? 1 : 0;
}
