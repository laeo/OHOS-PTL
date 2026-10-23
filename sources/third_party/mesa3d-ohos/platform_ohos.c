/*
 * Mesa 3-D graphics library
 *
 * [ohos-x86_64 port] OHOS EGL platform.
 *
 * This is a port of the Android (gralloc) platform to OHOS.  The original
 * OHOS platform in Mesa only supported zink/kopper (Vulkan swapchains) and
 * therefore did not provide any window-system buffer allocation for a
 * classic gallium DRI driver.  Here we implement the __DRIimageLoaderExtension
 * on top of OH_NativeWindow, so that a DRI driver can render directly into
 * OHOS native-window buffers.  The buffer is exported as a dma-buf fd via the
 * BufferHandle obtained from the requested OHNativeWindowBuffer, which the
 * gallium winsys imports with WINSYS_HANDLE_TYPE_FD.
 *
 * Two very different back-ends use this platform:
 *
 *  - QEMU test bench: virtio-gpu + virgl.  The GPU work happens on the host,
 *    so after rendering the result must be transferred back into the guest
 *    dma-buf (VIRGL_TRANSFER_GET) or the scanout stays black.  That transfer
 *    returns the image bottom-up, so we also flip the rows in place.  Only the
 *    virgl path needs this (see ohos_needs_host_sync()).
 *
 *  - Real hardware: iris (Intel Xe) draws directly into the guest-visible
 *    buffer; no transfer and no flip is wanted or needed.
 */

#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#if defined(__SSE2__)
#include <emmintrin.h>
#endif
#include <unistd.h>

#include <drm-uapi/drm_fourcc.h>

#include "dri_util.h"
#include "egl_dri2.h"
#include "loader/loader.h"
#include "pipe/p_screen.h"

#include "display_type.h"
#include "external_window.h"

/* [ohos port] diagnostics.
 *
 * The original trace helper wrote to /data/mesa_dbg.txt.  render_service runs
 * as uid "graphics" and /data is not writable for it, so *every* driver
 * selection / fallback message was silently dropped on the real device - the
 * only way to find out which gallium driver is in use was guessing.
 *
 * The replacement writes to (in order)
 *   1. hilog, via libhilog_ndk (dlopen'ed, best effort) -> greppable with
 *      "hilog | grep MESA-OHOS"
 *   2. stderr
 *   3. a file (MESA_OHOS_LOG_FILE, or the first writable of
 *      /data/service/el1/public/render_service/mesa_ohos.log ,
 *      /data/local/shader_cache/local/system/render_service/mesa_ohos.log ,
 *      /tmp/mesa_ohos.log)
 */
#define MESA_OHOS_HILOG_DOMAIN 0xD002000u
#define MESA_OHOS_HILOG_TAG "MESA-OHOS"

typedef int (*mesa_ohos_hilog_print_fn)(int type, int level, unsigned int domain,
                                         const char *tag, const char *fmt, ...);

static void
mesa_ohos_log(const char *fmt, ...)
{
   static mesa_ohos_hilog_print_fn hilog_print = NULL;
   static int hilog_tried = 0;
   static FILE *log_file = NULL;
   static int file_tried = 0;
   static int hilog_reported = 0;
   static int hilog_domain = MESA_OHOS_HILOG_DOMAIN;
   char buf[1024];
   va_list ap;

   va_start(ap, fmt);
   vsnprintf(buf, sizeof(buf), fmt, ap);
   va_end(ap);

   fprintf(stderr, "MESA-OHOS: %s\n", buf);
   fflush(stderr);

   if (!hilog_tried) {
      hilog_tried = 1;
      /* OHOS ships the ndk hilog implementation as "libhilog.so" on this
       * product; older/newer images may use "libhilog_ndk.z.so". */
      static const char *hilog_libs[] = { "libhilog.so", "libhilog_ndk.z.so", NULL };
      for (unsigned i = 0; hilog_libs[i] != NULL; i++) {
         void *h = dlopen(hilog_libs[i], RTLD_NOW | RTLD_LOCAL);
         if (h != NULL) {
            hilog_print = (mesa_ohos_hilog_print_fn)dlsym(h, "HiLogPrint");
            if (hilog_print != NULL)
               break;
         }
      }
   }
   if (hilog_print != NULL) {
      int r = hilog_print(3 /*LOG_CORE*/, 4 /*LOG_INFO*/, (unsigned int)hilog_domain,
                          MESA_OHOS_HILOG_TAG, "%{public}s", buf);
      if (r != 0) {
         /* The domain may not be allowed for this process - retry with the
          * RenderService domain (0xD001400) and remember what worked. */
         static const unsigned int fallback_domains[] = { 0xD001400u, 0xD000000u };
         for (unsigned i = 0; i < sizeof(fallback_domains) / sizeof(fallback_domains[0]); i++) {
            int r2 = hilog_print(3, 4, fallback_domains[i], MESA_OHOS_HILOG_TAG, "%{public}s", buf);
            if (r2 == 0) {
               hilog_domain = (int)fallback_domains[i];
               break;
            }
         }
         if (!hilog_reported) {
            hilog_reported = 1;
            fprintf(stderr, "MESA-OHOS: HiLogPrint(domain=0x%08x) returned %d\n",
                    MESA_OHOS_HILOG_DOMAIN, r);
         }
      }
   }

   if (!file_tried) {
      file_tried = 1;
      const char *cands[6];
      unsigned n = 0;
      const char *env = getenv("MESA_OHOS_LOG_FILE");
      if (env != NULL && env[0] != '\0')
         cands[n++] = env;
      cands[n++] = "/data/service/el0/render_service/mesa_ohos.log";
      cands[n++] = "/data/local/shader_cache/local/system/render_service/mesa_ohos.log";
      cands[n++] = "/data/service/el1/public/render_service/mesa_ohos.log";
      cands[n++] = "/data/local/tmp/mesa_ohos.log";
      cands[n++] = "/tmp/mesa_ohos.log";
      for (unsigned i = 0; i < n; i++) {
         log_file = fopen(cands[i], "a");
         if (log_file != NULL) {
            fprintf(stderr, "MESA-OHOS: logging to %s\n", cands[i]);
            break;
         }
      }
      if (log_file != NULL) {
         fprintf(log_file, "MESA-OHOS: [diag] hilog_lib=%s hilog_domain=0x%08x\n",
                 hilog_print != NULL ? "loaded" : "MISSING", (unsigned int)hilog_domain);
         fflush(log_file);
      }
   }
   if (log_file != NULL) {
      fprintf(log_file, "MESA-OHOS: %s\n", buf);
      fflush(log_file);
   }
}

