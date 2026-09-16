/* The file calls a ported program leans on, answered by Quark's VFS through
   the Linux translation layer. It removes everything it makes, and tolerates
   whatever a run that stopped half way left behind. */
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

/* What a run that stopped part way may have left. Errors are expected. */
static void clear_leftovers(void) {
    unlink(DIR "/sub/inner");
    rmdir(DIR "/sub");
    unlink(DIR "/sub-renamed/inner");
    rmdir(DIR "/sub-renamed");
    unlink(DIR "/gone");
    unlink(DIR "/moved");
    unlink(FILE_B);
}

int main(void) {
    printf("files:\n");
    clear_leftovers();
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


    printf("removing, renaming, shortening:\n");
    fd = open(FILE_A, O_WRONLY | O_TRUNC);
    check("O_TRUNC empties a file", fd >= 0 && fstat(fd, &f) == 0 && f.st_size == 0);
    check("which then takes new bytes", fd >= 0 && write(fd, "ab", 2) == 2);
    close(fd);
    check("and holds only those", stat(FILE_A, &f) == 0 && f.st_size == 2);

    check("ftruncate shortens", truncate(FILE_A, 1) == 0 && stat(FILE_A, &f) == 0 && f.st_size == 1);
    check("and lengthens", truncate(FILE_A, 5000) == 0 && stat(FILE_A, &f) == 0 && f.st_size == 5000);
    fd = open(FILE_A, O_RDWR);
    char big[5000];
    memset(big, 1, sizeof big);
    int zeros = fd >= 0 && read(fd, big, sizeof big) == 5000 && big[0] == 'a';
    for (int i = 1; i < 5000 && zeros; i++) {
        zeros = big[i] == 0;
    }
    check("with zeros past the old end", zeros);
    check("and a write into the gap lands", fd >= 0 && lseek(fd, 4096, SEEK_SET) == 4096 && write(fd, "z", 1) == 1);
    close(fd);

    #define GONE DIR "/gone"
    put(GONE, O_WRONLY | O_CREAT, "soon");
    fd = open(GONE, O_RDONLY);
    check("unlink a file", unlink(GONE) == 0);
    check("it is gone", stat(GONE, &f) == -1 && errno == ENOENT);
    memset(buf, 0, sizeof buf);
    check("an open handle still reads it", fd >= 0 && read(fd, buf, 4) == 4 && !memcmp(buf, "soon", 4));
    close(fd);
    check("unlinking it again says so", unlink(GONE) == -1 && errno == ENOENT);
    check("unlink refuses a directory", unlink(DIR) == -1 && errno == EISDIR);
    check("link is not offered", link(FILE_A, DIR "/hard") == -1 && errno == EPERM);

    #define MOVED DIR "/moved"
    unlink(MOVED);
    struct stat before;
    stat(FILE_B, &before);
    check("rename a file", rename(FILE_B, MOVED) == 0);
    check("the old name is gone", stat(FILE_B, &f) == -1 && errno == ENOENT);
    check("the new one is the same file", stat(MOVED, &f) == 0 && f.st_ino == before.st_ino);
    put(FILE_B, O_WRONLY | O_CREAT, "replacement");
    check("rename over a file replaces it", rename(MOVED, FILE_B) == 0 && stat(FILE_B, &f) == 0 && f.st_ino == before.st_ino && f.st_size == 1);

    #define SUB DIR "/sub"
    #define SUB2 DIR "/sub-renamed"
    mkdir(SUB, 0755);
    put(SUB "/inner", O_WRONLY | O_CREAT, "x");
    check("rmdir refuses a directory with something in it", rmdir(SUB) == -1 && errno == ENOTEMPTY);
    check("rename a directory", rename(SUB, SUB2) == 0 && stat(SUB2 "/inner", &f) == 0);
    check("not into itself", rename(SUB2, SUB2 "/itself") == -1 && errno == EINVAL);
    check("empty it", unlink(SUB2 "/inner") == 0);
    check("then rmdir removes it", rmdir(SUB2) == 0 && stat(SUB2, &f) == -1 && errno == ENOENT);

    check("tidy up", unlink(FILE_A) == 0 && unlink(FILE_B) == 0 && rmdir(DIR) == 0);

    printf("filetest: %s\n", failed ? "FAILED" : "ok");
    return failed ? 1 : 0;
}
