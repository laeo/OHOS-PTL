/*
 * Copyright (c) 2026
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/*
 * comp_kmsg.h - 显示 HDI 的 bring-up 发声器（文件为主，/dev/kmsg 为辅）。
 *
 * 为什么需要（2026-10-06 真机复盘的结论）：
 *   真机上 composer_host 的 HDF_LOGI/HILOG 走 hilogd，早期环形缓冲会被冲掉；
 *   之前只写 /dev/kmsg（被 zz_pslog 抓 dmesg）。但内核 devkmsg_write() 对
 *   **每一个 open 的 /dev/kmsg fd** 做 ___ratelimit(&user->rs)（默认 5s/10 条，
 *   /proc/sys/kernel/printk_devkmsg = "ratelimit"）。composer_host 在 discovery 阶段
 *   会在几毫秒内打 10+ 条，于是 SESSION/DRV 等关键行被**静默丢弃** —— 真机日志里
 *   "SESSION 一条都没有、DRV 也没有" 就是这么来的（见 fix_reliablelog/SUMMARY.md）。
 *
 * 本版本的做法：
 *   1. 每个进程启动时（CrashInstaller 静态构造）打开一个**文件**，追加写；
 *      每条消息一次 write()（无用户态缓冲 = 逐行落内核），可选逐行 fdatasync。
 *      文件是**主证据**，绝不依赖 /dev/kmsg。
 *   2. 同时仍然写 /dev/kmsg（兼容 zz_pslog / pstore / 串口）。
 *   3. 文件路径可用环境变量覆盖：COMPKMSG_FILE（完整路径）/ COMPKMSG_DIR（目录）/
 *      COMPKMSG_PROC（进程名，默认读 /proc/self/comm）；写失败时 selecting 过程与
 *      最终失败都会打点到 /dev/kmsg。
 *   4. 崩溃 signal handler 也同时写文件（async-signal-safe 的 write()）。
 *
 * 固定前缀 "COMPKMSG:"。全部 inline / header-only，不引入链接依赖。
 */

#ifndef COMP_KMSG_H
#define COMP_KMSG_H

#include <cerrno>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <csignal>
#include <execinfo.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

namespace comp_kmsg {

/* ---- 进程名（用于文件名；可被 COMPKMSG_PROC 覆盖） ---- */
inline const char *ProcName()
{
    static char sName[64] = {0};
    if (sName[0] != '\0') {
        return sName;
    }
    const char *env = ::getenv("COMPKMSG_PROC");
    if (env != nullptr && env[0] != '\0') {
        ::snprintf(sName, sizeof(sName), "%s", env);
        return sName;
    }
    char buf[64] = {0};
    int fd = ::open("/proc/self/comm", O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
        ssize_t n = ::read(fd, buf, sizeof(buf) - 1);
        ::close(fd);
        if (n > 0) {
            buf[n] = '\0';
            char *nl = ::strchr(buf, '\n');
            if (nl != nullptr) {
                *nl = '\0';
            }
        }
    }
    if (buf[0] == '\0') {
        ::snprintf(buf, sizeof(buf), "unknown");
    }
    /* 进程名可能被截断成 15 字符；保持可读即可 */
    ::snprintf(sName, sizeof(sName), "%s", buf);
    return sName;
}

/* ---- /dev/kmsg fd（缓存；注意 fd 级别的 ratelimit，见文件头说明） ---- */
inline int KmsgFd()
{
    static int sFd = -2;
    if (sFd == -2) {
        sFd = ::open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
        if (sFd < 0) {
            sFd = ::open("/dev/console", O_WRONLY | O_CLOEXEC);
        }
    }
    return sFd;
}

/* ---- 文件日志 fd（主证据；懒打开 + 启动时预热） ---- */
inline const char *FilePathUsed()
{
    static char sPath[256] = {0};
    return sPath;
}

inline bool EnvFlag(const char *name)
{
    const char *v = ::getenv(name);
    if (v == nullptr || v[0] == '\0') {
        return false;
    }
    return !(v[0] == '0' && v[1] == '\0');
}

/* 尝试在 dir 下打开 compkmsg.<proc>.log；mode 允许把目录加成可写（best effort）。 */
inline int TryOpenFile(const char *dir, int *outErr)
{
    char path[256] = {0};
    ::snprintf(path, sizeof(path), "%s/compkmsg.%s.log", dir, ProcName());
    (void)::mkdir(dir, 0777); /* best effort：目录可能已存在或无权限，忽略失败 */
    int fd = ::open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0666);
    if (fd >= 0) {
        ::snprintf(const_cast<char *>(FilePathUsed()), 256, "%s", path);
        if (outErr != nullptr) {
            *outErr = 0;
        }
    } else if (outErr != nullptr) {
        *outErr = errno;
    }
    return fd;
}