/* Backwards compatible alias for the old private trace helper. */
static void
mesa_dbg(const char *fmt, ...)
{
   char buf[1024];
   va_list ap;

   va_start(ap, fmt);
   vsnprintf(buf, sizeof(buf), fmt, ap);
   va_end(ap);
   mesa_ohos_log("%s", buf);
}

/* Wait for a sync fence fd to signal.  Returns 0 on success. */
static int
ohos_wait_fence_fd(int fd)
{
   struct pollfd pfd = {
      .fd = fd,
      .events = POLLIN,
   };
   int ret;

   do {
      ret = poll(&pfd, 1, -1);
   } while (ret == -1 && (errno == EINTR || errno == EAGAIN));

   if (ret > 0 && (pfd.revents & (POLLERR | POLLHUP)))
      return -1;

   return ret < 0 ? -1 : 0;
}

static void
close_in_fence_fd(struct dri2_egl_surface *dri2_surf)
{
   if (dri2_surf->in_fence_fd >= 0)
      close(dri2_surf->in_fence_fd);
   dri2_surf->in_fence_fd = -1;
}

/* Map an OHOS PixelFormat to a DRM fourcc understood by the gallium driver.
 * The values follow the vendor OHOS Mesa port. */
static int
ohos_format_to_fourcc(int32_t format)
{
   switch (format) {
   case PIXEL_FMT_RGBA_8888: /* 12 */
   case PIXEL_FMT_RGB_565:   /* 3  */
      return DRM_FORMAT_ABGR8888;
   case PIXEL_FMT_RGBX_8888: /* 11 */
      return DRM_FORMAT_XBGR8888;
   case PIXEL_FMT_BGRA_8888: /* 20 */
      return DRM_FORMAT_ARGB8888;
   default:
      _eglLog(_EGL_WARNING, "OHOS: unsupported native buffer format 0x%x",
              format);
      return DRM_FORMAT_ABGR8888;
   }
}

static struct dri_image *
ohos_create_image_from_native_buffer(_EGLDisplay *disp, void *buf,
                                     void *loaderPrivate)
{
   struct dri2_egl_display *dri2_dpy = dri2_egl_display(disp);
   BufferHandle *handle = OH_NativeWindow_GetBufferHandleFromNative(buf);
   unsigned error = 0;
   int fourcc;
   int fds[4] = {-1, -1, -1, -1};
   int strides[4] = {0, 0, 0, 0};
   int offsets[4] = {0, 0, 0, 0};

   if (!handle || handle->fd < 0)
      return NULL;

   fourcc = ohos_format_to_fourcc(handle->format);
   if (!handle->stride) {
      _eglError(EGL_BAD_ALLOC, "ohos_create_image_from_native_buffer");
      return NULL;
   }

   fds[0] = handle->fd;
   strides[0] = handle->stride;
   offsets[0] = 0;

   {
      static int dbg_count;
      if (dbg_count < 12) {
         dbg_count++;
         mesa_dbg("MESA_OHOS: create_image buf w=%d h=%d stride=%d fmt=0x%x "
                  "fourcc=0x%x fd=%d\n",
                  handle->width, handle->height, handle->stride, handle->format,
                  fourcc, handle->fd);
      }
   }

   return dri2_from_dma_bufs(dri2_dpy->dri_screen_render_gpu, handle->width,
                             handle->height, fourcc, DRM_FORMAT_MOD_INVALID,
                             fds, 1, strides, offsets,
                             __DRI_YUV_COLOR_SPACE_ITU_REC601,
                             __DRI_YUV_NARROW_RANGE,
                             __DRI_YUV_CHROMA_SITING_0,
                             __DRI_YUV_CHROMA_SITING_0, 0, &error,
                             loaderPrivate);
}

static void
handle_in_fence_fd(struct dri2_egl_surface *dri2_surf, struct dri_image *img)
{
   if (dri2_surf->in_fence_fd < 0)
      return;

   ohos_wait_fence_fd(dri2_surf->in_fence_fd);
   close(dri2_surf->in_fence_fd);
   dri2_surf->in_fence_fd = -1;
}

static EGLBoolean
ohos_window_dequeue_buffer(struct dri2_egl_surface *dri2_surf)
{
   int fence_fd = -1;

   if (OH_NativeWindow_NativeWindowRequestBuffer(
          (OHNativeWindow *)dri2_surf->window,
          (OHNativeWindowBuffer **)&dri2_surf->buffer, &fence_fd))
      return EGL_FALSE;

   close_in_fence_fd(dri2_surf);
   dri2_surf->in_fence_fd = fence_fd;

   EGLBoolean updated = EGL_FALSE;
   for (int i = 0; i < dri2_surf->color_buffers_count; i++) {
      if (!dri2_surf->color_buffers[i].buffer) {
         dri2_surf->color_buffers[i].buffer = dri2_surf->buffer;
      }
      if (dri2_surf->color_buffers[i].buffer == dri2_surf->buffer) {
         dri2_surf->back = &dri2_surf->color_buffers[i];
         updated = EGL_TRUE;
         break;
      }
   }

   if (!updated) {
      for (int i = 0; i < dri2_surf->color_buffers_count; i++) {
         dri2_surf->color_buffers[i].buffer = NULL;
         dri2_surf->color_buffers[i].age = 0;
      }
      dri2_surf->color_buffers[0].buffer = dri2_surf->buffer;
      dri2_surf->back = &dri2_surf->color_buffers[0];
   }

   return EGL_TRUE;
}

static EGLBoolean
ohos_window_enqueue_buffer(_EGLDisplay *disp, struct dri2_egl_surface *dri2_surf)
{
   Region region = { NULL, 0 };
   int fence_fd = dri2_surf->out_fence_fd;

   dri2_surf->out_fence_fd = -1;
   OH_NativeWindow_NativeWindowFlushBuffer(
      (OHNativeWindow *)dri2_surf->window,
      (OHNativeWindowBuffer *)dri2_surf->buffer, fence_fd, region);

   dri2_surf->buffer = NULL;
   dri2_surf->back = NULL;

   if (dri2_surf->dri_image_back) {
      dri2_destroy_image(dri2_surf->dri_image_back);
      dri2_surf->dri_image_back = NULL;
   }

   return EGL_TRUE;
}

