/* wlfuzz: a Wayland client that breaks the rules, to show the compositor
 * survives it.
 *
 *     wlfuzz SEED MESSAGES
 *
 * It speaks the wire format itself -- libwayland would refuse to send most of
 * this -- on the connection WAYLAND_SOCKET names. After a get_registry and a
 * sync it sends MESSAGES requests made from SEED: mostly requests of the right
 * shape on objects it made, with arguments anywhere from sensible to absurd,
 * and now and then one that is wrong in shape -- a size shorter than a
 * header, odd, or past what was sent; a string whose length lies or that has
 * no NUL; an array with a bad length; a descriptor nothing asked for, or none
 * where one is needed. Along the way it builds windows properly, and then
 * makes pools bigger than their memory, pools of things that are not memory,
 * and attaches buffers it has destroyed.
 *
 * It stops when the compositor closes the connection, says how far it got and
 * whether the compositor said why, and exits 0 either way: the test is whether
 * the compositor lives.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <unistd.h>

/* -- randomness ----------------------------------------------------------- */

static uint64_t rng;

static uint64_t rnd(void) {
    uint64_t x = rng;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    rng = x;
    return x * 0x2545F4914F6CDD1DULL;
}

static uint32_t below(uint32_t n) { return (uint32_t)(rnd() % n); }

/* -- what the compositor offers, and what this client has made ------------ */

enum kind {
    K_NONE, K_DISPLAY, K_REGISTRY, K_CALLBACK, K_COMPOSITOR, K_SHM, K_POOL,
    K_BUFFER, K_SURFACE, K_REGION, K_WM_BASE, K_XDG_SURFACE, K_TOPLEVEL,
    K_POSITIONER, K_SEAT, K_POINTER, K_KEYBOARD, K_TOUCH, K_OUTPUT, K_DDM,
    K_SOURCE, K_DEVICE, K_OFFER, K_DECO_MGR, K_DECO, K_POPUP, K_COUNT,
};

/* A request's arguments: n new id, o object, O object or null, u uint,
   i int, s string, S string or null, a array, h descriptor. `obj` is the kind
   each o or O in turn should be, `makes` what the new id becomes. */
struct req {
    const char *sig;
    enum kind makes;
    int destroys;
    enum kind obj[3];
};

#define DESTRUCTOR {"", K_NONE, 1, {0}}

