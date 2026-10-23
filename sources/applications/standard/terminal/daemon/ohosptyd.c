/*
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 OpenHarmony PC Image Contributors
 */

/*
 * ohosptyd - real-PTY shell daemon for OHOS (pc_ptl / x86_64).
 *
 * Allocates a genuine pseudo-terminal (posix_openpt + setsid + TIOCSCTTY +
 * dup2) and execs an interactive login shell inside it, so the ArkUI terminal
 * front end gets real tty semantics: prompt, line editing, history, ANSI
 * colours, Ctrl-C/Ctrl-Z, job control and SIGWINCH on resize.
 *
 * Session model (this revision): **session-scoped chroot sandbox**.
 *
 *   The daemon itself stays the privileged broker: it runs as root from an
 *   init service (secon u:r:su:s0), listens on 127.0.0.1:7788, and for every
 *   accepted connection builds a *private* namespace for the session:
 *
 *     unshare(CLONE_NEWNS | CLONE_NEWUTS)          +  / --propagation private
 *       tmpfs   /tmp  /run  /dev/shm               (private scratch)
 *       bind    /dev   (recursive, so pts+shm appear; private tmpfs over shm)
 *       proc    /proc
 *       sysfs   /sys
 *       bind ro /system /vendor /chip_prod /sys_prod   -> same paths in chroot
 *       bind rw  <HMDFS user share>  -> /mnt/share/{Download,Documents,...}
 *       chroot  /data/alpine      then setgid/setuid(1000) and exec /bin/zsh
 *
 *   Consequences / why:
 *     - the session userland is Alpine's own musl + libc, so `apk`, `git`,
 *       `curl`, `zsh` and `sudo apk update` work with *no* symbol errors
 *       (the previous "Alpine overlay on the OHOS root" design leaked OHOS'
 *       trimmed musl and the setuid-stripped LD_LIBRARY_PATH into them).
 *     - OHOS CLI stays usable because /system & /vendor are read-only bound
 *       into the sandbox: param / bm / aa / hidumper / ohos-diag all work.
 *     - /data is deliberately NOT bind mounted as a whole, so the Alpine
 *       secrets (apk keys, ssh keys, config) stay invisible to OHOS apps; the
 *       only OHOS data reachable without root is the user-visible HMDFS share
 *       at /mnt/share.
 *     - Everything the session does to the *mount* namespace dies with it:
 *       closing the terminal tab unmounts the whole sandbox.
 *     - root inside the sandbox (`sudo`) can still reach the real system
 *       through /system/bin/sudo + the chroot escape wrapper `ohos-diag`; this
 *       is the intended "privileged broker" escape hatch.
 *
 * Listen: 127.0.0.1:7788  (one pty per accepted connection; concurrent)
 *
 * Wire protocol
 *   client -> daemon frames:  u8 type | u16 len (LE) | u8 payload[len]
 *       type 0 : terminal input bytes   (keystrokes / paste)
 *       type 1 : window size, payload = cols(LE16) rows(LE16) xpix(LE16) ypix(LE16)
 *       type 2 : kill the foreground process group (SIGTERM to child session)
 *   daemon -> client : raw terminal output bytes (no framing)
 *
 * Debug helper (also used by the verification flow):
 *   ohosshd --chroot-exec CMD [ARGS...]   run CMD inside a throw-away sandbox
 *                                         with stdout on the caller's tty/pipe
 *
 * Static x86_64 build, uses only glibc:
 *   gcc -static -O2 -o ohosptyd ohosptyd.c
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <fcntl.h>
#include <grp.h>
#include <dirent.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/sysmacros.h>
#include <termios.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sched.h>
#include <ctype.h>

#define LISTEN_ADDR  "127.0.0.1"
#define LISTEN_PORT  7788
#define LOGFILE      "/data/ohosptyd.log"

/* ---- Alpine rootfs (on /data, i.e. p6) and the session account ----------- */
#define ALPINE_ROOT    "/data/alpine"
#define ALPINE_HOME    "/data/alpine/home/system"
#define LEGACY_HOME    "/data/alpine/home/ohos"
#define ALPINE_ZSH     "/data/alpine/bin/zsh"

/* OHOS' own musl loader plus every directory that holds OHOS shared objects.
 * Needed because OHOS binaries are linked against /lib/ld-musl-x86_64.so.1 and
 * their libraries are searched along OHOS' default path -- inside the sandbox
 * /lib and /usr/lib are *Alpine's*, so the loader must be told explicitly. */
#define OHOS_LOADER "/system/lib/ld-musl-x86_64.so.1"
#define OHOS_LIBPATH \
    "/system/lib64:/system/lib64/platformsdk:/system/lib64/chipset-sdk:" \
    "/system/lib64/chipset-sdk-sp:/system/lib64/module:/system/lib64/extensionability:" \
    "/system/lib64/appspawn:/system/lib64/init:/system/lib64/graphics3d:" \
    "/system/lib64/media:/system/lib64/edm_plugin:/system/lib64/ndk:" \
    "/system/lib64/appdetailability:/system/lib64/chipset-pub-sdk"

/* ---- paths as seen from *inside* the chroot ----------------------------- */
#define CH_HOME     "/home/system"
#define CH_SHELL    "/bin/zsh"
#define CH_SHARE    "/mnt/share"
#define CH_TMP      "/tmp"
#define CH_RUN      "/run"
#define CH_SHM      "/dev/shm"

#define USER_NAME  "system"
#define USER_UID   1000
#define USER_GID   1000

/* Directory that holds the generated OHOS CLI launchers *inside* the sandbox.
 *
 * It is the **last** element of the session PATH on purpose.  The previous
 * layout put the launchers in /usr/local/sbin (PATH head), which meant every
 * OHOS tool *shadowed* the Alpine program of the same name.  That is fatal for
 * anything a user installs later with apk: `sudo apk add nodejs` puts
 * /usr/bin/node in place, but `node` still resolved to the launcher for the
 * OHOS /system/bin/node shell wrapper and died with
 * "/system/bin/node: Not a valid dynamic program".
 * With the launcher directory last, Alpine always wins for names Alpine owns
 * (present *or installed later*), and the launchers only serve the names that
 * Alpine does not have. */
#define CH_OHOS_BIN  "/usr/local/ohos-bin"

/* Bumped whenever the provisioned session files change, so an already
 * provisioned device is repaired on the next daemon start. */
#define SESSION_ENV_VER "chroot2"

/* Hostname for the session: taken from the OHOS device name
 * (const.product.name, the same value deviceInfo.marketName exposes). */
static char g_host[128] = "OpenHarmony";

/* Canonical environment file (sourced from $HOME startup files).  The path is
 * the same file on the host and inside the chroot (/data/alpine/etc/...). */
#define SESSION_ENV "/data/alpine/etc/ohos-session-env.sh"
#define SESSION_ENV_VER_FILE "/data/alpine/etc/.ohos-session-ver"

/* The user visible HMDFS share.  Real device paths differ slightly between
 * builds, so probe the known candidates and keep the first one that really
 * holds the public folders. */
static const char *SHARE_CANDIDATES[] = {
    "/storage/media/100/local/files",
    "/storage/users/100/current/files",
    "/storage/media/100/local",
    "/storage/users/100/current",
    "/storage/el2/100/base/haps/entry/files",
    NULL
};
static const char *SHARE_SUBDIRS[] = {
    "Download", "Documents", "Pictures", "Camera", "Videos", "Music",
    "Audios", "Docs", "Movies", "MusicPlaylist", "Ringtones", NULL
};

