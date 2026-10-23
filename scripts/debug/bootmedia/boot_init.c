/*
 * boot_init.c - OpenHarmony boot-media first-stage init (static, no libc deps
 * beyond the C runtime).
 *
 * Runs as PID 1 (kernel parameter rdinit=/boot_init).  Finds the medium that
 * carries the per-partition raw images (system.img, vendor.img, ...), presents
 * them to the stock OHOS init as /dev/block/by-name/<name> via loop devices,
 * then execs /init.
 *
 * system/vendor are mounted read-only by OHOS  -> loop the image read-only.
 * sys_prod/chip_prod/userdata are mounted rw   -> loop in place if the medium
 *   is writable, otherwise copy to a tmpfs first (non-persistent).
 *
 * Media discovery (in order):
 *   1. /dev/sr0, /dev/sr1, /dev/mapper/ventoy          (plain ISO/CD boot)
 *   2. whole devices / partitions that directly carry *.img at their root
 *      (dd of the ISO to a USB stick, dd of ohos_disk.img, real partitions)
 *   3. *.iso files stored *inside* a mountable partition (e.g. a Ventoy USB
 *      data partition: VTOYEFI + exFAT/NTFS with the .iso file on it).  The
 *      ISO file is loop-mounted read-only and the *.img are read from it.
 *      This is required for Ventoy: its UEFI virtual CD-ROM only exists during
 *      bootloader time and is gone once the kernel's own drivers take over, so
 *      the kernel never sees /dev/sr0 -- only the physical USB partitions.
 *
 * Build:  gcc -static -O2 -o boot_init boot_init.c
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <dirent.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/ioctl.h>
#include <sys/sysmacros.h>
#include <sys/syscall.h>
#include <time.h>
#include <linux/loop.h>

#define MEDIA_MP   "/mnt/media"
#define PART_MP    "/mnt/part"
#define ISO_MP     "/mnt/iso"
#define BYNAME_DIR "/dev/block/by-name"
#define RWSTAGE    "/run/rw"
#define PSTORE_MP  "/mnt/pstore"
#define DATA_MP    "/mnt/data"
/* Persistent log directory.  Written to TWO independent targets, both on the
 * *boot medium* only (the internal disk / its ESP is never touched):
 *   1. <medium root>/ohos-log        -- boot_init writes boot.log directly
 *      (no loop needed; directly readable from Ubuntu at the root of the
 *      OHOSDISK partition).
 *   2. <userdata.img mount>/ohos-log -- the directory zz_pslog.sh appends to
 *      (userdata.img is looped in place, so this persists on the boot medium).
 * Kept in sync with /system/bin/zz_pslog.sh. */
#define LOG_DIR    "ohos-log"
#define BOOT_LOG   "boot.log"
#define ZLOG       "zzpslog.log"

static int kmsg_fd = -1;
/* When >= 0, boot_init also appends its own diagnostics and the pstore dump to
 * this file (opened on /data once userdata has been mounted). */
static int log_fd = -1;

static void logmsg(const char *fmt, ...)
{
    char buf[1024];
    va_list ap;
    int n;
    va_start(ap, fmt);
    n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n < 0)
        return;
    if (kmsg_fd >= 0 && kmsg_fd != log_fd)
        (void)write(kmsg_fd, buf, (size_t)n);
    if (log_fd >= 0 && log_fd != kmsg_fd)
        (void)write(log_fd, buf, (size_t)n);
    if (2 != kmsg_fd && 2 != log_fd)
        (void)write(2, buf, (size_t)n);
    if (1 != kmsg_fd && 1 != log_fd)
        (void)write(1, buf, (size_t)n);
}

static void mkdir_p(const char *path, mode_t mode)
{
    char tmp[512];
    size_t len;
    if (strlen(path) >= sizeof(tmp))
        return;
    strcpy(tmp, path);
    len = strlen(tmp);
    if (len > 1 && tmp[len - 1] == '/')
        tmp[len - 1] = 0;
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = 0;
            (void)mkdir(tmp, mode);
            *p = '/';
        }
    }
    (void)mkdir(tmp, mode);
}