static const struct req display_reqs[] = {
    {"n", K_CALLBACK, 0, {0}}, {"n", K_REGISTRY, 0, {0}},
};
static const struct req registry_reqs[] = {{"usun", K_NONE, 0, {0}}};
static const struct req compositor_reqs[] = {
    {"n", K_SURFACE, 0, {0}}, {"n", K_REGION, 0, {0}},
};
static const struct req shm_reqs[] = {{"nhi", K_POOL, 0, {0}}, DESTRUCTOR};
static const struct req pool_reqs[] = {
    {"niiiiu", K_BUFFER, 0, {0}}, DESTRUCTOR, {"i", K_NONE, 0, {0}},
};
static const struct req buffer_reqs[] = {DESTRUCTOR};
static const struct req surface_reqs[] = {
    DESTRUCTOR,
    {"Oii", K_NONE, 0, {K_BUFFER}},
    {"iiii", K_NONE, 0, {0}},
    {"n", K_CALLBACK, 0, {0}},
    {"O", K_NONE, 0, {K_REGION}},
    {"O", K_NONE, 0, {K_REGION}},
    {"", K_NONE, 0, {0}},
    {"i", K_NONE, 0, {0}},
    {"i", K_NONE, 0, {0}},
    {"iiii", K_NONE, 0, {0}},
    {"ii", K_NONE, 0, {0}},
};
static const struct req region_reqs[] = {
    DESTRUCTOR, {"iiii", K_NONE, 0, {0}}, {"iiii", K_NONE, 0, {0}},
};
static const struct req wm_base_reqs[] = {
    DESTRUCTOR,
    {"n", K_POSITIONER, 0, {0}},
    {"no", K_XDG_SURFACE, 0, {K_SURFACE}},
    {"u", K_NONE, 0, {0}},
};
static const struct req xdg_surface_reqs[] = {
    DESTRUCTOR,
    {"n", K_TOPLEVEL, 0, {0}},
    {"nOo", K_POPUP, 0, {K_XDG_SURFACE, K_POSITIONER}},
    {"iiii", K_NONE, 0, {0}},
    {"u", K_NONE, 0, {0}},
};
static const struct req toplevel_reqs[] = {
    DESTRUCTOR,
    {"O", K_NONE, 0, {K_TOPLEVEL}},
    {"s", K_NONE, 0, {0}},
    {"s", K_NONE, 0, {0}},
    {"ouii", K_NONE, 0, {K_SEAT}},
    {"ou", K_NONE, 0, {K_SEAT}},
    {"ouu", K_NONE, 0, {K_SEAT}},
    {"ii", K_NONE, 0, {0}},
    {"ii", K_NONE, 0, {0}},
    {"", K_NONE, 0, {0}},
    {"", K_NONE, 0, {0}},
    {"O", K_NONE, 0, {K_OUTPUT}},
    {"", K_NONE, 0, {0}},
    {"", K_NONE, 0, {0}},
};
static const struct req positioner_reqs[] = {
    DESTRUCTOR,
    {"ii", K_NONE, 0, {0}},
    {"iiii", K_NONE, 0, {0}},
    {"u", K_NONE, 0, {0}},
    {"u", K_NONE, 0, {0}},
    {"u", K_NONE, 0, {0}},
    {"ii", K_NONE, 0, {0}},
};
static const struct req seat_reqs[] = {
    {"n", K_POINTER, 0, {0}},
    {"n", K_KEYBOARD, 0, {0}},
    {"n", K_TOUCH, 0, {0}},
    DESTRUCTOR,
};
static const struct req pointer_reqs[] = {
    {"uOii", K_NONE, 0, {K_SURFACE}}, DESTRUCTOR,
};
static const struct req release_only[] = {DESTRUCTOR};
static const struct req ddm_reqs[] = {
    {"n", K_SOURCE, 0, {0}}, {"no", K_DEVICE, 0, {K_SEAT}},
};
static const struct req source_reqs[] = {
    {"s", K_NONE, 0, {0}}, DESTRUCTOR, {"u", K_NONE, 0, {0}},
};
static const struct req device_reqs[] = {
    {"OoOu", K_NONE, 0, {K_SOURCE, K_SURFACE, K_SURFACE}},
    {"Ou", K_NONE, 0, {K_SOURCE}},
    DESTRUCTOR,
};
static const struct req offer_reqs[] = {
    {"uS", K_NONE, 0, {0}},
    {"sh", K_NONE, 0, {0}},
    DESTRUCTOR,
    {"", K_NONE, 0, {0}},
    {"uu", K_NONE, 0, {0}},
};
static const struct req deco_mgr_reqs[] = {
    DESTRUCTOR, {"no", K_DECO, 0, {K_TOPLEVEL}},
};
static const struct req deco_reqs[] = {
    DESTRUCTOR, {"u", K_NONE, 0, {0}}, {"", K_NONE, 0, {0}},
};

struct iface {
    const char *name;
    const struct req *reqs;
    int nreqs;
};