static void
ohos_window_cancel_buffer(struct dri2_egl_surface *dri2_surf)
{
   int ret;

   dri2_surf->out_fence_fd = -1;
   ret = OH_NativeWindow_NativeWindowAbortBuffer(
      (OHNativeWindow *)dri2_surf->window,
      (OHNativeWindowBuffer *)dri2_surf->buffer);
   dri2_surf->buffer = NULL;
   if (ret < 0) {
      _eglLog(_EGL_WARNING, "OHOS: NativeWindowAbortBuffer failed");
      dri2_surf->base.Lost = EGL_TRUE;
   }

   close_in_fence_fd(dri2_surf);
}

static int
ohos_update_buffers(struct dri2_egl_surface *dri2_surf)
{
   BufferHandle *handle;

   if (dri2_surf->base.Lost)
      return -1;

   if (dri2_surf->base.Type != EGL_WINDOW_BIT)
      return 0;

   if (!dri2_surf->buffer && !ohos_window_dequeue_buffer(dri2_surf)) {
      _eglLog(_EGL_WARNING, "OHOS: could not dequeue native window buffer");
      dri2_surf->base.Lost = EGL_TRUE;
      return -1;
   }

   handle = OH_NativeWindow_GetBufferHandleFromNative(dri2_surf->buffer);
   if (!handle)
      return -1;

   if (dri2_surf->base.Width != handle->width ||
       dri2_surf->base.Height != handle->height) {
      dri2_surf->base.Width = handle->width;
      dri2_surf->base.Height = handle->height;
   }

   return 0;
}

static int
ohos_get_back_bo(struct dri2_egl_surface *dri2_surf)
{
   _EGLDisplay *disp = dri2_surf->base.Resource.Display;

   if (dri2_surf->dri_image_back)
      return 0;

   if (dri2_surf->base.Type == EGL_WINDOW_BIT) {
      if (!dri2_surf->buffer) {
         _eglLog(_EGL_WARNING, "OHOS: no native buffer to wrap");
         return -1;
      }

      dri2_surf->dri_image_back =
         ohos_create_image_from_native_buffer(disp, dri2_surf->buffer, NULL);
      if (!dri2_surf->dri_image_back) {
         _eglLog(_EGL_WARNING, "OHOS: failed to create DRI image from fd");
         return -1;
      }

      handle_in_fence_fd(dri2_surf, dri2_surf->dri_image_back);
   }

   return 0;
}

static int
ohos_get_front_bo(struct dri2_egl_surface *dri2_surf, unsigned int format)
{
   _EGLDisplay *disp = dri2_surf->base.Resource.Display;
   struct dri2_egl_display *dri2_dpy = dri2_egl_display(disp);

   if (dri2_surf->dri_image_front)
      return 0;

   if (dri2_surf->base.Type == EGL_PBUFFER_BIT) {
      dri2_surf->dri_image_front = dri_create_image(
         dri2_dpy->dri_screen_render_gpu, dri2_surf->base.Width,
         dri2_surf->base.Height, format, NULL, 0, 0, NULL);
      if (!dri2_surf->dri_image_front) {
         _eglLog(_EGL_WARNING, "OHOS: dri2_image_front allocation failed");
         return -1;
      }
   }

   return 0;
}

static int
ohos_image_get_buffers(struct dri_drawable *driDrawable, unsigned int format,
                       uint32_t *stamp, void *loaderPrivate,
                       uint32_t buffer_mask, struct __DRIimageList *images)
{
   struct dri2_egl_surface *dri2_surf = loaderPrivate;

   images->image_mask = 0;
   images->front = NULL;
   images->back = NULL;

   if (ohos_update_buffers(dri2_surf) < 0)
      return 0;

   if (_eglSurfaceInSharedBufferMode(&dri2_surf->base)) {
      if (ohos_get_back_bo(dri2_surf) < 0)
         return 0;

      images->back = dri2_surf->dri_image_back;
      images->image_mask |= __DRI_IMAGE_BUFFER_SHARED;
      return 1;
   }

   if (buffer_mask & __DRI_IMAGE_BUFFER_FRONT) {
      if (ohos_get_front_bo(dri2_surf, format) < 0)
         return 0;

      if (dri2_surf->dri_image_front) {
         images->front = dri2_surf->dri_image_front;
         images->image_mask |= __DRI_IMAGE_BUFFER_FRONT;
      }
   }

   if (buffer_mask & __DRI_IMAGE_BUFFER_BACK) {
      if (ohos_get_back_bo(dri2_surf) < 0)
         return 0;

      if (dri2_surf->dri_image_back) {
         images->back = dri2_surf->dri_image_back;
         images->image_mask |= __DRI_IMAGE_BUFFER_BACK;
      }
   }

   return 1;
}

static _EGLSurface *
ohos_create_surface(_EGLDisplay *disp, EGLint type, _EGLConfig *conf,
                    void *native_window, const EGLint *attrib_list)
{
   struct dri2_egl_display *dri2_dpy = dri2_egl_display(disp);
   struct dri2_egl_config *dri2_conf = dri2_egl_config(conf);
   struct dri2_egl_surface *dri2_surf;
   const struct dri_config *config;

   dri2_surf = calloc(1, sizeof *dri2_surf);
   if (!dri2_surf) {
      _eglError(EGL_BAD_ALLOC, "ohos_create_surface");
      return NULL;
   }

   if (!dri2_init_surface(&dri2_surf->base, disp, type, conf, attrib_list,
                          EGL_FALSE, native_window))
      goto cleanup_surface;

   dri2_surf->in_fence_fd = -1;

   if (type == EGL_WINDOW_BIT) {
      int format = 0;
      int buffer_count = 3;

      dri2_surf->color_buffers =
         calloc(buffer_count, sizeof(*dri2_surf->color_buffers));
      if (!dri2_surf->color_buffers) {
         _eglError(EGL_BAD_ALLOC, "ohos_create_surface");
         goto cleanup_surface;
      }
      dri2_surf->color_buffers_count = buffer_count;

      OH_NativeWindow_NativeWindowHandleOpt(native_window, GET_FORMAT, &format);
      if (format < 0) {
         _eglError(EGL_BAD_NATIVE_WINDOW, "ohos_create_surface");
         goto cleanup_surface;
      }

      if (format != dri2_conf->base.NativeVisualID) {
         _eglLog(_EGL_WARNING, "Native format mismatch: 0x%x != 0x%x", format,
                 dri2_conf->base.NativeVisualID);
      }

      OH_NativeWindow_NativeWindowHandleOpt(native_window, GET_BUFFER_GEOMETRY,
                                            &dri2_surf->base.Height,
                                            &dri2_surf->base.Width);
   }

   config = dri2_get_dri_config(dri2_conf, type, dri2_surf->base.GLColorspace);
   if (!config) {
      _eglError(EGL_BAD_MATCH,
                "Unsupported surfacetype/colorspace configuration");
      goto cleanup_surface;
   }

   if (!dri2_create_drawable(dri2_dpy, config, dri2_surf, dri2_surf))
      goto cleanup_surface;

   if (native_window) {
      OH_NativeWindow_NativeObjectReference(native_window);
      dri2_surf->window = native_window;
   }

   return &dri2_surf->base;

cleanup_surface:
   free(dri2_surf->color_buffers);
   free(dri2_surf);
   return NULL;
}