static int is_dir(const char *p)
{
    struct stat st;
    return stat(p, &st) == 0 && S_ISDIR(st.st_mode);
}

/* ---- loop devices ------------------------------------------------------- */

static int loop_control(void)
{
    int fd = open("/dev/loop-control", O_RDWR);
    if (fd < 0) {
        (void)mknod("/dev/loop-control", S_IFCHR | 0600, makedev(10, 237));
        fd = open("/dev/loop-control", O_RDWR);
    }
    return fd;
}

/* attach file to a free loop device; rw=0 read-only.
 * returns malloc'd device path or NULL. */
static char *loop_attach(const char *file, int rw)
{
    int cfd = loop_control();
    if (cfd < 0) {
        logmsg("boot_init: open loop-control failed: %s\n", strerror(errno));
        return NULL;
    }
    int num = ioctl(cfd, LOOP_CTL_GET_FREE);
    if (num < 0) {
        logmsg("boot_init: LOOP_CTL_GET_FREE failed: %s\n", strerror(errno));
        close(cfd);
        return NULL;
    }
    char dev[64];
    snprintf(dev, sizeof(dev), "/dev/loop%d", num);
    if (access(dev, F_OK) != 0)
        (void)mknod(dev, S_IFBLK | 0600, makedev(7, num));

    int ffd = open(file, rw ? O_RDWR : O_RDONLY);
    if (ffd < 0) {
        logmsg("boot_init: open %s failed: %s\n", file, strerror(errno));
        close(cfd);
        return NULL;
    }
    int lfd = open(dev, O_RDWR);
    if (lfd < 0) {
        logmsg("boot_init: open %s failed: %s\n", dev, strerror(errno));
        close(ffd);
        close(cfd);
        return NULL;
    }
    if (ioctl(lfd, LOOP_SET_FD, ffd) != 0) {
        logmsg("boot_init: LOOP_SET_FD %s -> %s failed: %s\n", file, dev, strerror(errno));
        close(lfd);
        close(ffd);
        close(cfd);
        return NULL;
    }
    close(lfd);
    close(ffd);
    close(cfd);
    return strdup(dev);
}

static void loop_detach(const char *dev)
{
    int lfd = open(dev, O_RDWR);
    if (lfd >= 0) {
        (void)ioctl(lfd, LOOP_CLR_FD, 0);
        close(lfd);
    }
}

/* ---- filesystem probing ------------------------------------------------- */

/* Filesystems we may meet on the boot medium, most specific first.  A plain
 * data ISO is iso9660; Ventoy's data partition is usually exFAT (also FAT32,
 * NTFS, ext4).  The kernel's NTFS3 driver registers as "ntfs3". */
static const char *g_fslist[] = {
    "iso9660", "ext4", "vfat", "exfat", "ntfs3", "udf"
};
#define NFS (int)(sizeof(g_fslist) / sizeof(g_fslist[0]))

static int has_img(const char *dir)
{
    char p[512];
    snprintf(p, sizeof(p), "%s/system.img", dir);
    return access(p, F_OK) == 0;
}

/* mount dev at mnt; prefer rw, fall back ro.  returns 1 on success.
 * *ro is set to 1 if only a read-only mount succeeded. */
static int do_mount(const char *dev, const char *fs, const char *mnt, int *ro)
{
    if (mount(dev, mnt, fs, 0, NULL) == 0) {
        *ro = 0;
        return 1;
    }
    if (mount(dev, mnt, fs, MS_RDONLY, NULL) == 0) {
        *ro = 1;
        return 1;
    }
    return 0;
}

/* ---- media discovery ---------------------------------------------------- */

static const char *g_media_dir = MEDIA_MP; /* dir holding the *.img files */
static const char *g_media_dev;            /* device/file the imgs came from */
static const char *g_media_fs;             /* filesystem holding the imgs */
static int g_media_ro = 1;                 /* imgs live on a read-only medium */

static int try_iso(const char *file);