inline int FileFd()
{
    static int sFd = -2;
    if (sFd != -2) {
        return sFd;
    }
    sFd = -1;
    int lastErr = 0;
    const char *envFile = ::getenv("COMPKMSG_FILE");
    if (envFile != nullptr && envFile[0] != '\0') {
        (void)::mkdir("/data/compkmsg", 0777);
        int fd = ::open(envFile, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0666);
        if (fd >= 0) {
            ::snprintf(const_cast<char *>(FilePathUsed()), 256, "%s", envFile);
            sFd = fd;
            return sFd;
        }
        lastErr = errno;
    }
    const char *envDir = ::getenv("COMPKMSG_DIR");
    if (sFd < 0 && envDir != nullptr && envDir[0] != '\0') {
        sFd = TryOpenFile(envDir, &lastErr);
    }
    /* 候选目录：优先 tmpfs/可写，再落 p6（/data 在非 [D] 模式下就是 p6）。 */
    static const char *kCandidates[] = {
        "/data/compkmsg",
        "/data",
        "/ohoslog/compkmsg",
        "/ohoslog",
        "/data/local/tmp",
        "/tmp",
    };
    for (size_t i = 0; sFd < 0 && i < (sizeof(kCandidates) / sizeof(kCandidates[0])); i++) {
        sFd = TryOpenFile(kCandidates[i], &lastErr);
    }
    if (sFd < 0) {
        const char *msg = "COMPKMSG:FILE open FAILED for all candidates";
        int kfd = KmsgFd();
        if (kfd >= 0) {
            char line[160];
            int n = ::snprintf(line, sizeof(line), "<3>%s (last errno=%d %s proc=%s)\n",
                msg, lastErr, ::strerror(lastErr), ProcName());
            (void)::write(kfd, line, static_cast<size_t>(n));
        }
    }
    return sFd;
}

/* ---- 底层写：文件为主，kmsg 为辅 ---- */
inline void WriteAll(int fd, const char *data, int len)
{
    if (fd < 0 || len <= 0) {
        return;
    }
    int off = 0;
    while (off < len) {
        ssize_t ret = ::write(fd, data + off, static_cast<size_t>(len - off));
        if (ret <= 0) {
            if (ret < 0 && errno == EINTR) {
                continue;
            }
            return;
        }
        off += static_cast<int>(ret);
    }
    if (EnvFlag("COMPKMSG_FSYNC")) {
        (void)::fdatasync(fd);
    }
}

inline void WriteRaw(const char *data, int len)
{
    if (len <= 0) {
        return;
    }
    /* 文件主证据 */
    WriteAll(FileFd(), data, len);
    /* /dev/kmsg 辅助（可能被 fd ratelimit 丢，但文件不会） */
    int kfd = KmsgFd();
    if (kfd >= 0) {
        /* data 已经带 "COMPKMSG:"；kmsg 需要 <3> 级别前缀。调用方保证 buf 前留 3 字节。 */
        (void)::write(kfd, data, static_cast<size_t>(len));
    }
}

/*
 * 格式化并同时写文件 + /dev/kmsg：
 *   file: "COMPKMSG:<tag> <msg>\n"
 *   kmsg: "<3>COMPKMSG:<tag> <msg>\n"
 * 这样无论是 grep 文件还是 dmesg，前缀都一致。
 */
