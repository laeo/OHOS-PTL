/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
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
 * hwdec_probe - Intel(R) hardware video decode probe for OpenHarmony (pc_ptl / PTL).
 *
 * Two independent decode paths are attempted, so that at least one of them can
 * give a definitive answer on a real machine:
 *
 *   (1) oneVPL : libvpl.so.2 (dispatcher)
 *                  -> libmfx-gen.so.1.2 (GPU runtime)
 *                  -> libva.so.2 / libva-drm.so.2
 *                  -> /vendor/lib64/dri/iHD_drv_video.so (Intel media driver)
 *                  -> libigdgmm.so.12 -> kernel xe (DRM_IOCTL_XE_EXEC)
 *
 *   (2) VA-API : libva.so.2 + libva-drm.so.2
 *                  -> /vendor/lib64/dri/iHD_drv_video.so
 *                  -> kernel xe
 *
 * The probe NEVER aborts: when no DRM/xe device or no runtime is available it
 * prints the reason and exits with 0, so the init service stays happy.
 *
 * Usage:  hwdec_probe [stream] [logfile] [max_frames] [codec] [mode]
 *         codec: avc | hevc | auto (default auto)
 *         mode : auto | vpl | va   (default auto)
 */

#define _GNU_SOURCE
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#ifdef HWDEC_NO_HILOG
/* host build (glibc) for validating the decode logic on a real GPU */
typedef int LogType;
typedef int LogLevel;
#define LOG_APP 0
#define LOG_INFO 4
static inline int OH_LOG_Print(LogType t, LogLevel l, unsigned int d, const char *tag, const char *fmt, ...)
{
    (void)t; (void)l; (void)d; (void)tag; (void)fmt;
    return 0;
}
#else
#include <hilog/log.h>
#endif
#include <mfx.h>

#include <va/va.h>
#include <va/va_drm.h>

#define HWDEC_LOG_DOMAIN 0xD003C00
#define HWDEC_LOG_TAG "HWDEC"

#define DEFAULT_STREAM "/system/etc/hwdec/sample.h264"
#define DEFAULT_LOG "/sys_prod/hwdec_probe.log"
#define FALLBACK_LOG "/data/local/tmp/hwdec_probe.log"
#define DEFAULT_MAX_FRAMES 120

#define API_MAJOR_REQUIRED 2
#define API_MINOR_REQUIRED 2
#define VPLVERSION(major, minor) ((major) << 16 | (minor))

#define VPL_BUFFER_SIZE (1 * 1024 * 1024)
#define MAX_NALS 400000

/* ------------------------------------------------------------------ logging */

static FILE *g_logFile = NULL;
static int g_hilogFailures = 0;

static void Plog(const char *fmt, ...)
{
    char buf[4096];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n < 0) {
        return;
    }
    if ((size_t)n >= sizeof(buf)) {
        n = (int)sizeof(buf) - 1;
    }
    buf[n] = '\0';
    printf("%s\n", buf);
    fflush(stdout);
    if (g_logFile != NULL) {
        fprintf(g_logFile, "%s\n", buf);
        fflush(g_logFile);
    }
    /* OH_LOG_Print returns >= 0 on success (byte count), < 0 when the message
     * was rejected (e.g. level below the current hilog threshold). */
    if (OH_LOG_Print(LOG_APP, LOG_INFO, HWDEC_LOG_DOMAIN, HWDEC_LOG_TAG, "%{public}s", buf) < 0) {
        g_hilogFailures++;
    }
}

