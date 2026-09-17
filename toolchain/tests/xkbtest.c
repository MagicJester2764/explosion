// LINK: -lxkbcommon
/* The keymap the compositor sends compiles, and turns keys into what a
   terminal needs: symbols, text, and modifiers. No XKB data files. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <xkbcommon/xkbcommon.h>

#define KEY(evdev) ((evdev) + 8)

static int failed;

static void check(const char *what, int ok) {
    printf("  %s  %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) {
        failed++;
    }
}

static int text_is(struct xkb_state *st, int evdev, const char *want) {
    char buf[8];
    xkb_state_key_get_utf8(st, KEY(evdev), buf, sizeof buf);
    return !strcmp(buf, want);
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "/usr/share/xkb/us.xkb";
    FILE *f = fopen(path, "rb");
    if (!f) {
        printf("xkbtest: cannot open %s\n", path);
        return 1;
    }
    static char text[1 << 20];
    size_t n = fread(text, 1, sizeof text - 1, f);
    fclose(f);
    text[n] = 0;

    printf("xkbcommon:\n");
    struct xkb_context *ctx =
        xkb_context_new(XKB_CONTEXT_NO_DEFAULT_INCLUDES | XKB_CONTEXT_NO_ENVIRONMENT_NAMES);
    check("a context with no data files", ctx != NULL);
    struct xkb_keymap *km =
        xkb_keymap_new_from_string(ctx, text, XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
    check("the compositor's keymap compiles", km != NULL);
    if (!km) {
        return 1;
    }
    check("with one layout", xkb_keymap_num_layouts(km) == 1);
    struct xkb_state *st = xkb_state_new(km);
    check("a is a", xkb_state_key_get_one_sym(st, KEY(30)) == XKB_KEY_a && text_is(st, 30, "a"));
    xkb_state_update_key(st, KEY(42), XKB_KEY_DOWN);
    check("shift is on", xkb_state_mod_name_is_active(st, XKB_MOD_NAME_SHIFT, XKB_STATE_MODS_EFFECTIVE) == 1);
    check("shift a is A", xkb_state_key_get_one_sym(st, KEY(30)) == XKB_KEY_A);
    check("shift 2 is @", xkb_state_key_get_one_sym(st, KEY(3)) == XKB_KEY_at && text_is(st, 3, "@"));
    xkb_state_update_key(st, KEY(42), XKB_KEY_UP);
    check("return is Return", xkb_state_key_get_one_sym(st, KEY(28)) == XKB_KEY_Return && text_is(st, 28, "\r"));
    xkb_state_update_key(st, KEY(58), XKB_KEY_DOWN);
    xkb_state_update_key(st, KEY(58), XKB_KEY_UP);
    check("caps lock locks", xkb_state_key_get_one_sym(st, KEY(30)) == XKB_KEY_A);
    xkb_state_update_key(st, KEY(58), XKB_KEY_DOWN);
    xkb_state_update_key(st, KEY(58), XKB_KEY_UP);
    xkb_state_update_key(st, KEY(29), XKB_KEY_DOWN);
    check("ctrl c is an interrupt", text_is(st, 46, "\x03"));
    xkb_state_update_key(st, KEY(29), XKB_KEY_UP);
    char *again = xkb_keymap_get_as_string(km, XKB_KEYMAP_FORMAT_TEXT_V1);
    struct xkb_keymap *km2 = again ? xkb_keymap_new_from_string(ctx, again, XKB_KEYMAP_FORMAT_TEXT_V1, 0) : NULL;
    check("and what it says it is compiles again", km2 != NULL);
    free(again);
    xkb_keymap_unref(km2);
    xkb_state_unref(st);
    xkb_keymap_unref(km);
    xkb_context_unref(ctx);
    printf("xkbtest: %s\n", failed ? "FAILED" : "ok");
    return failed ? 1 : 0;
}
