/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *     http://www.apache.org/licenses/LICENSE-2.0
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/*
 * libbt_vendor.z.so -- BT vendor HAL for pc_ptl (Intel PTL / CNVi PCIe BT).
 *
 * Why this file exists
 * --------------------
 * On this board the Bluetooth controller is a CNVi PCIe function
 * (8086:e476) driven by the in-kernel `btintel_pcie` transport plus the
 * shared `btintel` core.  The *kernel* therefore owns the controller and
 * already exposes a fully working HCI device (`hci0`); the firmware
 * download dance is done for us.
 *
 * The OHOS HCI HDI, however, speaks the Broadcom/Android "vendor HAL"
 * model: it dlopen()s libbt_vendor.z.so and expects it to hand back a set
 * of HCI channel file descriptors that it then drives with its own H4
 * framing
 * (drivers/peripheral/bluetooth/hci/hdi_service/implement/vendor_interface.cpp
 *  + h4_protocol.cpp).
 *
 * This shim bridges the two worlds:
 *
 *     OHOS H4Protocol  <--socketpair-->  this shim  <--AF_BLUETOOTH raw-->
 *                                                  hci0 (kernel btintel_pcie)
 *
 * Only ONE channel is returned (channelCount == 1), which makes the HDI
 * select the single-fd H4 path (vendor_interface.cpp:84).
 *
 * Kernel ABI notes (all verified against kernel/linux/linux-7.2)
 * -----------------------------------------------------------------
 * 1. struct sockaddr_hci is { sa_family_t hci_family; u16 hci_dev;
 *     u16 hci_channel; } - *not* the old "hci_bdaddr" layout.  hci_dev is
 *     the device index (0 == hci0), hci_channel 0 == HCI_CHANNEL_RAW.
 *     hci_sock_bind() copies min(sizeof(haddr), addr_len) bytes, so a short
 *     sockaddr is accepted, but we pass the full 6 bytes anyway.
 *
 * 2. HCIDEVUP is _IOW('H', 201, int) in this kernel (include/net/bluetooth/
 *     hci_sock.h:65).  The classic _IO(0,3) encoding does NOT exist any
 *     more and would fail with -ENOTTY.
 *     HCIDEVUP needs CAP_NET_ADMIN and returns -EALREADY when the device is
 *     already up - which is the normal case here, because btintel_pcie
 *     brings the controller up during probe.  EALREADY must be treated as
 *     success, otherwise the whole HDI stays down.
 *
 * 3. The RAW channel does NOT deliver the H4 type byte: the kernel hands
 *     out the bare payload (event code / ACL header) and keeps the packet
 *     type in skb metadata (net/bluetooth/hci_sock.c: hci_send_to_sock()).
 *     The OHOS H4Protocol on the other side *does* expect the type byte.
 *     We therefore open one raw socket per HCI packet type and give each a
 *     distinct SO_HCI_FILTER type_mask; the socket that produced a packet
 *     tells us the type.  (There is no SCM_CBFCPT in this kernel.)
 *
 * 4. Sending over the RAW channel needs CAP_NET_RAW (hci_sock_sendmsg():
 *     the opcode is checked against hci_sec_filter.ocf_mask otherwise).
 *     blue_host must therefore be started with the NET_RAW capability -
 *     see vendor/ohemu/virt/hdf_config/uhdf/device_info.hcs and the
 *     generated /vendor/etc/init/hdf_devhost.cfg.
 *
 * 5. The kernel echoes everything we transmit back to the *other* raw
 *     sockets of the same device ("Don't send frame to the socket it came
 *     from", hci_sock.c:222).  To avoid seeing our own TX data as RX we
 *     always send a given packet type on the socket of that same type.
 *
 * 6. h4 framing geometry (must match hci_protocol.cpp's header_ table):
 *       CMD : hdr 3 (opcode[2] + plen[1])      len off 2 size 1
 *       ACL : hdr 4 (hdl_flags[2] + dlen[2])   len off 2 size 2
 *       SCO : hdr 3 (handle[2] + dlen[1])      len off 2 size 1
 *       EVT : hdr 2 (evt[1] + plen[1])         len off 1 size 1
 *       ISO : hdr 4 (hdl_flags[2] + dlen[2])   len off 2 size 2
 *
 * Every step logs to BOTH stderr and a set of files on persistent
 * partitions so that the state of the bridge can be recovered from a device
 * even when hilog has rolled over.
 */

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include "bt_vendor_linux.h"