/* Try dev as a medium whose root directly holds the *.img files. */
static int try_media_dev(const char *dev)
{
    struct stat st;
    if (stat(dev, &st) != 0 || !S_ISBLK(st.st_mode))
        return 0;
    for (int i = 0; i < NFS; i++) {
        int ro = 0;
        if (!do_mount(dev, g_fslist[i], MEDIA_MP, &ro))
            continue;
        if (has_img(MEDIA_MP)) {
            g_media_dev = strdup(dev);
            g_media_fs = g_fslist[i];
            g_media_dir = MEDIA_MP;
            g_media_ro = ro;
            return 1;
        }
        (void)umount(MEDIA_MP);
    }
    return 0;
}

/* Mount an ISO file and look for *.img inside it. */
static int try_iso(const char *file)
{
    char *ldev = loop_attach(file, 0);
    if (!ldev)
        return 0;
    static const char *isofs[] = { "iso9660", "udf" };
    for (size_t i = 0; i < sizeof(isofs) / sizeof(isofs[0]); i++) {
        if (mount(ldev, ISO_MP, isofs[i], MS_RDONLY, NULL) != 0)
            continue;
        if (has_img(ISO_MP)) {
            g_media_dir = ISO_MP;
            g_media_dev = strdup(file);
            g_media_fs = isofs[i];
            g_media_ro = 1; /* an ISO is always read-only */
            logmsg("boot_init: ISO %s -> %s fs=%s (contains *.img)\n",
                   file, ldev, isofs[i]);
            /* keep the loop device attached for the lifetime of the boot */
            free(ldev);
            return 1;
        }
        (void)umount(ISO_MP);
    }
    loop_detach(ldev);
    free(ldev);
    return 0;
}

/* Search a mounted directory tree (depth <= 2) for *.iso files that contain
 * the OHOS images.  This is how a Ventoy data partition is handled. */
static int search_iso(const char *mnt, int depth)
{
    DIR *d = opendir(mnt);
    if (!d)
        return 0;
    struct dirent *e;
    char subdirs[16][512];
    int nsub = 0;
    int found = 0;

    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.' &&
            (e->d_name[1] == 0 || (e->d_name[1] == '.' && e->d_name[2] == 0)))
            continue;
        char full[512];
        snprintf(full, sizeof(full), "%s/%s", mnt, e->d_name);
        struct stat st;
        if (stat(full, &st) != 0)
            continue;
        if (S_ISDIR(st.st_mode)) {
            if (depth < 2 && nsub < 16) {
                strncpy(subdirs[nsub], full, sizeof(subdirs[0]) - 1);
                subdirs[nsub][sizeof(subdirs[0]) - 1] = 0;
                nsub++;
            }
            continue;
        }
        size_t n = strlen(e->d_name);
        if (n > 4 && strcasecmp(e->d_name + n - 4, ".iso") == 0) {
            logmsg("boot_init: trying ISO file %s\n", full);
            if (try_iso(full)) {
                found = 1;
                break;
            }
        }
    }
    closedir(d);
    if (found)
        return 1;
    for (int i = 0; i < nsub; i++)
        if (search_iso(subdirs[i], depth + 1))
            return 1;
    return 0;
}

/* Try dev as a partition: either it directly holds *.img, or it holds an ISO
 * file that we can loop-mount (Ventoy data partition). */
static int try_partition(const char *dev)
{
    struct stat st;
    if (stat(dev, &st) != 0 || !S_ISBLK(st.st_mode))
        return 0;
    for (int i = 0; i < NFS; i++) {
        int ro = 0;
        if (!do_mount(dev, g_fslist[i], PART_MP, &ro))
            continue;
        if (has_img(PART_MP)) {
            /* e.g. a hand-made partition holding the raw images */
            g_media_dev = strdup(dev);
            g_media_fs = g_fslist[i];
            g_media_dir = PART_MP;
            g_media_ro = ro;
            return 1;
        }
        if (search_iso(PART_MP, 0)) {
            logmsg("boot_init: partition %s hosts the boot ISO\n", dev);
            return 1;
        }
        (void)umount(PART_MP);
    }
    return 0;
}