static int g_log = -1;

static void logf_(const char *fmt, ...)
{
    if (g_log < 0) return;
    char buf[600];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n > 0) { if (write(g_log, buf, (size_t)n) < 0) { /* ignore */ } }
}

static int write_all(int fd, const void *buf, size_t len)
{
    const char *p = (const char *)buf;
    while (len > 0) {
        ssize_t w = write(fd, p, len);
        if (w < 0) { if (errno == EINTR) continue; return -1; }
        p += w; len -= (size_t)w;
    }
    return 0;
}

static void write_file(const char *path, const char *data, int mode)
{
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, mode);
    if (fd < 0) return;
    if (write_all(fd, data, strlen(data)) < 0) { /* ignore */ }
    close(fd);
}

static int write_file_if_missing(const char *path, const char *data, int mode)
{
    if (access(path, F_OK) == 0) return 0;
    write_file(path, data, mode);
    return 1;
}

/* Does any line of `path` start with "name:" ? */
static int file_has_entry(const char *path, const char *name)
{
    FILE *f = fopen(path, "r");
    if (f == NULL) return 0;
    size_t nl = strlen(name);
    char line[1024];
    int found = 0;
    while (fgets(line, sizeof(line), f) != NULL) {
        if (strncmp(line, name, nl) == 0 && line[nl] == ':') { found = 1; break; }
    }
    fclose(f);
    return found;
}

static void append_line(const char *path, const char *line)
{
    int fd = open(path, O_WRONLY | O_APPEND);
    if (fd < 0) {
        fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd < 0) return;
    }
    (void)write_all(fd, line, strlen(line));
    close(fd);
}

static void mkdir_p(const char *path, int mode)
{
    char tmp[512];
    snprintf(tmp, sizeof(tmp), "%s", path);
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = 0;
            (void)mkdir(tmp, mode);
            *p = '/';
        }
    }
    (void)mkdir(tmp, mode);
}

/* run a shell command and capture up to outsz-1 bytes of stdout/stderr. */
static void run_capture(const char *cmd, char *out, size_t outsz)
{
    out[0] = 0;
    int fds[2];
    if (pipe(fds) != 0) return;
    pid_t pid = fork();
    if (pid < 0) { close(fds[0]); close(fds[1]); return; }
    if (pid == 0) {
        close(fds[0]);
        dup2(fds[1], 1);
        dup2(fds[1], 2);
        close(fds[1]);
        execl("/system/bin/sh", "sh", "-c", cmd, (char *)NULL);
        execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
        _exit(127);
    }
    close(fds[1]);
    size_t n = 0;
    ssize_t r;
    while (n < outsz - 1 && (r = read(fds[0], out + n, outsz - 1 - n)) > 0) { n += (size_t)r; }
    out[n] = 0;
    (void)waitpid(pid, NULL, 0);
}

/* read "key=value" from an OHOS .para file (fallback for the param service). */
static int read_para_value(const char *path, const char *key, char *val, size_t valsz)
{
    FILE *f = fopen(path, "r");
    if (f == NULL) return 0;
    size_t kl = strlen(key);
    char line[512];
    int found = 0;
    while (fgets(line, sizeof(line), f) != NULL) {
        if (strncmp(line, key, kl) == 0 && line[kl] == '=') {
            char *v = line + kl + 1;
            char *nl = strchr(v, '\n');
            if (nl) *nl = 0;
            snprintf(val, valsz, "%s", v);
            found = 1;
        }
    }
    fclose(f);
    return found;
}

/* turn a device-name string into a valid hostname: drop surrounding quotes and
 * whitespace and replace inner spaces with '-'. */
static void sanitize_hostname(char *s)
{
    char *p = s;
    while (*p != 0 && (isspace((unsigned char)*p) || *p == '"' || *p == '\'')) p++;
    if (p != s) memmove(s, p, strlen(p) + 1);
    size_t n = strlen(s);
    while (n > 0 && (isspace((unsigned char)s[n - 1]) || s[n - 1] == '"' || s[n - 1] == '\'')) s[--n] = 0;
    for (char *q = s; *q; q++) {
        if (isspace((unsigned char)*q)) *q = '-';
    }
}

/* Hostname = OHOS device name (const.product.name).  Same value the device
 * reports through deviceInfo.marketName; the session's UTS namespace is set to
 * it so `hostname`, `$HOST` and the shell prompt all follow OHOS. */
static void load_device_name(void)
{
    char raw[256];
    raw[0] = 0;
    run_capture("/system/bin/param get const.product.name", raw, sizeof(raw));
    sanitize_hostname(raw);
    if (raw[0] != 0) {
        snprintf(g_host, sizeof(g_host), "%s", raw);
    } else {
        char v[256];
        if (read_para_value("/system/etc/param/ohos.para", "const.product.name", v, sizeof(v))) {
            sanitize_hostname(v);
            if (v[0] != 0) { snprintf(g_host, sizeof(g_host), "%s", v); }
        }
    }
    logf_("device name (hostname) = %s\n", g_host);
}

/* ------------------------------------------------------------------ *
 * Session files (all paths inside the chroot: /etc, /home/system, ...)
 * ------------------------------------------------------------------ */

/* Canonical, idempotent session environment (single source of truth).
 * PATH is the stock Alpine PATH plus two managed directories:
 *   - /usr/local/bin (head): the daemon's own shims (sudo/whoami/ohos-diag);
 *   - /usr/local/ohos-bin (**tail**): generated launchers for OHOS tools that
 *     Alpine does not ship.  It is last so that anything a user installs later
 *     with `apk add` (nodejs, npm, python, ...) wins over the launcher of the
 *     same name -- see CH_OHOS_BIN.  The guard keeps PATH from being rebuilt
 *     (and duplicated) on every re-source. */
static const char SESSION_ENV_SH[] =
    "# /etc/ohos-session-env.sh  (real file: " ALPINE_ROOT "/etc/ohos-session-env.sh)\n"
    "# pc_ptl terminal session environment -- single source of truth.\n"
    "# Sourced from ~/.zshenv ~/.zprofile ~/.zshrc ~/.profile ~/.bashrc ~/.mkshrc\n"
    "# The session runs inside a chroot of /data/alpine (see ohosptyd.c), so all\n"
    "# paths below are *chroot* paths and Alpine's own musl/libc are in charge.\n"
    "# /system/bin is deliberately NOT on PATH: OHOS tools are musl binaries whose\n"
    "# interpreter is /lib/ld-musl-x86_64.so.1, which inside this chroot is\n"
    "# *Alpine's* loader -> \"symbol not found\".  Instead the daemon generates\n"
    "# launchers in /usr/local/ohos-bin (param, bm, aa, hidumper, node, ...) that\n"
    "# invoke OHOS' own loader; `ohos CMD` runs any OHOS binary the same way.\n"
    "case \":$PATH:\" in\n"
    "  *\"/usr/local/ohos-bin\"*) ;;  # already applied\n"
    "  *) PATH=\"/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/ohos-bin\" ;;\n"
    "esac\n"
    "export PATH\n"
    "unset LD_LIBRARY_PATH\n"
    "export TERMINFO=\"/etc/terminfo\"\n"
    "export TERMINFO_DIRS=\"/etc/terminfo\"\n"
    "export APK_CONFIG=\"/etc/apk/config\"\n"
    "export SSL_CERT_FILE=\"/etc/ssl/certs/ca-certificates.crt\"\n"
    "export CURL_CA_BUNDLE=\"$SSL_CERT_FILE\"\n"
    "export TERM=\"${TERM:-xterm-256color}\"\n"
    "export COLORTERM=\"${COLORTERM:-truecolor}\"\n"
    "export LANG=\"${LANG:-C.UTF-8}\"\n"
    "export LC_ALL=\"${LC_ALL:-C.UTF-8}\"\n"
    ": \"${HOME:=/home/system}\"; export HOME\n"
    "export USER=\"${USER:-system}\" LOGNAME=\"${LOGNAME:-system}\"\n"
    "export SHELL=\"/bin/zsh\"\n"
    "export TMPDIR=\"/tmp\"\n"
    "export EDITOR=\"${EDITOR:-vim}\" PAGER=\"${PAGER:-less}\"\n"
    "# the OHOS user-visible share (HMDFS), read-write\n"
    "export OHOS_SHARE=\"/mnt/share\"\n";