inline void Print(const char *tag, const char *fmt, ...)
{
    char buf[768];
    /* 前 3 字节留给 kmsg 的 "<3>"；文件从 buf+3 开始。 */
    buf[0] = '<';
    buf[1] = '3';
    buf[2] = '>';
    int n = 3;
    int n2 = ::snprintf(buf + n, sizeof(buf) - n, "COMPKMSG:%s ", (tag != nullptr) ? tag : "?");
    if (n2 < 0) {
        return;
    }
    n += (n2 < static_cast<int>(sizeof(buf)) - n) ? n2 : static_cast<int>(sizeof(buf)) - n;
    int remain = static_cast<int>(sizeof(buf)) - n - 1; /* 预留 '\n' 与 '\0' */
    if (remain <= 0) {
        WriteRaw(buf, n);
        return;
    }
    va_list ap;
    va_start(ap, fmt);
    int m = ::vsnprintf(buf + n, static_cast<size_t>(remain), fmt, ap);
    va_end(ap);
    if (m > 0) {
        n += (m < remain) ? m : remain;
    }
    buf[n++] = '\n';

    /* 文件写入 buf+3（去掉 "<3>"） */
    WriteAll(FileFd(), buf + 3, n - 3);
    if (EnvFlag("COMPKMSG_FSYNC")) {
        /* WriteAll 已按需 fdatasync，这里不重复 */
    }
    /* kmsg 写入 buf（含 "<3>"） */
    int kfd = KmsgFd();
    if (kfd >= 0) {
        (void)::write(kfd, buf, static_cast<size_t>(n));
    }
}

/* ---- async-signal-safe helpers for the crash handler ---- */

inline int AppendInt(char *dst, long v)
{
    char tmp[24];
    int k = 0;
    bool neg = (v < 0);
    unsigned long u = neg ? static_cast<unsigned long>(-v) : static_cast<unsigned long>(v);
    if (u == 0) {
        tmp[k++] = '0';
    }
    while (u > 0) {
        tmp[k++] = static_cast<char>('0' + (u % 10));
        u /= 10;
    }
    int n = 0;
    if (neg) {
        dst[n++] = '-';
    }
    while (k > 0) {
        dst[n++] = tmp[--k];
    }
    return n;
}

inline void AppendStr(char *dst, int &n, const char *s)
{
    if (s == nullptr) {
        s = "?";
    }
    while (*s != '\0') {
        dst[n++] = *s++;
    }
}

/* 十六进制（0x 前缀，小写）。用于崩溃回溯里的地址/偏移，避免 snprintf。 */
inline void AppendHex(char *dst, int &n, unsigned long long v)
{
    dst[n++] = '0';
    dst[n++] = 'x';
    char tmp[16];
    int k = 0;
    if (v == 0) {
        tmp[k++] = '0';
    }
    while (v > 0) {
        int d = static_cast<int>(v & 0xfULL);
        tmp[k++] = static_cast<char>((d < 10) ? ('0' + d) : ('a' + d - 10));
        v >>= 4;
    }
    while (k > 0) {
        dst[n++] = tmp[--k];
    }
}

/* 只取路径的 basename（模块名），用于日志可读性。 */
inline const char *BaseName(const char *path)
{
    if (path == nullptr) {
        return "?";
    }
    const char *base = path;
    for (const char *p = path; *p != '\0'; ++p) {
        if (*p == '/') {
            base = p + 1;
        }
    }
    return base;
}

/*
 * 把一个运行时地址解析成 "模块名+偏移 (符号名+偏移)" 并追加到 dst。
 * 用 dladdr()（musl libc 提供）取模块/符号；取不到就只留裸地址。
 * 返回追加的字符数。
 */
inline void AppendResolvedAddr(char *dst, int &n, const char *label, const void *addr)
{
    AppendStr(dst, n, label);
    AppendHex(dst, n, static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(addr)));
    Dl_info info;
    (void)::memset(&info, 0, sizeof(info));
    int ok = (addr != nullptr) ? ::dladdr(addr, &info) : 0;
    if (ok != 0 && info.dli_fname != nullptr) {
        AppendStr(dst, n, " mod=");
        AppendStr(dst, n, BaseName(info.dli_fname));
        unsigned long long modOff = static_cast<unsigned long long>(
            reinterpret_cast<uintptr_t>(addr) - reinterpret_cast<uintptr_t>(info.dli_fbase));
        AppendStr(dst, n, "+");
        AppendHex(dst, n, modOff);
        if (info.dli_sname != nullptr) {
            AppendStr(dst, n, " sym=");
            AppendStr(dst, n, info.dli_sname);
            if (info.dli_saddr != nullptr) {
                unsigned long long symOff = static_cast<unsigned long long>(
                    reinterpret_cast<uintptr_t>(addr) - reinterpret_cast<uintptr_t>(info.dli_saddr));
                AppendStr(dst, n, "+");
                AppendHex(dst, n, symOff);
            }
        }
    } else {
        AppendStr(dst, n, " mod=? (dladdr failed)");
    }
}

