/* The file calls a ported program leans on, answered by Quark's VFS through
   the Linux translation layer. It tolerates whatever an earlier run left
   behind, so it can be run again. */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static int failed;

static void check(const char *what, int ok) {
    printf("  %s  %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) {
        failed++;
    }
}

#define DIR    "/tmp/filetest-a-directory-with-a-name-past-the-old-limit"
#define FILE_A DIR "/a-file-whose-whole-path-is-well-over-forty-seven-bytes"
#define FILE_B DIR "/another"

static int put(const char *path, int flags, const char *text) {
    int fd = open(path, flags, 0644);
    if (fd < 0) {
        return -1;
    }
    ssize_t n = write(fd, text, strlen(text));
    close(fd);
    return n == (ssize_t)strlen(text) ? 0 : -1;
}

int main(void) {
    printf("files:\n");
    int r = mkdir(DIR, 0755);
    check("make a directory with a long name", r == 0 || errno == EEXIST);
    check("making it again says it exists", mkdir(DIR, 0755) == -1 && errno == EEXIST);
    check("create a file with a long path", put(FILE_A, O_WRONLY | O_CREAT, "0123456789") == 0);

    int fd = open(FILE_A, O_RDWR | O_CREAT, 0644);
    char buf[16] = {0};
    check("O_CREAT opens a file that exists", fd >= 0);
    check("and keeps what it held", fd >= 0 && read(fd, buf, 10) == 10 && !memcmp(buf, "0123456789", 10));
    close(fd);

    fd = open(FILE_A, O_WRONLY | O_CREAT | O_EXCL, 0644);
    check("O_EXCL refuses one that exists", fd == -1 && errno == EEXIST);
    fd = open(FILE_A, O_RDONLY | O_DIRECTORY);
    check("O_DIRECTORY refuses a file", fd == -1 && errno == ENOTDIR);
    fd = open(DIR, O_WRONLY);
    check("a directory cannot be opened to write", fd == -1 && errno == EISDIR);

    struct stat a1, a2, b, d, f;
    put(FILE_B, O_WRONLY | O_CREAT, "b");
    check("stat a file", stat(FILE_A, &a1) == 0 && S_ISREG(a1.st_mode) && a1.st_size >= 10);
    check("twice, and it is the same inode", stat(FILE_A, &a2) == 0 && a1.st_ino == a2.st_ino);
    check("another file is another inode", stat(FILE_B, &b) == 0 && b.st_ino != a1.st_ino);
    check("a file has a link", a1.st_nlink >= 1);
    check("stat a directory", stat(DIR, &d) == 0 && S_ISDIR(d.st_mode) && d.st_nlink >= 2);
    time_t now = time(NULL);
    check("a file written now is dated now", a1.st_mtime <= now && now - a1.st_mtime < 600);
    fd = open(FILE_A, O_RDONLY);
    check("fstat agrees with stat", fd >= 0 && fstat(fd, &f) == 0 && f.st_ino == a1.st_ino);
    close(fd);

    char longname[sizeof DIR + 300];
    memcpy(longname, DIR "/", sizeof DIR);
    memset(longname + sizeof DIR, 'x', 260);
    longname[sizeof DIR + 260] = 0;
    fd = open(longname, O_WRONLY | O_CREAT, 0644);
    check("a name longer than 255 bytes is refused", fd == -1 && errno == ENAMETOOLONG);

    printf("filetest: %s\n", failed ? "FAILED" : "ok");
    return failed ? 1 : 0;
}