/*
 * HCIDEVUP.  linux-7.2 (include/net/bluetooth/hci_sock.h:65) defines it as
 * _IOW('H', 201, int) - the classic _IO(0,3) encoding no longer exists and
 * would be rejected with -ENOTTY.
 */
#define VENDOR_HCIDEVUP _IOW('H', 201, int)

/* ------------------------------------------------------------------ */
/* log sinks                                                          */
/* ------------------------------------------------------------------ */

/*
 * Log sinks, tried in order, best-effort (an unwritable sink is skipped).
 *
 * 2026-10-22: *none* of the file sinks is writable from the process that
 * loads this library.  The library is dlopen()ed by the HDF host service
 * "blue_host", which runs under the uid "blue_host":
 *
 *   /sys_prod          root:root   0755   -> blue_host cannot create a file
 *   /data/local/tmp    shell:shell 0770   -> blue_host is not "shell"
 *   /mnt/od            (not mounted in the blue_host mount namespace)
 *
 * Measured on the real machine and in QEMU:
 *   /proc/<blue_host pid>/root/sys_prod        drwxr-xr-x root root
 *   /proc/<blue_host pid>/root/data/local/tmp  drwxrwx--x shell shell
 *
 * So the file sinks produced *nothing* and the whole trace was lost - which
 * is exactly what the diagnostic reported ("bt_vendor.log missing" even
 * though blue_host had really dlopen()ed the library).
 *
 * The fix: log through **hilog** (libhilog.so is dlopen()ed lazily, so the
 * vendor library stays dependency free) into the Bluetooth HDF domain
 * 0xD000105, which is the domain the diagnostic already streams.  The file
 * sinks are kept as a best effort for the case where the library is loaded
 * by a process that *can* write them.
 */
#define LOG_FILE "/data/local/tmp/bt_vendor.log"
static const char *const g_log_files[] = {
    "/sys_prod/bt_vendor.log",
    "/mnt/od/bt_vendor.log",
    "/data/vendor/bluetooth/bt_vendor.log",
    LOG_FILE,
};

/* the hilog domain of the Bluetooth HDF host service */
#define BT_VENDOR_LOG_DOMAIN 0xD000105
#define BT_VENDOR_LOG_TAG "bt_vendor"

/*
 * hilog is reached through dlopen() so that this library keeps no link time
 * dependency on libhilog (the HDF host loads it into its own process).
 */
typedef int (*HiLogPrintFn)(int type, int level, unsigned int domain, const char *tag,
                             const char *fmt, ...);
#define HILOG_LOG_CORE 3
#define HILOG_LOG_INFO 4

static HiLogPrintFn g_hiLogPrint = NULL;
static int g_hiLogTried = 0;

static void BtVendorInitHiLog(void)
{
    void *handle;

    if (g_hiLogTried) {
        return;
    }
    g_hiLogTried = 1;
    handle = dlopen("libhilog.so", RTLD_NOW);
    if (handle == NULL) {
        return;
    }
    g_hiLogPrint = (HiLogPrintFn)dlsym(handle, "HiLogPrint");
}

#define MAX_HCI_DEV 16
#define H4_PARSE_BUF 4096
#define HCI_RX_BUF 2048

/*
 * struct sockaddr_hci from <linux/bluetooth.h> (linux-7.2):
 *   sa_family_t hci_family; unsigned short hci_dev; unsigned short hci_channel;
 */
struct vendor_sockaddr_hci {
    uint16_t hci_family;
    uint16_t hci_dev;
    uint16_t hci_channel;
};

/*
 * Userspace HCI filter, mirrors `struct hci_ufilter` from
 * kernel/linux/linux-7.2/include/net/bluetooth/hci_sock.h
 */
struct vendor_hci_ufilter {
    uint32_t type_mask;
    uint32_t event_mask[2];
    uint16_t opcode;
};

static pthread_mutex_t g_log_lock = PTHREAD_MUTEX_INITIALIZER;