/* scan /dev for block devices whose name starts with one of the prefixes */
static int scan_dir(const char *dir, const char *const *prefixes, int npref,
                    int as_partition)
{
    DIR *d = opendir(dir);
    if (!d)
        return 0;
    struct dirent *e;
    int found = 0;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.')
            continue;
        for (int i = 0; i < npref; i++) {
            size_t pl = strlen(prefixes[i]);
            if (pl && strncmp(e->d_name, prefixes[i], pl) != 0)
                continue;
            char path[512];
            snprintf(path, sizeof(path), "%s/%s", dir, e->d_name);
            int ok = as_partition ? try_partition(path) : try_media_dev(path);
            if (ok) {
                found = 1;
                break;
            }
        }
        if (found)
            break;
    }
    closedir(d);
    return found;
}

static int find_media(void)
{
    static const char *pref[] = { "vd", "sd", "nvme", "mmcblk" };
    const int npref = (int)(sizeof(pref) / sizeof(pref[0]));

    /* optical / dm first (plain UEFI ISO boot, Ventoy's own dm mapping) */
    if (try_media_dev("/dev/sr0") || try_media_dev("/dev/sr1") ||
        try_media_dev("/dev/mapper/ventoy"))
        return 1;

    /* whole devices / partitions carrying the images directly, then partitions
     * carrying a boot ISO file (Ventoy). */
    if (scan_dir("/dev", pref, npref, 0))
        return 1;
    if (scan_dir("/dev", pref, npref, 1))
        return 1;

    /* last resort: any mapper node (e.g. ventoy under another name) */
    static const char *pref_m[] = { "" };
    if (is_dir("/dev/mapper") && scan_dir("/dev/mapper", pref_m, 1, 0))
        return 1;
    return 0;
}

/* ---- diagnostics -------------------------------------------------------- */

/* Print any previous crash dump left by pstore (EFI vars / ramoops) so that a
 * log from before the last reboot is visible on this boot's console/serial.
 * The dump was written by the kernel on the *previous* panic. */
static void dump_one_pstore(const char *path)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        return;
    logmsg("boot_init: --- pstore %s ---\n", path);
    char buf[4096];
    static const char pfx[] = "PSTORE: ";
    ssize_t n;
    while ((n = read(fd, buf, sizeof(buf))) > 0) {
        (void)write(1, buf, (size_t)n);
        if (kmsg_fd >= 0)
            (void)write(kmsg_fd, buf, (size_t)n);
        if (log_fd >= 0) {
            (void)write(log_fd, pfx, sizeof(pfx) - 1);
            (void)write(log_fd, buf, (size_t)n);
            (void)write(log_fd, "\n", 1);
        }
    }
    logmsg("\nboot_init: --- end pstore %s ---\n", path);
    close(fd);
}

static void dump_pstore(void)
{
    if (mount("pstore", PSTORE_MP, "pstore", 0, NULL) != 0) {
        logmsg("boot_init: pstore mount failed: %s\n", strerror(errno));
        return;
    }
    DIR *d = opendir(PSTORE_MP);
    if (!d)
        return;
    struct dirent *e;
    int cnt = 0;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.')
            continue;
        char full[512];
        snprintf(full, sizeof(full), "%s/%s", PSTORE_MP, e->d_name);
        dump_one_pstore(full);
        cnt++;
    }
    closedir(d);
    if (cnt == 0)
        logmsg("boot_init: pstore is empty (no previous crash dump)\n");
    /* Drop the mount so the stock init does not try to move it to /usr. */
    (void)umount(PSTORE_MP);
}

/* ---- persistent log on /data ------------------------------------------- */

/* Copy the first line of a small text file into out (empty on failure). */
static void read_first_line(const char *path, char *out, size_t n)
{
    out[0] = 0;
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        return;
    char buf[512];
    ssize_t r = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (r <= 0)
        return;
    buf[r] = 0;
    char *nl = strchr(buf, '\n');
    if (nl)
        *nl = 0;
    strncpy(out, buf, n - 1);
    out[n - 1] = 0;
}

/* Current UTC time as "YYYY-MM-DDTHH:MM:SSZ". */
static void utc_stamp(char *out, size_t n)
{
    time_t t = time(NULL);
    struct tm tm;
    if (gmtime_r(&t, &tm) == NULL) {
        snprintf(out, n, "?");
        return;
    }
    strftime(out, n, "%Y-%m-%dT%H:%M:%SZ", &tm);
}

