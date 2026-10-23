/*
 * Copyright (c) 2026
 *
 * HDF is dual licensed: you can use it either under the terms of
 * the GPL, or the BSD license, at your option.
 * See the LICENSE file in the root of this repository for complete details.
 */

/*
 * hdf_diag_log.h - HDF manager/host bring-up 文件发声器（与显示 comp_kmsg.h 同格式）。
 *
 * 背景（fix_reliablelog / fix_svcreg）：
 *   HDF 框架的 HDF_LOGI/HDF_LOGE 走 hilogd，早期环形缓冲会被冲掉，真机上
 *   "注册没注册上" 看不到。这里给 hdf_core 侧（hdf_devhost / hdf_devmgr）
 *   一个 header-only 的文件日志：写 /data/compkmsg/compkmsg.<proc>.log，
 *   并同时写 /dev/kmsg（被 zz_pslog 抓）。固定前缀 "COMPKMSG:"。
 *
 * 仅供 bring-up 诊断，不参与业务逻辑；失败静默（绝不因日志失败影响启动）。
 */

#ifndef HDF_DIAG_LOG_H
#define HDF_DIAG_LOG_H

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifdef __cplusplus
extern "C" {
#endif

static inline const char *HdfDiagProc(void)
{
    static char sName[64];
    if (sName[0] != '\0') {
        return sName;
    }
    const char *env = getenv("HDF_DIAG_PROC");
    if (env != NULL && env[0] != '\0') {
        (void)snprintf(sName, sizeof(sName), "%s", env);
        return sName;
    }
    char buf[64] = {0};
    int fd = open("/proc/self/comm", O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
        ssize_t n = read(fd, buf, sizeof(buf) - 1);
        close(fd);
        if (n > 0) {
            buf[n] = '\0';
            char *nl = strchr(buf, '\n');
            if (nl != NULL) {
                *nl = '\0';
            }
        }
    }
    if (buf[0] == '\0') {
        (void)snprintf(buf, sizeof(buf), "unknown");
    }
    (void)snprintf(sName, sizeof(sName), "%s", buf);
    return sName;
}

static inline int HdfDiagFileFd(void)
{
    static int sFd = -2;
    if (sFd != -2) {
        return sFd;
    }
    sFd = -1;
    static const char *kDirs[] = {
        "/data/compkmsg", "/data", "/ohoslog/compkmsg", "/ohoslog", "/data/local/tmp", "/tmp",
    };
    for (size_t i = 0; i < sizeof(kDirs) / sizeof(kDirs[0]); i++) {
        char path[256] = {0};
        (void)snprintf(path, sizeof(path), "%s/compkmsg.%s.log", kDirs[i], HdfDiagProc());
        (void)mkdir(kDirs[i], 0777);
        int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0666);
        if (fd >= 0) {
            sFd = fd;
            break;
        }
    }
    return sFd;
}

static inline int HdfDiagKmsgFd(void)
{
    static int sFd = -2;
    if (sFd == -2) {
        sFd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
        if (sFd < 0) {
            sFd = open("/dev/console", O_WRONLY | O_CLOEXEC);
        }
    }
    return sFd;
}

static inline void HdfDiagWriteAll(int fd, const char *data, int len)
{
    if (fd < 0 || len <= 0) {
        return;
    }
    int off = 0;
    while (off < len) {
        ssize_t ret = write(fd, data + off, (size_t)(len - off));
        if (ret <= 0) {
            if (ret < 0 && errno == EINTR) {
                continue;
            }
            return;
        }
        off += (int)ret;
    }
}

static inline void HdfDiagPrint(const char *tag, const char *fmt, ...)
{
    char body[512] = {0};
    va_list ap;
    va_start(ap, fmt);
    (void)vsnprintf(body, sizeof(body), fmt, ap);
    va_end(ap);

    char line[640] = {0};
    int n = snprintf(line, sizeof(line), "COMPKMSG:%s(pid=%d) %s\n", tag, (int)getpid(), body);
    HdfDiagWriteAll(HdfDiagFileFd(), line, n);

    int kfd = HdfDiagKmsgFd();
    if (kfd >= 0) {
        char kline[680] = {0};
        int m = snprintf(kline, sizeof(kline), "<3>%s", line);
        HdfDiagWriteAll(kfd, kline, m);
    }
}

#ifdef __cplusplus
}
#endif
#endif /* HDF_DIAG_LOG_H */
