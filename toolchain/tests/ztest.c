// LINK: -lz
/* zlib, in memory and through a file. `ztest prepare` and `ztest verify`
   bracket a minigzip round trip in zlib.tests. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#define DATA "/tmp/zdata"
#define LEN (64 * 1024)

static int failed;

static void check(const char *what, int ok) {
    printf("  %s  %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) {
        failed++;
    }
}

/* Compressible and not trivially so. */
static void pattern(unsigned char *p, size_t n) {
    unsigned x = 12345;
    for (size_t i = 0; i < n; i++) {
        x = x * 1103515245u + 12345u;
        p[i] = (unsigned char)("quark zlib "[i % 11] ^ ((x >> 16) & 3));
    }
}

static int prepare(void) {
    unsigned char *p = malloc(LEN);
    pattern(p, LEN);
    FILE *f = fopen(DATA, "wb");
    int ok = f && fwrite(p, 1, LEN, f) == LEN;
    ok &= f && fclose(f) == 0;
    free(p);
    return ok ? 0 : 1;
}

static int verify(void) {
    unsigned char *want = malloc(LEN), *got = malloc(LEN + 1);
    pattern(want, LEN);
    FILE *f = fopen(DATA, "rb");
    size_t n = f ? fread(got, 1, LEN + 1, f) : 0;
    if (f) {
        fclose(f);
    }
    int ok = n == LEN && !memcmp(want, got, LEN);
    printf("ztest: %s after minigzip and back\n", ok ? "identical" : "DIFFERENT");
    free(want);
    free(got);
    return ok && remove(DATA) == 0 ? 0 : 1;
}

int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "prepare")) {
        return prepare();
    }
    if (argc > 1 && !strcmp(argv[1], "verify")) {
        return verify();
    }
    printf("zlib %s:\n", zlibVersion());
    check("crc32 of 123456789", crc32(0, (const Bytef *)"123456789", 9) == 0xCBF43926u);
    check("adler32 of Wikipedia", adler32(1, (const Bytef *)"Wikipedia", 9) == 0x11E60398u);

    unsigned char *src = malloc(LEN), *back = malloc(LEN);
    pattern(src, LEN);
    for (int level = 1; level <= 9; level += 4) {
        uLongf clen = compressBound(LEN);
        unsigned char *c = malloc(clen);
        uLongf blen = LEN;
        int ok = compress2(c, &clen, src, LEN, level) == Z_OK && clen < LEN
              && uncompress(back, &blen, c, clen) == Z_OK && blen == LEN && !memcmp(src, back, LEN);
        char what[64];
        snprintf(what, sizeof what, "level %d round trip (%lu bytes)", level, (unsigned long)clen);
        check(what, ok);
        free(c);
    }

    gzFile gz = gzopen("/tmp/ztest.gz", "wb");
    int wrote = gz && gzwrite(gz, src, LEN) == LEN && gzclose(gz) == Z_OK;
    check("write a gzip file", wrote);
    gz = gzopen("/tmp/ztest.gz", "rb");
    memset(back, 0, LEN);
    int read_back = gz && gzread(gz, back, LEN) == LEN && !memcmp(src, back, LEN);
    check("and read it back", read_back);
    check("to its end", gz && gzread(gz, back, 1) == 0 && gzeof(gz));
    if (gz) {
        gzclose(gz);
    }
    check("and remove it", remove("/tmp/ztest.gz") == 0);
    printf("ztest: %s\n", failed ? "FAILED" : "ok");
    return failed ? 1 : 0;
}