/* Print the last maxbytes bytes of path to the console/kmsg (NOT to the log
 * file, to avoid duplicating the previous session into boot.log). */
static void print_tail(const char *path, long maxbytes)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        return;
    struct stat st;
    if (fstat(fd, &st) != 0) {
        close(fd);
        return;
    }
    long off = (st.st_size > maxbytes) ? (long)st.st_size - maxbytes : 0;
    if (off > 0)
        (void)lseek(fd, off, SEEK_SET);
    logmsg("boot_init: --- previous %s (last %ld bytes of %lld) ---\n",
           path, maxbytes, (long long)st.st_size);
    char buf[4096];
    ssize_t n;
    while ((n = read(fd, buf, sizeof(buf))) > 0) {
        (void)write(1, buf, (size_t)n);
        if (kmsg_fd >= 0)
            (void)write(kmsg_fd, buf, (size_t)n);
    }
    logmsg("\nboot_init: --- end previous %s ---\n", path);
    close(fd);
}

/* Read the build id string from <medium root>/ohos_build_id into out. */
static void read_build_id(char *out, size_t n)
{
    char bidfile[512];
    snprintf(bidfile, sizeof(bidfile), "%s/ohos_build_id", g_media_dir);
    read_first_line(bidfile, out, n);
    if (out[0] == 0)
        snprintf(out, n, "unknown");
}

/* Append this boot's BOOT MARKER + pstore dump to <dir>/boot.log.  Returns 1
 * when the file could be opened (i.e. <dir> is writable), 0 otherwise.  Never
 * fatal: a clear message is printed and boot continues.  print_prev also prints
 * the previous zzpslog.log tail to the console/kmsg (not into the file, it is
 * already persisted in zzpslog.log). */
static int append_boot_log(const char *dir, const char *tag,
                           const char *ts, const char *bid, int print_prev)
{
    mkdir_p(dir, 0755);
    char bootlog[512], zlog[512];
    snprintf(bootlog, sizeof(bootlog), "%s/%s", dir, BOOT_LOG);
    snprintf(zlog, sizeof(zlog), "%s/%s", dir, ZLOG);

    int fd = open(bootlog, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) {
        logmsg("boot_init: WARN cannot write %s: %s\n", bootlog, strerror(errno));
        return 0;
    }
    /* Never let the log file occupy fd 0/1/2: on some boot paths fd 0/1/2 are
     * closed and open() would return 1, so logmsg's own console write(fd 1)
     * would silently duplicate every line into the file. */
    if (fd < 3) {
        int nfd = fcntl(fd, F_DUPFD, 3);
        if (nfd >= 0) {
            close(fd);
            fd = nfd;
        }
    }
    int saved = log_fd;
    log_fd = fd;
    if (print_prev)
        print_tail(zlog, 12000);
    logmsg("========== BOOT MARKER ==========\n");
    logmsg("time_utc=%s build_id=%s media=%s target=%s\n",
           ts, bid, g_media_dev, tag);
    logmsg("========== END BOOT MARKER ==========\n");
    /* Dump pstore into the file as well (logmsg writes to log_fd now). */
    dump_pstore();
    close(fd);
    log_fd = saved;
    return 1;
}

/* Persist this boot's marker before handing off to the stock init, so a log
 * exists even if user space never comes up.  Two targets on the boot medium:
 *   a) <medium root>/ohos-log  (needs no loop; always tried when writable)
 *   b) <userdata mount>/ohos-log (the directory zz_pslog.sh appends to)
 * Every failure is non-fatal and reported.  The internal disk is never used. */