#define IFACE(n, r) {n, r, (int)(sizeof(r) / sizeof(r[0]))}
static const struct iface ifaces[K_COUNT] = {
    [K_DISPLAY] = IFACE("wl_display", display_reqs),
    [K_REGISTRY] = IFACE("wl_registry", registry_reqs),
    [K_COMPOSITOR] = IFACE("wl_compositor", compositor_reqs),
    [K_SHM] = IFACE("wl_shm", shm_reqs),
    [K_POOL] = IFACE("wl_shm_pool", pool_reqs),
    [K_BUFFER] = IFACE("wl_buffer", buffer_reqs),
    [K_SURFACE] = IFACE("wl_surface", surface_reqs),
    [K_REGION] = IFACE("wl_region", region_reqs),
    [K_WM_BASE] = IFACE("xdg_wm_base", wm_base_reqs),
    [K_XDG_SURFACE] = IFACE("xdg_surface", xdg_surface_reqs),
    [K_TOPLEVEL] = IFACE("xdg_toplevel", toplevel_reqs),
    [K_POSITIONER] = IFACE("xdg_positioner", positioner_reqs),
    [K_SEAT] = IFACE("wl_seat", seat_reqs),
    [K_POINTER] = IFACE("wl_pointer", pointer_reqs),
    [K_KEYBOARD] = IFACE("wl_keyboard", release_only),
    [K_TOUCH] = IFACE("wl_touch", release_only),
    [K_OUTPUT] = IFACE("wl_output", release_only),
    [K_DDM] = IFACE("wl_data_device_manager", ddm_reqs),
    [K_SOURCE] = IFACE("wl_data_source", source_reqs),
    [K_DEVICE] = IFACE("wl_data_device", device_reqs),
    [K_OFFER] = IFACE("wl_data_offer", offer_reqs),
    [K_DECO_MGR] = IFACE("zxdg_decoration_manager_v1", deco_mgr_reqs),
    [K_DECO] = IFACE("zxdg_toplevel_decoration_v1", deco_reqs),
};

#define MAX_OBJECTS 512
static struct {
    uint32_t id;
    enum kind kind;
    int dead;
} objects[MAX_OBJECTS];
static int nobjects;
static uint32_t next_id = 2;

static void remember(uint32_t id, enum kind kind) {
    for (int i = 0; i < nobjects; i++) {
        if (objects[i].id == id) {
            objects[i].kind = kind;
            objects[i].dead = 0;
            return;
        }
    }
    if (nobjects < MAX_OBJECTS) {
        objects[nobjects].id = id;
        objects[nobjects].kind = kind;
        objects[nobjects].dead = 0;
        nobjects++;
    }
}

static void forget(uint32_t id) {
    for (int i = 0; i < nobjects; i++) {
        if (objects[i].id == id) {
            objects[i].dead = 1;
        }
    }
}

static enum kind kind_of(uint32_t id) {
    for (int i = 0; i < nobjects; i++) {
        if (objects[i].id == id && !objects[i].dead) {
            return objects[i].kind;
        }
    }
    return K_NONE;
}

/* A live object of `kind`, or of any kind, or 0. */
static uint32_t pick(enum kind kind) {
    uint32_t found[MAX_OBJECTS];
    int n = 0;
    for (int i = 0; i < nobjects; i++) {
        if (!objects[i].dead && (kind == K_NONE || objects[i].kind == kind)) {
            found[n++] = objects[i].id;
        }
    }
    return n ? found[below(n)] : 0;
}

/* A dead object's id, which the compositor has forgotten or should have. */
static uint32_t pick_dead(void) {
    for (int tries = 0; tries < 8 && nobjects; tries++) {
        int i = below(nobjects);
        if (objects[i].dead) {
            return objects[i].id;
        }
    }
    return 0;
}

/* The globals the registry announced: the name number and the version each
   was offered at, by kind. Binding above the version offered is a protocol
   error, so the versions are what the opening binds use — a fuzzer that is
   thrown out in its first four messages fuzzes nothing. */
static uint32_t global_name[K_COUNT];
static uint32_t global_version[K_COUNT];
/* The last configure serial, so that some acks are right. */
static uint32_t last_serial;

/* -- the connection -------------------------------------------------------- */

static int sock = -1;
/* The peer has gone: a read reached the end of the stream. */
static int closed;
/* Nothing more can be sent, which is not the same thing — the compositor may
   have an error waiting to be read after it stopped taking requests. */
static int stopped;
static int told_error;
static uint32_t error_object, error_code;
static char error_text[128];

static void read_events(void);

/* Send `len` bytes, with `fd` alongside if it is not -1. False once the
   compositor has gone. */
