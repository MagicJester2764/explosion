// PKG: freetype2
/* FreeType renders glyphs from a font on disk, exactly as it does on the
   host. The checksum covers every bitmap and metric, so a difference in the
   rasteriser, the hinter or the file shows. */
#include <stdio.h>
#include <string.h>
#include <ft2build.h>
#include FT_FREETYPE_H

/* What the same FreeType, built the same way, says on the host. */
#define EXPECTED 0x4E829DE6u
#define GLYPHS 6253

static unsigned fnv(unsigned h, const unsigned char *p, size_t n) {
    while (n--) {
        h = (h ^ *p++) * 16777619u;
    }
    return h;
}

static unsigned mix(unsigned h, long v) {
    return fnv(h, (const unsigned char *)&v, sizeof v);
}

int main(int argc, char **argv) {
    const char *font = argc > 1 ? argv[1] : "/usr/share/fonts/dejavu/DejaVuSans.ttf";
    FT_Library lib;
    FT_Face face;
    int failed = 0;
    if (FT_Init_FreeType(&lib) || FT_New_Face(lib, font, 0, &face)) {
        printf("fttest: cannot open %s\n", font);
        return 1;
    }
    printf("fttest: %s %s, %ld glyphs (expected %d)\n", face->family_name,
           face->style_name, face->num_glyphs, GLYPHS);
    failed |= strcmp(face->family_name, "DejaVu Sans") != 0;
    failed |= face->num_glyphs != GLYPHS;
    FT_Set_Pixel_Sizes(face, 0, 32);
    unsigned h = 2166136261u;
    for (const char *s = "Quark 13 renders text"; *s; s++) {
        if (FT_Load_Char(face, (unsigned char)*s, FT_LOAD_RENDER)) {
            failed = 1;
            continue;
        }
        FT_GlyphSlot g = face->glyph;
        h = mix(h, g->bitmap.width);
        h = mix(h, g->bitmap.rows);
        h = mix(h, g->bitmap_left);
        h = mix(h, g->bitmap_top);
        h = mix(h, g->advance.x);
        for (unsigned r = 0; r < g->bitmap.rows; r++) {
            h = fnv(h, g->bitmap.buffer + r * (unsigned)g->bitmap.pitch, g->bitmap.width);
        }
    }
    printf("fttest: checksum %08X, expected %08X\n", h, EXPECTED);
    failed |= h != EXPECTED;
    FT_Done_Face(face);
    FT_Done_FreeType(lib);
    printf("fttest: %s\n", failed ? "FAILED" : "ok");
    return failed;
}