static void early_log_prev(void)
{
    char ts[32], bid[256];
    utc_stamp(ts, sizeof(ts));
    read_build_id(bid, sizeof(bid));

    /* (a) boot-medium root, e.g. the OHOSDISK ext4 partition holding the imgs. */
    int medium_ok = 0;
    if (!g_media_ro) {
        char mroot[600];
        snprintf(mroot, sizeof(mroot), "%s/%s", g_media_dir, LOG_DIR);
        medium_ok = append_boot_log(mroot, "medium", ts, bid, 0);
        if (medium_ok)
            logmsg("boot_init: persistent log on boot medium: %s/%s\n",
                   mroot, BOOT_LOG);
        else
            logmsg("boot_init: WARN boot medium not writable for logs\n");
    } else {
        logmsg("boot_init: WARN boot medium is read-only; cannot persist on it\n");
    }

    /* (b) /data (the looped userdata.img) -- the directory zz_pslog.sh uses. */
    char mp[] = DATA_MP;
    mkdir_p(mp, 0755);
    if (mount(BYNAME_DIR "/userdata", mp, "ext4", 0, NULL) != 0) {
        logmsg("boot_init: WARN mount " BYNAME_DIR "/userdata failed: %s "
               "(log kept on boot medium only: %d)\n", strerror(errno), medium_ok);
        return;
    }
    char logdir[256];
    snprintf(logdir, sizeof(logdir), "%s/%s", mp, LOG_DIR);
    if (append_boot_log(logdir, "userdata", ts, bid, 1))
        logmsg("boot_init: persistent log on /data: %s/%s\n", logdir, BOOT_LOG);
    else
        logmsg("boot_init: WARN could not write /data log (medium_ok=%d)\n",
               medium_ok);
    (void)umount(mp);
}

static void dump_block_devs(void)
{
    logmsg("boot_init: --- /proc/partitions ---\n");
    int fd = open("/proc/partitions", O_RDONLY);
    if (fd >= 0) {
        char buf[1024];
        ssize_t n;
        while ((n = read(fd, buf, sizeof(buf))) > 0)
            (void)write(2, buf, (size_t)n);
        close(fd);
    }
    DIR *d = opendir("/dev");
    if (d) {
        struct dirent *e;
        logmsg("boot_init: --- block nodes in /dev ---\n");
        while ((e = readdir(d)) != NULL) {
            if (e->d_name[0] == '.')
                continue;
            if (strncmp(e->d_name, "sd", 2) == 0 ||
                strncmp(e->d_name, "vd", 2) == 0 ||
                strncmp(e->d_name, "sr", 2) == 0 ||
                strncmp(e->d_name, "nvme", 4) == 0 ||
                strncmp(e->d_name, "mmcblk", 6) == 0 ||
                strncmp(e->d_name, "loop", 4) == 0)
                logmsg("boot_init:   /dev/%s\n", e->d_name);
        }
        closedir(d);
    }
}

/* ---- per-partition setup ------------------------------------------------ */

static int copy_file(const char *src, const char *dst)
{
    int in = open(src, O_RDONLY);
    if (in < 0)
        return -1;
    int out = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (out < 0) {
        close(in);
        return -1;
    }
    char buf[1 << 20];
    ssize_t r;
    int rc = 0;
    while ((r = read(in, buf, sizeof(buf))) > 0) {
        ssize_t off = 0;
        while (off < r) {
            ssize_t w = write(out, buf + off, (size_t)(r - off));
            if (w <= 0) {
                rc = -1;
                goto out;
            }
            off += w;
        }
    }
    if (r < 0)
        rc = -1;
out:
    close(in);
    close(out);
    return rc;
}

/* QEMU's /vendor/etc/fstab.virt refers to the virtio disk names vdb..vdf; create
 * matching aliases so the stock second-stage init can re-mount /data etc. */
static void link_legacy(const char *legacy, const char *target)
{
    if (!legacy)
        return;
    char lp[512];
    snprintf(lp, sizeof(lp), "/dev/block/%s", legacy);
    (void)unlink(lp);
    if (symlink(target, lp) != 0)
        logmsg("boot_init: WARN alias %s -> %s failed: %s\n", lp, target, strerror(errno));
}