/* 一条 crash 日志行同时写文件（主证据）与 /dev/kmsg（辅）。n 为不含 "<3>" 的文件长度。 */
inline void CrashWriteLine(const char *buf, int n)
{
    if (n <= 3) {
        return;
    }
    int ffd = FileFd();
    if (ffd >= 0) {
        (void)::write(ffd, buf + 3, static_cast<size_t>(n - 3));
    }
    int kfd = KmsgFd();
    if (kfd >= 0) {
        (void)::write(kfd, buf, static_cast<size_t>(n));
    }
}

/* ---- ucontext 手工回溯（2026-10-07） ----
 *
 * 为什么需要：backtrace()（_Unwind_Backtrace）从 signal handler 里调用时，
 * 会在「信号蹦床/restorer」处停住——因为该蹦床没有 .cfi_signal_frame，
 * 展开器无法跨到被中断的上下文。于是日志里只有 handler 自己的帧
 * （CrashHandler / CrashDumpBacktrace / ld-musl restorer），**拿不到真正
 * 的调用者**（例如 musl calloc 除零时究竟是 render_service 里哪一段代码调的）。
 *
 * 本函数不依赖 unwind 表：直接从 ucontext 取被中断上下文的 RIP/RSP/RBP，
 * 以 RIP 为 #0，然后从 RSP **向上做保守栈扫描**，把栈上「像代码地址」的字
 * （能 dladdr 到某个已加载模块）当作返回地址逐个解析输出。栈是向下增长的，
 * 向上就是更老的调用帧，正是我们想要的调用者。这样可直接给出：
 *   COMPKMSG:CRASH   #1 pc=0x.. mod=libxxx.z.so+0x.. sym=Func+0x.. [call]
 * 其中 [call] 表示该地址前 5 字节是 E8（直接 call 的返回地址），可信度高。
 *
 * 只做 raw write()；dladdr 在崩溃诊断场景可接受（原 backtrace 版也这么做）。
 */

/* 一个值是否「像用户态代码地址」（规范化范围内且能解析到某个模块）。 */
inline bool LooksLikeCode(uintptr_t w)
{
    if (w < 0x10000ULL) {
        return false;
    }
    if (w >= 0x0000800000000000ULL) { /* 非规范化 / 内核地址 */
        return false;
    }
    Dl_info info;
    (void)::memset(&info, 0, sizeof(info));
    if (::dladdr(reinterpret_cast<const void *>(w), &info) == 0) {
        return false;
    }
    return info.dli_fname != nullptr;
}

/* 返回地址是否紧跟一条直接 call（E8 rel32）：E8 是 x86_64 最常见的 call 编码。 */
inline bool PrecededByDirectCall(uintptr_t w)
{
    const unsigned char *p = reinterpret_cast<const unsigned char *>(w);
    return (p[-5] == 0xE8);
}