static const char ZSHENV_SH[] =
    "[ -r /etc/ohos-session-env.sh ] && . /etc/ohos-session-env.sh\n"
    "module_path=(/usr/lib/zsh/5.9)\n"
    "fpath=(/usr/share/zsh/functions/*(/N) /usr/share/zsh/site-functions $fpath)\n";

static const char ZPROFILE_SH[] =
    "[ -r /etc/ohos-session-env.sh ] && . /etc/ohos-session-env.sh\n";

static const char ZSHRC_SH[] =
    "[ -r /etc/ohos-session-env.sh ] && . /etc/ohos-session-env.sh\n"
    "export ZSH=/usr/share/oh-my-zsh\n"
    "ZSH_THEME=\"ascii\"\n"
    "zstyle ':omz:update' mode disabled\n"
    "DISABLE_AUTO_UPDATE=\"true\"\n"
    "DISABLE_UPDATE_PROMPT=\"true\"\n"
    "HYPHEN_INSENSITIVE=\"true\"\n"
    "COMPLETION_WAITING_DOTS=\"true\"\n"
    "export ZSH_COMPDUMP=\"$HOME/.zcompdump-$HOST\"\n"
    "plugins=(git)\n"
    "source $ZSH/oh-my-zsh.sh\n"
    "alias ll='ls -alF'\n"
    "alias la='ls -A'\n"
    "alias l='ls -CF'\n"
    "alias grep='grep --color=auto'\n"
    "alias ohos='ls /mnt/share'\n"
    "# make the session's user identity explicit and consistent with the OHOS\n"
    "# account (uid 1000); a function bypasses any PATH/hash lookup issue.\n"
    "whoami() { /system/bin/id -un }\n"
    "hostname() { local h; read -r h < /proc/sys/kernel/hostname; print -r -- \"$h\" }\n"
    "export EDITOR=vim\n"
    "export PAGER=less\n"
    "# Desktop-terminal style tab title: user@host: cwd (OSC 0/2).\n"
    "autoload -Uz add-zsh-hook\n"
    "_ohos_set_title() { print -Pn \"\\e]0;%n@%M: %~\\a\" }\n"
    "add-zsh-hook precmd _ohos_set_title\n";

static const char PROFILE_SH[] =
    "[ -r /etc/ohos-session-env.sh ] && . /etc/ohos-session-env.sh\n";

static const char BASHRC_SH[] =
    "[ -r /etc/ohos-session-env.sh ] && . /etc/ohos-session-env.sh\n";

static const char MKSHRC_SH[] =
    "[ -r /etc/ohos-session-env.sh ] && . /etc/ohos-session-env.sh\n"
    "PS1='$(pwd) \\$ '\n";

/* ASCII-only prompt theme.  The old copy used the zsh prompt escape %h
 * (history event number) instead of %m, so the prompt showed an ever
 * increasing "1", "2", ... after the '@'. */
static const char ASCII_THEME[] =
    "# ASCII-only prompt (no Nerd Font glyphs / unicode -> no tofu boxes)\n"
    "PROMPT='%F{green}%n@%M%f:%F{blue}%~%f%# '\n"
    "RPROMPT=''\n";

/* /data is mounted nosuid, so the setuid-root helper must live on the
 * read-only system partition (/system/bin/sudo, mode 04755).  Inside the
 * chroot /system is bind-mounted read-only, and the helper is still honoured
 * by the kernel (the bind mount carries no nosuid flag). */
static const char SUDO_SHIM[] =
    "#!/bin/sh\n"
    "# forward to the setuid-root helper on the read-only system partition\n"
    "exec /system/bin/sudo \"$@\"\n";

/* Alpine has no `id -un` style whoami difference, but keep the OHOS account
 * name authoritative so prompt/$USER/whoami/id all agree. */
/* Generic escape hatch: run any OHOS binary through OHOS' own musl loader
 * (its ELF interpreter is /lib/ld-musl-x86_64.so.1, which resolves to Alpine's
 * loader inside the sandbox and therefore fails with "symbol not found"). */
static const char OHOS_SHIM[] =
    "#!/bin/sh\n"
    "# run an OHOS binary from inside the terminal sandbox with OHOS' own loader\n"
    "# usage: ohos /system/bin/<tool> [args...]   |   ohos <tool-in-/system/bin> [args...]\n"
    "# ELF binaries go through the musl loader; shell scripts (shebang, e.g.\n"
    "# /system/bin/node) are run by OHOS' own shell, again through the loader.\n"
    "case \"$1\" in\n"
    "  /*) ;;\n"
    "  *) _p=/system/bin/$1 ; shift ; set -- \"$_p\" \"$@\" ;;\n"
    "esac\n"
    "_t=$1 ; shift\n"
    "[ -x \"$_t\" ] || { echo \"ohos: $_t not found\" >&2; exit 127; }\n"
    "_m=$(dd if=\"$_t\" bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d ' \\n')\n"
    "if [ \"$_m\" = \"7f454c46\" ]; then\n"
    "  exec /system/lib/ld-musl-x86_64.so.1 --library-path " OHOS_LIBPATH " \"$_t\" \"$@\"\n"
    "fi\n"
    "exec /system/lib/ld-musl-x86_64.so.1 --library-path " OHOS_LIBPATH " /system/bin/sh \"$_t\" \"$@\"\n";

static const char WHOAMI_SHIM[] =
    "#!/bin/sh\n"
    "exec /system/bin/id -un\n";

/* ohos-diag entry point inside the sandbox.
 *
 * /system is bind-mounted read-only, so /system/bin/ohos-diag is reachable,
 * but the diagnostic data it walks (/data/app, /data/log, ...) is deliberately
 * NOT bind-mounted into the sandbox.  A root shell can legitimately escape the
 * chroot (CAP_SYS_CHROOT) and therefore run the real tool; an unprivileged
 * session is told to use `sudo`. */