static void BtVendorLog(const char *fmt, ...)
{
    char body[1024];
    char line[1200];
    va_list ap;

    va_start(ap, fmt);
    vsnprintf(body, sizeof(body), fmt, ap);
    va_end(ap);

    pthread_mutex_lock(&g_log_lock);
    /* stderr goes to the blue_host console (not to hilog) */
    fprintf(stderr, "[bt_vendor] %s\n", body);
    /* the real sink: hilog */
    BtVendorInitHiLog();
    if (g_hiLogPrint != NULL) {
        (void)g_hiLogPrint(HILOG_LOG_CORE, HILOG_LOG_INFO, BT_VENDOR_LOG_DOMAIN,
                           BT_VENDOR_LOG_TAG, "%{public}s", body);
    }
    /* best effort file sinks (only writable for a privileged loader) */
    for (size_t i = 0; i < sizeof(g_log_files) / sizeof(g_log_files[0]); i++) {
        int fd = open(g_log_files[i], O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
        if (fd >= 0) {
            int n = snprintf(line, sizeof(line), "[%ld] %s\n", (long)time(NULL), body);
            if (n > 0) {
                (void)write(fd, line, (size_t)n);
            }
            close(fd);
        }
    }
    pthread_mutex_unlock(&g_log_lock);
}

/* ------------------------------------------------------------------ */
/* rfkill / device bring-up                                           */
/* ------------------------------------------------------------------ */

/*
 * OHOS has no rfkill agent, so hci0 can be left soft-blocked, in which case
 * HCIDEVUP fails with -ERFKILL and the whole HDI stays down.
 * Unblock every rfkill switch whose type is "bluetooth".
 */
static void UnblockBluetoothRfkill(void)
{
    char path[128];
    char type[32];
    int idx;

    for (idx = 0; idx < MAX_HCI_DEV; idx++) {
        int fd;
        ssize_t n;

        snprintf(path, sizeof(path), "/sys/class/rfkill/rfkill%d/type", idx);
        fd = open(path, O_RDONLY | O_CLOEXEC);
        if (fd < 0) {
            continue; /* no such rfkill device */
        }
        n = read(fd, type, sizeof(type) - 1);
        close(fd);
        if (n <= 0) {
            continue;
        }
        type[n] = '\0';
        if (strncmp(type, "bluetooth", 9) != 0) {
            continue;
        }

        snprintf(path, sizeof(path), "/sys/class/rfkill/rfkill%d/soft", idx);
        fd = open(path, O_WRONLY | O_CLOEXEC);
        if (fd < 0) {
            BtVendorLog("rfkill soft open failed: %s", strerror(errno));
            continue;
        }
        if (write(fd, "0", 1) != 1) {
            BtVendorLog("rfkill soft unblock write failed: %s", strerror(errno));
        } else {
            BtVendorLog("rfkill rfkill%d (bluetooth) soft-unblocked", idx);
        }
        close(fd);
    }
}

static void DumpHciDevNodes(void)
{
    char path[128];
    int idx;

    for (idx = 0; idx < MAX_HCI_DEV; idx++) {
        snprintf(path, sizeof(path), "/sys/class/bluetooth/hci%d", idx);
        if (access(path, F_OK) == 0) {
            BtVendorLog("sysfs: hci%d present", idx);
        }
    }
}

/* ------------------------------------------------------------------ */
/* H4 re-framing helpers (HDI byte stream <-> whole frames)            */
/* ------------------------------------------------------------------ */

/*
 * Header geometry per H4 packet type.  This mirrors the table the HDI uses
 * in hci_protocol.cpp (HciProtocol::header_), so both ends agree.
 */
static int H4HeaderSize(uint8_t type)
{
    switch (type) {
        case VENDOR_H4_TYPE_CMD:
        case VENDOR_H4_TYPE_SCO:
            return 3;
        case VENDOR_H4_TYPE_EVT:
            return 2;
        case VENDOR_H4_TYPE_ACL:
        case VENDOR_H4_TYPE_ISO:
            return 4;
        default:
            return -1;
    }
}

static int H4DataLenSize(uint8_t type)
{
    return (type == VENDOR_H4_TYPE_ACL || type == VENDOR_H4_TYPE_ISO) ? 2 : 1;
}

static int H4DataLenOffset(uint8_t type)
{
    return type == VENDOR_H4_TYPE_EVT ? 1 : 2;
}

static ssize_t WriteAll(int fd, const uint8_t *buf, size_t len)
{
    size_t done = 0;

    while (done < len) {
        ssize_t n = write(fd, buf + done, len - done);
        if (n > 0) {
            done += (size_t)n;
            continue;
        }
        if (n < 0 && (errno == EINTR || errno == EAGAIN)) {
            continue;
        }
        return -1;
    }
    return (ssize_t)done;
}

/*
 * One complete H4 frame found in the byte stream.
 */
typedef struct {
    uint8_t type;
    size_t offset;   /* offset of the type byte inside the stream */
    size_t length;   /* whole frame length, type byte included */
} H4Frame;

/*
 * Scans a byte stream for complete H4 frames.
 *
 * The HDI writes the type byte and the payload with two separate write()
 * calls (h4_protocol.cpp::SendPacket), so the socketpair carries a *byte
 * stream* that has to be cut into whole frames again before it can be handed
 * to the kernel (the kernel wants exactly one send() per HCI packet).
 *
 * Returns the number of complete frames found; the caller consumes
 * out[0..n-1] and then moves the remaining bytes to the front of the buffer.
 */
static int H4ScanFrames(const uint8_t *stream, size_t have, H4Frame *out, int maxOut)
{
    int n = 0;
    size_t off = 0;

    while (off < have && n < maxOut) {
        uint8_t type = stream[off];
        int hdr = H4HeaderSize(type);
        int lenOff;
        int lenSize;
        uint32_t dataLen = 0;
        size_t frameLen;
        int i;

        if (hdr < 0) {
            /* not a valid H4 type byte - resynchronise on the next byte */
            off++;
            continue;
        }
        if (have - off < (size_t)(hdr + 1)) {
            break; /* header not complete yet */
        }
        lenOff = H4DataLenOffset(type);
        lenSize = H4DataLenSize(type);
        for (i = 0; i < lenSize; i++) {
            dataLen |= (uint32_t)stream[off + 1 + lenOff + i] << (i * 8);
        }
        frameLen = 1u + (size_t)hdr + (size_t)dataLen;

        if (frameLen > (size_t)H4_PARSE_BUF) {
            /* implausible length - resynchronise */
            off++;
            continue;
        }
        if (have - off < frameLen) {
            break; /* payload not complete yet */
        }
        out[n].type = type;
        out[n].offset = off;
        out[n].length = frameLen;
        n++;
        off += frameLen;
    }
    return n;
}

/* ------------------------------------------------------------------ */
/* global state                                                        */
/* ------------------------------------------------------------------ */

/*
 * One raw socket per HCI packet type.  The SO_HCI_FILTER type_mask makes
 * the kernel deliver only the matching packet type to that socket, which is
 * how we recover the H4 type byte that the RAW channel does not deliver.
 */
typedef struct {
    int fd;
    uint8_t h4Type;      /* H4 type byte to prepend on the way to the HDI */
    uint32_t typeMask;   /* kernel HCI_*_PKT bit for SO_HCI_FILTER */
    const char *name;
} BtRawChannel;

#define BT_RAW_CHAN_COUNT 5

static BtVendorCallbacksT g_callbacks;
static BtRawChannel g_chan[BT_RAW_CHAN_COUNT] = {
    { -1, VENDOR_H4_TYPE_CMD, 1u << VENDOR_HCI_COMMAND_PKT, "cmd" },
    { -1, VENDOR_H4_TYPE_ACL, 1u << VENDOR_HCI_ACLDATA_PKT, "acl" },
    { -1, VENDOR_H4_TYPE_SCO, 1u << VENDOR_HCI_SCODATA_PKT, "sco" },
    { -1, VENDOR_H4_TYPE_EVT, 1u << VENDOR_HCI_EVENT_PKT, "evt" },
    { -1, VENDOR_H4_TYPE_ISO, 1u << VENDOR_HCI_ISODATA_PKT, "iso" },
};

static int g_relayFd = -1;    /* socketpair end owned by this shim */
static int g_hdiFd = -1;      /* socketpair end handed to the HDI */
static int g_devIdx = -1;
static pthread_t g_k2u_thread;   /* kernel -> HDI */
static pthread_t g_u2k_thread;   /* HDI  -> kernel */
static volatile int g_running = 0;
static volatile unsigned long g_stat_k2u_frames = 0;
static volatile unsigned long g_stat_u2k_frames = 0;
static volatile unsigned long g_stat_k2u_bytes = 0;
static volatile unsigned long g_stat_u2k_bytes = 0;

/* ------------------------------------------------------------------ */
/* raw HCI socket setup                                                */
/* ------------------------------------------------------------------ */

/*
 * Opens one HCI_CHANNEL_RAW socket bound to hci<idx> and installs a filter
 * that only lets the given packet type through.
 */
static int OpenRawChannel(int idx, uint32_t typeMask)
{
    struct vendor_sockaddr_hci addr;
    struct vendor_hci_ufilter flt;
    int sock;

    sock = socket(VENDOR_AF_BLUETOOTH, SOCK_RAW | SOCK_CLOEXEC, VENDOR_BTPROTO_HCI);
    if (sock < 0) {
        BtVendorLog("socket(AF_BLUETOOTH) failed: %s", strerror(errno));
        return -1;
    }

    memset(&addr, 0, sizeof(addr));
    addr.hci_family = VENDOR_AF_BLUETOOTH;
    addr.hci_dev = (uint16_t)idx;
    addr.hci_channel = VENDOR_HCI_CHANNEL_RAW;
    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        BtVendorLog("bind hci%d failed: %s", idx, strerror(errno));
        close(sock);
        return -1;
    }

    /*
     * type_mask: only the packet type this socket is interested in.
     * event_mask: all events (needed for LE Meta / scan results).
     * opcode 0: do not filter command-complete/command-status by opcode.
     *
     * NOTE: the kernel intersects this filter with hci_sec_filter unless
     * the process has CAP_NET_RAW.  Without NET_RAW type_mask would be
     * reduced to 0x10 (events only) and all LE scan results would be
     * dropped - that is why blue_host must run with the NET_RAW cap.
     */
    memset(&flt, 0, sizeof(flt));
    flt.type_mask = typeMask;
    flt.event_mask[0] = 0xFFFFFFFFu;
    flt.event_mask[1] = 0xFFFFFFFFu;
    flt.opcode = 0;
    if (setsockopt(sock, VENDOR_SOL_HCI, VENDOR_HCI_FILTER, &flt, sizeof(flt)) < 0) {
        BtVendorLog("SO_HCI_FILTER(type=0x%x) failed: %s", typeMask, strerror(errno));
    } else {
        BtVendorLog("SO_HCI_FILTER set: type_mask=0x%08x", typeMask);
    }

    return sock;
}