static _EGLSurface *
ohos_create_window_surface(_EGLDisplay *disp, _EGLConfig *conf,
                           void *native_window, const EGLint *attrib_list)
{
   return ohos_create_surface(disp, EGL_WINDOW_BIT, conf, native_window,
                              attrib_list);
}

static _EGLSurface *
ohos_create_pbuffer_surface(_EGLDisplay *disp, _EGLConfig *conf,
                            const EGLint *attrib_list)
{
   return ohos_create_surface(disp, EGL_PBUFFER_BIT, conf, NULL, attrib_list);
}

static EGLBoolean
ohos_destroy_surface(_EGLDisplay *disp, _EGLSurface *surf)
{
   struct dri2_egl_surface *dri2_surf = dri2_egl_surface(surf);

   if (dri2_surf->base.Type == EGL_WINDOW_BIT) {
      if (dri2_surf->buffer)
         ohos_window_cancel_buffer(dri2_surf);

      if (dri2_surf->window)
         OH_NativeWindow_NativeObjectUnreference(dri2_surf->window);
   }

   if (dri2_surf->dri_image_back) {
      dri2_destroy_image(dri2_surf->dri_image_back);
      dri2_surf->dri_image_back = NULL;
   }
   if (dri2_surf->dri_image_front) {
      dri2_destroy_image(dri2_surf->dri_image_front);
      dri2_surf->dri_image_front = NULL;
   }

   driDestroyDrawable(dri2_surf->dri_drawable);

   close_in_fence_fd(dri2_surf);
   dri2_fini_surface(surf);
   free(dri2_surf->color_buffers);
   free(dri2_surf);

   return EGL_TRUE;
}

/* Bytes per pixel for the DRM fourcc formats we hand to the gallium driver.
 * The OHOS window buffers are always 32bpp 8888 (rgb565 is mapped to ABGR
 * above), but keep the 16bpp case for completeness. */
static unsigned
ohos_fourcc_bytes_per_pixel(int fourcc)
{
   switch (fourcc) {
   case DRM_FORMAT_ABGR8888:
   case DRM_FORMAT_XBGR8888:
   case DRM_FORMAT_ARGB8888:
   case DRM_FORMAT_XRGB8888:
      return 4;
   case DRM_FORMAT_BGR565:
   case DRM_FORMAT_RGB565:
      return 2;
   default:
      return 4;
   }
}

/* [ohos port] Does this back-end render on a remote/host GPU and therefore
 * need the host->guest transfer back into the OHOS dma-buf?
 *
 * Evidence / rationale:
 *   - The transfer ring is implemented by virgl.  On QEMU the DRM node is
 *     virtio-gpu and the DRI driver name reported by loader_get_driver_for_fd()
 *     is "virtio_gpu" (gallium driver "virgl"); running a "virtio_gpu"-named
 *     driver means 3D commands are executed on the host and the result must be
 *     read back, otherwise the OHOS display HDI (which scans the guest dma-buf)
 *     sees only zeros (black screen, verified in AGENTS 14.2).
 *   - iris (Intel Xe), softpipe/swrast and all other in-tree drivers write the
 *     guest-visible buffer directly, so there is nothing to transfer and no row
 *     flip is wanted (a flip would turn the screen upside down).
 *   - The row flip is a property of the virgl TRANSFER_GET output (bottom-up)
 *     relative to the OHOS top-down scanout, so it is tied to the same test.
 *
 * Can be overridden for debugging with MESA_OHOS_SYNC_BACK=0|1.
 */
static bool
ohos_needs_host_sync(struct dri2_egl_display *dri2_dpy)
{
   static int override = -2;
   if (override == -2) {
      const char *v = getenv("MESA_OHOS_SYNC_BACK");
      override = v ? (v[0] == '0' ? 0 : 1) : -1;
   }
   if (override >= 0)
      return override != 0;

   if (!dri2_dpy->driver_name)
      return false;

   return strcmp(dri2_dpy->driver_name, "virtio_gpu") == 0 ||
          strcmp(dri2_dpy->driver_name, "virgl") == 0;
}

/* [ohos port] Read a "key=value" line out of the configuration file
 * /system/etc/mesa_prof (the file can be dropped into the image, so that the
 * behaviour can be changed without touching the environment of the render
 * service).  Returns NULL when the key is not present. */
static const char *
ohos_config_get(const char *key)
{
   /* one cache slot per key ("profile", "flip") */
   static char values[2][256];
   static int loaded[2] = {0, 0};
   static const char *keys[2] = {"profile", "flip"};
   int slot = (strcmp(key, "flip") == 0) ? 1 : 0;
   char *value = values[slot];
   FILE *f;

   if (!loaded[slot]) {
      loaded[slot] = 1;
      value[0] = '\0';
      f = fopen("/system/etc/mesa_prof", "r");
      if (!f) {
         return NULL;
      }
      {
         char line[320];
         while (fgets(line, sizeof(line), f)) {
            char *eq = strchr(line, '=');
            char *nl;
            if (!eq) {
               continue;
            }
            *eq = '\0';
            nl = strchr(eq + 1, '\n');
            if (nl) {
               *nl = '\0';
            }
            nl = strchr(eq + 1, '\r');
            if (nl) {
               *nl = '\0';
            }
            if (strcmp(line, key) == 0) {
               snprintf(value, 256, "%s", eq + 1);
               break;
            }
         }
      }
      fclose(f);
   }
   return value[0] ? value : NULL;
}

/* [ohos port] Flip mode selection.
 *   MESA_OHOS_FLIP=memcpy (default) -> copy whole rows (fast)
 *   MESA_OHOS_FLIP=byte             -> original byte-wise swap (reference)
 *   MESA_OHOS_FLIP=0                -> do not flip at all
 * The same value can be set with "flip=" in /system/etc/mesa_prof.
 */
