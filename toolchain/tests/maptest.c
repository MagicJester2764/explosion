/* Files mapped into memory: private mappings here; shared ones in Task 11. */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static int failed;

static void check(const char *what, int ok) {
    printf("  %s  %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) {
        failed++;
    }
}

#define F "/tmp/maptest"
#define PAGES 3
#define SIZE (PAGES * 4096 - 100)

static unsigned char pattern(size_t i) {
    return (unsigned char)(i * 7 + (i >> 12));
}

int main(void) {
    printf("mapped files:\n");
    int fd = open(F, O_RDWR | O_CREAT | O_TRUNC, 0644);
    unsigned char buf[SIZE];
    for (size_t i = 0; i < SIZE; i++) buf[i] = pattern(i);
    check("a file to map", fd >= 0 && write(fd, buf, SIZE) == SIZE);
    unsigned char *r = mmap(NULL, SIZE, PROT_READ, MAP_PRIVATE, fd, 0);
    check("maps for reading", r != MAP_FAILED);
    int same = r != MAP_FAILED;
    for (size_t i = 0; same && i < SIZE; i++) same = r[i] == pattern(i);
    check("and holds what the file holds", same);
    int tail = r != MAP_FAILED;
    for (size_t i = SIZE; tail && i < PAGES * 4096; i++) tail = r[i] == 0;
    check("with zeroes past the end of its last page", tail);
    unsigned char *w = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 4096);
    check("a private writable mapping of page 1", w != MAP_FAILED && w[0] == pattern(4096));
    if (w != MAP_FAILED) w[0] = (unsigned char)~pattern(4096);
    unsigned char one;
    check("a write to it stays private", pread(fd, &one, 1, 4096) == 1 && one == pattern(4096));
    check("and the read-only mapping still shows the file", r != MAP_FAILED && r[4096] == pattern(4096));
    if (w != MAP_FAILED) munmap(w, 4096);
    if (r != MAP_FAILED) munmap(r, SIZE);
    int dir = open("/tmp", O_RDONLY | O_DIRECTORY);
    errno = 0;
    /* ENODEV is POSIX's word for it; Linux says EACCES. */
    check("a directory cannot be mapped", mmap(NULL, 4096, PROT_READ, MAP_PRIVATE, dir, 0) == MAP_FAILED &&
          (errno == ENODEV || errno == EACCES));
    close(dir);
    int ro = open(F, O_RDONLY);
    errno = 0;
    check("nor written shared through a read-only descriptor",
          mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, ro, 0) == MAP_FAILED && errno == EACCES);
    close(ro);
    close(fd);
    check("tidy up", unlink(F) == 0);
    printf("maptest: %s\n", failed ? "FAILED" : "ok");
    return failed ? 1 : 0;
}