/*
 * Brings the controller up if it is not up yet.
 *
 * HCIDEVUP is _IOW('H', 201, int) in linux-7.2 and requires CAP_NET_ADMIN.
 * btintel_pcie already opened the device during probe, in which case the
 * ioctl returns -EALREADY, which is success for us.
 */
static int EnsureHciUp(int idx)
{
    int devId = idx;

    if (ioctl(g_chan[0].fd, VENDOR_HCIDEVUP, &devId) < 0) {
        int err = errno;
        if (err == EALREADY) {
            BtVendorLog("HCIDEVUP hci%d: already up (EALREADY), continuing", idx);
            return 0;
        }
        BtVendorLog("HCIDEVUP hci%d failed: %s", idx, strerror(err));
        return -1;
    }
    BtVendorLog("HCIDEVUP hci%d ok", idx);
    return 0;
}

/*
 * Opens all raw channels on the first hciN that exists.
 * Returns 0 on success, -1 on failure.
 */
static int OpenRawHciDev(void)
{
    char path[128];
    int idx;

    UnblockBluetoothRfkill();
    DumpHciDevNodes();

    for (idx = 0; idx < MAX_HCI_DEV; idx++) {
        int i;
        int ok = 1;

        snprintf(path, sizeof(path), "/sys/class/bluetooth/hci%d", idx);
        if (access(path, F_OK) != 0) {
            continue;
        }

        for (i = 0; i < BT_RAW_CHAN_COUNT; i++) {
            int fd = OpenRawChannel(idx, g_chan[i].typeMask);
            if (fd < 0) {
                ok = 0;
                break;
            }
            g_chan[i].fd = fd;
        }
        if (!ok) {
            for (i = 0; i < BT_RAW_CHAN_COUNT; i++) {
                if (g_chan[i].fd >= 0) {
                    close(g_chan[i].fd);
                    g_chan[i].fd = -1;
                }
            }
            continue;
        }

        g_devIdx = idx;
        BtVendorLog("raw HCI sockets bound on hci%d (%d channels)", idx, BT_RAW_CHAN_COUNT);
        if (EnsureHciUp(idx) != 0) {
            BtVendorLog("warning: could not confirm hci%d up, continuing anyway", idx);
        }
        return 0;
    }

    BtVendorLog("no usable hciN found under /sys/class/bluetooth "
                "(btintel_pcie did not create a device?)");
    return -1;
}

