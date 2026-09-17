// LINK: -lfontconfig -lfreetype -lexpat -lz -lm
/* fontconfig finds the fonts on disk, answers the generic families with
   them, and uses the cache the image came with. */
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <fontconfig/fontconfig.h>

static int failed;

static void check(const char *what, int ok) {
    printf("  %s  %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) {
        failed++;
    }
}

static int matches(const char *pattern, const char *want) {
    FcPattern *p = FcNameParse((const FcChar8 *)pattern);
    FcConfigSubstitute(NULL, p, FcMatchPattern);
    FcDefaultSubstitute(p);
    FcResult r;
    FcPattern *m = FcFontMatch(NULL, p, &r);
    FcChar8 *file = NULL;
    int ok = m && FcPatternGetString(m, FC_FILE, 0, &file) == FcResultMatch
             && !strcmp((const char *)file, want);
    if (!ok) {
        printf("        %s gave %s\n", pattern, file ? (const char *)file : "nothing");
    }
    if (m) {
        FcPatternDestroy(m);
    }
    FcPatternDestroy(p);
    return ok;
}

int main(void) {
    printf("fontconfig %d:\n", FcGetVersion());
    check("initialise", FcInit());
    FcPattern *all = FcPatternCreate();
    FcObjectSet *os = FcObjectSetBuild(FC_FAMILY, FC_FILE, (char *)0);
    FcFontSet *fs = FcFontList(NULL, all, os);
    int sans = 0, mono = 0;
    for (int i = 0; fs && i < fs->nfont; i++) {
        FcChar8 *family;
        if (FcPatternGetString(fs->fonts[i], FC_FAMILY, 0, &family) == FcResultMatch) {
            sans += !strcmp((const char *)family, "DejaVu Sans");
            mono += !strcmp((const char *)family, "DejaVu Sans Mono");
        }
    }
    check("the fonts on disk are listed", fs && fs->nfont == 4);
    check("DejaVu Sans among them", sans == 2);
    check("and DejaVu Sans Mono", mono == 2);
    check("sans-serif is DejaVu Sans", matches("sans-serif", "/usr/share/fonts/dejavu/DejaVuSans.ttf"));
    check("bold is its bold face", matches("sans-serif:bold", "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf"));
    check("monospace is DejaVu Sans Mono", matches("monospace", "/usr/share/fonts/dejavu/DejaVuSansMono.ttf"));

    FcChar8 *cache_file = NULL;
    FcCache *cache = FcDirCacheLoad((const FcChar8 *)"/usr/share/fonts/dejavu", NULL, &cache_file);
    check("the directory's cache loads", cache != NULL);
    check("from /var/cache/fontconfig",
          cache_file && !strncmp((const char *)cache_file, "/var/cache/fontconfig/", 22));
#ifdef __quark__
    /* The cache came with the image: it is older than this boot. */
    struct timespec now, up;
    clock_gettime(CLOCK_REALTIME, &now);
    clock_gettime(CLOCK_MONOTONIC, &up);
    time_t booted = now.tv_sec - up.tv_sec;
    struct stat cst;
    check("the cache was built with the image",
          cache_file && stat((const char *)cache_file, &cst) == 0 && cst.st_mtime < booted);
#endif
    if (cache) {
        FcDirCacheUnload(cache);
    }
    FcFontSetDestroy(fs);
    FcObjectSetDestroy(os);
    FcPatternDestroy(all);
    FcFini();
    printf("fctest: %s\n", failed ? "FAILED" : "ok");
    return failed ? 1 : 0;
}