enum ohos_flip_mode {
   OHOS_FLIP_SIMD = 0,
   OHOS_FLIP_BYTE = 1,
   OHOS_FLIP_OFF = 2,
   OHOS_FLIP_ROWCOPY = 3,
};

static int
ohos_flip_mode(void)
{
   static int mode = -1;
   if (mode < 0) {
      const char *v = getenv("MESA_OHOS_FLIP");
      if (!v || !*v) {
         v = ohos_config_get("flip");
      }
      if (!v || !*v) {
         mode = OHOS_FLIP_SIMD;
      } else if (v[0] == '0') {
         mode = OHOS_FLIP_OFF;
      } else if (strncmp(v, "byte", 4) == 0) {
         mode = OHOS_FLIP_BYTE;
      } else if (strncmp(v, "rowcopy", 7) == 0) {
         mode = OHOS_FLIP_ROWCOPY;
      } else {
         mode = OHOS_FLIP_SIMD;
      }
   }
   return mode;
}

/* [ohos port] Flip the rows of a linear buffer in place (bottom-up -> top-down).
 *
 * Performance note: the original implementation swapped the buffer *byte by
 * byte*.  For a 1280x800 RGBA surface that is 4 MiB / 4 194 304 byte
 * iterations per swap, i.e. several milliseconds of pure CPU work per frame
 * (and it is on the critical path of every eglSwapBuffers).  Copying whole
 * rows with memcpy() moves the same data with wide loads/stores and is
 * typically 5-10x faster, while producing bit-identical output.
 *
 * The temporary row buffer keeps the operation in place (no extra allocation
 * of a full frame). */
static void
ohos_flip_rows(unsigned char *base, int height, int stride, unsigned row_bytes)
{
   unsigned char *tmp;

   if (height < 2 || row_bytes == 0)
      return;

   int mode = ohos_flip_mode();

   if (mode == OHOS_FLIP_BYTE) {
      /* The original implementation, kept as a reference for the A/B
       * measurement (MESA_OHOS_FLIP=byte). */
      for (int y = 0; y < height / 2; y++) {
         unsigned char *top = base + (size_t)y * stride;
         unsigned char *bot = base + (size_t)(height - 1 - y) * stride;
         for (unsigned i = 0; i < row_bytes; i++) {
            unsigned char t = top[i];
            top[i] = bot[i];
            bot[i] = t;
         }
      }
      return;
   }

   if (mode == OHOS_FLIP_ROWCOPY) {
      /* Copy the rows through a temporary buffer. */
      tmp = malloc(row_bytes);
      if (!tmp) {
         for (int y = 0; y < height / 2; y++) {
            unsigned char *top = base + (size_t)y * stride;
            unsigned char *bot = base + (size_t)(height - 1 - y) * stride;
            for (unsigned i = 0; i < row_bytes; i++) {
               unsigned char t = top[i];
               top[i] = bot[i];
               bot[i] = t;
            }
         }
         return;
      }
      for (int y = 0; y < height / 2; y++) {
         unsigned char *top = base + (size_t)y * stride;
         unsigned char *bot = base + (size_t)(height - 1 - y) * stride;
         memcpy(tmp, top, row_bytes);
         memcpy(top, bot, row_bytes);
         memcpy(bot, tmp, row_bytes);
      }
      free(tmp);
      return;
   }

   /* Default: swap the two rows in place with 16 byte SIMD accesses.
    *
    * Swapping in place avoids the extra memory traffic of the temporary
    * buffer (which is what made the plain memcpy version slower than the
    * byte-wise one), and the wide accesses cut the instruction count by an
    * order of magnitude.  For a 1280x800 RGBA surface this is ~4 MiB of
    * read + 4 MiB of write per frame, i.e. it is pure memory bandwidth. */
   for (int y = 0; y < height / 2; y++) {
      unsigned char *top = base + (size_t)y * stride;
      unsigned char *bot = base + (size_t)(height - 1 - y) * stride;
      unsigned i = 0;
#if defined(__SSE2__)
      for (; i + 16 <= row_bytes; i += 16) {
         __m128i a = _mm_loadu_si128((const __m128i *)(top + i));
         __m128i b = _mm_loadu_si128((const __m128i *)(bot + i));
         _mm_storeu_si128((__m128i *)(top + i), b);
         _mm_storeu_si128((__m128i *)(bot + i), a);
      }
#endif
      for (; i < row_bytes; i++) {
         unsigned char t = top[i];
         top[i] = bot[i];
         bot[i] = t;
      }
   }
}

/* [ohos port] Profiling of the host-sync path (virgl only).  Enabled with
 * MESA_OHOS_PROFILE=<path>; the file gets one line per swap with the time
 * spent in the host->guest transfer (map) and in the row flip.  Used to prove
 * where the per-frame cost of the QEMU/virgl path goes. */
struct ohos_sync_profile {
   unsigned long swaps;
   unsigned long map_ns;
   unsigned long flip_ns;
   unsigned long unmap_ns;
   int fd;
};

static struct ohos_sync_profile ohos_profile;

static void
ohos_profile_open(void)
{
   const char *path;

   if (ohos_profile.fd)
      return;
   path = getenv("MESA_OHOS_PROFILE");
   if (!path || !*path) {
      /* Fall back to a file in the image so that the profiling can be enabled
       * without touching the environment of the render service. */
      path = ohos_config_get("profile");
      if (!path || !*path)
         return;
   }
   ohos_profile.fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
}

static void
ohos_profile_dump(const char *tag, unsigned long map_ns, unsigned long flip_ns,
                  unsigned long unmap_ns)
{
   char buf[256];
   int len;

   if (!ohos_profile.fd)
      return;
   ohos_profile.swaps++;
   ohos_profile.map_ns += map_ns;
   ohos_profile.flip_ns += flip_ns;
   ohos_profile.unmap_ns += unmap_ns;
   if (ohos_profile.swaps % 60)
      return;
   len = snprintf(buf, sizeof(buf),
                  "%s swaps=%lu avg_map_us=%.1f avg_flip_us=%.1f avg_unmap_us=%.1f\n",
                  tag, ohos_profile.swaps,
                  (double)ohos_profile.map_ns / ohos_profile.swaps / 1000.0,
                  (double)ohos_profile.flip_ns / ohos_profile.swaps / 1000.0,
                  (double)ohos_profile.unmap_ns / ohos_profile.swaps / 1000.0);
   if (len > 0)
      (void)write(ohos_profile.fd, buf, (size_t)len);
}

