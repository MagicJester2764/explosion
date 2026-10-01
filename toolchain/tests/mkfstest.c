/* The filesystem tools, doing what they are for: a disk of memory is given
 * an ext4 filesystem, an ext2 one and a FAT one, each is checked by the
 * program that checks its kind, and the first sectors are read to see that
 * what was asked for is what is there.
 *
 * And what they must not do. The disk this system is running from is a
 * disk like any other under /dev; told to make a filesystem on it, and
 * told not to ask, mke2fs has to be refused. */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#define BLKGETSIZE64 0x80081272
#define SIZE (64L << 20)

extern char **environ;

static int failed;

static void check(const char *what, int ok) {
    printf("  %s  %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) {
        failed++;
    }
}

/* Run a program with nothing to read and wait for it. Its exit status, or
   -1 if it did not exit. `quietly` is for one that is expected to complain:
   what it says goes nowhere. */
static int run(int quietly, char *const argv[]) {
    char path[64];
    posix_spawn_file_actions_t actions;
    pid_t pid;
    int status;

    snprintf(path, sizeof path, "/usr/bin/%s", argv[0]);
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    if (quietly) {
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0);
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0);
    }
    int err = posix_spawn(&pid, path, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    if (err || waitpid(pid, &status, 0) != pid || !WIFEXITED(status)) {
        return -1;
    }
    return WEXITSTATUS(status);
}

#define RUN(...) run(0, (char *const[]){ __VA_ARGS__, NULL })
#define REFUSED(...) (run(1, (char *const[]){ __VA_ARGS__, NULL }) > 0)

/* The disk of memory just made: the one that is SIZE long. */
static int find(char *path, size_t len) {
    for (int tries = 0; tries < 100; tries++) {
        for (int n = 0; n < 8; n++) {
            unsigned long long bytes = 0;
            snprintf(path, len, "/dev/ram%d", n);
            int fd = open(path, O_RDONLY);
            if (fd < 0) {
                continue;
            }
            int is = ioctl(fd, BLKGETSIZE64, &bytes) == 0 && bytes == SIZE;
            close(fd);
            if (is) {
                return 1;
            }
        }
        usleep(20 * 1000);
    }
    return 0;
}

static unsigned le32(const unsigned char *p) {
    return p[0] | p[1] << 8 | p[2] << 16 | (unsigned)p[3] << 24;
}

int main(void) {
    /* What the tools print comes between the lines this does. */
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("the filesystem tools:\n");
    char dev[32];
    pid_t disk = 0;
    char *ramdisk[] = { "ramdisk", "64", NULL };
    if (posix_spawn(&disk, "/usr/bin/ramdisk", NULL, NULL, ramdisk, environ) || !find(dev, sizeof dev)) {
        check("a disk of memory to work on", 0);
        return 1;
    }
    unsigned char sb[1024], boot[512];

    /* ext4. */
    check("mkfs.ext4 makes a filesystem", RUN("mkfs.ext4", "-q", dev) == 0);
    int fd = open(dev, O_RDONLY);
    int got = pread(fd, sb, sizeof sb, 1024) == (ssize_t)sizeof sb;
    check("which has the magic number of one", got && sb[56] == 0x53 && sb[57] == 0xEF);
    /* compat 0x4: a journal. incompat 0x40: extents. */
    check("with a journal and extents, which is what makes it ext4",
          got && (le32(sb + 92) & 0x4) && (le32(sb + 96) & 0x40));
    close(fd);
    check("e2fsck finds nothing wrong with it", RUN("e2fsck", "-fn", dev) == 0);

    /* ext2: the same program, by another name. */
    check("mkfs.ext2 makes one too", RUN("mkfs.ext2", "-q", dev) == 0);
    fd = open(dev, O_RDONLY);
    got = pread(fd, sb, sizeof sb, 1024) == (ssize_t)sizeof sb;
    check("with neither, which is what makes it ext2",
          got && sb[56] == 0x53 && sb[57] == 0xEF && !(le32(sb + 92) & 0x4) && !(le32(sb + 96) & 0x40));
    close(fd);
    check("and e2fsck finds nothing wrong with that", RUN("e2fsck", "-fn", dev) == 0);

    /* FAT32, as an EFI system partition is. */
    check("mkfs.fat makes a FAT32 filesystem", RUN("mkfs.fat", "-F", "32", dev) == 0);
    fd = open(dev, O_RDONLY);
    got = pread(fd, boot, sizeof boot, 0) == (ssize_t)sizeof boot;
    check("which says so in its first sector",
          got && !memcmp(boot + 82, "FAT32", 5) && boot[510] == 0x55 && boot[511] == 0xAA);
    close(fd);
    check("fsck.fat finds nothing wrong with it", RUN("fsck.fat", "-n", dev) == 0);
    check("and e2fsck says it is no filesystem of its kind", REFUSED("e2fsck", "-fn", dev));

    kill(disk, SIGKILL);
    waitpid(disk, NULL, 0);

    /* The disk this is running from: the one of the disks that is busy to
       whatever would write it. -F tells mke2fs not to ask and not to look. */
    char root[280] = "";
    DIR *devdir = opendir("/dev");
    struct dirent *e;
    while (devdir && (e = readdir(devdir))) {
        char path[280];
        if (e->d_type != DT_BLK) {
            continue;
        }
        snprintf(path, sizeof path, "/dev/%s", e->d_name);
        int w = open(path, O_RDWR);
        if (w >= 0) {
            close(w);
        } else if (errno == EBUSY && strlen(path) > strlen(root)) {
            /* The longest name: the partition, not the disk around it. */
            strcpy(root, path);
        }
    }
    if (devdir) {
        closedir(devdir);
    }
    check("the disk this runs from is found", root[0]);
    fd = open(root, O_RDONLY);
    got = pread(fd, sb, sizeof sb, 1024) == (ssize_t)sizeof sb;
    check("mke2fs, told not to ask, is refused it", REFUSED("mke2fs", "-q", "-F", root));
    unsigned char after[1024];
    check("and its filesystem is as it was",
          got && pread(fd, after, sizeof after, 1024) == (ssize_t)sizeof after &&
              /* But for what a running system writes there itself: the
                 counts of what is free, and when it was last written. */
              !memcmp(sb + 56, after + 56, 2) && !memcmp(sb + 104, after + 104, 16));
    close(fd);

    printf("mkfstest: %s\n", failed ? "FAILED" : "ok");
    return failed ? 1 : 0;
}
