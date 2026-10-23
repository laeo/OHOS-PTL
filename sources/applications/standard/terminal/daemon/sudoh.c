/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 OpenHarmony PC Image Contributors
 */

/*
 * sudoh - minimal setuid-root sudo for the OHOS pc_ptl Alpine overlay.
 *
 * The terminal session runs as the unprivileged user `ohos` (uid 1000), but
 * privilege escalation must still be possible.  /data is mounted `nosuid`, so
 * the helper lives on the read-only system partition (/system/bin/sudo,
 * mode 04755) and is therefore honored by the kernel.
 *
 * Behaviour (no password; the device is a single-user developer box):
 *   sudo CMD [args]        -> run CMD as root
 *   sudo -u USER CMD ...   -> run CMD as USER (name or numeric uid)
 *   sudo -i | -l | --login -> root login shell (Alpine zsh via its loader)
 *   sudo -s | --shell      -> root interactive shell
 *   (no command)           -> root interactive shell
 *
 * Build (static): gcc -static -O2 -o sudoh sudoh.c
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pwd.h>
#include <grp.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/stat.h>

/* The helper runs both on the OHOS root (legacy overlay session) and inside
 * the terminal's chroot sandbox, where the Alpine rootfs *is* "/" and the
 * absolute /data/alpine/... paths do not exist.  Pick the right set once. */
static int in_chroot(void)
{
    return access("/data/alpine", F_OK) != 0 && access("/etc/apk", F_OK) == 0;
}

static const char *ROOT_HOME_V;
static const char *DEF_SHELL_V;
static const char *LOADER_V;
static const char *LIBPATH_V;
static const char *PASSWD_FILE_V;

static void pick_paths(void)
{
    if (in_chroot()) {
        ROOT_HOME_V = "/root";
        DEF_SHELL_V = "/bin/zsh";
        LOADER_V = "/lib/ld-musl-x86_64.so.1";
        LIBPATH_V = "/lib:/usr/lib:/usr/lib/sudo";
        PASSWD_FILE_V = "/etc/passwd";
    } else {
        ROOT_HOME_V = "/data/alpine/root";
        DEF_SHELL_V = "/data/alpine/bin/zsh";
        LOADER_V = "/data/alpine/lib/ld-musl-x86_64.so.1";
        LIBPATH_V = "/data/alpine/lib:/data/alpine/usr/lib:/data/alpine/usr/lib/sudo";
        PASSWD_FILE_V = "/data/alpine/etc/passwd";
    }
}

struct acct {
    uid_t uid;
    gid_t gid;
    char home[256];
    char shell[256];
    char name[64];
};

static int lookup_user(const char *who, struct acct *a)
{
    memset(a, 0, sizeof(*a));
    strncpy(a->name, "root", sizeof(a->name) - 1);
    strncpy(a->home, ROOT_HOME_V, sizeof(a->home) - 1);
    strncpy(a->shell, DEF_SHELL_V, sizeof(a->shell) - 1);
    a->uid = 0; a->gid = 0;

    if (who == NULL || strcmp(who, "root") == 0) { return 0; }

    /* numeric uid? */
    int numeric = 1;
    for (const char *p = who; *p; p++) { if (*p < '0' || *p > '9') { numeric = 0; break; } }
    if (numeric) {
        a->uid = (uid_t)atoi(who);
        a->gid = a->uid;
        snprintf(a->name, sizeof(a->name), "%s", who);
        return 0;
    }

    FILE *f = fopen(PASSWD_FILE_V, "r");
    if (f == NULL) return -1;
    char line[1024];
    int found = -1;
    while (fgets(line, sizeof(line), f) != NULL) {
        /* name:passwd:uid:gid:gecos:home:shell */
        char *nl = strchr(line, '\n');
        if (nl) *nl = 0;
        char *p = line;
        char *f0 = strsep(&p, ":");
        (void)strsep(&p, ":");
        char *f2 = strsep(&p, ":");
        char *f3 = strsep(&p, ":");
        (void)strsep(&p, ":");
        char *f5 = strsep(&p, ":");
        char *f6 = strsep(&p, ":");
        if (f0 && strcmp(f0, who) == 0) {
            a->uid = f2 ? (uid_t)atoi(f2) : 0;
            a->gid = f3 ? (gid_t)atoi(f3) : 0;
            if (f5 && f5[0]) snprintf(a->home, sizeof(a->home), "%s", f5);
            if (f6 && f6[0]) snprintf(a->shell, sizeof(a->shell), "%s", f6);
            snprintf(a->name, sizeof(a->name), "%s", f0);
            found = 0;
            break;
        }
    }
    fclose(f);
    return found;
}