static void link_part(const char *name, const char *img, int needrw, int writable,
                      const char *legacy)
{
    char path[512];
    snprintf(path, sizeof(path), "%s/%s", g_media_dir, img);

    if (access(path, F_OK) != 0) {
        logmsg("boot_init: WARN %s missing, skip %s\n", path, name);
        return;
    }

    char staged[512];
    if (needrw && !writable) {
        snprintf(staged, sizeof(staged), RWSTAGE "/%s.img", name);
        logmsg("boot_init: copying %s -> %s (tmpfs)\n", path, staged);
        if (copy_file(path, staged) != 0) {
            logmsg("boot_init: WARN copy %s failed: %s\n", path, strerror(errno));
            return;
        }
        strncpy(path, staged, sizeof(path) - 1);
    }

    char *dev = loop_attach(path, needrw);
    if (!dev) {
        logmsg("boot_init: WARN loop_attach %s failed\n", path);
        return;
    }

    char linkpath[512];
    snprintf(linkpath, sizeof(linkpath), BYNAME_DIR "/%s", name);
    (void)unlink(linkpath);
    if (symlink(dev, linkpath) != 0)
        logmsg("boot_init: WARN symlink %s -> %s failed: %s\n", linkpath, dev, strerror(errno));
    else
        logmsg("boot_init: %s -> %s (%s)\n", name, dev, path);
    link_legacy(legacy, dev);
    free(dev);
}

int main(void)
{
    (void)mount("proc", "/proc", "proc", 0, NULL);
    (void)mount("sysfs", "/sys", "sysfs", 0, NULL);
    (void)mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
    if (access("/dev/null", F_OK) != 0)
        (void)mknod("/dev/null", S_IFCHR | 0666, makedev(1, 3));
    /* Make fd 0/1/2 refer to the console if the kernel did not set them up,
     * so logmsg's console writes are visible on the real screen/serial. */
    int cfd = open("/dev/console", O_RDWR);
    if (cfd >= 0) {
        (void)dup2(cfd, 0);
        (void)dup2(cfd, 1);
        (void)dup2(cfd, 2);
        if (cfd > 2)
            close(cfd);
    }
    /* Open /dev/kmsg only after devtmpfs is mounted: then every diagnostic
     * below also reaches dmesg / the real console. */
    kmsg_fd = open("/dev/kmsg", O_WRONLY);
    logmsg("boot_init: start (kmsg_fd=%d console_fd=%d)\n", kmsg_fd, cfd);

    mkdir_p(BYNAME_DIR, 0755);
    mkdir_p(MEDIA_MP, 0755);
    mkdir_p(PART_MP, 0755);
    mkdir_p(ISO_MP, 0755);
    mkdir_p(RWSTAGE, 0755);
    mkdir_p(PSTORE_MP, 0755);

    /* If the previous boot panicked, pstore holds the tail of its console log
     * in EFI NVRAM; print it now so it is visible without another OS. */
    dump_pstore();

    logmsg("boot_init: searching for OHOS boot medium ...\n");
    int tries = 0;
    while (!find_media() && tries < 30) {
        tries++;
        sleep(1);
    }
    if (!g_media_dev) {
        logmsg("boot_init: FATAL no medium with system.img after %ds\n", tries);
        dump_block_devs();
        /* Keep the last messages on screen instead of dying before the
         * (broken) ramdisk shell can print anything. */
        for (;;)
            sleep(3600);
    }
    logmsg("boot_init: media=%s fs=%s dir=%s\n", g_media_dev, g_media_fs,
           g_media_dir);

    int writable = 0;
    if (!g_media_ro) {
        char rwtest[512];
        snprintf(rwtest, sizeof(rwtest), "%s/.ohos_rw_test", g_media_dir);
        int tf = open(rwtest, O_WRONLY | O_CREAT, 0600);
        if (tf >= 0) {
            writable = 1;
            close(tf);
            (void)unlink(rwtest);
        }
    }
    logmsg("boot_init: medium writable=%d\n", writable);

    link_part("system",    "system.img",    0, writable, "vdb");
    link_part("vendor",    "vendor.img",    0, writable, "vdc");
    link_part("sys_prod",  "sys_prod.img",  1, writable, "vdd");
    link_part("chip_prod", "chip_prod.img", 1, writable, "vde");
    link_part("userdata",  "userdata.img",  1, writable, "vdf");

    /* Persist this boot's marker + pstore dump to the boot medium: the medium
     * root AND /data (looped userdata.img).  Non-fatal on any failure; the
     * internal disk / its ESP is intentionally never used. */
    early_log_prev();

    logmsg("boot_init: handing off to /init\n");
    (void)execl("/init", "init", NULL);
    logmsg("boot_init: exec /init failed: %s\n", strerror(errno));
    return 1;
}