static int send_bytes(const uint8_t *buf, size_t len, int fd) {
    size_t done = 0;
    int tries = 0;
    while (done < len && !closed && !stopped) {
        struct iovec iov = {(void *)(buf + done), len - done};
        struct msghdr m = {0};
        char control[CMSG_SPACE(sizeof(int))];
        m.msg_iov = &iov;
        m.msg_iovlen = 1;
        if (fd >= 0 && done == 0) {
            struct cmsghdr *c = (struct cmsghdr *)control;
            memset(control, 0, sizeof(control));
            c->cmsg_len = CMSG_LEN(sizeof(int));
            c->cmsg_level = SOL_SOCKET;
            c->cmsg_type = SCM_RIGHTS;
            memcpy(CMSG_DATA(c), &fd, sizeof(int));
            m.msg_control = control;
            m.msg_controllen = sizeof(control);
        }
        ssize_t n = sendmsg(sock, &m, MSG_DONTWAIT);
        if (n < 0 && errno == EAGAIN) {
            /* The compositor is behind. Take what it has sent, so that it
               can make progress, and try again for a while. */
            read_events();
            if (++tries > 2000) {
                stopped = 1;
                return 0;
            }
            usleep(1000);
            continue;
        }
        if (n <= 0) {
            stopped = 1;
            return 0;
        }
        done += (size_t)n;
    }
    return !closed && !stopped;
}

static uint32_t get32(const uint8_t *p) {
    uint32_t v;
    memcpy(&v, p, 4);
    return v;
}

static uint8_t inbuf[16384];
static size_t inlen;

/* Take whatever the compositor has sent, and act on the few events that
   matter here. */
static void read_events(void) {
    while (!closed) {
        if (inlen == sizeof(inbuf)) {
            inlen = 0; /* an event bigger than this is nonsense anyway */
        }
        struct iovec iov = {inbuf + inlen, sizeof(inbuf) - inlen};
        char control[CMSG_SPACE(sizeof(int))];
        struct msghdr m = {0};
        m.msg_iov = &iov;
        m.msg_iovlen = 1;
        m.msg_control = control;
        m.msg_controllen = sizeof(control);
        ssize_t n = recvmsg(sock, &m, MSG_DONTWAIT);
        if (n < 0 && errno == EAGAIN) {
            break;
        }
        if (n <= 0) {
            closed = 1;
            break;
        }
        if (m.msg_controllen >= CMSG_LEN(sizeof(int))) {
            int fd;
            memcpy(&fd, CMSG_DATA((struct cmsghdr *)control), sizeof(int));
            close(fd); /* a keymap or a transfer: not wanted */
        }
        inlen += (size_t)n;
        size_t at = 0;
        while (inlen - at >= 8) {
            uint32_t object = get32(inbuf + at);
            uint32_t word = get32(inbuf + at + 4);
            uint16_t opcode = word & 0xFFFF;
            uint16_t size = word >> 16;
            if (size < 8) {
                closed = 1; /* the compositor has lost its place, or ours */
                return;
            }
            if (inlen - at < size) {
                break;
            }
            const uint8_t *args = inbuf + at + 8;
            size_t alen = size - 8;
            enum kind k = kind_of(object);
            if (object == 1 && opcode == 0 && alen >= 12) {
                told_error = 1;
                error_object = get32(args);
                error_code = get32(args + 4);
                uint32_t slen = get32(args + 8);
                if (slen > 0 && slen <= alen - 12) {
                    size_t copy = slen < sizeof(error_text) ? slen : sizeof(error_text) - 1;
                    memcpy(error_text, args + 12, copy);
                    error_text[copy] = 0;
                }
            } else if (object == 1 && opcode == 1 && alen >= 4) {
                forget(get32(args)); /* delete_id */
            } else if (k == K_REGISTRY && opcode == 0 && alen >= 8) {
                uint32_t name = get32(args);
                uint32_t slen = get32(args + 4);
                if (slen > 0 && slen <= alen - 8) {
                    const char *iface = (const char *)args + 8;
                    uint32_t version = alen >= 8 + slen ? get32(args + 4 + 4 + ((slen + 3) & ~3u)) : 1;
                    for (int i = 0; i < K_COUNT; i++) {
                        if (ifaces[i].name && strncmp(iface, ifaces[i].name, slen) == 0) {
                            global_name[i] = name;
                            global_version[i] = version ? version : 1;
                        }
                    }
                }
            } else if (k == K_XDG_SURFACE && opcode == 0 && alen >= 4) {
                last_serial = get32(args);
            } else if (k == K_DEVICE && opcode == 0 && alen >= 4) {
                remember(get32(args), K_OFFER); /* data_offer, named by the compositor */
            }
            at += size;
        }
        memmove(inbuf, inbuf + at, inlen - at);
        inlen -= at;
    }
}

