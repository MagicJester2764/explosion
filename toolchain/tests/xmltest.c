// LINK: -lexpat
/* expat parses what fontconfig will hand it, and says where a bad document
   goes wrong. */
#include <stdio.h>
#include <string.h>
#include <expat.h>

static int failed;

static void check(const char *what, int ok) {
    printf("  %s  %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) {
        failed++;
    }
}

struct seen {
    int elements, dirs, prefixed;
    char text[256];
    size_t len;
    int in_dir;
};

static void start(void *u, const XML_Char *name, const XML_Char **attr) {
    struct seen *s = u;
    s->elements++;
    if (!strcmp(name, "dir")) {
        s->dirs++;
        s->in_dir = 1;
        for (int i = 0; attr[i]; i += 2) {
            if (!strcmp(attr[i], "prefix") && !strcmp(attr[i + 1], "xdg")) {
                s->prefixed++;
            }
        }
    }
}

static void end(void *u, const XML_Char *name) {
    struct seen *s = u;
    if (!strcmp(name, "dir")) {
        s->in_dir = 0;
        if (s->len < sizeof s->text - 1) {
            s->text[s->len++] = '|';
        }
    }
}

static void chars(void *u, const XML_Char *p, int n) {
    struct seen *s = u;
    if (s->in_dir) {
        for (int i = 0; i < n && s->len < sizeof s->text - 1; i++) {
            s->text[s->len++] = p[i];
        }
    }
}

static const char DOC[] =
    "<?xml version=\"1.0\"?>\n"
    "<!DOCTYPE fontconfig SYSTEM \"urn:fontconfig:fonts.dtd\">\n"
    "<fontconfig>\n"
    "  <dir>/usr/share/fonts</dir>\n"
    "  <dir prefix=\"xdg\">fonts</dir>\n"
    "  <match target=\"pattern\"><test name=\"family\"><string>mono &amp; co</string></test></match>\n"
    "</fontconfig>\n";

int main(void) {
    printf("expat %s:\n", XML_ExpatVersion());
    struct seen s = {0};
    XML_Parser p = XML_ParserCreate(NULL);
    XML_SetUserData(p, &s);
    XML_SetElementHandler(p, start, end);
    XML_SetCharacterDataHandler(p, chars);
    /* Fed in small pieces, so the parser's buffering is what is tested. */
    int ok = 1;
    for (size_t i = 0; i < sizeof DOC - 1; i += 7) {
        size_t n = sizeof DOC - 1 - i < 7 ? sizeof DOC - 1 - i : 7;
        ok &= XML_Parse(p, DOC + i, (int)n, 0) == XML_STATUS_OK;
    }
    ok &= XML_Parse(p, "", 0, 1) == XML_STATUS_OK;
    s.text[s.len] = 0;
    check("a fontconfig document parses in pieces", ok);
    check("with all six elements", s.elements == 6);
    check("and both directories", s.dirs == 2 && !strcmp(s.text, "/usr/share/fonts|fonts|"));
    check("and their attributes", s.prefixed == 1);
    XML_ParserFree(p);

    p = XML_ParserCreate(NULL);
    int bad = XML_Parse(p, "<a>\n<b></a>", 11, 1) == XML_STATUS_ERROR;
    check("a mismatched tag is an error", bad && XML_GetErrorCode(p) == XML_ERROR_TAG_MISMATCH);
    check("on line 2", XML_GetCurrentLineNumber(p) == 2);
    XML_ParserFree(p);
    printf("xmltest: %s\n", failed ? "FAILED" : "ok");
    return failed ? 1 : 0;
}
