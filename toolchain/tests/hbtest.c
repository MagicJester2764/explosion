// PKG: harfbuzz
/* Shaping, which is what turns a string and a font into positioned glyphs.
 *
 * The font is read by harfbuzz itself rather than through FreeType: it has an
 * OpenType parser of its own, and using it means this test says something
 * about harfbuzz and nothing about anything under it.
 *
 * The numbers below come from the same harfbuzz built for the build machine —
 * build-harfbuzz.sh prints them — so this is a comparison against the shaper's
 * own answer elsewhere, not against a value somebody thought looked right.
 */

#include <hb.h>
#include <stdio.h>
#include <string.h>

#ifndef DEJAVU
#define DEJAVU "/usr/share/fonts/dejavu/DejaVuSans.ttf"
#endif

static int failures;

static void check(const char *what, int ok) {
    printf("%s: %s\n", ok ? "ok" : "FAILED", what);
    if (!ok) {
        failures++;
    }
}

/* Shape `text` and reduce the result to one number, so that a difference
   anywhere — a glyph, an advance, a cluster — is one difference to report. */
static unsigned long shape_sum(hb_font_t *font, const char *text, unsigned *n_out,
                               unsigned *first_advance) {
    hb_buffer_t *buf = hb_buffer_create();
    hb_buffer_add_utf8(buf, text, -1, 0, -1);
    hb_buffer_guess_segment_properties(buf);
    hb_shape(font, buf, NULL, 0);

    unsigned n = 0;
    hb_glyph_info_t *info = hb_buffer_get_glyph_infos(buf, &n);
    hb_glyph_position_t *pos = hb_buffer_get_glyph_positions(buf, NULL);

    unsigned long sum = 5381;
    for (unsigned i = 0; i < n; i++) {
        sum = sum * 33 + info[i].codepoint;
        sum = sum * 33 + info[i].cluster;
        sum = sum * 33 + (unsigned long)(pos[i].x_advance & 0xFFFF);
    }
    if (n_out) {
        *n_out = n;
    }
    if (first_advance && n > 0) {
        *first_advance = (unsigned)pos[0].x_advance;
    }
    hb_buffer_destroy(buf);
    return sum & 0xFFFFFFFF;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("hbtest: harfbuzz %s\n", hb_version_string());

    hb_blob_t *blob = hb_blob_create_from_file(DEJAVU);
    check("the font is readable", hb_blob_get_length(blob) > 100000);
    hb_face_t *face = hb_face_create(blob, 0);
    check("it is a face", hb_face_get_glyph_count(face) > 1000);
    hb_font_t *font = hb_font_create(face);
    hb_font_set_scale(font, 2048, 2048);

    unsigned n = 0, first = 0;
    unsigned long sum = shape_sum(font, "Hello, Quark", &n, &first);
    printf("   twelve characters: %u glyphs, sum %lu\n", n, sum);
    check("one glyph per character", n == 12);
    check("the shaped run is what it is elsewhere", sum == 920013085UL);

    /* Kerning is the plainest evidence that shaping happened at all: the
       advance of A depends on what follows it. */
    unsigned a_alone = 0, a_before_v = 0;
    shape_sum(font, "A", NULL, &a_alone);
    shape_sum(font, "AV", NULL, &a_before_v);
    printf("   A advances %u alone, %u before V\n", a_alone, a_before_v);
    check("A is kerned towards V", a_before_v < a_alone);

    /* And a substitution: DejaVu Sans maps f + i to one glyph. */
    unsigned fi = 0, f_only = 0;
    shape_sum(font, "fi", &fi, NULL);
    shape_sum(font, "f", &f_only, NULL);
    printf("   \"fi\" is %u glyph(s), \"f\" is %u\n", fi, f_only);
    check("f and i become one glyph", fi == 1 && f_only == 1);

    /* Nothing in the string is missing from the font. */
    hb_buffer_t *buf = hb_buffer_create();
    hb_buffer_add_utf8(buf, "Quark 64", -1, 0, -1);
    hb_buffer_guess_segment_properties(buf);
    hb_shape(font, buf, NULL, 0);
    unsigned m = 0;
    hb_glyph_info_t *info = hb_buffer_get_glyph_infos(buf, &m);
    int notdef = 0;
    for (unsigned i = 0; i < m; i++) {
        if (info[i].codepoint == 0) {
            notdef++;
        }
    }
    check("no character came out as .notdef", m == 8 && notdef == 0);
    check("the direction was guessed", hb_buffer_get_direction(buf) == HB_DIRECTION_LTR);
    check("and the script", hb_buffer_get_script(buf) == HB_SCRIPT_LATIN);
    hb_buffer_destroy(buf);

    hb_font_destroy(font);
    hb_face_destroy(face);
    hb_blob_destroy(blob);

    printf("hbtest: %d failed\n", failures);
    return failures ? 1 : 0;
}