/* -- building requests ----------------------------------------------------- */

static uint8_t msg[8192];
static size_t mlen;
static int msg_fd = -1;

static void put32(uint32_t v) {
    if (mlen + 4 <= sizeof(msg)) {
        memcpy(msg + mlen, &v, 4);
        mlen += 4;
    }
}

static void put_bytes(const uint8_t *p, size_t n) {
    while (n-- && mlen < sizeof(msg)) {
        msg[mlen++] = *p++;
    }
}

static void pad(void) {
    while (mlen % 4 && mlen < sizeof(msg)) {
        msg[mlen++] = 0;
    }
}

/* A descriptor to send: memory of some size, or something that is not
   memory at all. */
static int make_fd(size_t size) {
    int fds[2];
    switch (below(6)) {
    case 0:
        if (pipe(fds) == 0) {
            close(fds[1]);
            return fds[0];
        }
        return -1;
    case 1:
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0) {
            close(fds[1]);
            return fds[0];
        }
        return -1;
    default: {
        int fd = memfd_create("wlfuzz", 0);
        if (fd >= 0 && size) {
            ftruncate(fd, (off_t)size);
        }
        return fd;
    }
    }
}

static uint32_t uint_arg(void) {
    switch (below(8)) {
    case 0: return 0;
    case 1: return 0xFFFFFFFFu;
    case 2: return last_serial;
    case 3: return last_serial + 1;
    case 4: return (uint32_t)rnd();
    default: return below(8);
    }
}

static int32_t int_arg(void) {
    switch (below(10)) {
    case 0: return 0;
    case 1: return -1;
    case 2: return INT32_MIN;
    case 3: return INT32_MAX;
    case 4: return (int32_t)rnd();
    case 5: return -(int32_t)below(5000);
    case 6: return (int32_t)below(1 << 20);
    default: return 1 + (int32_t)below(400);
    }
}

static void string_arg(int nullable) {
    if (nullable && below(4) == 0) {
        put32(0);
        return;
    }
    char s[96];
    size_t n = below(sizeof(s) - 1);
    for (size_t i = 0; i < n; i++) {
        s[i] = below(16) == 0 ? (char)(rnd() & 0xFF) : (char)('a' + below(26));
    }
    s[n] = 0;
    switch (below(24)) {
    case 0: /* a length that says more than there is */
        put32((uint32_t)n + 1 + below(1 << 16));
        put_bytes((uint8_t *)s, n + 1);
        break;
    case 1: /* no NUL */
        put32((uint32_t)n);
        put_bytes((uint8_t *)s, n);
        break;
    case 2: /* a huge length */
        put32(0xFFFFFFF0u);
        put_bytes((uint8_t *)s, n + 1);
        break;
    case 3: /* a NUL in the middle */
        if (n > 2) {
            s[n / 2] = 0;
        }
        put32((uint32_t)n + 1);
        put_bytes((uint8_t *)s, n + 1);
        break;
    default:
        put32((uint32_t)n + 1);
        put_bytes((uint8_t *)s, n + 1);
        break;
    }
    pad();
}

static void array_arg(void) {
    uint8_t a[64];
    size_t n = below(sizeof(a));
    for (size_t i = 0; i < n; i++) {
        a[i] = (uint8_t)rnd();
    }
    switch (below(8)) {
    case 0: put32((uint32_t)n + 1 + below(4096)); break;
    case 1: put32(0xFFFFFFFFu); break;
    default: put32((uint32_t)n); break;
    }
    put_bytes(a, n);
    pad();
}

static uint32_t object_arg(enum kind want, int nullable) {
    switch (below(12)) {
    case 0: return nullable ? 0 : pick(want);
    case 1: return pick(K_NONE);
    case 2: return pick_dead();
    case 3: return (uint32_t)rnd();
    case 4: return 1;
    default: return pick(want);
    }
}

