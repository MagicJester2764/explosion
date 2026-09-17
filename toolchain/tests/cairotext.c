// PKG: cairo-ft cairo-fc
/* Text drawn by cairo with glyphs FreeType rasterised from a font on disk —
   first from a face opened directly, which must match the host bit for bit,
   then through fontconfig, which must find DejaVu Sans. */
#include <stdio.h>
#include <string.h>
#include <cairo/cairo.h>
#include <cairo/cairo-ft.h>
#include <ft2build.h>
#include FT_FREETYPE_H

#define EXPECTED 0x9D2AB01Eu

static int failed;

static void check(const char *what, int ok) {
    printf("  %s  %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) {
        failed++;
    }
}

static unsigned fnv(const unsigned char *p, size_t n) {
    unsigned h = 2166136261u;
    while (n--) {
        h = (h ^ *p++) * 16777619u;
    }
    return h;
}

static cairo_t *canvas(cairo_surface_t **s) {
    *s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 320, 48);
    cairo_t *cr = cairo_create(*s);
    cairo_set_source_rgb(cr, 1, 1, 1);
    cairo_paint(cr);
    cairo_set_source_rgb(cr, 0, 0, 0);
    cairo_font_options_t *o = cairo_font_options_create();
    cairo_font_options_set_antialias(o, CAIRO_ANTIALIAS_GRAY);
    cairo_font_options_set_hint_style(o, CAIRO_HINT_STYLE_NONE);
    cairo_font_options_set_hint_metrics(o, CAIRO_HINT_METRICS_OFF);
    cairo_set_font_options(cr, o);
    cairo_font_options_destroy(o);
    cairo_set_font_size(cr, 24);
    cairo_move_to(cr, 8, 32);
    return cr;
}

static int inked(cairo_surface_t *s) {
    unsigned char *px = cairo_image_surface_get_data(s);
    int n = 0;
    for (int i = 0; i < 320 * 48; i++) {
        n += px[i * 4] < 128;
    }
    return n;
}

int main(int argc, char **argv) {
    const char *font = argc > 1 ? argv[1] : "/usr/share/fonts/dejavu/DejaVuSans.ttf";
    printf("cairo %s, text:\n", cairo_version_string());
    FT_Library lib;
    FT_Face face;
    if (FT_Init_FreeType(&lib) || FT_New_Face(lib, font, 0, &face)) {
        printf("cairotext: cannot open %s\n", font);
        return 1;
    }
    cairo_surface_t *s;
    cairo_t *cr = canvas(&s);
    cairo_font_face_t *ff = cairo_ft_font_face_create_for_ft_face(face, 0);
    cairo_set_font_face(cr, ff);
    cairo_show_text(cr, "Quark draws text.");
    cairo_surface_flush(s);
    unsigned sum = fnv(cairo_image_surface_get_data(s),
                       (size_t)cairo_image_surface_get_stride(s) * 48);
    printf("cairotext: checksum %08X, expected %08X\n", sum, EXPECTED);
    check("text from a face on disk matches the host", sum == EXPECTED);
    check("and put ink on the page", inked(s) > 200);
    cairo_destroy(cr);
    cairo_surface_destroy(s);
    cairo_font_face_destroy(ff);

    cr = canvas(&s);
    cairo_select_font_face(cr, "sans-serif", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_scaled_font_t *sf = cairo_get_scaled_font(cr);
    FT_Face chosen = cairo_ft_scaled_font_lock_face(sf);
    printf("cairotext: sans-serif is %s\n", chosen ? chosen->family_name : "not a FreeType font");
#ifdef __quark__
    check("sans-serif, through fontconfig, is DejaVu Sans",
          chosen && !strcmp(chosen->family_name, "DejaVu Sans"));
#endif
    if (chosen) {
        cairo_ft_scaled_font_unlock_face(sf);
    }
    cairo_show_text(cr, "Quark draws text.");
    cairo_surface_flush(s);
    check("and draws", inked(s) > 200);
    cairo_destroy(cr);
    cairo_surface_destroy(s);
    FT_Done_Face(face);
    FT_Done_FreeType(lib);
    printf("cairotext: %s\n", failed ? "FAILED" : "ok");
    return failed ? 1 : 0;
}