static const char OHOSTDIAG_SHIM[] =
    "#!/bin/sh\n"
    "# ohos-diag inside the terminal sandbox.\n"
    "# /system/bin/ohos-diag is visible (read-only bind), but the OHOS data it\n"
    "# collects (/data/...) is not exposed to the sandbox, so escape the chroot\n"
    "# first -- that needs root, i.e. `sudo ohos-diag`.\n"
    "if [ \"$(id -u)\" != \"0\" ]; then\n"
    "    echo \"ohos-diag: 需要 root 才能读取系统诊断数据，请用: sudo ohos-diag $*\" >&2\n"
    "    echo \"ohos-diag: 沙箱内只暴露 /system/bin (只读) 与 /mnt/share。\" >&2\n"
    "    exit 1\n"
    "fi\n"
    "# -C makes the setuid helper leave the chroot before exec'ing the tool.\n"
    "# The path is the same before and after the escape (/system/bin/ohos-diag).\n"
    "exec /system/bin/sudo -C /system/bin/ohos-diag \"$@\"\n";

/* Alpine already provides this command name?  Then the Alpine one wins
 * (that is exactly what the chroot is for). */
static int alpine_has(const char *name)
{
    static const char *dirs[] = {
        "/usr/local/sbin", "/usr/local/bin", "/usr/sbin", "/usr/bin", "/sbin", "/bin", NULL
    };
    char p[512];
    for (int i = 0; dirs[i] != NULL; i++) {
        snprintf(p, sizeof(p), "%s%s/%s", ALPINE_ROOT, dirs[i], name);
        if (access(p, X_OK) == 0) { return 1; }
    }
    return 0;
}

static int is_exec_file(const char *path)
{
    struct stat st;
    if (stat(path, &st) != 0 || !S_ISREG(st.st_mode)) { return 0; }
    if ((st.st_mode & 0111) == 0) { return 0; }
    if (st.st_size < 4) { return 0; }
    return 1;
}

/* How must an OHOS executable be started inside the sandbox?
 *
 *  * ELF  -> OHOS' own musl loader plus an explicit --library-path.  This is
 *           the only way, because the ELF interpreter path /lib/ld-musl-*.so.1
 *           resolves to *Alpine's* loader inside the chroot, which then looks
 *           for OHOS' libraries in Alpine's library directories.
 *  * script (shebang pointing at /system/bin/sh, e.g. /system/bin/node,
 *    helpers) -> run it with OHOS' own shell.  Handing a *script* to the
 *           loader is what produced
 *           "/system/bin/node: Not a valid dynamic program" (the user-visible
 *           `node -v` failure); the kernel would have executed the shebang
 *           line correctly in the first place, but the loader refuses before
 *           that ever happens.
 *
 * Returns 'E' (ELF), 'S' (shell script) or 0 (anything else -> no launcher). */
static char ohos_entry_kind(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (f == NULL) { return 0; }
    char head[160];
    size_t n = fread(head, 1, sizeof(head) - 1, f);
    fclose(f);
    if (n < 4) { return 0; }
    head[n] = 0;
    if (head[0] == 0x7f && head[1] == 'E' && head[2] == 'L' && head[3] == 'F') {
        return 'E';
    }
    if (head[0] == '#' && head[1] == '!' && strchr(head, '\n') != NULL) {
        /* only trust interpreters that exist on the read-only system partition */
        if (strstr(head, "sh") != NULL) { return 'S'; }
        return 0;
    }
    return 0;
}

static void write_ohos_wrapper(const char *fullpath, const char *name)
{
    char body[1400];
    char dst[512];
    char kind = ohos_entry_kind(fullpath);
    if (kind == 'S') {
        snprintf(body, sizeof(body),
                 "#!/bin/sh\n"
                 "# OHOS CLI launcher (generated by ohosptyd): %s is a *shell\n"
                 "# script* (shebang), not an ELF binary, so handing it to the musl\n"
                 "# loader aborts with \"Not a valid dynamic program\".  Run it with\n"
                 "# OHOS' own shell -- itself started through OHOS' loader, because\n"
                 "# /system/bin/sh is an OHOS binary that Alpine's loader cannot load.\n"
                 "exec /system/lib/ld-musl-x86_64.so.1 --library-path " OHOS_LIBPATH " /system/bin/sh %s \"$@\"\n",
                 fullpath, fullpath);
    } else if (kind == 'E') {
        snprintf(body, sizeof(body),
                 "#!/bin/sh\n"
                 "# OHOS CLI launcher (generated by ohosptyd): run %s through OHOS' own\n"
                 "# musl loader -- inside the Alpine sandbox /lib/ld-musl-x86_64.so.1 is\n"
                 "# Alpine's, which cannot resolve OHOS' libraries.\n"
                 "exec /system/lib/ld-musl-x86_64.so.1 --library-path " OHOS_LIBPATH " %s \"$@\"\n",
                 fullpath, fullpath);
    } else {
        return;
    }
    snprintf(dst, sizeof(dst), "%s%s/%s", ALPINE_ROOT, CH_OHOS_BIN, name);
    write_file(dst, body, 0755);
}

/* Older experiments of this daemon installed a few hundred busybox shims into
 * /usr/local/bin (e.g. "exec /system/bin/sh /data/alpine/lib/ld-musl ... busybox
 * hostname").  Those absolute paths are meaningless inside the chroot, so every
 * one of them fails with a loader error and also hides the proper command.
 * /usr/local/bin is owned by this daemon -- wipe it, keeping only the three
 * files it manages itself. */
static void clean_legacy_shims(void)
{
    static const char *keep[] = { "sudo", "whoami", "ohos-diag", NULL };
    char dirpath[512];
    snprintf(dirpath, sizeof(dirpath), "%s/usr/local/bin", ALPINE_ROOT);
    DIR *d = opendir(dirpath);
    if (d == NULL) { return; }
    int removed = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.') { continue; }
        int keepit = 0;
        for (int i = 0; keep[i] != NULL; i++) {
            if (strcmp(e->d_name, keep[i]) == 0) { keepit = 1; break; }
        }
        if (keepit) { continue; }
        char p[768];
        snprintf(p, sizeof(p), "%s/%s", dirpath, e->d_name);
        if (unlink(p) == 0) { removed++; }
    }
    closedir(d);
    if (removed > 0) {
        logf_("provision: removed %d stale shims from /usr/local/bin\n", removed);
    }
}

/* The OHOS CLI launchers used to be generated into /usr/local/sbin (PATH head)
 * in a previous revision.  They must not stay there: on PATH head they shadow
 * the Alpine program of the same name, which is exactly what broke
 * `apk add nodejs` followed by `node -v`.  Remove every launcher this daemon
 * generated earlier (identified by its own banner) plus the old `ohos` runner,
 * which is now written to CH_OHOS_BIN.  Anything else a user may have put in
 * /usr/local/sbin is left untouched. */
static int is_our_launcher(const char *path)
{
    FILE *f = fopen(path, "r");
    if (f == NULL) { return 0; }
    char line[512];
    char acc[1024];
    size_t n = 0;
    for (int i = 0; i < 6 && fgets(line, sizeof(line), f) != NULL; i++) {
        size_t l = strlen(line);
        if (n + l < sizeof(acc) - 1) { memcpy(acc + n, line, l); n += l; }
    }
    fclose(f);
    acc[n] = 0;
    return strstr(acc, "OHOS CLI launcher (generated by ohosptyd)") != NULL ||
           strstr(acc, "run an OHOS binary from inside the terminal sandbox") != NULL;
}