static uint32_t new_id_arg(void) {
    switch (below(24)) {
    case 0: return 0;
    case 1: return pick(K_NONE); /* in use */
    case 2: return (uint32_t)rnd();
    case 3: return 0xFF000001u; /* the compositor's half */
    default: return next_id++;
    }
}

/* Finish the message: its header's size is usually right. */
static int finish(uint32_t object, uint16_t opcode) {
    uint16_t size = (uint16_t)mlen;
    size_t send_len = mlen;
    if (below(40) == 0) {
        switch (below(5)) {
        case 0: size = (uint16_t)below(8); break;          /* shorter than a header */
        case 1: size = (uint16_t)(mlen + 1 + below(3)); break; /* odd, or past the end */
        case 2: size = (uint16_t)(mlen + 64 + below(256)); break; /* past what was sent */
        case 3: send_len = mlen > 8 ? 8 + below(mlen - 8) : mlen; size = (uint16_t)send_len; break;
        default: size = (uint16_t)(8 + 4 * below(8)); break; /* too short for its arguments */
        }
    }
    uint32_t word = ((uint32_t)size << 16) | opcode;
    memcpy(msg, &object, 4);
    memcpy(msg + 4, &word, 4);
    /* A descriptor nothing asked for, now and then. */
    if (msg_fd < 0 && below(30) == 0) {
        msg_fd = make_fd(4096 * below(4));
    }
    int ok = send_bytes(msg, send_len, msg_fd);
    if (msg_fd >= 0) {
        close(msg_fd);
        msg_fd = -1;
    }
    return ok;
}

static int bind_global(enum kind kind, uint32_t version);

/* A bind that is legal: the name, interface and version the registry
   offered. Mostly what the fuzzer sends on a registry, because a bind the
   compositor is right to refuse ends the connection — and a session thrown
   out in its third message fuzzes nothing. */
static int legal_bind(void) {
    enum kind have[K_COUNT];
    int n = 0;
    for (int i = 0; i < K_COUNT; i++) {
        if (global_name[i]) {
            have[n++] = (enum kind)i;
        }
    }
    if (!n) {
        return 1;
    }
    enum kind k = have[below(n)];
    return bind_global(k, 1 + below(global_version[k]));
}

/* One request on `object`, which is of `kind`. */
static int request(uint32_t object, enum kind kind) {
    if (kind == K_REGISTRY && below(4) != 0) {
        return legal_bind();
    }
    const struct iface *f = &ifaces[kind];
    int opcode;
    if (!f->nreqs || below(20) == 0) {
        opcode = below(4) == 0 ? (int)(rnd() & 0xFFFF) : (int)below(21);
    } else {
        opcode = (int)below((uint32_t)f->nreqs);
    }
    const struct req *r = opcode < f->nreqs ? &f->reqs[opcode] : NULL;
    const char *sig = r ? r->sig : "uuuu";
    mlen = 8;
    int objn = 0;
    uint32_t made = 0;
    int32_t pool_size = 0;
    for (const char *c = sig; *c; c++) {
        switch (*c) {
        case 'n':
            made = new_id_arg();
            put32(made);
            break;
        case 'o':
        case 'O':
            put32(object_arg(r && objn < 3 ? r->obj[objn] : K_NONE, *c == 'O'));
            objn++;
            break;
        case 'u':
            if (kind == K_REGISTRY) {
                /* bind: name first, version after the interface */
                put32(c == sig ? (below(8) ? global_name[below(K_COUNT)] : (uint32_t)rnd())
                               : below(8));
            } else {
                put32(uint_arg());
            }
            break;
        case 'i': {
            int32_t v = int_arg();
            if (kind == K_SHM) {
                pool_size = v;
            }
            put32((uint32_t)v);
            break;
        }
        case 's':
        case 'S':
            if (kind == K_REGISTRY) {
                const char *name = ifaces[below(K_COUNT)].name;
                if (!name) {
                    name = "wl_nothing";
                }
                size_t n = strlen(name);
                put32((uint32_t)n + 1);
                put_bytes((const uint8_t *)name, n + 1);
                pad();
            } else {
                string_arg(*c == 'S');
            }
            break;
        case 'a':
            array_arg();
            break;
        case 'h':
            /* Usually present; its memory the size asked for, or less. */
            if (below(8) != 0) {
                msg_fd = make_fd(0);
            }
            break;
        }
    }
    if (kind == K_SHM && msg_fd >= 0 && pool_size > 0 && below(2)) {
        /* Memory, but smaller than the pool it is said to be. */
        ftruncate(msg_fd, (off_t)(pool_size / (1 + below(4))));
    }
    if (!finish(object, (uint16_t)opcode)) {
        return 0;
    }
    if (r && made) {
        enum kind makes = r->makes;
        if (kind == K_REGISTRY) {
            makes = (enum kind)below(K_COUNT);
        }
        if (makes != K_NONE) {
            remember(made, makes);
        }
    }
    if (r && r->destroys) {
        forget(object);
    }
    return 1;
}

