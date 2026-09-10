/* What a Wayland client does before it draws anything.
 *
 * Upstream libwayland, unmodified: it connects through WAYLAND_SOCKET, asks
 * for the registry, binds what it finds, and makes a buffer pool out of
 * memory the compositor will read directly. Every step prints, because a
 * Wayland client that gets something wrong does not fail where it went wrong
 * — it waits.
 *
 * A roundtrip returning a count rather than -1 means the loop closed: the
 * client marshalled a request, the compositor parsed it off a stream and
 * answered, and the client's own dispatch believed the answer.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>

#define W 200
#define H 150
#define STRIDE (W * 4)
#define POOL_SIZE (STRIDE * H)

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static uint32_t formats;
static int count;

static void global(void *data, struct wl_registry *r, uint32_t name,
                   const char *iface, uint32_t version) {
    (void)data;
    printf("  global %u: %s v%u\n", name, iface, version);
    count++;
    if (strcmp(iface, "wl_compositor") == 0) {
        compositor = wl_registry_bind(r, name, &wl_compositor_interface, 1);
    } else if (strcmp(iface, "wl_shm") == 0) {
        shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
    }
}

static void global_remove(void *data, struct wl_registry *r, uint32_t name) {
    (void)data;
    (void)r;
    (void)name;
}

static const struct wl_registry_listener listener = { global, global_remove };

static void shm_format(void *data, struct wl_shm *s, uint32_t format) {
    (void)data;
    (void)s;
    printf("  format %u\n", format);
    formats++;
}

static const struct wl_shm_listener shm_listener = { shm_format };

/* Why the connection died. libwayland keeps this after a failed roundtrip, and
   without printing it a protocol error looks exactly like a hang. */
static void why(struct wl_display *d) {
    int e = wl_display_get_error(d);
    if (!e) {
        return;
    }
    const struct wl_interface *iface = NULL;
    uint32_t id = 0;
    uint32_t code = wl_display_get_protocol_error(d, &iface, &id);
    printf("  error: errno %d, %s id %u code %u\n", e,
           iface ? iface->name : "(none)", id, code);
}

int main(void) {
    /* Unbuffered: this prints onto a console the compositor is drawing over,
       and a line still sitting in a FILE buffer when something later hangs is
       a line you never see. */
    setvbuf(stdout, NULL, _IONBF, 0);

    struct wl_display *d = wl_display_connect(NULL);
    printf("connect: %s\n", d ? "OK" : "NULL");
    if (!d) {
        return 1;
    }
    struct wl_registry *r = wl_display_get_registry(d);
    wl_registry_add_listener(r, &listener, NULL);
    printf("roundtrip: %d\n", wl_display_roundtrip(d));
    printf("globals: %d compositor: %s shm: %s\n", count,
           compositor ? "OK" : "NULL", shm ? "OK" : "NULL");
    if (!compositor || !shm) {
        return 1;
    }

    wl_shm_add_listener(shm, &shm_listener, NULL);
    printf("formats roundtrip: %d\n", wl_display_roundtrip(d));
    printf("formats: %u\n", formats);

    /* The pool the way every client makes one: unnamed memory, sized after
       the fact, mapped here and handed over as a descriptor. */
    int fd = memfd_create("wlprobe", 0);
    printf("memfd: %d\n", fd);
    if (fd < 0) {
        return 1;
    }
    printf("ftruncate: %d\n", ftruncate(fd, POOL_SIZE));
    void *px = mmap(NULL, POOL_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    printf("mmap: %s\n", px == MAP_FAILED ? "FAILED" : "OK");
    if (px == MAP_FAILED) {
        return 1;
    }
    /* Something recognisable, so a later task can tell the compositor drew the
       client's pixels rather than its own idea of them. */
    for (int y = 0; y < H; y++) {
        uint32_t *row = (uint32_t *)((char *)px + y * STRIDE);
        for (int x = 0; x < W; x++) {
            row[x] = 0xFF000000u | ((uint32_t)x << 16) | ((uint32_t)y << 8) | 0x40;
        }
    }

    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, POOL_SIZE);
    printf("pool: %s\n", pool ? "OK" : "NULL");
    struct wl_buffer *buf =
        wl_shm_pool_create_buffer(pool, 0, W, H, STRIDE, WL_SHM_FORMAT_XRGB8888);
    printf("buffer: %s\n", buf ? "OK" : "NULL");
    printf("pool roundtrip: %d\n", wl_display_roundtrip(d));
    why(d);

    /* And the check that matters: a buffer that does not fit must be refused
       rather than composited out of memory that is not there. */
    struct wl_buffer *bad =
        wl_shm_pool_create_buffer(pool, POOL_SIZE - 4, W, H, STRIDE,
                                  WL_SHM_FORMAT_XRGB8888);
    (void)bad;
    printf("overrun roundtrip: %d (want -1)\n", wl_display_roundtrip(d));
    why(d);

    wl_display_disconnect(d);
    return 0;
}