static void clean_stale_launcher_dir(void)
{
    char dirpath[512];
    snprintf(dirpath, sizeof(dirpath), "%s/usr/local/sbin", ALPINE_ROOT);
    DIR *d = opendir(dirpath);
    if (d == NULL) { return; }
    int removed = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.') { continue; }
        char p[768];
        snprintf(p, sizeof(p), "%s/%s", dirpath, e->d_name);
        if (!is_our_launcher(p)) { continue; }
        if (unlink(p) == 0) { removed++; }
    }
    closedir(d);
    if (removed > 0) {
        logf_("provision: removed %d stale launchers from /usr/local/sbin "
              "(now generated into %s instead)\n", removed, CH_OHOS_BIN);
    }
}

static void build_ohos_cli_wrappers(void)
{
    static const char *srcdirs[] = { "/system/bin", "/vendor/bin", NULL };
    int made = 0;
    mkdir_p(ALPINE_ROOT "/usr/local/sbin", 0755);
    mkdir_p(ALPINE_ROOT "/usr/local/bin", 0755);
    mkdir_p(ALPINE_ROOT CH_OHOS_BIN, 0755);
    for (int i = 0; srcdirs[i] != NULL; i++) {
        DIR *d = opendir(srcdirs[i]);
        if (d == NULL) { continue; }
        struct dirent *e;
        while ((e = readdir(d)) != NULL) {
            if (e->d_name[0] == '.') { continue; }
            char full[512];
            snprintf(full, sizeof(full), "%s/%s", srcdirs[i], e->d_name);
            if (!is_exec_file(full)) { continue; }
            if (alpine_has(e->d_name)) { continue; }
            write_ohos_wrapper(full, e->d_name);
            made++;
        }
        closedir(d);
    }
    logf_("provision: %d OHOS CLI launchers in %s\n", made, CH_OHOS_BIN);
}

/* /etc/apk/config of the old overlay layout carried "root /data/alpine".
 * Inside the chroot the Alpine rootfs *is* "/", so that line makes every apk
 * command die with "ERROR: Unable to open root: No such file or directory".
 * Drop it (keeping every other setting) -- this is what makes
 * `sudo apk update` work again. */
static void fix_apk_root_config(void)
{
    char path[512];
    snprintf(path, sizeof(path), "%s/etc/apk/config", ALPINE_ROOT);
    FILE *f = fopen(path, "r");
    if (f == NULL) { return; }
    char keep[4096];
    size_t n = 0;
    int changed = 0;
    char line[1024];
    while (fgets(line, sizeof(line), f) != NULL) {
        const char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (strncmp(p, "root ", 5) == 0 || strncmp(p, "root\t", 5) == 0 ||
            strcmp(p, "root\n") == 0) {
            changed = 1;
            continue;
        }
        size_t l = strlen(line);
        if (n + l < sizeof(keep) - 1) { memcpy(keep + n, line, l); n += l; }
    }
    fclose(f);
    if (!changed) { return; }
    keep[n] = 0;
    write_file(path, keep, 0644);
    logf_("provision: dropped the stale \"root\" line from /etc/apk/config\n");
}

/* The sandbox shares the host network namespace, so Alpine only needs the
 * resolver configuration OHOS uses. */
static void copy_resolv(void)
{
    char dst[512];
    snprintf(dst, sizeof(dst), "%s/etc/resolv.conf", ALPINE_ROOT);
    struct stat st;
    if (stat(dst, &st) == 0 && st.st_size > 0) { return; }
    char buf[2048];
    size_t n = 0;
    FILE *in = fopen("/system/etc/resolv.conf", "r");
    if (in != NULL) {
        n = fread(buf, 1, sizeof(buf) - 1, in);
        fclose(in);
    }
    if (n == 0) {
        snprintf(buf, sizeof(buf), "nameserver 8.8.8.8\n");
        n = strlen(buf);
    }
    buf[n] = 0;
    write_file(dst, buf, 0644);
}

static void ensure_owner(const char *path)
{
    (void)chown(path, (uid_t)USER_UID, (gid_t)USER_GID);
}

static int session_files_need_refresh(void)
{
    char have[64] = "";
    FILE *f = fopen(SESSION_ENV_VER_FILE, "r");
    if (f != NULL) {
        if (fgets(have, sizeof(have), f) != NULL) {
            char *nl = strchr(have, '\n');
            if (nl) *nl = 0;
        }
        fclose(f);
    }
    return strcmp(have, SESSION_ENV_VER) != 0;
}

/*
 * Provision the unprivileged account and the file-based environment.  Runs as
 * root at daemon start; fully idempotent (safe on every boot).
 */