/* ------------------------------------------------------------------ */
/* relay threads                                                       */
/* ------------------------------------------------------------------ */

/*
 * kernel -> HDI.
 *
 * The RAW channel delivers the bare payload, so we prepend the H4 type byte
 * of the socket the packet arrived on.
 */
static void *KernelToHdiThread(void *arg)
{
    uint8_t buf[HCI_RX_BUF];
    (void)arg;

    BtVendorLog("k2u relay started (hci%d -> hdi fd %d)", g_devIdx, g_relayFd);
    while (g_running) {
        struct pollfd pfd[BT_RAW_CHAN_COUNT];
        int nready;
        int i;

        for (i = 0; i < BT_RAW_CHAN_COUNT; i++) {
            pfd[i].fd = g_chan[i].fd;
            pfd[i].events = POLLIN;
            pfd[i].revents = 0;
        }

        nready = poll(pfd, BT_RAW_CHAN_COUNT, 200);
        if (nready < 0) {
            if (errno == EINTR) {
                continue;
            }
            BtVendorLog("k2u poll error: %s", strerror(errno));
            break;
        }
        if (nready == 0) {
            continue;
        }

        for (i = 0; i < BT_RAW_CHAN_COUNT; i++) {
            ssize_t n;
            uint8_t framed[HCI_RX_BUF + 1];

            if (!(pfd[i].revents & (POLLIN | POLLERR | POLLHUP))) {
                continue;
            }
            n = read(g_chan[i].fd, buf, sizeof(buf));
            if (n <= 0) {
                if (n < 0 && (errno == EINTR || errno == EAGAIN)) {
                    continue;
                }
                BtVendorLog("k2u read error on %s channel: %s",
                            g_chan[i].name, n == 0 ? "EOF" : strerror(errno));
                if (n == 0) {
                    g_running = 0;
                }
                continue;
            }
            framed[0] = g_chan[i].h4Type;
            memcpy(framed + 1, buf, (size_t)n);
            if (WriteAll(g_relayFd, framed, (size_t)n + 1) < 0) {
                BtVendorLog("k2u write to hdi failed: %s", strerror(errno));
                g_running = 0;
                break;
            }
            g_stat_k2u_frames++;
            g_stat_k2u_bytes += (unsigned long)n;
        }
    }
    BtVendorLog("k2u relay exiting");
    return NULL;
}