static double NowWallMs(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

static double NowCpuMs(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

/* Open the log file and redirect stderr into it, so that the messages the
 * VA stack writes to stderr (libva "Trying to open ...", the Intel media
 * driver, gmmlib) end up in the same log file instead of being lost. */
static int OpenLogFile(const char *path)
{
    g_logFile = fopen(path, "w");
    if (g_logFile == NULL && strcmp(path, FALLBACK_LOG) != 0) {
        g_logFile = fopen(FALLBACK_LOG, "w");
        if (g_logFile != NULL) {
            printf("HWDEC: WARN log path '%s' not writable (%s), fallback to %s\n", path,
                   strerror(errno), FALLBACK_LOG);
        }
    }
    if (g_logFile == NULL) {
        return -1;
    }
    fflush(stderr);
    dup2(fileno(g_logFile), STDERR_FILENO);
    return 0;
}

/* ------------------------------------------------------------- annex-B NALs */

typedef struct {
    const uint8_t *data; /* payload without start code */
    size_t len;
} Nal;

typedef struct {
    const uint8_t *p;
    size_t len;
    size_t bitpos;
} BitReader;

/* Annex-B scan: fills nals[] with NAL payloads (start codes removed). */
static int ScanAnnexB(const uint8_t *buf, size_t len, Nal *nals, int max)
{
    int count = 0;
    size_t i = 0;
    size_t start = 0;
    int in_nal = 0;
    while (i + 3 < len && count < max) {
        if (buf[i] == 0 && buf[i + 1] == 0 && buf[i + 2] == 1) {
            if (in_nal) {
                nals[count].data = buf + start;
                nals[count].len = i - start;
                count++;
            }
            i += 3;
            start = i;
            in_nal = 1;
        } else {
            i++;
        }
    }
    if (in_nal && count < max) {
        nals[count].data = buf + start;
        nals[count].len = len - start;
        count++;
    }
    return count;
}

static uint32_t ReadBits(BitReader *br, int n)
{
    uint32_t v = 0;
    for (int i = 0; i < n; i++) {
        size_t byte = br->bitpos >> 3;
        int bit = 7 - (int)(br->bitpos & 7);
        uint32_t b = (byte < br->len) ? ((br->p[byte] >> bit) & 1) : 0;
        v = (v << 1) | b;
        br->bitpos++;
    }
    return v;
}

static uint32_t ReadUE(BitReader *br)
{
    int zeros = 0;
    while (ReadBits(br, 1) == 0) {
        zeros++;
        if (zeros > 32) {
            return 0;
        }
    }
    if (zeros == 0) {
        return 0;
    }
    return ((1u << zeros) - 1) + ReadBits(br, zeros);
}

static int32_t ReadSE(BitReader *br)
{
    uint32_t k = ReadUE(br);
    if (k & 1) {
        return (int32_t)((k + 1) >> 1);
    }
    return -(int32_t)(k >> 1);
}

/* Parse an AVC (H.264) SPS NAL payload (start code already removed, the
 * 1 byte NAL header still present) -> picture width/height in luma samples.
 * Returns 0 on success. */
static int ParseAvcSps(const uint8_t *nal, size_t len, int *outW, int *outH)
{
    if (len < 5) {
        return -1;
    }
    BitReader br = {nal + 1, len - 1, 0}; /* skip the NAL header byte */
    uint32_t profileIdc = ReadBits(&br, 8);
    ReadBits(&br, 8); /* constraint flags + reserved */
    ReadBits(&br, 8); /* level_idc */
    ReadUE(&br);      /* seq_parameter_set_id */

    uint32_t chromaFormatIdc = 1;
    int separateColourPlane = 0;
    if (profileIdc == 100 || profileIdc == 110 || profileIdc == 122 || profileIdc == 244 ||
        profileIdc == 44 || profileIdc == 83 || profileIdc == 86 || profileIdc == 118 ||
        profileIdc == 128 || profileIdc == 138 || profileIdc == 139 || profileIdc == 134 ||
        profileIdc == 135) {
        chromaFormatIdc = ReadUE(&br);
        if (chromaFormatIdc == 3) {
            separateColourPlane = (int)ReadBits(&br, 1);
        }
        ReadUE(&br); /* bit_depth_luma_minus8 */
        ReadUE(&br); /* bit_depth_chroma_minus8 */
        ReadBits(&br, 1); /* qpprime_y_zero_transform_bypass_flag */
        if (ReadBits(&br, 1)) { /* seq_scaling_matrix_present_flag */
            int n = (chromaFormatIdc != 3) ? 8 : 12;
            for (int i = 0; i < n; i++) {
                if (ReadBits(&br, 1)) {
                    int lastScale = 8, nextScale = 8;
                    int size = (i < 6) ? 16 : 64;
                    for (int j = 0; j < size; j++) {
                        if (nextScale != 0) {
                            int delta = (int)ReadSE(&br);
                            nextScale = (lastScale + delta + 256) % 256;
                        }
                        lastScale = (nextScale == 0) ? lastScale : nextScale;
                    }
                }
            }
        }
    }
    ReadUE(&br); /* log2_max_frame_num_minus4 */
    uint32_t pocType = ReadUE(&br);
    if (pocType == 0) {
        ReadUE(&br); /* log2_max_pic_order_cnt_lsb_minus4 */
    } else if (pocType == 1) {
        ReadBits(&br, 1);
        ReadSE(&br);
        ReadSE(&br);
        uint32_t n = ReadUE(&br);
        for (uint32_t i = 0; i < n && i < 256; i++) {
            ReadSE(&br);
        }
    }
    ReadUE(&br); /* max_num_ref_frames */
    ReadBits(&br, 1); /* gaps_in_frame_num_value_allowed_flag */
    uint32_t widthInMbs = ReadUE(&br) + 1;
    uint32_t heightInMapUnits = ReadUE(&br) + 1;
    int frameMbsOnly = (int)ReadBits(&br, 1);
    if (!frameMbsOnly) {
        ReadBits(&br, 1); /* mb_adaptive_frame_field_flag */
    }
    ReadBits(&br, 1); /* direct_8x8_inference_flag */
    int width = (int)(widthInMbs * 16);
    int height = (int)(heightInMapUnits * 16) * (2 - frameMbsOnly);
    if (ReadBits(&br, 1)) { /* frame_cropping_flag */
        uint32_t cl = ReadUE(&br);
        uint32_t cr = ReadUE(&br);
        uint32_t ct = ReadUE(&br);
        uint32_t cb = ReadUE(&br);
        int subW = (chromaFormatIdc == 1) ? 2 : 1;
        int subH = (chromaFormatIdc == 1) ? 2 : 1;
        if (separateColourPlane) {
            subW = 1;
            subH = 1;
        }
        int cropUnitX = (chromaFormatIdc == 0 || separateColourPlane) ? 1 : subW;
        int cropUnitY = ((chromaFormatIdc == 0 || separateColourPlane) ? 1 : subH) * (2 - frameMbsOnly);
        width -= (int)((cl + cr) * (uint32_t)cropUnitX);
        height -= (int)((ct + cb) * (uint32_t)cropUnitY);
    }
    if (width <= 0 || height <= 0 || width > 8192 || height > 8192) {
        return -1;
    }
    *outW = width;
    *outH = height;
    return 0;
}

static const char *CodecName(mfxU32 codec)
{
    return (codec == MFX_CODEC_HEVC) ? "HEVC" : ((codec == MFX_CODEC_AVC) ? "AVC" : "OTHER");
}

static const char *FourccName(mfxU32 fourcc)
{
    switch (fourcc) {
        case MFX_FOURCC_NV12:
            return "NV12";
        case MFX_FOURCC_I420:
            return "I420";
        case MFX_FOURCC_YV12:
            return "YV12";
        case MFX_FOURCC_P010:
            return "P010";
        default:
            return "UNKNOWN";
    }
}

/* ---------------------------------------------------------------- VA loader */

typedef struct {
    void *lib;
    void *libdrm;
    VADisplay (*GetDisplayDRM)(int fd);
    VAStatus (*Initialize)(VADisplay dpy, int *major, int *minor);
    VAStatus (*Terminate)(VADisplay dpy);
    const char *(*ErrorStr)(VAStatus s);
    const char *(*VendorString)(VADisplay dpy);
    int (*MaxNumProfiles)(VADisplay dpy);
    VAStatus (*QueryConfigProfiles)(VADisplay dpy, VAProfile *list, int *num);
    VAStatus (*CreateConfig)(VADisplay dpy, VAProfile p, VAEntrypoint e, VAConfigAttrib *a, int n,
                             VAConfigID *id);
    VAStatus (*DestroyConfig)(VADisplay dpy, VAConfigID id);
    VAStatus (*CreateSurfaces)(VADisplay dpy, unsigned int fmt, unsigned int w, unsigned int h,
                               VASurfaceID *s, int n, VASurfaceAttrib *a, int na);
    VAStatus (*DestroySurfaces)(VADisplay dpy, VASurfaceID *s, int n);
    VAStatus (*CreateContext)(VADisplay dpy, VAConfigID cid, int w, int h, int flag,
                              VASurfaceID *rt, int nrt, VAContextID *ctx);
    VAStatus (*DestroyContext)(VADisplay dpy, VAContextID ctx);
    VAStatus (*CreateBuffer)(VADisplay dpy, VAContextID ctx, VABufferType type, unsigned int size,
                              unsigned int num, void *data, VABufferID *id);
    VAStatus (*DestroyBuffer)(VADisplay dpy, VABufferID id);
    VAStatus (*BeginPicture)(VADisplay dpy, VAContextID ctx, VASurfaceID s);
    VAStatus (*RenderPicture)(VADisplay dpy, VAContextID ctx, VABufferID *bufs, int n);
    VAStatus (*EndPicture)(VADisplay dpy, VAContextID ctx);
    VAStatus (*SyncSurface)(VADisplay dpy, VASurfaceID s);
    VAStatus (*MapBuffer)(VADisplay dpy, VABufferID id, void **p);
    VAStatus (*UnmapBuffer)(VADisplay dpy, VABufferID id);
    VAStatus (*CreateImage)(VADisplay dpy, VAImageFormat *fmt, unsigned int w, unsigned int h,
                            VAImage *img);
    VAStatus (*GetImage)(VADisplay dpy, VASurfaceID s, int x, int y, unsigned int w, unsigned int h,
                         VAImageID img);
    VAStatus (*DestroyImage)(VADisplay dpy, VAImageID img);
} VaApi;

static void *VaSym(void *lib, const char *name)
{
    void *s = dlsym(lib, name);
    if (s == NULL) {
        Plog("HWDEC: diag libva symbol '%s' missing: %s", name, dlerror());
    }
    return s;
}

static int VaLoad(VaApi *va)
{
    static const char *cands[] = {"libva.so.2", "/vendor/lib64/libva.so.2", "libva.so"};
    static const char *drmCands[] = {"libva-drm.so.2", "/vendor/lib64/libva-drm.so.2", "libva-drm.so"};
    memset(va, 0, sizeof(*va));
    for (size_t i = 0; i < sizeof(cands) / sizeof(cands[0]); i++) {
        va->lib = dlopen(cands[i], RTLD_NOW | RTLD_GLOBAL);
        if (va->lib != NULL) {
            Plog("HWDEC: diag dlopen(%s) OK", cands[i]);
            break;
        }
    }
    if (va->lib == NULL) {
        Plog("HWDEC: diag dlopen(libva.so.2) FAILED: %s", dlerror());
        return -1;
    }
    for (size_t i = 0; i < sizeof(drmCands) / sizeof(drmCands[0]); i++) {
        va->libdrm = dlopen(drmCands[i], RTLD_NOW | RTLD_GLOBAL);
        if (va->libdrm != NULL) {
            Plog("HWDEC: diag dlopen(%s) OK", drmCands[i]);
            break;
        }
    }
    if (va->libdrm == NULL) {
        Plog("HWDEC: diag dlopen(libva-drm.so.2) FAILED: %s", dlerror());
        return -1;
    }
#define VSYM(field, name)                                  \
    do {                                                    \
        va->field = VaSym(va->lib, name);                  \
        if (va->field == NULL) {                           \
            return -1;                                     \
        }                                                   \
    } while (0)
    VSYM(Initialize, "vaInitialize");
    VSYM(Terminate, "vaTerminate");
    VSYM(ErrorStr, "vaErrorStr");
    VSYM(VendorString, "vaQueryVendorString");
    VSYM(MaxNumProfiles, "vaMaxNumProfiles");
    VSYM(QueryConfigProfiles, "vaQueryConfigProfiles");
    VSYM(CreateConfig, "vaCreateConfig");
    VSYM(DestroyConfig, "vaDestroyConfig");
    VSYM(CreateSurfaces, "vaCreateSurfaces");
    VSYM(DestroySurfaces, "vaDestroySurfaces");
    VSYM(CreateContext, "vaCreateContext");
    VSYM(DestroyContext, "vaDestroyContext");
    VSYM(CreateBuffer, "vaCreateBuffer");
    VSYM(DestroyBuffer, "vaDestroyBuffer");
    VSYM(BeginPicture, "vaBeginPicture");
    VSYM(RenderPicture, "vaRenderPicture");
    VSYM(EndPicture, "vaEndPicture");
    VSYM(SyncSurface, "vaSyncSurface");
    VSYM(MapBuffer, "vaMapBuffer");
    VSYM(UnmapBuffer, "vaUnmapBuffer");
    VSYM(CreateImage, "vaCreateImage");
    VSYM(GetImage, "vaGetImage");
    VSYM(DestroyImage, "vaDestroyImage");
#undef VSYM
    void *g = VaSym(va->libdrm, "vaGetDisplayDRM");
    if (g == NULL) {
        /* older name */
        g = VaSym(va->libdrm, "vaOpenDisplay");
    }
    if (g == NULL) {
        return -1;
    }
    va->GetDisplayDRM = (VADisplay(*)(int))g;
    return 0;
}

/* Open the DRM device and create a VA display for it.
 * The render node (renderD128) is the one libva/iHD wants; card0 is only a
 * fallback.  Returns the display or NULL, and fills *fdOut with the fd. */
static VADisplay VaOpenDisplay(VaApi *va, const char **nodeOut, int *fdOut, int *errOut)
{
    static const char *nodes[] = {"/dev/dri/renderD128", "/dev/dri/card0", "/dev/dri/card1"};
    struct stat st;
    for (size_t i = 0; i < sizeof(nodes) / sizeof(nodes[0]); i++) {
        if (stat(nodes[i], &st) != 0) {
            Plog("HWDEC: diag drm node %s: %s", nodes[i], strerror(errno));
            continue;
        }
        Plog("HWDEC: diag drm node %s exists mode=0%o uid=%d gid=%d", nodes[i], (unsigned)st.st_mode,
             (int)st.st_uid, (int)st.st_gid);
        int fd = open(nodes[i], O_RDWR | O_CLOEXEC);
        if (fd < 0) {
            fd = open(nodes[i], O_RDONLY | O_CLOEXEC);
        }
        if (fd < 0) {
            Plog("HWDEC: diag open(%s) failed: %s", nodes[i], strerror(errno));
            continue;
        }
        VADisplay dpy = va->GetDisplayDRM(fd);
        if (dpy == NULL) {
            Plog("HWDEC: diag vaGetDisplayDRM(%s) returned NULL", nodes[i]);
            close(fd);
            continue;
        }
        int major = 0, minor = 0;
        VAStatus rc = va->Initialize(dpy, &major, &minor);
        if (rc != VA_STATUS_SUCCESS) {
            const char *es = va->ErrorStr != NULL ? va->ErrorStr(rc) : "(no vaErrorStr)";
            Plog("HWDEC: diag vaInitialize(%s) rc=%d (%s) [VA_STATUS_ERROR_INVALID_DISPLAY=%d]",
                 nodes[i], (int)rc, es != NULL ? es : "?", (int)VA_STATUS_ERROR_INVALID_DISPLAY);
            if (errOut != NULL && *errOut == 0) {
                *errOut = (int)rc;
            }
            close(fd);
            continue;
        }
        Plog("HWDEC: diag vaInitialize(%s) OK va_api=%d.%d", nodes[i], major, minor);
        const char *vs = va->VendorString != NULL ? va->VendorString(dpy) : NULL;
        Plog("HWDEC: diag va vendor string: %s", vs != NULL ? vs : "(null)");
        *nodeOut = nodes[i];
        *fdOut = fd;
        return dpy;
    }
    return NULL;
}

/* --------------------------------------------------------- VA-API decoding */

typedef struct {
    int frames;
    int nonzeroPixels;
    int width;
    int height;
    double wallMs;
    double cpuMs;
    double minFrameMs;
    double maxFrameMs;
} VaResult;

/* submit one picture (parameter sets + all its slices) to the VA decoder */
static int VaSubmitPicture(VaApi *va, VADisplay dpy, VAContextID context, VASurfaceID surface,
                           const uint8_t *pbuf, size_t pbufLen, int width, int height, VaResult *res,
                           double *last)
{
    /* the Intel media driver requires num_elements == 1 for a slice data
     * buffer (media_ddi_decode_base.cpp: "if(type != VASliceParameterBufferType
     * && numElements > 1) return VA_STATUS_ERROR_INVALID_PARAMETER") */
    /* BeginPicture must be called before RenderPicture: it resets some driver
     * side parameters (see the media driver ULT: "As BeginPicture would reset
     * some parameters, so it should be called before RenderPicture"). */
    if (va->BeginPicture(dpy, context, surface) != VA_STATUS_SUCCESS) {
        Plog("HWDEC: va BeginPicture failed");
        return -1;
    }
    VABufferID sliceBuf = 0;
    VAStatus s4 = va->CreateBuffer(dpy, context, VASliceDataBufferType, (unsigned int)pbufLen, 1,
                                    (void *)pbuf, &sliceBuf);
    if (s4 != VA_STATUS_SUCCESS) {
        Plog("HWDEC: va CreateBuffer(slice) failed rc=%d (%s)", (int)s4,
             va->ErrorStr != NULL ? va->ErrorStr(s4) : "?");
        return -1;
    }
    VAStatus rrc = va->RenderPicture(dpy, context, &sliceBuf, 1);
    if (rrc != VA_STATUS_SUCCESS) {
        Plog("HWDEC: va RenderPicture failed rc=%d (%s)", (int)rrc,
             va->ErrorStr != NULL ? va->ErrorStr(rrc) : "?");
    }
    VAStatus erc = va->EndPicture(dpy, context);
    if (erc != VA_STATUS_SUCCESS) {
        Plog("HWDEC: va EndPicture failed rc=%d (%s)", (int)erc,
             va->ErrorStr != NULL ? va->ErrorStr(erc) : "?");
        va->DestroyBuffer(dpy, sliceBuf);
        return -1;
    }
    va->SyncSurface(dpy, surface);

    if (res->frames == 0) {
        VAImage image;
        VAImageFormat fmt;
        memset(&image, 0, sizeof(image));
        memset(&fmt, 0, sizeof(fmt));
        fmt.fourcc = VA_FOURCC_NV12;
        fmt.byte_order = VA_LSB_FIRST;
        fmt.bits_per_pixel = 12;
        if (va->CreateImage(dpy, &fmt, (unsigned int)width, (unsigned int)height, &image) ==
                VA_STATUS_SUCCESS &&
            va->GetImage(dpy, surface, 0, 0, (unsigned int)width, (unsigned int)height,
                         image.image_id) == VA_STATUS_SUCCESS) {
            void *pix = NULL;
            if (va->MapBuffer(dpy, image.buf, &pix) == VA_STATUS_SUCCESS && pix != NULL) {
                int nz = 0;
                const uint8_t *p = (const uint8_t *)pix;
                for (int y = 0; y < height; y++) {
                    for (int x = 0; x < width; x++) {
                        if (p[(size_t)y * (size_t)width + (size_t)x] != 0) {
                            nz++;
                        }
                    }
                }
                res->nonzeroPixels = nz;
                va->UnmapBuffer(dpy, image.buf);
            }
            va->DestroyImage(dpy, image.image_id);
        }
    }
    va->DestroyBuffer(dpy, sliceBuf);
    res->frames++;
    double now = NowWallMs();
    double dt = now - *last;
    *last = now;
    if (dt < res->minFrameMs) {
        res->minFrameMs = dt;
    }
    if (dt > res->maxFrameMs) {
        res->maxFrameMs = dt;
    }
    if (res->frames <= 3 || (res->frames % 30) == 0) {
        Plog("HWDEC: va frame %d decoded in %.2f ms", res->frames, dt);
    }
    return 0;
}

static int VaDecode(VaApi *va, VADisplay dpy, const uint8_t *buf, size_t fsize, Nal *nals, int nnals,
                     int isHevc, int maxFrames, int width, int height, VaResult *res)
{
    (void)buf;
    (void)fsize;
    memset(res, 0, sizeof(*res));
    res->minFrameMs = 1e9;
    res->width = width;
    res->height = height;

    VAProfile profile = isHevc ? VAProfileHEVCMain : VAProfileH264Main;
    int n = va->MaxNumProfiles(dpy);
    if (n > 0) {
        VAProfile *profiles = (VAProfile *)calloc((size_t)n, sizeof(VAProfile));
        int np = n;
        if (va->QueryConfigProfiles(dpy, profiles, &np) == VA_STATUS_SUCCESS) {
            int found = 0;
            for (int i = 0; i < np; i++) {
                if (profiles[i] == profile) {
                    found = 1;
                }
            }
            Plog("HWDEC: va profile %s supported=%d (of %d profiles)",
                 isHevc ? "HEVCMain" : "H264Main", found, np);
            if (!found) {
                free(profiles);
                return -1;
            }
        }
        free(profiles);
    }

    VAConfigAttrib attribs[1];
    attribs[0].type = VAConfigAttribRTFormat;
    attribs[0].value = VA_RT_FORMAT_YUV420;
    VAConfigID configId = 0;
    VAStatus rc = va->CreateConfig(dpy, profile, VAEntrypointVLD, attribs, 1, &configId);
    if (rc != VA_STATUS_SUCCESS) {
        Plog("HWDEC: va CreateConfig failed rc=%d (%s)", (int)rc,
             va->ErrorStr != NULL ? va->ErrorStr(rc) : "?");
        return -1;
    }

    VASurfaceID surface = 0;
    rc = va->CreateSurfaces(dpy, VA_FOURCC_NV12, (unsigned int)width, (unsigned int)height, &surface, 1,
                            NULL, 0);
    if (rc != VA_STATUS_SUCCESS) {
        Plog("HWDEC: va CreateSurfaces failed rc=%d (%s)", (int)rc,
             va->ErrorStr != NULL ? va->ErrorStr(rc) : "?");
        va->DestroyConfig(dpy, configId);
        return -1;
    }
    VAContextID context = 0;
    rc = va->CreateContext(dpy, configId, width, height, VA_PROGRESSIVE, &surface, 1, &context);
    if (rc != VA_STATUS_SUCCESS) {
        Plog("HWDEC: va CreateContext failed rc=%d (%s)", (int)rc,
             va->ErrorStr != NULL ? va->ErrorStr(rc) : "?");
        va->DestroySurfaces(dpy, &surface, 1);
        va->DestroyConfig(dpy, configId);
        return -1;
    }
    Plog("HWDEC: va context id=0x%x surface=0x%x NV12 %dx%d", context, surface, width, height);

    /* collect the parameter sets (SPS/PPS[/VPS]) */
    size_t psCap = 1024 * 1024;
    uint8_t *psData = (uint8_t *)malloc(psCap);
    size_t psLen = 0;
    int nps = 0;
    if (psData != NULL) {
        for (int i = 0; i < nnals && nps < 16; i++) {
            int type = isHevc ? ((nals[i].data[0] >> 1) & 0x3F) : (nals[i].data[0] & 0x1F);
            int isPs = isHevc ? (type == 32 || type == 33 || type == 34) : (type == 7 || type == 8);
            if (!isPs || psLen + nals[i].len + 4 > psCap) {
                continue;
            }
            psData[psLen++] = 0;
            psData[psLen++] = 0;
            psData[psLen++] = 0;
            psData[psLen++] = 1;
            memcpy(psData + psLen, nals[i].data, nals[i].len);
            psLen += nals[i].len;
            nps++;
        }
    }
    Plog("HWDEC: va param sets: %d NAL(s), %zu bytes", nps, psLen);

    double t0 = NowWallMs();
    double cpu0 = NowCpuMs();
    double last = t0;

    /* A picture may consist of several slices (the sample has 2 per picture);
     * all slices of one picture must be submitted in a single slice data
     * buffer, otherwise the decoder gets an incomplete picture. */
    uint8_t *pbuf = NULL;
    size_t pbufLen = 0;
    size_t pbufCap = 0;
    int havePic = 0;

#define VA_APPEND_NAL(payload, plen)                                          \
    do {                                                                      \
        if (pbufLen + (plen) + 4 > pbufCap) {                                 \
            pbufCap = pbufLen + (plen) + 65536;                               \
            uint8_t *nb = (uint8_t *)realloc(pbuf, pbufCap);                  \
            if (nb == NULL) {                                                 \
                pbuf = NULL;                                                  \
                break;                                                        \
            }                                                                 \
            pbuf = nb;                                                        \
        }                                                                     \
        pbuf[pbufLen++] = 0;                                                  \
        pbuf[pbufLen++] = 0;                                                  \
        pbuf[pbufLen++] = 0;                                                  \
        pbuf[pbufLen++] = 1;                                                  \
        memcpy(pbuf + pbufLen, (payload), (plen));                            \
        pbufLen += (plen);                                                    \
    } while (0)

    for (int i = 0; i < nnals && res->frames < maxFrames; i++) {
        int type = isHevc ? ((nals[i].data[0] >> 1) & 0x3F) : (nals[i].data[0] & 0x1F);
        int isPs = isHevc ? (type >= 32 && type <= 34) : (type == 7 || type == 8);
        if (isPs) {
            continue;
        }
        int startsPicture = 0;
        if (isHevc) {
            if (nals[i].len > 2) {
                BitReader br = {nals[i].data + 2, nals[i].len - 2, 0};
                startsPicture = (int)ReadBits(&br, 1);
            }
        } else if (nals[i].len > 1) {
            BitReader br = {nals[i].data + 1, nals[i].len - 1, 0};
            startsPicture = (ReadUE(&br) == 0);
        }
        if (startsPicture) {
            if (havePic && pbuf != NULL && pbufLen > 0) {
                if (VaSubmitPicture(va, dpy, context, surface, pbuf, pbufLen, width, height, res,
                                    &last) != 0) {
                    break;
                }
            }
            havePic = 1;
            pbufLen = 0;
            if (psLen > 0) {
                if (psLen > pbufCap) {
                    pbufCap = psLen + 65536;
                    pbuf = (uint8_t *)realloc(pbuf, pbufCap);
                    if (pbuf == NULL) {
                        break;
                    }
                }
                memcpy(pbuf, psData, psLen);
                pbufLen = psLen;
            }
        } else if (!havePic) {
            continue; /* continuation slice without a picture start */
        }
        VA_APPEND_NAL(nals[i].data, nals[i].len);
        if (pbuf == NULL) {
            break;
        }
    }
    if (havePic && pbuf != NULL && pbufLen > 0 && res->frames < maxFrames) {
        VaSubmitPicture(va, dpy, context, surface, pbuf, pbufLen, width, height, res, &last);
    }
#undef VA_APPEND_NAL
    free(pbuf);

    res->wallMs = NowWallMs() - t0;
    res->cpuMs = NowCpuMs() - cpu0;
    if (res->minFrameMs > 1e8) {
        res->minFrameMs = 0;
    }

    va->DestroyContext(dpy, context);
    va->DestroySurfaces(dpy, &surface, 1);
    va->DestroyConfig(dpy, configId);
    free(psData);
    return (res->frames > 0) ? 0 : -1;
}

/* --------------------------------------------------------------- oneVPL path */

typedef struct {
    int frames;
    mfxU32 width;
    mfxU32 height;
    mfxU32 fourcc;
    double wallMs;
    double cpuMs;
    double minFrameMs;
    double maxFrameMs;
} VplResult;

/* Move the not-yet-consumed bitstream to the front of the buffer and append
 * more data from the file.  This is the canonical oneVPL feeding pattern
 * (see the official oneVPL decode sample). */
static int VplFeedMore(mfxBitstream *bs, FILE *f)
{
    if (bs->DataOffset > 0) {
        mfxU32 remaining = (bs->DataLength > bs->DataOffset) ? (bs->DataLength - bs->DataOffset) : 0;
        if (remaining > 0) {
            memmove(bs->Data, bs->Data + bs->DataOffset, remaining);
        }
        bs->DataLength = remaining;
        bs->DataOffset = 0;
    }
    if (bs->DataLength >= bs->MaxLength) {
        return 0;
    }
    size_t n = fread(bs->Data + bs->DataLength, 1, bs->MaxLength - bs->DataLength, f);
    bs->DataLength += (mfxU32)n;
    return (int)n;
}

static int VplDecode(mfxLoader loader, mfxU32 codec, const char *streamPath, int maxFrames,
                      VplResult *res, mfxU32 *implDescOut)
{
    memset(res, 0, sizeof(*res));
    res->minFrameMs = 1e9;

    mfxSession session = NULL;
    mfxStatus sts = MFXCreateSession(loader, 0, &session);
    if (sts != MFX_ERR_NONE || session == NULL) {
        Plog("HWDEC: vpl MFXCreateSession failed sts=%d", (int)sts);
        return -1;
    }

    FILE *f = fopen(streamPath, "rb");
    if (f == NULL) {
        Plog("HWDEC: vpl cannot reopen stream: %s", strerror(errno));
        MFXVideoDECODE_Close(session);
        MFXClose(session);
        return -1;
    }

    mfxBitstream bs;
    memset(&bs, 0, sizeof(bs));
    bs.MaxLength = VPL_BUFFER_SIZE;
    bs.Data = (mfxU8 *)calloc(bs.MaxLength, 1);
    if (bs.Data == NULL) {
        fclose(f);
        MFXVideoDECODE_Close(session);
        MFXClose(session);
        return -1;
    }
    bs.CodecId = codec;

    mfxVideoParam decParam;
    memset(&decParam, 0, sizeof(decParam));
    decParam.mfx.CodecId = codec;
    decParam.mfx.FrameInfo.FrameRateExtN = 30;
    decParam.mfx.FrameInfo.FrameRateExtD = 1;
    decParam.mfx.NumThread = 0;
    decParam.IOPattern = MFX_IOPATTERN_OUT_SYSTEM_MEMORY;

    /* the bitstream MUST carry a valid DataLength, otherwise oneVPL sees an
     * empty stream and DecodeHeader fails with MFX_ERR_INVAL (-10) */
    VplFeedMore(&bs, f);
    Plog("HWDEC: vpl bitstream prepared: DataLength=%u MaxLength=%u codec_id=%u", (unsigned)bs.DataLength,
         (unsigned)bs.MaxLength, (unsigned)bs.CodecId);
    Plog("HWDEC: vpl params: CodecId=%u FrameRate=%u/%u NumThread=%d IOPattern=0x%x",
         (unsigned)decParam.mfx.CodecId, (unsigned)decParam.mfx.FrameInfo.FrameRateExtN,
         (unsigned)decParam.mfx.FrameInfo.FrameRateExtD, (int)decParam.mfx.NumThread,
         (unsigned)decParam.IOPattern);

    sts = MFXVideoDECODE_DecodeHeader(session, &bs, &decParam);
    if (sts != MFX_ERR_NONE) {
        /* retry with a minimal parameter set (some runtimes dislike FrameRate) */
        Plog("HWDEC: vpl DecodeHeader sts=%d, retrying with minimal params", (int)sts);
        memset(&decParam, 0, sizeof(decParam));
        decParam.mfx.CodecId = codec;
        decParam.IOPattern = MFX_IOPATTERN_OUT_SYSTEM_MEMORY;
        bs.DataOffset = 0;
        VplFeedMore(&bs, f);
        sts = MFXVideoDECODE_DecodeHeader(session, &bs, &decParam);
    }
    if (sts != MFX_ERR_NONE) {
        Plog("HWDEC: vpl FAIL DecodeHeader sts=%d (MFX_ERR_MORE_DATA=%d "
             "MFX_ERR_INVALID_VIDEO_PARAM=%d MFX_ERR_UNSUPPORTED=%d)",
             (int)sts, (int)MFX_ERR_MORE_DATA, (int)MFX_ERR_INVALID_VIDEO_PARAM,
             (int)MFX_ERR_UNSUPPORTED);
        Plog("HWDEC: vpl header detail: DataLength=%u CodecId=%u FrameRate=%u/%u", (unsigned)bs.DataLength,
             (unsigned)decParam.mfx.CodecId, (unsigned)decParam.mfx.FrameInfo.FrameRateExtN,
             (unsigned)decParam.mfx.FrameInfo.FrameRateExtD);
        free(bs.Data);
        fclose(f);
        MFXVideoDECODE_Close(session);
        MFXClose(session);
        return -1;
    }
    res->width = decParam.mfx.FrameInfo.Width;
    res->height = decParam.mfx.FrameInfo.Height;
    res->fourcc = decParam.mfx.FrameInfo.FourCC;
    Plog("HWDEC: vpl header w=%u h=%u fourcc=%s profile=%u level=%u", res->width, res->height,
         FourccName(res->fourcc), (unsigned)decParam.mfx.CodecProfile, (unsigned)decParam.mfx.CodecLevel);

    sts = MFXVideoDECODE_Init(session, &decParam);
    if (sts != MFX_ERR_NONE) {
        Plog("HWDEC: vpl FAIL DecodeInit sts=%d", (int)sts);
        free(bs.Data);
        fclose(f);
        MFXVideoDECODE_Close(session);
        MFXClose(session);
        return -1;
    }

    double t0 = NowWallMs();
    double cpu0 = NowCpuMs();
    double last = t0;
    int eof = 0;
    while (res->frames < maxFrames) {
        if (!eof && (bs.DataLength - bs.DataOffset) < 64 * 1024) {
            if (VplFeedMore(&bs, f) == 0) {
                eof = 1;
            }
        }
        mfxFrameSurface1 *outSurface = NULL;
        mfxSyncPoint sync;
        memset(&sync, 0, sizeof(sync));
        sts = MFXVideoDECODE_DecodeFrameAsync(session, &bs, NULL, &outSurface, &sync);
        if (sts == MFX_ERR_NONE && outSurface != NULL) {
            if (outSurface->FrameInterface != NULL) {
                mfxStatus s3 = outSurface->FrameInterface->Synchronize(outSurface, 1000000);
                while (s3 == MFX_WRN_IN_EXECUTION) {
                    usleep(2000);
                    s3 = outSurface->FrameInterface->Synchronize(outSurface, 1000000);
                }
                if (s3 == MFX_ERR_NONE) {
                    res->frames++;
                    res->width = outSurface->Info.Width;
                    res->height = outSurface->Info.Height;
                    res->fourcc = outSurface->Info.FourCC;
                    double now = NowWallMs();
                    double dt = now - last;
                    last = now;
                    if (dt < res->minFrameMs) {
                        res->minFrameMs = dt;
                    }
                    if (dt > res->maxFrameMs) {
                        res->maxFrameMs = dt;
                    }
                    if (res->frames <= 3 || (res->frames % 30) == 0) {
                        Plog("HWDEC: vpl frame %d decoded %ux%u fourcc=%s in %.2f ms", res->frames,
                             res->width, res->height, FourccName(res->fourcc), dt);
                    }
                }
                outSurface->FrameInterface->Release(outSurface);
            } else {
                res->frames++;
            }
            continue;
        }
        if (sts == MFX_ERR_MORE_DATA) {
            if (eof) {
                break;
            }
            if (VplFeedMore(&bs, f) == 0) {
                eof = 1;
            }
            continue;
        }
        if (sts == MFX_ERR_MORE_SURFACE) {
            continue;
        }
        if (sts == MFX_WRN_VIDEO_PARAM_CHANGED) {
            Plog("HWDEC: vpl video param changed");
            continue;
        }
        Plog("HWDEC: vpl decode stopped sts=%d after %d frames", (int)sts, res->frames);
        break;
    }
    res->wallMs = NowWallMs() - t0;
    res->cpuMs = NowCpuMs() - cpu0;
    if (res->minFrameMs > 1e8) {
        res->minFrameMs = 0;
    }
    free(bs.Data);
    fclose(f);
    MFXVideoDECODE_Close(session);
    MFXClose(session);
    (void)implDescOut;
    return (res->frames > 0) ? 0 : -1;
}

/* ------------------------------------------------------------------- system */

static void DumpDriDir(void)
{
    DIR *d = opendir("/dev/dri");
    if (d == NULL) {
        Plog("HWDEC: diag /dev/dri not accessible: %s", strerror(errno));
        return;
    }
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.') {
            continue;
        }
        char path[256];
        snprintf(path, sizeof(path), "/dev/dri/%s", e->d_name);
        struct stat st;
        if (stat(path, &st) == 0) {
            Plog("HWDEC: diag /dev/dri/%s mode=0%o type=%s", e->d_name, (unsigned)st.st_mode,
                 S_ISCHR(st.st_mode) ? "chr" : "other");
        }
    }
    closedir(d);
}