static void provision_user(void)
{
    if (access(ALPINE_ROOT, F_OK) != 0) {
        logf_("provision: %s missing, skip\n", ALPINE_ROOT);
        return;
    }
    int refresh = session_files_need_refresh();
    logf_("provision: session files %s\n", refresh ? "need refresh" : "up to date");

    mkdir_p(ALPINE_ROOT "/home", 0755);
    /* migrate the pre-rename home so a device already provisioned as the old
     * "ohos" account keeps its files after the rename to the OHOS account name */
    if (access(LEGACY_HOME, F_OK) == 0 && access(ALPINE_HOME, F_OK) != 0) {
        if (rename(LEGACY_HOME, ALPINE_HOME) == 0) {
            logf_("provision: migrated %s -> %s\n", LEGACY_HOME, ALPINE_HOME);
        }
    }
    mkdir_p(ALPINE_HOME, 0755);
    mkdir_p(ALPINE_ROOT CH_HOME, 0755);
    /* mount points for the sandbox scratch space + the user visible share */
    mkdir_p(ALPINE_ROOT CH_TMP, 1777);
    mkdir_p(ALPINE_ROOT CH_RUN, 0755);
    mkdir_p(ALPINE_ROOT CH_SHARE, 0755);
    for (int i = 0; SHARE_SUBDIRS[i] != NULL; i++) {
        char p[512];
        snprintf(p, sizeof(p), "%s%s/%s", ALPINE_ROOT, CH_SHARE, SHARE_SUBDIRS[i]);
        mkdir_p(p, 0777);
    }
    /* mount points for the read-only OHOS partitions */
    mkdir_p(ALPINE_ROOT "/system", 0755);
    mkdir_p(ALPINE_ROOT "/vendor", 0755);
    mkdir_p(ALPINE_ROOT "/chip_prod", 0755);
    mkdir_p(ALPINE_ROOT "/sys_prod", 0755);

    /* passwd / group / shadow entries */
    if (!file_has_entry(ALPINE_ROOT "/etc/passwd", USER_NAME)) {
        append_line(ALPINE_ROOT "/etc/passwd",
            USER_NAME ":x:" "1000" ":1000:OpenHarmony User:" CH_HOME ":" CH_SHELL "\n");
        logf_("provision: added passwd entry %s\n", USER_NAME);
    }
    if (!file_has_entry(ALPINE_ROOT "/etc/group", USER_NAME)) {
        append_line(ALPINE_ROOT "/etc/group", USER_NAME ":x:1000:\n");
    }
    if (!file_has_entry(ALPINE_ROOT "/etc/shadow", USER_NAME)) {
        append_line(ALPINE_ROOT "/etc/shadow", USER_NAME ":!:19000:0:99999:7:::\n");
    }

    /* canonical env + $HOME startup files.  Paths *inside* them are chroot
     * paths, so they are only correct after the chroot conversion -- rewrite
     * them all whenever the version stamp does not match. */
    if (refresh) {
        write_file(SESSION_ENV, SESSION_ENV_SH, 0644);
        write_file(ALPINE_HOME "/.zshenv", ZSHENV_SH, 0644);
        write_file(ALPINE_HOME "/.zprofile", ZPROFILE_SH, 0644);
        write_file(ALPINE_HOME "/.zshrc", ZSHRC_SH, 0644);
        write_file(ALPINE_HOME "/.profile", PROFILE_SH, 0644);
        write_file(ALPINE_HOME "/.bashrc", BASHRC_SH, 0644);
        write_file(ALPINE_HOME "/.mkshrc", MKSHRC_SH, 0644);
    } else {
        write_file_if_missing(SESSION_ENV, SESSION_ENV_SH, 0644);
        write_file_if_missing(ALPINE_HOME "/.zshenv", ZSHENV_SH, 0644);
        write_file_if_missing(ALPINE_HOME "/.zprofile", ZPROFILE_SH, 0644);
        write_file_if_missing(ALPINE_HOME "/.zshrc", ZSHRC_SH, 0644);
        write_file_if_missing(ALPINE_HOME "/.profile", PROFILE_SH, 0644);
        write_file_if_missing(ALPINE_HOME "/.bashrc", BASHRC_SH, 0644);
        write_file_if_missing(ALPINE_HOME "/.mkshrc", MKSHRC_SH, 0644);
    }

    /* infrastructure: sudo shim must always point at the setuid helper */
    write_file(ALPINE_ROOT "/usr/local/bin/sudo", SUDO_SHIM, 0755);
    /* whoami shim so the session user matches the OHOS uid-1000 account */
    write_file(ALPINE_ROOT "/usr/local/bin/whoami", WHOAMI_SHIM, 0755);
    /* ohos-diag entry point (chroot escape, root only) */
    write_file(ALPINE_ROOT "/usr/local/bin/ohos-diag", OHOSTDIAG_SHIM, 0755);
    /* generic OHOS-binary runner (last on PATH, next to the OHOS launchers) */
    write_file(ALPINE_ROOT CH_OHOS_BIN "/ohos", OHOS_SHIM, 0755);

    /* --- OHOS CLI launchers ------------------------------------------------
     * Every OHOS tool is a musl binary whose ELF interpreter is
     * /lib/ld-musl-x86_64.so.1.  Inside the sandbox that path is *Alpine's*
     * loader, so running them directly dies with "symbol not found"
     * (libcrypto_opensselinux/z.so ...).  For every OHOS executable whose
     * name is not already provided by Alpine we drop a tiny launcher in
     * /usr/local/ohos-bin -- the **last** PATH element -- that runs it
     * through OHOS' loader (ELF) or OHOS' shell (shebang scripts).
     * Names that Alpine also ships (ls, cp, mount, node after
     * `apk add nodejs`, ...) keep the Alpine version, which is the whole
     * point of the chroot. */
    clean_legacy_shims();
    clean_stale_launcher_dir();
    build_ohos_cli_wrappers();
    fix_apk_root_config();
    copy_resolv();
    write_file(SESSION_ENV_VER_FILE, SESSION_ENV_VER "\n", 0644);

    /* fix the prompt theme (hostname instead of history number) -- always
     * overwrite so an already-provisioned device is repaired too */
    mkdir_p(ALPINE_ROOT "/usr/share/oh-my-zsh/custom/themes", 0755);
    write_file(ALPINE_ROOT "/usr/share/oh-my-zsh/custom/themes/ascii.zsh-theme",
               ASCII_THEME, 0644);

    /* ownership */
    ensure_owner(ALPINE_ROOT "/home");
    ensure_owner(ALPINE_HOME);
    ensure_owner(ALPINE_ROOT "/.zshenv");
    ensure_owner(ALPINE_HOME "/.zshenv");
    ensure_owner(ALPINE_HOME "/.zprofile");
    ensure_owner(ALPINE_HOME "/.zshrc");
    ensure_owner(ALPINE_HOME "/.profile");
    ensure_owner(ALPINE_HOME "/.bashrc");
    ensure_owner(ALPINE_HOME "/.mkshrc");
    chmod(ALPINE_ROOT CH_TMP, 1777);
    logf_("provision: user=%s uid=%d home=%s chroot=%s\n",
          USER_NAME, USER_UID, ALPINE_HOME, ALPINE_ROOT);
}

/* ------------------------------------------------------------------ *
 * Sandbox construction
 * ------------------------------------------------------------------ */

static const char *g_share_fallback = NULL;

/* Return the first known candidate that holds the public folders, falling back
 * to the first candidate that merely exists (HMDFS creates Download/Documents/
 * ... lazily, so an empty base directory is normal on a fresh device). */
static const char *find_share_base(void)
{
    for (int i = 0; SHARE_CANDIDATES[i] != NULL; i++) {
        const char *base = SHARE_CANDIDATES[i];
        struct stat st;
        if (stat(base, &st) != 0 || !S_ISDIR(st.st_mode)) { continue; }
        int hits = 0;
        for (int j = 0; SHARE_SUBDIRS[j] != NULL; j++) {
            char p[512];
            snprintf(p, sizeof(p), "%s/%s", base, SHARE_SUBDIRS[j]);
            if (access(p, F_OK) == 0) { hits++; }
        }
        logf_("share candidate %s -> exists, %d public dirs\n", base, hits);
        if (hits > 0) { return base; }
        /* Nothing there yet (HMDFS creates the public dirs lazily).  Still bind
         * the base directory: it is a live bind, so whatever the Files app /
         * an app creates later shows up in the sandbox immediately. */
        if (g_share_fallback == NULL) { g_share_fallback = base; }
    }
    return g_share_fallback;
}

static int bind_ro(const char *src, const char *dst)
{
    if (mount(src, dst, NULL, MS_BIND | MS_REC, NULL) != 0) {
        logf_("bind %s -> %s failed: %s\n", src, dst, strerror(errno));
        return -1;
    }
    /* make the copy read-only (only affects our private namespace) */
    if (mount(NULL, dst, NULL, MS_BIND | MS_REMOUNT | MS_RDONLY, NULL) != 0) {
        logf_("remount-ro %s failed: %s\n", dst, strerror(errno));
    }
    return 0;
}

static int bind_rw(const char *src, const char *dst)
{
    if (mount(src, dst, NULL, MS_BIND, NULL) != 0) {
        logf_("bind-rw %s -> %s failed: %s\n", src, dst, strerror(errno));
        return -1;
    }
    return 0;
}

/*
 * Build the per-session sandbox.  Runs as root, before dropping privileges.
 * Returns 0 when the process now lives inside the chroot.
 */