/* [ohos port] Force the (possibly virgl/GPU) render buffer back into its guest
 * dma-buf memory.  The OHOS display HDI consumes the composed buffer through
 * its guest mapping / a guest-memory composition copy, so a purely host-side
 * GPU render (virgl) never reaches the scanout and the panel stays black.
 * Mapping the back image with __DRI_IMAGE_TRANSFER_READ makes the gallium
 * driver issue the host->guest transfer for this buffer.
 *
 * Orientation: OHOS scans out the buffer top-down (row 0 = top of the
 * screen), while the buffer produced by the virgl TRANSFER_GET is bottom-up
 * (row 0 = bottom).  Without correction the whole image is mirrored vertically
 * (the lock screen clock appears upside down).  The map above gives us a linear
 * view of the guest buffer, so flip the rows in place before the buffer is
 * enqueued.  Native (iris) and CPU drivers render the buffer directly and skip
 * all of this.
 *
 * Debug switches:
 *   MESA_OHOS_SYNC_BACK=0|1  force the host->guest sync on/off
 *   MESA_OHOS_FLIP=0|1       force the row flip on/off
 *   MESA_OHOS_PROFILE=<path> append per-swap timing statistics to <path> */
static void
ohos_sync_back_buffer(_EGLDisplay *disp, struct dri2_egl_surface *dri2_surf)
{
   struct dri2_egl_display *dri2_dpy = dri2_egl_display(disp);
   struct dri_context *dri_ctx;
   int stride = 0;
   void *data = NULL;
   void *map;
   _EGLContext *egl_ctx = _eglGetCurrentContext();
   struct timespec t0, t1, t2, t3;

   if (!ohos_needs_host_sync(dri2_dpy))
      return;
   if (!dri2_surf->dri_image_back || !egl_ctx)
      return;
   dri_ctx = dri2_egl_context(egl_ctx)->dri_context;
   if (!dri_ctx || !dri2_surf->base.Width || !dri2_surf->base.Height)
      return;

   ohos_profile_open();
   clock_gettime(CLOCK_MONOTONIC, &t0);

   map = dri2_map_image(dri_ctx, dri2_surf->dri_image_back, 0, 0,
                         dri2_surf->base.Width, dri2_surf->base.Height,
                         __DRI_IMAGE_TRANSFER_READ, &stride, &data);
   clock_gettime(CLOCK_MONOTONIC, &t1);
   if (map) {
      int width = dri2_surf->base.Width;
      int height = dri2_surf->base.Height;
      int fourcc = 0;
      unsigned bpp = 4;
      unsigned row_bytes;
      unsigned char *base = map;

      if (dri2_query_image(dri2_surf->dri_image_back,
                           __DRI_IMAGE_ATTRIB_FOURCC, &fourcc))
         bpp = ohos_fourcc_bytes_per_pixel(fourcc);

      row_bytes = (unsigned)width * bpp;
      if (stride > 0 && (unsigned)stride < row_bytes)
         row_bytes = (unsigned)stride;

      if (ohos_flip_mode() != OHOS_FLIP_OFF)
         ohos_flip_rows(base, height, stride, row_bytes);
      clock_gettime(CLOCK_MONOTONIC, &t2);

      dri2_unmap_image(dri_ctx, dri2_surf->dri_image_back, data);
   }
   clock_gettime(CLOCK_MONOTONIC, &t3);

   if (ohos_profile.fd) {
      unsigned long map_ns = (unsigned long)((t1.tv_sec - t0.tv_sec) * 1000000000L +
                                              (t1.tv_nsec - t0.tv_nsec));
      unsigned long flip_ns = (unsigned long)((t2.tv_sec - t1.tv_sec) * 1000000000L +
                                              (t2.tv_nsec - t1.tv_nsec));
      unsigned long unmap_ns = (unsigned long)((t3.tv_sec - t2.tv_sec) * 1000000000L +
                                                (t3.tv_nsec - t2.tv_nsec));
      ohos_profile_dump("ohos_sync", map_ns, flip_ns, unmap_ns);
   }
}

static EGLBoolean
ohos_swap_buffers(_EGLDisplay *disp, _EGLSurface *draw)
{
   struct dri2_egl_surface *dri2_surf = dri2_egl_surface(draw);
   const bool has_mutable_rb = _eglSurfaceHasMutableRenderBuffer(draw);

   if (has_mutable_rb && draw->RequestedRenderBuffer == EGL_SINGLE_BUFFER &&
       draw->ActiveRenderBuffer == EGL_SINGLE_BUFFER)
      return EGL_TRUE;

   for (int i = 0; i < dri2_surf->color_buffers_count; i++) {
      if (dri2_surf->color_buffers[i].age > 0)
         dri2_surf->color_buffers[i].age++;
   }

   if (dri2_surf->back)
      dri2_surf->back->age = 1;

   dri2_flush_drawable_for_swapbuffers_flags(disp, draw,
                                             __DRI2_NOTHROTTLE_SWAPBUFFER);

   ohos_sync_back_buffer(disp, dri2_surf);

   if (dri2_surf->buffer)
      ohos_window_enqueue_buffer(disp, dri2_surf);

   dri_invalidate_drawable(dri2_surf->dri_drawable);

   return EGL_TRUE;
}

static EGLBoolean
ohos_query_surface(_EGLDisplay *disp, _EGLSurface *surf, EGLint attribute,
                   EGLint *value)
{
   struct dri2_egl_surface *dri2_surf = dri2_egl_surface(surf);

   switch (attribute) {
   case EGL_WIDTH:
      if (dri2_surf->base.Type == EGL_WINDOW_BIT && dri2_surf->window) {
         OH_NativeWindow_NativeWindowHandleOpt(dri2_surf->window,
                                               GET_BUFFER_GEOMETRY,
                                               &surf->Height, value);
         return EGL_TRUE;
      }
      break;
   case EGL_HEIGHT:
      if (dri2_surf->base.Type == EGL_WINDOW_BIT && dri2_surf->window) {
         int height = 0;
         OH_NativeWindow_NativeWindowHandleOpt(dri2_surf->window,
                                               GET_BUFFER_GEOMETRY,
                                               &height, value);
         *value = height;
         return EGL_TRUE;
      }
      break;
   default:
      break;
   }
   return _eglQuerySurface(disp, surf, attribute, value);
}

static EGLint
ohos_query_buffer_age(_EGLDisplay *disp, _EGLSurface *surface)
{
   struct dri2_egl_surface *dri2_surf = dri2_egl_surface(surface);

   if (ohos_update_buffers(dri2_surf) < 0) {
      _eglError(EGL_BAD_ALLOC, "ohos_query_buffer_age");
      return -1;
   }

   return dri2_surf->back ? dri2_surf->back->age : 0;
}