/*
 * HDI -> kernel.
 *
 * The HDI emits a type byte and its payload as separate write() calls, so
 * we must reassemble complete frames before handing them to the kernel,
 * which requires exactly one send() per HCI packet.
 *
 * Every frame is sent on the raw socket that matches its type: the kernel
 * echoes transmitted frames to the *other* raw sockets of the device, so
 * sending an ACL frame on the "cmd" socket would make us receive our own
 * TX data as if it were RX.
 */
static void *HdiToKernelThread(void *arg)
{
    uint8_t stream[H4_PARSE_BUF];
    size_t have = 0;
    (void)arg;

    BtVendorLog("u2k relay started (hdi fd %d -> hci%d)", g_hdiFd, g_devIdx);

    while (g_running) {
        ssize_t n;

        if (have >= sizeof(stream)) { /* cannot happen; parse is bounded */
            BtVendorLog("u2k parser buffer overflow, resetting stream");
            have = 0;
        }

        n = read(g_relayFd, stream + have, sizeof(stream) - have);
        if (n == 0) {
            BtVendorLog("u2k hdi socket EOF");
            break;
        }
        if (n < 0) {
            if (errno == EINTR || errno == EAGAIN) {
                continue;
            }
            BtVendorLog("u2k read error: %s", strerror(errno));
            break;
        }
        have += (size_t)n;

        /* Consume as many whole frames as the buffer currently holds. */
        H4Frame frames[16];
        int nframes = H4ScanFrames(stream, have, frames, (int)(sizeof(frames) / sizeof(frames[0])));
        size_t off = 0;
        for (int f = 0; f < nframes; f++) {
            uint8_t type = frames[f].type;
            int txChan = -1;

            for (int i = 0; i < BT_RAW_CHAN_COUNT; i++) {
                if (g_chan[i].h4Type == type) {
                    txChan = i;
                    break;
                }
            }
            if (txChan < 0 || g_chan[txChan].fd < 0) {
                BtVendorLog("u2k no raw channel for H4 type 0x%02x", type);
                off += frames[f].length;
                continue;
            }
            if (send(g_chan[txChan].fd, stream + frames[f].offset, frames[f].length, 0) < 0) {
                BtVendorLog("u2k send to kernel failed (type 0x%02x): %s",
                            type, strerror(errno));
                goto done;
            }
            g_stat_u2k_frames++;
            g_stat_u2k_bytes += (unsigned long)frames[f].length;
            off += frames[f].length;
        }

        /* move the remainder to the front */
        if (off > 0) {
            memmove(stream, stream + off, have - off);
            have -= off;
        }
    }

done:
    BtVendorLog("u2k relay exiting");
    return NULL;
}