static int enter_chroot(void)
{
    if (unshare(CLONE_NEWNS | CLONE_NEWUTS) != 0) {
        logf_("unshare(NEWNS|NEWUTS) failed: %s\n", strerror(errno));
        return -1;
    }
    /* keep every mount we make strictly inside this session */
    if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) {
        logf_("make-rprivate failed: %s\n", strerror(errno));
        return -1;
    }
    (void)sethostname(g_host, strlen(g_host));

    /* --- private scratch ------------------------------------------------- */
    if (mount("tmpfs", ALPINE_ROOT CH_TMP, "tmpfs", 0, "size=512m,mode=1777") != 0) {
        logf_("mount tmpfs %s failed: %s\n", CH_TMP, strerror(errno));
    }
    if (mount("tmpfs", ALPINE_ROOT CH_RUN, "tmpfs", 0, "size=32m,mode=0755") != 0) {
        logf_("mount tmpfs %s failed: %s\n", CH_RUN, strerror(errno));
    }
    /* --- /dev (recursive bind: brings the pts instance this session's own
     *     tty lives in, plus /dev/shm which we then shadow privately).
     *     NOTE: the target must be the path *inside the chroot* -- the bind
     *     has to be visible after chroot(), so binding the host /dev would
     *     be useless (that path is not reachable any more once we chroot). */
    mkdir_p(ALPINE_ROOT "/dev", 0755);
    if (mount("/dev", ALPINE_ROOT "/dev", NULL, MS_BIND | MS_REC, NULL) != 0) {
        logf_("bind /dev failed: %s\n", strerror(errno));
    }
    char ch_shm[512];
    snprintf(ch_shm, sizeof(ch_shm), "%s%s", ALPINE_ROOT, CH_SHM);
    if (access(ch_shm, F_OK) == 0 &&
        mount("tmpfs", ch_shm, "tmpfs", 0, "size=256m,mode=1777") != 0) {
        logf_("private %s failed: %s\n", CH_SHM, strerror(errno));
    }
    /* --- kernel filesystems ---------------------------------------------- */
    if (mount("proc", ALPINE_ROOT "/proc", "proc", 0, NULL) != 0) {
        logf_("mount /proc failed: %s\n", strerror(errno));
    }
    if (mount("sysfs", ALPINE_ROOT "/sys", "sysfs", 0, NULL) != 0) {
        logf_("mount /sys failed: %s\n", strerror(errno));
    }

    /* --- read-only OHOS partitions --------------------------------------- */
    static const char *ro[] = { "/system", "/vendor", "/chip_prod", "/sys_prod", NULL };
    for (int i = 0; ro[i] != NULL; i++) {
        if (access(ro[i], F_OK) != 0) { continue; }
        char dst[512];
        snprintf(dst, sizeof(dst), "%s%s", ALPINE_ROOT, ro[i]);
        mkdir_p(dst, 0755);
        (void)bind_ro(ro[i], dst);
    }

    /* --- read-write user-visible share ----------------------------------- */
    const char *share = find_share_base();
    if (share == NULL) {
        logf_("share: no HMDFS public dir found, %s stays empty\n", CH_SHARE);
    } else {
        (void)bind_rw(share, ALPINE_ROOT CH_SHARE);
        int bound = 0;
        for (int j = 0; SHARE_SUBDIRS[j] != NULL; j++) {
            char src[512];
            char dst[512];
            snprintf(src, sizeof(src), "%s/%s", share, SHARE_SUBDIRS[j]);
            if (access(src, F_OK) != 0) { continue; }
            snprintf(dst, sizeof(dst), "%s%s/%s", ALPINE_ROOT, CH_SHARE, SHARE_SUBDIRS[j]);
            mkdir_p(dst, 0777);
            if (bind_rw(src, dst) == 0) { bound++; }
        }
        logf_("share: %s -> %s (%d public dirs bound)\n", share, CH_SHARE, bound);
    }

    /* --- chroot ----------------------------------------------------------- */
    if (chroot(ALPINE_ROOT) != 0) {
        logf_("chroot failed: %s\n", strerror(errno));
        return -1;
    }
    if (chdir(CH_HOME) != 0) { (void)chdir("/"); }
    return 0;
}

/* Legacy (pre-chroot) fallback: Alpine binaries run straight on the OHOS
 * root with an explicit loader + library path.  Kept so a device without
 * /data/alpine still gets a usable shell. */
static void legacy_exec_shell(void)
{
    setenv("HOME", ALPINE_HOME, 1);
    setenv("PATH",
           "/system/bin:/vendor/bin:" ALPINE_ROOT "/usr/local/bin:" ALPINE_ROOT
           "/usr/bin:" ALPINE_ROOT "/bin:" ALPINE_ROOT "/usr/sbin:" ALPINE_ROOT "/sbin", 1);
    setenv("LD_LIBRARY_PATH",
           ALPINE_ROOT "/lib:" ALPINE_ROOT "/usr/lib:" ALPINE_ROOT "/usr/lib/sudo", 1);
    if (access(ALPINE_ROOT "/lib/ld-musl-x86_64.so.1", X_OK) == 0) {
        execl(ALPINE_ROOT "/lib/ld-musl-x86_64.so.1", "ld-musl-x86_64.so.1",
              "--library-path",
              ALPINE_ROOT "/lib:" ALPINE_ROOT "/usr/lib:" ALPINE_ROOT "/usr/lib/sudo",
              ALPINE_ZSH, "-l", (char *)NULL);
    }
    if (access(ALPINE_ZSH, X_OK) == 0) { execl(ALPINE_ZSH, "zsh", "-l", (char *)NULL); }
    if (access("/system/bin/sh", X_OK) == 0) { execl("/system/bin/sh", "sh", "-l", (char *)NULL); }
    execl("/bin/sh", "sh", "-l", (char *)NULL);
    _exit(127);
}

/* Drop from root to the unprivileged session user. */
static void drop_privileges(void)
{
    if (geteuid() != 0) { return; }
    if (setgroups(0, NULL) != 0) { logf_("setgroups: %s\n", strerror(errno)); }
    if (setgid(USER_GID) != 0) { logf_("setgid: %s\n", strerror(errno)); }
    if (setuid(USER_UID) != 0) { logf_("setuid: %s\n", strerror(errno)); }
}

/* Bootstrap environment for a session (works for both chroot and legacy). */
static void session_env_bootstrap(void)
{
    setenv("TERM", "xterm-256color", 1);
    setenv("COLORTERM", "truecolor", 1);
    setenv("LANG", "C.UTF-8", 1);
    setenv("LC_ALL", "C.UTF-8", 1);
    setenv("HOSTNAME", g_host, 1);
    /* PATH is owned by /etc/ohos-session-env.sh inside the sandbox */
    unsetenv("PATH");
    unsetenv("LD_LIBRARY_PATH");
    unsetenv("LD_PRELOAD");
    unsetenv("PROOT_TMP_DIR");
}

static void child_run(int slave, const struct winsize *ws)
{
    (void)setsid();
    (void)ioctl(slave, TIOCSCTTY, 0);
    if (ws != NULL) { (void)ioctl(slave, TIOCSWINSZ, ws); }
    (void)dup2(slave, 0);
    (void)dup2(slave, 1);
    (void)dup2(slave, 2);
    if (slave > 2) { close(slave); }

    session_env_bootstrap();

    if (access(ALPINE_ROOT, F_OK) == 0 && enter_chroot() == 0) {
        setenv("HOME", CH_HOME, 1);
        setenv("USER", USER_NAME, 1);
        setenv("LOGNAME", USER_NAME, 1);
        setenv("SHELL", CH_SHELL, 1);
        setenv("TMPDIR", CH_TMP, 1);
        setenv("PWD", CH_HOME, 1);
        setenv("ENV", CH_HOME "/.mkshrc", 1);
        setenv("PATH",
               "/usr/local/bin:/usr/local/sbin:"
               "/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/ohos-bin", 1);
        drop_privileges();
        execl(CH_SHELL, "zsh", "-l", (char *)NULL);
        _exit(127);
    }

    logf_("falling back to the non-chroot (overlay) session\n");
    setenv("HOME", ALPINE_HOME, 1);
    setenv("USER", USER_NAME, 1);
    setenv("LOGNAME", USER_NAME, 1);
    setenv("SHELL", ALPINE_ZSH, 1);
    setenv("TMPDIR", ALPINE_HOME "/tmp", 1);
    setenv("ENV", ALPINE_HOME "/.mkshrc", 1);
    drop_privileges();
    legacy_exec_shell();
}