inline void CrashDumpInterruptedBacktrace(void *ucontextRaw)
{
#if (defined(_GNU_SOURCE) || defined(_BSD_SOURCE)) && defined(REG_RIP)
    if (ucontextRaw == nullptr) {
        return;
    }
    const ucontext_t *uc = static_cast<const ucontext_t *>(ucontextRaw);
    uintptr_t rip = static_cast<uintptr_t>(uc->uc_mcontext.gregs[REG_RIP]);
    uintptr_t rsp = static_cast<uintptr_t>(uc->uc_mcontext.gregs[REG_RSP]);
    uintptr_t rbp = static_cast<uintptr_t>(uc->uc_mcontext.gregs[REG_RBP]);

    char buf[1024];

    /* 原始寄存器，便于离线符号化（即使 dladdr 全失败也有线索）。 */
    {
        int n = 0;
        buf[n++] = '<'; buf[n++] = '3'; buf[n++] = '>';
        AppendStr(buf, n, "COMPKMSG:CRASH   regs rip=");
        AppendHex(buf, n, static_cast<unsigned long long>(rip));
        AppendStr(buf, n, " rsp=");
        AppendHex(buf, n, static_cast<unsigned long long>(rsp));
        AppendStr(buf, n, " rbp=");
        AppendHex(buf, n, static_cast<unsigned long long>(rbp));
        buf[n++] = '\n';
        CrashWriteLine(buf, n);
    }

    /* #0：故障指令（与前面 fault_pc 一致，这里也放进取证序列）。 */
    {
        int n = 0;
        buf[n++] = '<'; buf[n++] = '3'; buf[n++] = '>';
        AppendStr(buf, n, "COMPKMSG:CRASH   #");
        n += AppendInt(buf + n, 0);
        AppendResolvedAddr(buf, n, " pc=", reinterpret_cast<const void *>(rip));
        buf[n++] = '\n';
        CrashWriteLine(buf, n);
    }

    /* 保守栈扫描：从 RSP 向上，最多 2048 个字(16KiB)，最多 40 帧。 */
    const int kMaxWords = 2048;
    const int kMaxFrames = 40;
    int frame = 1;
    uintptr_t lastRa = 0;
    if (rsp >= 0x10000ULL && rsp < 0x0000800000000000ULL) {
        for (int i = 0; i < kMaxWords && frame < kMaxFrames; ++i) {
            uintptr_t w = *reinterpret_cast<const uintptr_t *>(rsp + static_cast<uintptr_t>(i) * 8ULL);
            if (w == lastRa) {
                continue;
            }
            if (!LooksLikeCode(w)) {
                continue;
            }
            lastRa = w;
            bool isCall = PrecededByDirectCall(w);
            int n = 0;
            buf[n++] = '<'; buf[n++] = '3'; buf[n++] = '>';
            AppendStr(buf, n, "COMPKMSG:CRASH   #");
            n += AppendInt(buf + n, static_cast<long>(frame++));
            AppendResolvedAddr(buf, n, " pc=", reinterpret_cast<const void *>(w));
            AppendStr(buf, n, isCall ? " [call]" : " [stack]");
            buf[n++] = '\n';
            CrashWriteLine(buf, n);
        }
    }
#else
    (void)ucontextRaw;
#endif
}

/*
 * 崩溃回溯：用 backtrace()（musl libc 提供，基于 unwind 表，比帧指针扫描可靠）
 * 收集调用栈，再用 dladdr() 解析出「模块名 + 偏移 + 符号名 + 偏移」。
 * 目标：真机日志里直接看到崩溃地址对应哪个 .so / 哪个函数。
 * 全部只做 raw write()，尽量贴近 async-signal-safe；dladdr 可能取内部锁，
 * 但在进程即将崩溃的诊断场景下可接受。
 *
 * 注意：从 signal handler 调用时只能拿到 handler 自身帧（见上面
 * CrashDumpInterruptedBacktrace 的说明）；本函数保留作为没有 ucontext 时的兜底。
 */
inline void CrashDumpBacktrace()
{
    void *frames[64];
    int cnt = ::backtrace(frames, static_cast<int>(sizeof(frames) / sizeof(frames[0])));
    char buf[1024];
    for (int i = 0; i < cnt; ++i) {
        int n = 0;
        buf[n++] = '<';
        buf[n++] = '3';
        buf[n++] = '>';
        AppendStr(buf, n, "COMPKMSG:CRASH   bt#");
        n += AppendInt(buf + n, static_cast<long>(i));
        AppendResolvedAddr(buf, n, " pc=", frames[i]);
        if (n < static_cast<int>(sizeof(buf)) - 1) {
            buf[n++] = '\n';
        }
        CrashWriteLine(buf, n);
    }
}

inline void CrashHandler(int sig, siginfo_t *info, void *ucontext)
{
    char buf[512];
    int n = 0;
    /* 与 Print 一致：前 3 字节给 kmsg 的 "<3>"，文件从 buf+3 开始。 */
    buf[n++] = '<';
    buf[n++] = '3';
    buf[n++] = '>';
    AppendStr(buf, n, "COMPKMSG:CRASH signal=");
    n += AppendInt(buf + n, static_cast<long>(sig));
    AppendStr(buf, n, " si_code=");
    n += AppendInt(buf + n, (info != nullptr) ? static_cast<long>(info->si_code) : 0L);
    AppendStr(buf, n, " addr=");
    AppendHex(buf, n, (info != nullptr)
        ? static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(info->si_addr)) : 0ULL);
    /* 故障指令地址（ucontext RIP）：定位「哪条指令、哪个函数」的关键。 */