/* ------------------------------------------------------------------ */
/* vendor HAL entry points                                            */
/* ------------------------------------------------------------------ */

/*
 * Environment probe.  Loaded by blue_host (an init service, so the "init"
 * namespace) but the diag collector may run elsewhere, and on this port we
 * have seen /vendor and /data absent from the collector's mount namespace.
 * Log what *this* process can actually see so the next bundle is conclusive.
 */
static void BtVendorProbeEnv(void)
{
    static const char *const dirs[] = {
        "/sys/class/bluetooth", "/vendor/lib64", "/vendor/etc", "/system/lib64",
        "/system/etc", "/data", "/data/local/tmp", "/sys_prod", "/mnt/od",
    };
    struct stat st;

    BtVendorLog("probe: pid=%d uid=%d", (int)getpid(), (int)getuid());
    for (size_t i = 0; i < sizeof(dirs) / sizeof(dirs[0]); i++) {
        if (stat(dirs[i], &st) == 0) {
            BtVendorLog("probe: %-22s OK", dirs[i]);
        } else {
            BtVendorLog("probe: %-22s MISSING (errno=%d)", dirs[i], errno);
        }
    }
    for (size_t i = 0; i < sizeof(g_log_files) / sizeof(g_log_files[0]); i++) {
        if (stat(g_log_files[i], &st) == 0) {
            BtVendorLog("probe: sink %s present (size=%lld)", g_log_files[i], (long long)st.st_size);
        } else {
            BtVendorLog("probe: sink %s NOT present (errno=%d)", g_log_files[i], errno);
        }
    }
}

static int BtVendorInit(const BtVendorCallbacksT *pCb, unsigned char *localBdaddr)
{
    BtVendorLog("init: cb=%p bdaddr=%02x:%02x:%02x:%02x:%02x:%02x",
                (const void *)pCb,
                localBdaddr ? localBdaddr[0] : 0, localBdaddr ? localBdaddr[1] : 0,
                localBdaddr ? localBdaddr[2] : 0, localBdaddr ? localBdaddr[3] : 0,
                localBdaddr ? localBdaddr[4] : 0, localBdaddr ? localBdaddr[5] : 0);
    BtVendorProbeEnv();
    if (pCb == NULL) {
        BtVendorLog("init: NULL callbacks");
        return -1;
    }
    memcpy(&g_callbacks, pCb, sizeof(g_callbacks));
    return 0;
}