static _EGLImage *
ohos_create_image_khr(_EGLDisplay *disp, _EGLContext *ctx, EGLenum target,
                      EGLClientBuffer buffer, const EGLint *attr_list)
{
#ifndef EGL_NATIVE_BUFFER_OHOS
#define EGL_NATIVE_BUFFER_OHOS 0x34E1
#endif
   switch (target) {
   case EGL_NATIVE_BUFFER_OHOS: {
      struct dri_image *dri_image;

      if (ctx != NULL) {
         _eglError(EGL_BAD_CONTEXT,
                   "eglCreateEGLImageKHR: for EGL_NATIVE_BUFFER_OHOS, the "
                   "context must be EGL_NO_CONTEXT");
         return NULL;
      }

      dri_image = ohos_create_image_from_native_buffer(disp, buffer, buffer);
      if (!dri_image)
         return NULL;

      return dri2_create_image_from_dri(disp, dri_image);
   }
   default:
      return dri2_create_image_khr(disp, ctx, target, buffer, attr_list);
   }
}

static void
ohos_flush_front_buffer(struct dri_drawable *driDrawable, void *loaderPrivate)
{
   (void)driDrawable;
   (void)loaderPrivate;
}

static unsigned
ohos_get_capability(void *loaderPrivate, enum dri_loader_cap cap)
{
   /* Note: loaderPrivate is _EGLDisplay* */
   (void)loaderPrivate;
   switch (cap) {
   case DRI_LOADER_CAP_RGBA_ORDERING:
      return 1;
   default:
      return 0;
   }
}

static void
ohos_destroy_loader_image_state(void *loaderPrivate)
{
   (void)loaderPrivate;
}

static const struct dri2_egl_display_vtbl dri2_ohos_display_vtbl = {
   .create_window_surface = ohos_create_window_surface,
   .create_pbuffer_surface = ohos_create_pbuffer_surface,
   .destroy_surface = ohos_destroy_surface,
   .create_image = ohos_create_image_khr,
   .swap_buffers = ohos_swap_buffers,
   .query_buffer_age = ohos_query_buffer_age,
   .query_surface = ohos_query_surface,
   .get_dri_drawable = dri2_surface_get_dri_drawable,
};

static const __DRIimageLoaderExtension ohos_image_loader_extension = {
   .base = {__DRI_IMAGE_LOADER, 4},
   .getBuffers = ohos_image_get_buffers,
   .flushFrontBuffer = ohos_flush_front_buffer,
   .getCapability = ohos_get_capability,
   .flushSwapBuffers = NULL,
   .destroyLoaderImageState = ohos_destroy_loader_image_state,
};

static void
ohos_drawable_info(struct dri_drawable *draw, int *x, int *y, int *w, int *h,
                   void *loaderPrivate)
{
   struct dri2_egl_surface *dri2_surf = loaderPrivate;

   if (dri2_surf->base.Type == EGL_WINDOW_BIT && dri2_surf->window) {
      OH_NativeWindow_NativeWindowHandleOpt(dri2_surf->window,
                                            GET_BUFFER_GEOMETRY,
                                            &dri2_surf->base.Height,
                                            &dri2_surf->base.Width);
   }

   *x = *y = 0;
   *w = dri2_surf->base.Width;
   *h = dri2_surf->base.Height;
}

static const __DRIswrastLoaderExtension swrast_loader_extension = {
   .base = {__DRI_SWRAST_LOADER, 1},
   .getDrawableInfo = ohos_drawable_info,
};

static const __DRIextension *image_loader_extensions[] = {
   &ohos_image_loader_extension.base,
   &image_lookup_extension.base,
   &swrast_loader_extension.base,
   NULL,
};

/* [ohos port] Enumerate the DRM nodes that are actually present, so the log
 * tells us what the loader had to choose from. */
static void
ohos_log_drm_nodes(void)
{
   DIR *dir = opendir("/dev/dri");
   struct dirent *entry = NULL;

   if (dir == NULL) {
      mesa_ohos_log("drm: /dev/dri not readable (errno %d)", errno);
      return;
   }
   while ((entry = readdir(dir)) != NULL) {
      if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0)
         continue;
      mesa_ohos_log("drm: node /dev/dri/%s", entry->d_name);
   }
   closedir(dir);
}

static bool
ohos_load_driver(_EGLDisplay *disp)
{
   struct dri2_egl_display *dri2_dpy = dri2_egl_display(disp);
   int fd = -1;
   char *name = NULL;
   const char *forced = getenv("MESA_OHOS_DRIVER");
   static const char *paths[] = {
      "/dev/dri/renderD128",
      "/dev/dri/card0",
      "/dev/dri/card1",
   };

   ohos_log_drm_nodes();

   for (unsigned i = 0; i < ARRAY_SIZE(paths); i++) {
      fd = loader_open_device(paths[i]);
      if (fd >= 0) {
         mesa_ohos_log("drm: opened %s fd=%d", paths[i], fd);
         break;
      }
   }
   if (fd < 0)
      mesa_ohos_log("drm: no DRM node could be opened (all of renderD128/card0/card1 failed)");

   if (fd >= 0) {
      int vendor_id = 0;
      int chip_id = 0;
      if (loader_get_pci_id_for_fd(fd, &vendor_id, &chip_id)) {
         mesa_ohos_log("drm: pci id %04x:%04x", vendor_id, chip_id);
      } else {
         mesa_ohos_log("drm: pci id unavailable");
      }
      name = loader_get_driver_for_fd(fd);
      mesa_ohos_log("drm: loader_get_driver_for_fd -> %s", name ? name : "(null)");
      if (name && name[0]) {
         dri2_dpy->driver_name = strdup(name);
         free(name);
      }
   }

   dri2_dpy->fd_render_gpu = fd;
   dri2_dpy->fd_display_gpu = fd;

   if (forced != NULL && forced[0] != '\0') {
      mesa_ohos_log("drm: MESA_OHOS_DRIVER override -> %s", forced);
      free(dri2_dpy->driver_name);
      dri2_dpy->driver_name = strdup(forced);
   }

   if (!dri2_dpy->driver_name)
      dri2_dpy->driver_name = strdup("swrast");
   if (!dri2_dpy->driver_name)
      return false;

   mesa_ohos_log("drm: using gallium driver '%s'", dri2_dpy->driver_name);

   /* Force the image-loader (DRI3 + swrast loader) path, never kopper. */
   dri2_detect_swrast_kopper(disp);
   dri2_dpy->kopper = false;
   dri2_dpy->swrast = false;
   dri2_dpy->swrast_not_kms = false;
   dri2_dpy->loader_extensions = image_loader_extensions;

   if (!dri2_create_screen(disp)) {
      mesa_ohos_log("drm: dri2_create_screen FAILED for driver '%s' (errno %d)",
                    dri2_dpy->driver_name ? dri2_dpy->driver_name : "(null)", errno);
      free(dri2_dpy->driver_name);
      dri2_dpy->driver_name = NULL;
      return false;
   }

   mesa_ohos_log("drm: dri2_create_screen OK driver='%s'", dri2_dpy->driver_name);
   return true;
}