/* Leave the terminal's chroot sandbox.
 *
 * The sandbox is a plain chroot() of /data/alpine inside a private mount
 * namespace, so a root process inside it can step back out with the classic
 * "chroot to a subdirectory, walk up, chroot /" sequence (CAP_SYS_CHROOT).
 * Used by `ohos-diag` (sudo -C) so the session can still run the real
 * diagnostic collector, which needs the OHOS /data tree. */
static int escape_chroot(void)
{
    /* chroot() does not move the working directory, so after chroot(dir) the
     * cwd still points at the *outer* root.  Climbing ".." from there walks
     * back out of the new root, and chroot(".") then re-roots us at the real
     * filesystem. */
    if (chdir("/") != 0) return -1;
    (void)mkdir("/tmp/.ohos-escape", 0755);
    if (chroot("/tmp/.ohos-escape") != 0) return -1;
    if (chdir("../../..") != 0) return -1;
    if (chroot(".") != 0) return -1;
    if (access("/data", F_OK) != 0) return -1;   /* sanity: really escaped? */
    return 0;
}

static void exec_shell_as(const struct acct *a, int login)
{
    setenv("HOME", a->home, 1);
    setenv("USER", a->name, 1);
    setenv("LOGNAME", a->name, 1);
    setenv("SHELL", a->shell, 1);
    if (a->uid == 0) {
        execl(LOADER_V, "ld-musl-x86_64.so.1", "--library-path", LIBPATH_V,
              a->shell, login ? "-l" : "-i", (char *)NULL);
    }
    execl(a->shell, login ? "-zsh" : "zsh", login ? "-l" : "-i", (char *)NULL);
    if (access("/bin/sh", X_OK) == 0) { execl("/bin/sh", "sh", login ? "-l" : "-i", (char *)NULL); }
    execl("/system/bin/sh", "sh", login ? "-l" : "-i", (char *)NULL);
    _exit(127);
}

int main(int argc, char **argv)
{
    int login = 0, ishell = 0, escape = 0;
    const char *user = NULL;
    int i = 1;

    pick_paths();

    /* drop dangerous preload hooks from the inherited environment */
    unsetenv("LD_PRELOAD");
    unsetenv("LD_AUDIT");

    for (; i < argc; i++) {
        const char *arg = argv[i];
        if (strcmp(arg, "--") == 0) { i++; break; }
        if (arg[0] != '-' || arg[1] == '\0') { break; } /* command starts here */
        if (strcmp(arg, "-u") == 0) { if (i + 1 < argc) user = argv[++i]; continue; }
        if (strncmp(arg, "-u", 2) == 0 && arg[2]) { user = arg + 2; continue; }
        if (strcmp(arg, "-g") == 0) { if (i + 1 < argc) i++; continue; }
        if (strncmp(arg, "-g", 2) == 0 && arg[2]) { continue; }
        if (strcmp(arg, "-C") == 0 || strcmp(arg, "--escape-chroot") == 0) { escape = 1; continue; }
        if (strcmp(arg, "-i") == 0 || strcmp(arg, "-l") == 0 ||
            strcmp(arg, "--login") == 0) { login = 1; continue; }
        if (strcmp(arg, "-s") == 0 || strcmp(arg, "--shell") == 0) { ishell = 1; continue; }
        if (strcmp(arg, "-H") == 0) { continue; }
        /* -n -E -k -S -b -P -A -e ... : accept and ignore */
        continue;
    }

    struct acct a;
    if (lookup_user(user, &a) != 0) {
        fprintf(stderr, "sudo: unknown user: %s\n", user ? user : "(null)");
        return 1;
    }

    if (geteuid() != 0) {
        fprintf(stderr, "sudo: effective uid is not 0 (setuid bit missing?)\n");
        return 1;
    }

    /* target is root: make every id root and run the command. */
    if (a.uid == 0) {
        (void)setgroups(0, NULL);
        (void)setgid(0);
        (void)setuid(0);
        if (escape && i < argc) {
            if (escape_chroot() != 0) {
                fprintf(stderr, "sudo: chroot escape failed: %s\n", strerror(errno));
                return 1;
            }
        }
        if (login || ishell || i >= argc) { exec_shell_as(&a, login); }
        execvp(argv[i], &argv[i]);
        fprintf(stderr, "sudo: %s: %s\n", argv[i], strerror(errno));
        return 127;
    }

    /* target is a regular user: drop to it. */
    (void)setgroups(0, NULL);
    if (setgid(a.gid) != 0) { perror("sudo: setgid"); return 1; }
    if (setuid(a.uid) != 0) { perror("sudo: setuid"); return 1; }
    if (login || ishell || i >= argc) { exec_shell_as(&a, login); }
    setenv("HOME", a.home, 1);
    setenv("USER", a.name, 1);
    setenv("LOGNAME", a.name, 1);
    execvp(argv[i], &argv[i]);
    fprintf(stderr, "sudo: %s: %s\n", argv[i], strerror(errno));
    return 127;
}