static int BtVendorOp(BtOpcodeT opcode, void *param)
{
    BtVendorLog("op %d start", (int)opcode);

    switch (opcode) {
        case BT_OP_POWER_ON:
            BtVendorLog("op BT_OP_POWER_ON (controller is owned by the kernel)");
            return 0;

        case BT_OP_POWER_OFF:
            BtVendorLog("op BT_OP_POWER_OFF");
            return 0;

        case BT_OP_HCI_CHANNEL_OPEN: {
            int pair[2];

            if (param == NULL) {
                BtVendorLog("BT_OP_HCI_CHANNEL_OPEN: NULL param");
                return -1;
            }
            if (OpenRawHciDev() != 0) {
                BtVendorLog("BT_OP_HCI_CHANNEL_OPEN: could not obtain raw HCI sockets");
                return -1;
            }

            if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair) < 0) {
                BtVendorLog("socketpair failed: %s", strerror(errno));
                for (int i = 0; i < BT_RAW_CHAN_COUNT; i++) {
                    if (g_chan[i].fd >= 0) {
                        close(g_chan[i].fd);
                        g_chan[i].fd = -1;
                    }
                }
                return -1;
            }
            g_relayFd = pair[0]; /* shim side */
            g_hdiFd = pair[1];   /* handed to the HDI */

            g_running = 1;
            if (pthread_create(&g_k2u_thread, NULL, KernelToHdiThread, NULL) != 0) {
                BtVendorLog("pthread_create(k2u) failed: %s", strerror(errno));
                g_running = 0;
                goto fail;
            }
            if (pthread_create(&g_u2k_thread, NULL, HdiToKernelThread, NULL) != 0) {
                BtVendorLog("pthread_create(u2k) failed: %s", strerror(errno));
                g_running = 0;
                pthread_join(g_k2u_thread, NULL);
                goto fail;
            }

            BtVendorLog("BT_OP_HCI_CHANNEL_OPEN ok: returning 1 channel, fd=%d (hci%d)",
                        g_hdiFd, g_devIdx);
            ((int *)param)[HCI_CMD] = g_hdiFd;
            return 1; /* channelCount == 1 -> HDI takes the single-fd H4 path */

        fail:
            close(pair[0]);
            close(pair[1]);
            g_relayFd = g_hdiFd = -1;
            for (int i = 0; i < BT_RAW_CHAN_COUNT; i++) {
                if (g_chan[i].fd >= 0) {
                    close(g_chan[i].fd);
                    g_chan[i].fd = -1;
                }
            }
            return -1;
        }

        case BT_OP_HCI_CHANNEL_CLOSE:
            BtVendorLog("BT_OP_HCI_CHANNEL_CLOSE");
            g_running = 0;
            if (g_relayFd >= 0) {
                shutdown(g_relayFd, SHUT_RDWR);
                close(g_relayFd);
                g_relayFd = -1;
            }
            if (g_hdiFd >= 0) {
                close(g_hdiFd);
                g_hdiFd = -1;
            }
            for (int i = 0; i < BT_RAW_CHAN_COUNT; i++) {
                if (g_chan[i].fd >= 0) {
                    close(g_chan[i].fd);
                    g_chan[i].fd = -1;
                }
            }
            BtVendorLog("channels closed (k2u=%lu frames/%lu bytes, u2k=%lu frames/%lu bytes)",
                        g_stat_k2u_frames, g_stat_k2u_bytes,
                        g_stat_u2k_frames, g_stat_u2k_bytes);
            return 0;

        case BT_OP_INIT:
            BtVendorLog("op BT_OP_INIT: notifying host");
            if (g_callbacks.initCb != NULL) {
                g_callbacks.initCb(BTC_OP_RESULT_SUCCESS);
            }
            return 0;

        case BT_OP_GET_LPM_TIMER: {
            /* 0 = never auto-enter low power mode.  The controller is
             * managed by the kernel here, so we must not inject our own LPM
             * idle timeout or scans would stop between events. */
            uint32_t ms = 0;
            if (param != NULL) {
                memcpy(param, &ms, sizeof(ms));
            }
            BtVendorLog("op BT_OP_GET_LPM_TIMER -> 0 (LPM disabled)");
            return 0;
        }

        case BT_OP_LPM_ENABLE:
        case BT_OP_LPM_DISABLE:
        case BT_OP_WAKEUP_LOCK:
        case BT_OP_WAKEUP_UNLOCK:
        case BT_OP_EVENT_CALLBACK:
            /* No controller-side state to manage on a kernel-owned device. */
            return 0;

        default:
            BtVendorLog("op %d: unhandled, returning success", (int)opcode);
            return 0;
    }
}

static void BtVendorClose(void)
{
    BtVendorLog("close");
    (void)BtVendorOp(BT_OP_HCI_CHANNEL_CLOSE, NULL);
}

/*
 * dlsym() name used by the HDI:
 *   BT_VENDOR_INTERFACE_SYMBOL_NAME == "BLUETOOTH_VENDOR_LIB_INTERFACE"
 *   (drivers/peripheral/bluetooth/hci/hdi_service/implement/bt_hal_constant.h)
 */
__attribute__((visibility("default"))) BtVendorInterfaceT BLUETOOTH_VENDOR_LIB_INTERFACE = {
    sizeof(BtVendorInterfaceT),
    BtVendorInit,
    BtVendorOp,
    BtVendorClose,
};