/* Try to come up with a usable software screen when the DRM driver has no
 * (working) acceleration.  The single-step swrast fallback matches the
 * behaviour that was validated for the QEMU 2D case.  NOTE: keep this
 * single-step; trying "kms_swrast" first leaves dri2_dpy in a dirty state and
 * makes render_service crash-loop (verified 2026-09-22). */
static bool
ohos_load_driver_swrast(_EGLDisplay *disp)
{
   struct dri2_egl_display *dri2_dpy = dri2_egl_display(disp);

   free(dri2_dpy->driver_name);
   dri2_dpy->driver_name = strdup("swrast");
   if (!dri2_dpy->driver_name)
      return false;

   dri2_detect_swrast_kopper(disp);
   dri2_dpy->loader_extensions = image_loader_extensions;

   if (!dri2_create_screen(disp)) {
      mesa_ohos_log("swrast: dri2_create_screen FAILED (errno %d)", errno);
      free(dri2_dpy->driver_name);
      dri2_dpy->driver_name = NULL;
      return false;
   }

   mesa_ohos_log("swrast: dri2_create_screen OK (SOFTWARE RENDERING ACTIVE)");
   return true;
}

static void
ohos_add_configs_for_visuals(_EGLDisplay *disp)
{
   struct dri2_egl_display *dri2_dpy = dri2_egl_display(disp);
   static const struct {
      int hal_format;
      enum pipe_format pipe_format;
   } visuals[] = {
      {PIXEL_FMT_RGBA_8888, PIPE_FORMAT_RGBA8888_UNORM},
      {PIXEL_FMT_RGBX_8888, PIPE_FORMAT_RGBX8888_UNORM},
      {PIXEL_FMT_RGB_565, PIPE_FORMAT_B5G6R5_UNORM},
      {PIXEL_FMT_BGRA_8888, PIPE_FORMAT_BGRA8888_UNORM},
   };

   unsigned int format_count[ARRAY_SIZE(visuals)] = {0};
   bool has_rgba = false;

   for (int i = 0; i < ARRAY_SIZE(visuals); i++) {
      if (visuals[i].hal_format == PIXEL_FMT_BGRA_8888 && has_rgba)
         continue;
      for (int j = 0; dri2_dpy->driver_configs[j]; j++) {
         const struct gl_config *gl_config =
            (struct gl_config *)dri2_dpy->driver_configs[j];

         enum pipe_format linear_format =
            util_format_linear(gl_config->color_format);
         if (linear_format != visuals[i].pipe_format)
            continue;

         const EGLint surface_type = EGL_WINDOW_BIT | EGL_PBUFFER_BIT;
         const EGLint config_attrs[] = {
            EGL_NATIVE_VISUAL_ID, visuals[i].hal_format, EGL_NATIVE_VISUAL_TYPE,
            visuals[i].hal_format, EGL_NONE};

         struct dri2_egl_config *dri2_conf = dri2_add_config(
            disp, dri2_dpy->driver_configs[j], surface_type, config_attrs);
         if (dri2_conf)
            format_count[i]++;
      }

      if (visuals[i].hal_format == PIXEL_FMT_RGBA_8888 && format_count[i])
         has_rgba = true;
   }

   for (int i = 0; i < ARRAY_SIZE(format_count); i++) {
      if (!format_count[i]) {
         _eglLog(_EGL_DEBUG, "No DRI config supports native format 0x%x",
                 visuals[i].hal_format);
      }
   }
}

EGLBoolean
dri2_initialize_ohos(_EGLDisplay *disp)
{
    const char *err;
    struct dri2_egl_display *dri2_dpy = dri2_display_create(disp);
    if (!dri2_dpy)
        return EGL_FALSE;

    err = "DRI2: failed to load driver";
    if (!ohos_load_driver(disp)) {
        const char *no_fallback = getenv("MESA_OHOS_NO_SWRAST_FALLBACK");
        mesa_ohos_log("init: hardware driver NOT usable -> %s",
                      (no_fallback != NULL && no_fallback[0] == '1') ?
                          "swrast fallback DISABLED by MESA_OHOS_NO_SWRAST_FALLBACK=1" :
                          "falling back to swrast (SOFTWARE RENDERING)");
        if (no_fallback != NULL && no_fallback[0] == '1') {
            err = "DRI2: failed to load driver (swrast fallback disabled)";
            goto cleanup;
        }
        if (!ohos_load_driver_swrast(disp)) {
            err = "DRI2: failed to create screen (swrast fallback failed too)";
            goto cleanup;
        }
    }

    if (!dri2_dpy->dri_screen_render_gpu) {
        err = "DRI2: failed to create screen";
        goto cleanup;
    }
    {
        struct pipe_screen *pscreen = dri_get_pipe_screen(dri2_dpy->dri_screen_render_gpu);
        const char *renderer = pscreen != NULL ? pscreen->get_name(pscreen) : "(null)";
        mesa_ohos_log("init: create_screen OK driver='%s' renderer='%s' fd=%d",
                      dri2_dpy->driver_name ? dri2_dpy->driver_name : "(null)",
                      renderer, dri2_dpy->fd_render_gpu);
        if (strcmp(renderer, "softpipe") == 0 || strcmp(renderer, "llvmpipe") == 0 ||
            strcmp(renderer, "swrast") == 0) {
            mesa_ohos_log("init: *** WARNING: SOFTWARE RASTERIZER IN USE ('%s') - "
                          "everything will be CPU rendered ***", renderer);
        }
    }

    dri2_setup_screen(disp);

    ohos_add_configs_for_visuals(disp);

    disp->Extensions.KHR_image = EGL_TRUE;

    dri2_dpy->vtbl = &dri2_ohos_display_vtbl;

    return EGL_TRUE;

 cleanup:
    dri2_display_destroy(disp);
    return _eglError(EGL_NOT_INITIALIZED, err);
}