/* A plain request with only unsigned arguments, well formed. */
static int simple(uint32_t object, uint16_t opcode, const uint32_t *args, int n, int fd) {
    mlen = 8;
    for (int i = 0; i < n; i++) {
        put32(args[i]);
    }
    uint16_t size = (uint16_t)mlen;
    uint32_t word = ((uint32_t)size << 16) | opcode;
    memcpy(msg, &object, 4);
    memcpy(msg + 4, &word, 4);
    return send_bytes(msg, mlen, fd);
}

static int bind_global(enum kind kind, uint32_t version) {
    const char *name = ifaces[kind].name;
    size_t n = strlen(name);
    uint32_t id = next_id++;
    mlen = 8;
    put32(global_name[kind]);
    put32((uint32_t)n + 1);
    put_bytes((const uint8_t *)name, n + 1);
    pad();
    put32(version);
    put32(id);
    uint32_t word = ((uint32_t)mlen << 16) | 0;
    uint32_t registry = 2;
    memcpy(msg, &registry, 4);
    memcpy(msg + 4, &word, 4);
    if (!send_bytes(msg, mlen, -1)) {
        return 0;
    }
    remember(id, kind);
    return 1;
}

/* A window, made properly, then treated badly: a pool that is not what it
   says, a buffer attached after it was destroyed. */