#if (defined(_GNU_SOURCE) || defined(_BSD_SOURCE)) && defined(REG_RIP)
    if (ucontext != nullptr) {
        const ucontext_t *uc = static_cast<const ucontext_t *>(ucontext);
        unsigned long long rip = static_cast<unsigned long long>(uc->uc_mcontext.gregs[REG_RIP]);
        AppendResolvedAddr(buf, n, " fault_pc=", reinterpret_cast<const void *>(rip));
    }
#else
    (void)ucontext;
#endif
    buf[n++] = '\n';
    CrashWriteLine(buf, n);

    /* 首选：从 ucontext 手工回溯被中断的上下文（能跨过信号蹦床，给出真实调用者）。 */
    CrashDumpInterruptedBacktrace(ucontext);

    /* 兜底：backtrace()（无 ucontext / 非 x86_64 时）。它通常只能给出 handler 自身帧。 */
    CrashDumpBacktrace();

    /* 恢复默认动作并重新 raise，保持原有 core dump / init 重启语义 */
    (void)::signal(sig, SIG_DFL);
    (void)::raise(sig);
}

/*
 * 自检工具：读 /proc/cmdline 判断是否含某个子串（用于「人为触发崩溃验证回溯」）。
 * 不依赖 shell/param，只需在 QEMU/GRUB 的内核命令行里加 compkmsg_testcrash=1。
 */
inline bool CmdlineHas(const char *needle)
{
    if (needle == nullptr || needle[0] == '\0') {
        return false;
    }
    int fd = ::open("/proc/cmdline", O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return false;
    }
    char buf[2048] = {0};
    ssize_t n = ::read(fd, buf, sizeof(buf) - 1);
    ::close(fd);
    if (n <= 0) {
        return false;
    }
    buf[n] = '\0';
    return ::strstr(buf, needle) != nullptr;
}

/*
 * 自检：故意在地址 0x178 上写（空指针 + 偏移 0x178），制造与真机一致的 SIGSEGV，
 * 用来验证 CrashHandler 能打印出「模块名 + 偏移 + 符号」的调用栈。
 * 仅在 /proc/cmdline 含 compkmsg_testcrash=1 时由调用方触发；默认关闭。
 */
inline void CrashTest0x178()
{
    Print("CRASH", "TESTCRASH: deliberate null-pointer write at addr=0x178 (backtrace self-test)");
    volatile unsigned int *p = reinterpret_cast<volatile unsigned int *>(static_cast<uintptr_t>(0x178));
    *p = 0xdeadbeefu;
}

inline void InstallCrashHandler()
{
    /* 独立信号栈：避免在（可能已损坏/溢出的）被中断栈上再压 handler 帧，
     * 也让 ucontext 回溯读到的被中断栈保持原样。 */
    static char g_altStack[64 * 1024];
    stack_t ss;
    (void)::memset(&ss, 0, sizeof(ss));
    ss.ss_sp = g_altStack;
    ss.ss_size = sizeof(g_altStack);
    ss.ss_flags = 0;
    (void)::sigaltstack(&ss, nullptr);

    struct sigaction sa;
    (void)::memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = CrashHandler;
    sa.sa_flags = SA_SIGINFO | SA_RESETHAND | SA_ONSTACK;
    (void)::sigemptyset(&sa.sa_mask);
    (void)::sigaction(SIGSEGV, &sa, nullptr);
    (void)::sigaction(SIGABRT, &sa, nullptr);
    (void)::sigaction(SIGBUS, &sa, nullptr);
    (void)::sigaction(SIGILL, &sa, nullptr);
    (void)::sigaction(SIGFPE, &sa, nullptr);
}

struct CrashInstaller {
    CrashInstaller()
    {
        InstallCrashHandler();
        /* 预热文件（在崩溃可能发生之前就打开好），随后打印启动横幅。 */
        (void)FileFd();
        Print("INIT", "comp_kmsg armed pid=%d proc=%s file=%s (fsync=%s)",
            static_cast<int>(::getpid()), ProcName(),
            (FilePathUsed()[0] != '\0') ? FilePathUsed() : "(none)",
            EnvFlag("COMPKMSG_FSYNC") ? "on" : "off");
    }
};

__attribute__((unused)) static CrashInstaller g_crashInstaller;

} // namespace comp_kmsg

#endif // COMP_KMSG_H