static void DumpEnv(void)
{
    static const char *names[] = {"LIBVA_DRIVERS_PATH", "LIBVA_DRIVER_NAME", "ONEVPL_SEARCH_PATH",
                                  "ONEVPL_PRIORITY_PATH", "MFX_VPL_LOG_LEVEL", "MFX_VPL_GPU_IMPL"};
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        const char *v = getenv(names[i]);
        Plog("HWDEC: diag env %s=%s", names[i], v != NULL ? v : "(unset)");
    }
    static const char *files[] = {"/vendor/lib64/dri/iHD_drv_video.so", "/vendor/lib64/libva.so.2",
                                  "/vendor/lib64/libvpl.so.2", "/vendor/lib64/libmfx-gen.so.1.2"};
    for (size_t i = 0; i < sizeof(files) / sizeof(files[0]); i++) {
        struct stat st;
        if (stat(files[i], &st) == 0) {
            Plog("HWDEC: diag file %s present size=%lld", files[i], (long long)st.st_size);
        } else {
            Plog("HWDEC: diag file %s MISSING (%s)", files[i], strerror(errno));
        }
    }
}

/* --------------------------------------------------------------------- main */

int main(int argc, char **argv)
{
    const char *streamPath = (argc > 1) ? argv[1] : DEFAULT_STREAM;
    const char *logPath = (argc > 2) ? argv[2] : DEFAULT_LOG;
    int maxFrames = (argc > 3) ? atoi(argv[3]) : DEFAULT_MAX_FRAMES;
    const char *codecArg = (argc > 4) ? argv[4] : "auto";
    const char *modeArg = (argc > 5) ? argv[5] : "auto";

    OpenLogFile(logPath);

    Plog("HWDEC: start probe stream=%s log=%s max_frames=%d codec=%s mode=%s", streamPath,
         g_logFile != NULL ? "opened" : "none", maxFrames, codecArg, modeArg);
    Plog("HWDEC: uid=%d gid=%d pid=%d", (int)getuid(), (int)getgid(), (int)getpid());

    /* Make sure the VA stack can find the Intel media driver.  The libva that
     * is shipped in the image is built with
     *   -Ddriverdir=/vendor/lib64/dri
     * so this is only a belt-and-braces measure (and the fallback for the
     * case that an older libva with the build-time host path is used). */
    if (getenv("LIBVA_DRIVERS_PATH") == NULL) {
        /* only override when the device directory really exists, otherwise we
         * would break a correct host / system wide setting */
        if (access("/vendor/lib64/dri", F_OK) == 0) {
            setenv("LIBVA_DRIVERS_PATH", "/vendor/lib64/dri:/system/lib64/dri", 1);
        } else {
            Plog("HWDEC: diag /vendor/lib64/dri missing, keeping the inherited LIBVA_DRIVERS_PATH");
        }
    }
    if (getenv("LIBVA_DRIVER_NAME") == NULL) {
        if (access("/vendor/lib64/dri/iHD_drv_video.so", F_OK) == 0) {
            setenv("LIBVA_DRIVER_NAME", "iHD", 1);
        }
    }
    if (getenv("ONEVPL_SEARCH_PATH") == NULL) {
        setenv("ONEVPL_SEARCH_PATH", "/system/lib64:/vendor/lib64", 1);
    }
    if (getenv("ONEVPL_PRIORITY_PATH") == NULL) {
        setenv("ONEVPL_PRIORITY_PATH", "/vendor/lib64:/system/lib64", 1);
    }
    setenv("MFX_VPL_LOG_LEVEL", "1", 0);
    DumpEnv();
    DumpDriDir();

    /* --- load the elementary stream --- */
    FILE *fp = fopen(streamPath, "rb");
    if (fp == NULL) {
        Plog("HWDEC: FAIL cannot open stream '%s': %s", streamPath, strerror(errno));
        Plog("HWDEC: RESULT=FAIL reason=no_stream");
        return 0;
    }
    fseek(fp, 0, SEEK_END);
    long fsize = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    if (fsize <= 0) {
        Plog("HWDEC: FAIL empty stream '%s'", streamPath);
        fclose(fp);
        Plog("HWDEC: RESULT=FAIL reason=empty_stream");
        return 0;
    }
    uint8_t *buf = (uint8_t *)malloc((size_t)fsize);
    if (buf == NULL || fread(buf, 1, (size_t)fsize, fp) != (size_t)fsize) {
        Plog("HWDEC: FAIL cannot read stream (%ld bytes)", fsize);
        free(buf);
        fclose(fp);
        Plog("HWDEC: RESULT=FAIL reason=read_error");
        return 0;
    }
    fclose(fp);
    Plog("HWDEC: stream loaded bytes=%ld", fsize);

    Nal *nals = (Nal *)malloc(sizeof(Nal) * MAX_NALS);
    int nnals = 0;
    if (nals != NULL) {
        nnals = ScanAnnexB(buf, (size_t)fsize, nals, MAX_NALS);
    }
    Plog("HWDEC: annex-B NALs parsed=%d", nnals);

    mfxU32 codec = MFX_CODEC_AVC;
    if (strcasecmp(codecArg, "hevc") == 0 || strcasecmp(codecArg, "h265") == 0) {
        codec = MFX_CODEC_HEVC;
    } else if (strcasecmp(codecArg, "avc") == 0 || strcasecmp(codecArg, "h264") == 0) {
        codec = MFX_CODEC_AVC;
    } else {
        /* sniff: HEVC VPS/SPS/PPS are NAL types 32/33/34 */
        codec = MFX_CODEC_AVC;
        for (int i = 0; i < nnals && i < 16; i++) {
            uint8_t t = (uint8_t)(nals[i].data[0] & 0x1F);
            if (t == 32 || t == 33 || t == 34) {
                codec = MFX_CODEC_HEVC;
                break;
            }
        }
    }
    int isHevc = (codec == MFX_CODEC_HEVC);
    Plog("HWDEC: codec=%s", CodecName(codec));

    /* picture size from the SPS (needed by the VA-API path) */
    int spsW = 0, spsH = 0;
    if (!isHevc && nals != NULL) {
        for (int i = 0; i < nnals; i++) {
            uint8_t t = (uint8_t)(nals[i].data[0] & 0x1F);
            if (t == 7) {
                if (ParseAvcSps(nals[i].data, nals[i].len, &spsW, &spsH) == 0) {
                    Plog("HWDEC: SPS parsed: %dx%d", spsW, spsH);
                }
                break;
            }
        }
    }
    if (spsW <= 0 || spsH <= 0) {
        Plog("HWDEC: WARN no usable SPS size (w=%d h=%d)", spsW, spsH);
    }

    int doVpl = (strcasecmp(modeArg, "va") != 0);
    int doVa = (strcasecmp(modeArg, "vpl") != 0);

    VplResult vres;
    memset(&vres, 0, sizeof(vres));
    int vplOk = 0;

    /* ------------------------------------------------------------- oneVPL -- */
    if (doVpl) {
        mfxLoader loader = MFXLoad();
        if (loader == NULL) {
            Plog("HWDEC: vpl MFXLoad failed (no oneVPL runtime found)");
        } else {
            int implCount = 0;
            for (mfxU32 i = 0; i < 8; i++) {
                mfxImplDescription *d = NULL;
                if (MFXEnumImplementations(loader, i, MFX_IMPLCAPS_IMPLDESCSTRUCTURE, (mfxHDL *)&d) !=
                        MFX_ERR_NONE ||
                    d == NULL) {
                    break;
                }
                implCount++;
                Plog("HWDEC: vpl impl[%d] name=%s api=%u.%u accel_mode=0x%x impl=0x%x vendor=0x%x", (int)i,
                     d->ImplName, d->ApiVersion.Major, d->ApiVersion.Minor,
                     (unsigned)d->AccelerationMode, (unsigned)d->Impl, (unsigned)d->VendorID);
                MFXDispReleaseImplDescription(loader, (mfxHDL)d);
            }
            Plog("HWDEC: vpl implementations found=%d", implCount);
            if (implCount == 0) {
                static const char *cands[] = {"libmfx-gen.so.1.2", "/vendor/lib64/libmfx-gen.so.1.2.17",
                                             "/vendor/lib64/libmfx-gen.so.1.2"};
                for (size_t i = 0; i < sizeof(cands) / sizeof(cands[0]); i++) {
                    void *h = dlopen(cands[i], RTLD_NOW | RTLD_LOCAL);
                    if (h != NULL) {
                        Plog("HWDEC: diag dlopen(%s) OK", cands[i]);
                        dlclose(h);
                    } else {
                        Plog("HWDEC: diag dlopen(%s) FAILED: %s", cands[i], dlerror());
                    }
                }
            } else {
                mfxConfig cfg[3];
                mfxVariant cfgVal[3];
                mfxStatus sts = MFX_ERR_NONE;
                cfg[0] = MFXCreateConfig(loader);
                cfgVal[0].Type = MFX_VARIANT_TYPE_U32;
                cfgVal[0].Data.U32 = MFX_IMPL_TYPE_HARDWARE;
                sts = MFXSetConfigFilterProperty(cfg[0], (mfxU8 *)"mfxImplDescription.Impl", cfgVal[0]);
                cfg[1] = MFXCreateConfig(loader);
                cfgVal[1].Type = MFX_VARIANT_TYPE_U32;
                cfgVal[1].Data.U32 = codec;
                sts = MFXSetConfigFilterProperty(
                    cfg[1], (mfxU8 *)"mfxImplDescription.mfxDecoderDescription.decoder.CodecID",
                    cfgVal[1]);
                cfg[2] = MFXCreateConfig(loader);
                cfgVal[2].Type = MFX_VARIANT_TYPE_U32;
                cfgVal[2].Data.U32 = VPLVERSION(API_MAJOR_REQUIRED, API_MINOR_REQUIRED);
                sts = MFXSetConfigFilterProperty(
                    cfg[2], (mfxU8 *)"mfxImplDescription.ApiVersion.Version", cfgVal[2]);
                if (sts != MFX_ERR_NONE) {
                    Plog("HWDEC: vpl filter failed sts=%d", (int)sts);
                } else {
                    vplOk = (VplDecode(loader, codec, streamPath, maxFrames, &vres, NULL) == 0);
                }
            }
            MFXUnload(loader);
        }
    }

    /* -------------------------------------------------------------- VA-API -- */
    VaApi va;
    VaResult vares;
    memset(&vares, 0, sizeof(vares));
    int vaOk = 0;
    VADisplay dpy = NULL;
    int drmFd = -1;
    const char *drmNode = NULL;
    if (doVa) {
        if (VaLoad(&va) == 0) {
            int vaErr = 0;
            dpy = VaOpenDisplay(&va, &drmNode, &drmFd, &vaErr);
            if (dpy == NULL) {
                Plog("HWDEC: va no usable display (last rc=%d)", vaErr);
            } else if (spsW > 0 && spsH > 0 && nals != NULL) {
                vaOk = (VaDecode(&va, dpy, buf, (size_t)fsize, nals, nnals, isHevc, maxFrames, spsW,
                                 spsH, &vares) == 0);
            } else {
                Plog("HWDEC: va skip decode (no picture size)");
            }
        }
    }

    /* ------------------------------------------------------------- summary -- */
    double cpuRatio = 0.0;
    double fps = 0.0;
    if (vplOk) {
        Plog("HWDEC: vpl SUMMARY frames=%d format=%s %ux%u wall_ms=%.1f cpu_ms=%.1f fps=%.1f "
             "cpu_ratio=%.1f%% min_frame_ms=%.2f max_frame_ms=%.2f",
             vres.frames, FourccName(vres.fourcc), vres.width, vres.height, vres.wallMs, vres.cpuMs,
             vres.wallMs > 0 ? vres.frames * 1000.0 / vres.wallMs : 0.0,
             vres.wallMs > 0 ? vres.cpuMs * 100.0 / vres.wallMs : 0.0, vres.minFrameMs, vres.maxFrameMs);
    }
    if (dpy != NULL) {
        if (vaOk) {
            Plog("HWDEC: va SUMMARY frames=%d format=NV12 %ux%u wall_ms=%.1f cpu_ms=%.1f fps=%.1f "
                 "cpu_ratio=%.1f%% min_frame_ms=%.2f max_frame_ms=%.2f nonzero_pixels=%d/%d",
                 vares.frames, vares.width, vares.height, vares.wallMs, vares.cpuMs,
                 vares.wallMs > 0 ? vares.frames * 1000.0 / vares.wallMs : 0.0,
                 vares.wallMs > 0 ? vares.cpuMs * 100.0 / vares.wallMs : 0.0, vares.minFrameMs,
                 vares.maxFrameMs, vares.nonzeroPixels, vares.width * vares.height);
        }
        va.Terminate(dpy);
    }
    if (drmFd >= 0) {
        close(drmFd);
    }

    int totalFrames = (vplOk ? vres.frames : 0) + (vaOk ? vares.frames : 0);
    double totalWall = (vplOk ? vres.wallMs : 0.0) + (vaOk ? vares.wallMs : 0.0);
    double totalCpu = (vplOk ? vres.cpuMs : 0.0) + (vaOk ? vares.cpuMs : 0.0);
    if (totalWall > 0) {
        cpuRatio = totalCpu * 100.0 / totalWall;
        fps = totalFrames * 1000.0 / totalWall;
    }
    Plog("HWDEC: SUMMARY path=%s frames=%d wall_ms=%.1f cpu_ms=%.1f fps=%.1f cpu_ratio=%.1f%%",
         (vplOk && vaOk) ? "both" : (vplOk ? "onevpl" : (vaOk ? "vaapi" : "none")), totalFrames,
         totalWall, totalCpu, fps, cpuRatio);
    Plog("HWDEC: hilog_print_failures=%d", g_hilogFailures);

    if (totalFrames > 0) {
        Plog("HWDEC: RESULT=OK decoded_frames=%d cpu_ratio=%.1f%%", totalFrames, cpuRatio);
    } else {
        const char *reason = "no_frame_decoded";
        if (!doVpl && !doVa) {
            reason = "no_path_selected";
        } else if (dpy == NULL && vres.frames == 0) {
            reason = "no_va_display";
        }
        Plog("HWDEC: RESULT=FAIL reason=%s", reason);
    }

    free(buf);
    free(nals);
    if (g_logFile != NULL) {
        fclose(g_logFile);
        g_logFile = NULL;
    }
    return 0;
}