static void bridge(int cfd, int master, pid_t pid)
{
    unsigned char rbuf[16384];
    unsigned char inbuf[131072];
    size_t inlen = 0;

    for (;;) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(cfd, &rfds);
        FD_SET(master, &rfds);
        int maxfd = cfd > master ? cfd : master;
        int r = select(maxfd + 1, &rfds, NULL, NULL, NULL);
        if (r < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (FD_ISSET(master, &rfds)) {
            ssize_t n = read(master, rbuf, sizeof(rbuf));
            if (n <= 0) break;
            if (write_all(cfd, rbuf, (size_t)n) < 0) break;
        }
        if (FD_ISSET(cfd, &rfds)) {
            ssize_t n = read(cfd, rbuf, sizeof(rbuf));
            if (n <= 0) break;
            if (inlen + (size_t)n > sizeof(inbuf)) { inlen = 0; continue; }
            memcpy(inbuf + inlen, rbuf, (size_t)n);
            inlen += (size_t)n;

            size_t off = 0;
            while (inlen - off >= 3) {
                unsigned char type = inbuf[off];
                unsigned int len = (unsigned int)inbuf[off + 1] |
                                   ((unsigned int)inbuf[off + 2] << 8);
                if (inlen - off < 3 + (size_t)len) break;
                unsigned char *p = inbuf + off + 3;
                if (type == 0) {
                    if (write_all(master, p, len) < 0) goto done;
                } else if (type == 1 && len >= 8) {
                    struct winsize w;
                    memset(&w, 0, sizeof(w));
                    w.ws_col = (unsigned short)(p[0] | (p[1] << 8));
                    w.ws_row = (unsigned short)(p[2] | (p[3] << 8));
                    w.ws_xpixel = (unsigned short)(p[4] | (p[5] << 8));
                    w.ws_ypixel = (unsigned short)(p[6] | (p[7] << 8));
                    (void)ioctl(master, TIOCSWINSZ, &w);
                } else if (type == 2) {
                    (void)kill(-pid, SIGTERM);
                }
                off += 3 + len;
            }
            if (off > 0) {
                memmove(inbuf, inbuf + off, inlen - off);
                inlen -= off;
            }
        }
    }
done:
    (void)kill(-pid, SIGHUP);
    (void)kill(-pid, SIGKILL);
    (void)waitpid(pid, NULL, 0);
}

static void handle_conn(int cfd)
{
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_col = 80;
    ws.ws_row = 24;

    int master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master < 0) {
        logf_("posix_openpt failed: %s\n", strerror(errno));
        close(cfd);
        return;
    }
    if (grantpt(master) != 0 || unlockpt(master) != 0) {
        logf_("grantpt/unlockpt failed: %s\n", strerror(errno));
        close(master); close(cfd);
        return;
    }
    char *sname = ptsname(master);
    if (sname == NULL) { close(master); close(cfd); return; }
    int slave = open(sname, O_RDWR | O_NOCTTY);
    if (slave < 0) {
        logf_("open %s failed: %s\n", sname, strerror(errno));
        close(master); close(cfd);
        return;
    }
    /* /dev/pts is bind-mounted into the session sandbox, so hand the session's
     * own tty to the unprivileged account (otherwise it could not read it and
     * `tty` would point at a node it may not open). */
    (void)chown(sname, (uid_t)USER_UID, (gid_t)USER_GID);
    (void)chmod(sname, 0620);

    pid_t pid = fork();
    if (pid < 0) {
        close(slave); close(master); close(cfd);
        return;
    }
    if (pid == 0) {
        close(cfd);
        close(master);
        child_run(slave, &ws);
        _exit(127);
    }
    close(slave);
    logf_("session pid=%d pty=%s\n", (int)pid, sname);
    bridge(cfd, master, pid);
    logf_("session pid=%d closed (sandbox torn down)\n", (int)pid);
    close(master);
    close(cfd);
}

static int ensure_ptmx(void)
{
    if (access("/dev/ptmx", F_OK) == 0) return 0;
    (void)mkdir("/dev/pts", 0755);
    (void)mknod("/dev/ptmx", S_IFCHR | 0666, makedev(5, 2));
    (void)mount("devpts", "/dev/pts", "devpts", 0, "mode=0620");
    return access("/dev/ptmx", F_OK);
}

/* `ohosshd --chroot-exec CMD ...`: run one command inside a throw-away
 * sandbox and exit.  Used by the verification flow (and handy for debugging)
 * without needing the GUI terminal. */
static int mode_chroot_exec(int argc, char **argv)
{
    signal(SIGPIPE, SIG_IGN);
    g_log = open(LOGFILE, O_WRONLY | O_CREAT | O_APPEND, 0644);
    load_device_name();
    provision_user();
    session_env_bootstrap();
    if (access(ALPINE_ROOT, F_OK) != 0 || enter_chroot() != 0) {
        fprintf(stderr, "chroot unavailable, running without sandbox\n");
        legacy_exec_shell();
        return 127;
    }
    setenv("HOME", CH_HOME, 1);
    setenv("USER", USER_NAME, 1);
    setenv("LOGNAME", USER_NAME, 1);
    setenv("SHELL", CH_SHELL, 1);
    setenv("TMPDIR", CH_TMP, 1);
    setenv("PWD", CH_HOME, 1);
    setenv("ENV", CH_HOME "/.mkshrc", 1);
    setenv("PATH",
           "/usr/local/bin:/usr/local/sbin:"
           "/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/ohos-bin", 1);
    drop_privileges();
    execvp(argv[0], &argv[0]);
    fprintf(stderr, "%s: %s\n", argv[0], strerror(errno));
    return 127;
}

int main(int argc, char **argv)
{
    signal(SIGPIPE, SIG_IGN);
    signal(SIGCHLD, SIG_IGN); /* auto-reap per-session children */

    g_log = open(LOGFILE, O_WRONLY | O_CREAT | O_APPEND, 0644);

    if (argc > 1 && strcmp(argv[1], "--chroot-exec") == 0) {
        if (argc < 3) {
            fprintf(stderr, "usage: %s --chroot-exec CMD [ARGS...]\n", argv[0]);
            return 2;
        }
        return mode_chroot_exec(argc - 2, &argv[2]);
    }

    load_device_name();
    logf_("ohosptyd start (chroot=%s user=%s:%d host=%s shell=%s)\n",
          ALPINE_ROOT, USER_NAME, USER_UID, g_host, CH_SHELL);

    provision_user();
    ensure_ptmx();

    int lfd = socket(AF_INET, SOCK_STREAM, 0);
    if (lfd < 0) return 1;
    int one = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons(LISTEN_PORT);
    sa.sin_addr.s_addr = inet_addr(LISTEN_ADDR);
    if (bind(lfd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        logf_("bind failed: %s\n", strerror(errno));
        return 1;
    }
    if (listen(lfd, 16) < 0) return 1;

    for (;;) {
        int cfd = accept(lfd, NULL, NULL);
        if (cfd < 0) { if (errno == EINTR) continue; break; }
        pid_t pid = fork();
        if (pid == 0) {
            close(lfd);
            handle_conn(cfd);
            _exit(0);
        }
        close(cfd);
    }
    return 0;
}