static int window(void) {
    uint32_t compositor = pick(K_COMPOSITOR), wm = pick(K_WM_BASE), shm = pick(K_SHM);
    if (!compositor || !wm || !shm) {
        return 1;
    }
    uint32_t surface = next_id++, xdg = next_id++, top = next_id++;
    uint32_t a[4];
    a[0] = surface;
    if (!simple(compositor, 0, a, 1, -1)) return 0;
    remember(surface, K_SURFACE);
    a[0] = xdg;
    a[1] = surface;
    if (!simple(wm, 2, a, 2, -1)) return 0;
    remember(xdg, K_XDG_SURFACE);
    a[0] = top;
    if (!simple(xdg, 1, a, 1, -1)) return 0;
    remember(top, K_TOPLEVEL);
    for (int i = 0; i < 20 && !last_serial && !closed; i++) {
        usleep(5000);
        read_events();
    }
    a[0] = last_serial;
    if (!simple(xdg, 4, a, 1, -1)) return 0;

    int32_t w = 16 + (int32_t)below(300), h = 16 + (int32_t)below(200);
    size_t size = (size_t)w * (size_t)h * 4;
    int fd;
    switch (below(4)) {
    case 0: fd = make_fd(size / 2); break;           /* short, or not memory */
    case 1: fd = memfd_create("wlfuzz", 0); break;   /* empty */
    default:
        fd = memfd_create("wlfuzz", 0);
        if (fd >= 0) {
            ftruncate(fd, (off_t)size);
            void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            if (p != MAP_FAILED) {
                memset(p, (int)(rnd() & 0xFF), size);
                munmap(p, size);
            }
        }
        break;
    }
    uint32_t pool = next_id++, buffer = next_id++;
    a[0] = pool;
    a[1] = (uint32_t)size;
    int sent = simple(shm, 0, a, 2, fd);
    if (fd >= 0) {
        close(fd);
    }
    if (!sent) return 0;
    remember(pool, K_POOL);
    uint32_t b[6] = {buffer, 0, (uint32_t)w, (uint32_t)h, (uint32_t)w * 4, 1};
    if (!simple(pool, 0, b, 6, -1)) return 0;
    remember(buffer, K_BUFFER);
    a[0] = buffer;
    a[1] = 0;
    a[2] = 0;
    if (!simple(surface, 1, a, 3, -1)) return 0; /* attach */
    if (!simple(surface, 6, NULL, 0, -1)) return 0; /* commit */
    if (below(2)) {
        if (!simple(buffer, 0, NULL, 0, -1)) return 0; /* destroy */
        forget(buffer);
        if (below(2)) {
            if (!simple(pool, 1, NULL, 0, -1)) return 0; /* and the pool */
            forget(pool);
        }
        if (!simple(surface, 1, a, 3, -1)) return 0; /* attach it anyway */
        if (!simple(surface, 6, NULL, 0, -1)) return 0;
    }
    return 1;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: wlfuzz SEED MESSAGES\n");
        return 2;
    }
    char *end;
    unsigned long long seed = strtoull(argv[1], &end, 10);
    if (*end) {
        fprintf(stderr, "wlfuzz: '%s' is not a seed\n", argv[1]);
        return 2;
    }
    long total = strtol(argv[2], &end, 10);
    if (*end || total < 0 || total > 1000000) {
        fprintf(stderr, "wlfuzz: '%s' is not a number of messages\n", argv[2]);
        return 2;
    }
    const char *env = getenv("WAYLAND_SOCKET");
    if (!env) {
        fprintf(stderr, "wlfuzz: no WAYLAND_SOCKET; run it under a compositor\n");
        return 1;
    }
    sock = atoi(env);
    rng = (seed ^ 0x9E3779B97F4A7C15ULL) | 1;
    for (int i = 0; i < 4; i++) {
        rnd();
    }

    remember(1, K_DISPLAY);
    uint32_t a[1] = {next_id++};
    remember(a[0], K_REGISTRY);
    simple(1, 1, a, 1, -1); /* get_registry */
    a[0] = next_id++;
    simple(1, 0, a, 1, -1); /* sync */
    for (int i = 0; i < 100 && !global_name[K_COMPOSITOR] && !closed; i++) {
        usleep(10000);
        read_events();
    }
    const enum kind globals[] = {
        K_COMPOSITOR, K_SHM, K_OUTPUT, K_WM_BASE, K_SEAT, K_DECO_MGR, K_DDM,
    };
    for (size_t i = 0; i < sizeof(globals) / sizeof(globals[0]); i++) {
        enum kind k = globals[i];
        if (global_name[k]) {
            /* A version that was offered. Binding above it is a protocol
               error, and one in the opening four messages would end the
               session before it had fuzzed anything; the fuzzing proper
               sends those. */
            bind_global(k, 1 + below(global_version[k]));
        }
    }

    /* One window, made properly, before anything is broken: it is what puts
       a pool, a buffer and a surface in front of the compositor, and those
       are the parts a bad client can hurt. */
    window();

    long sent = 0;
    while (sent < total && !closed && !stopped) {
        int ok;
        if (below(25) == 0) {
            ok = window();
        } else {
            uint32_t object = below(10) == 0 ? object_arg(K_NONE, 0) : pick(K_NONE);
            enum kind kind = kind_of(object);
            if (kind == K_NONE) {
                kind = (enum kind)below(K_COUNT);
            }
            ok = request(object, kind);
        }
        if (!ok) {
            break;
        }
        sent++;
        read_events();
    }
    /* Whatever the compositor said last, read even when it has stopped
       taking requests: the error it sends before closing is the part worth
       printing, and it arrives after the send that failed.  */
    for (int i = 0; i < 40 && !closed; i++) {
        usleep(10000);
        read_events();
    }
    const char *how = closed  ? "the compositor closed the connection"
                    : stopped ? "the compositor stopped taking messages"
                              : "still connected";
    printf("wlfuzz: seed %llu: %ld of %ld messages sent; %s", seed, sent, total, how);
    if (told_error) {
        printf(", saying object %u error %u: %s", error_object, error_code, error_text);
    }
    printf("\n");
    /* Stay a while, so that the compositor's session outlives this one's
       first seconds either way. */
    return 0;
}
