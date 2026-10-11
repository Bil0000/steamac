/* wmtr VR export: see include/wmtr_vr.h. Manual retain/release, like wmtr_host.m. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <IOSurface/IOSurface.h>
#include <servers/bootstrap.h>
#include <mach/mach.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define WINEMETAL_API
#include "winemetal_thunks.h"
#include "vrlink.h"
#include "wmtr_vr.h"

#define STATUS_SUCCESS 0
#define STATUS_INVALID_PARAMETER ((int)0xC000000D)
#define STATUS_NOT_SUPPORTED ((int)0xC00000BB)
#define STATUS_UNSUCCESSFUL ((int)0xC0000001)

#define VR_IMAGES 3 /* per eye: one being written, one in the compositor, one spare */

struct vr_swapchain {
  uint32_t id, width, height, format, flags;
  IOSurfaceRef surface[VR_IMAGES];
  id<MTLTexture> image[VR_IMAGES];
  _Atomic int busy[VR_IMAGES]; /* between the blit and VRL_RELEASE */
};

struct wmtr_vr {
  int fd;
  char mach_name[128];
  mach_port_t service;
  id<MTLDevice> device;
  id<MTLCommandQueue> queue;
  struct vr_swapchain sc[2]; /* one per eye; ids 1 and 2 */
  uint32_t generation;       /* bumps swapchain ids on recreate: id = eye + 1 + 2 * generation */
  _Atomic uint64_t submits, sent, dropped, released, errors, swapchains;
  int warned;
  _Atomic int inflight; /* command buffers whose completion handler has not run */
};

static int64_t
now_ns(void) {
  return (int64_t)clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

static void
vr_log(struct wmtr_vr *vr, const char *msg) {
  if (vr->warned++ < 16) fprintf(stderr, "wmtr-vr: %s\n", msg);
}

/* IOSurface layout for the pixel formats VR eye textures use */
static int
format_info(uint32_t mtl, uint32_t *fourcc, uint32_t *bpe) {
  switch (mtl) {
  case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB: *fourcc = 'RGBA'; *bpe = 4; return 1;
  case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatBGRA8Unorm_sRGB: *fourcc = 'BGRA'; *bpe = 4; return 1;
  case MTLPixelFormatRGBA16Float: *fourcc = 'RGhA'; *bpe = 8; return 1;
  default: return 0;
  }
}

static int
send_packet(struct wmtr_vr *vr, const void *p, size_t n) {
  ssize_t r;
  do r = send(vr->fd, p, n, 0); while (r < 0 && errno == EINTR);
  if (r != (ssize_t)n) { atomic_fetch_add(&vr->errors, 1); return 0; }
  return 1;
}

static mach_port_t
service_port(struct wmtr_vr *vr) {
  if (vr->service == MACH_PORT_NULL &&
      bootstrap_look_up(bootstrap_port, vr->mach_name, &vr->service) != KERN_SUCCESS)
    vr->service = MACH_PORT_NULL;
  return vr->service;
}

static void
swapchain_free(struct vr_swapchain *s) {
  for (int i = 0; i < VR_IMAGES; i++) {
    [s->image[i] release]; s->image[i] = nil;
    if (s->surface[i]) CFRelease(s->surface[i]);
    s->surface[i] = NULL;
    atomic_store(&s->busy[i], 0);
  }
  s->id = 0;
}

/* (re)create eye `eye`'s swapchain: images, ports to the host (Mach first), then VRL_SWAPCHAIN */
static int
swapchain_make(struct wmtr_vr *vr, int eye, uint32_t w, uint32_t h, uint32_t format, uint32_t flags) {
  struct vr_swapchain *s = &vr->sc[eye];
  uint32_t fourcc, bpe;
  if (!format_info(format, &fourcc, &bpe)) { vr_log(vr, "unsupported eye texture format"); return 0; }
  mach_port_t svc = service_port(vr);
  if (svc == MACH_PORT_NULL) { vr_log(vr, "vrhost mach service not found"); return 0; }
  swapchain_free(s);
  vr->generation++;
  s->id = (uint32_t)eye + 1 + 2 * vr->generation;
  s->width = w; s->height = h; s->format = format; s->flags = flags;
  struct vrl_mach_swapchain m;
  memset(&m, 0, sizeof m);
  for (int i = 0; i < VR_IMAGES; i++) {
    NSDictionary *props = @{
      (id)kIOSurfaceWidth : @(w), (id)kIOSurfaceHeight : @(h), (id)kIOSurfaceBytesPerElement : @(bpe),
      (id)kIOSurfacePixelFormat : @(fourcc),
    };
    s->surface[i] = IOSurfaceCreate((CFDictionaryRef)props);
    if (!s->surface[i]) { swapchain_free(s); vr_log(vr, "IOSurfaceCreate failed"); return 0; }
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModeShared;
    s->image[i] = [vr->device newTextureWithDescriptor:d iosurface:s->surface[i] plane:0];
    if (!s->image[i]) { swapchain_free(s); vr_log(vr, "IOSurface texture failed"); return 0; }
    m.ports[i].name = IOSurfaceCreateMachPort(s->surface[i]);
    m.ports[i].disposition = MACH_MSG_TYPE_MOVE_SEND;
    m.ports[i].type = MACH_MSG_PORT_DESCRIPTOR;
  }
  m.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
  m.header.msgh_size = sizeof m;
  m.header.msgh_remote_port = svc;
  m.header.msgh_id = VRL_MACH_SWAPCHAIN_ID;
  m.body.msgh_descriptor_count = VRL_MAX_IMAGES;
  for (int i = VR_IMAGES; i < VRL_MAX_IMAGES; i++) { m.ports[i].name = MACH_PORT_NULL; m.ports[i].disposition = MACH_MSG_TYPE_COPY_SEND; m.ports[i].type = MACH_MSG_PORT_DESCRIPTOR; }
  m.swapchain_id = s->id;
  m.image_count = VR_IMAGES;
  kern_return_t kr = mach_msg(&m.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, MACH_PORT_NULL, 1000, MACH_PORT_NULL);
  if (kr != KERN_SUCCESS) {
    for (int i = 0; i < VR_IMAGES; i++) mach_port_deallocate(mach_task_self(), m.ports[i].name);
    mach_port_deallocate(mach_task_self(), vr->service);
    vr->service = MACH_PORT_NULL;
    swapchain_free(s);
    vr_log(vr, "mach send of swapchain ports failed");
    return 0;
  }
  struct vrl_swapchain p = {{VRL_SWAPCHAIN, sizeof p}, s->id, VR_IMAGES, w, h, format, flags};
  if (!send_packet(vr, &p, sizeof p)) { swapchain_free(s); return 0; }
  atomic_fetch_add(&vr->swapchains, 1);
  return 1;
}

/* VRL_RELEASE packets: mark images free (executor thread, non-blocking) */
static void
drain_releases(struct wmtr_vr *vr) {
  union { struct vrl_header h; struct vrl_release r; uint8_t raw[512]; } u;
  for (;;) {
    ssize_t n = recv(vr->fd, &u, sizeof u, MSG_DONTWAIT);
    if (n <= 0) return;
    if (n < (ssize_t)sizeof u.h || u.h.type != VRL_RELEASE || n < (ssize_t)sizeof u.r) continue;
    for (int e = 0; e < 2; e++)
      if (vr->sc[e].id == u.r.swapchain && u.r.image < VR_IMAGES) atomic_store(&vr->sc[e].busy[u.r.image], 0);
    atomic_fetch_add(&vr->released, 1);
  }
}

int
wmtr_vr_submit(struct wmtr_vr *vr, const struct WMTVRSubmitInfo *info) {
  if (!vr) return STATUS_NOT_SUPPORTED;
  int64_t t_submit = now_ns();
  atomic_fetch_add(&vr->submits, 1);
  drain_releases(vr);
  id<MTLTexture> src[2];
  uint32_t rx[2], ry[2], rw[2], rh[2];
  for (int e = 0; e < 2; e++) {
    const struct WMTVREye *in = &info->eye[e];
    src[e] = (id<MTLTexture>)in->texture;
    if (!src[e] || src[e].sampleCount != 1 || in->slice >= src[e].arrayLength) {
      atomic_fetch_add(&vr->errors, 1); vr_log(vr, "bad eye texture"); return STATUS_INVALID_PARAMETER;
    }
    rx[e] = in->x; ry[e] = in->y;
    rw[e] = in->w ? in->w : (uint32_t)src[e].width;
    rh[e] = in->w ? in->h : (uint32_t)src[e].height;
    if (!rw[e] || !rh[e] || rx[e] + rw[e] > src[e].width || ry[e] + rh[e] > src[e].height) {
      atomic_fetch_add(&vr->errors, 1); vr_log(vr, "eye rect out of bounds"); return STATUS_INVALID_PARAMETER;
    }
    if (!vr->device) { vr->device = [src[e].device retain]; vr->queue = [vr->device newCommandQueue]; }
    uint32_t fmt = (uint32_t)src[e].pixelFormat;
    uint32_t flags = (in->flags & WMTVR_EYE_SRGB) || fmt == MTLPixelFormatRGBA8Unorm_sRGB || fmt == MTLPixelFormatBGRA8Unorm_sRGB
                         ? VRL_SWAPCHAIN_SRGB : 0;
    struct vr_swapchain *s = &vr->sc[e];
    if (!s->id || s->width != rw[e] || s->height != rh[e] || s->format != fmt || s->flags != flags)
      if (!swapchain_make(vr, e, rw[e], rh[e], fmt, flags)) { atomic_fetch_add(&vr->errors, 1); return STATUS_UNSUCCESSFUL; }
  }
  int img[2];
  for (int e = 0; e < 2; e++) {
    img[e] = -1;
    for (int i = 0; i < VR_IMAGES && img[e] < 0; i++) {
      int expect = 0;
      if (atomic_compare_exchange_strong(&vr->sc[e].busy[i], &expect, 1)) img[e] = i;
    }
  }
  if (img[0] < 0 || img[1] < 0) {
    for (int e = 0; e < 2; e++) if (img[e] >= 0) atomic_store(&vr->sc[e].busy[img[e]], 0);
    atomic_fetch_add(&vr->dropped, 1);
    return STATUS_SUCCESS;
  }
  struct vrl_submit p;
  memset(&p, 0, sizeof p);
  p.h.type = VRL_SUBMIT; p.h.size = sizeof p;
  p.frame_id = info->frame_id;
  p.display_time = (int64_t)info->display_time;
  p.app_submit_time = t_submit;
  memcpy(p.pose, info->pose, sizeof p.pose);
  memcpy(p.fov, info->fov, sizeof p.fov);
  id<MTLCommandBuffer> cb = [vr->queue commandBuffer];
  if (info->wait_event && info->wait_value) [cb encodeWaitForEvent:(id<MTLSharedEvent>)info->wait_event value:info->wait_value];
  id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
  for (int e = 0; e < 2; e++) {
    [be copyFromTexture:src[e] sourceSlice:info->eye[e].slice sourceLevel:0 sourceOrigin:MTLOriginMake(rx[e], ry[e], 0)
             sourceSize:MTLSizeMake(rw[e], rh[e], 1) toTexture:vr->sc[e].image[img[e]] destinationSlice:0
       destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    p.eye[e] = (struct vrl_eye){vr->sc[e].id, (uint32_t)img[e], 0, 0, rw[e], rh[e],
                                (info->eye[e].flags & WMTVR_EYE_FLIP_Y) ? VRL_EYE_FLIP_Y : 0, 0};
  }
  [be endEncoding];
  atomic_fetch_add(&vr->inflight, 1);
  [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
    struct vrl_submit q = p;
    if (done.status != MTLCommandBufferStatusCompleted) {
      atomic_fetch_add(&vr->errors, 1);
      for (int e = 0; e < 2; e++)
        if (vr->sc[e].id == q.eye[e].swapchain) atomic_store(&vr->sc[e].busy[q.eye[e].image], 0);
      atomic_fetch_sub(&vr->inflight, 1);
      return;
    }
    q.ready_time = now_ns();
    if (send_packet(vr, &q, sizeof q)) atomic_fetch_add(&vr->sent, 1);
    atomic_fetch_sub(&vr->inflight, 1);
  }];
  [cb commit];
  return STATUS_SUCCESS;
}

struct wmtr_vr *
wmtr_vr_create(int link_fd, const char *mach_name) {
  if (link_fd < 0 || !mach_name) return NULL;
  struct wmtr_vr *vr = calloc(1, sizeof *vr);
  vr->fd = link_fd;
  snprintf(vr->mach_name, sizeof vr->mach_name, "%s", mach_name);
  int on = 1;
  setsockopt(link_fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
  struct vrl_hello hello = {{VRL_HELLO, sizeof hello}, VRL_VERSION, (uint32_t)getpid()};
  send_packet(vr, &hello, sizeof hello);
  return vr;
}

struct wmtr_vr *
wmtr_vr_connect(const char *path, const char *mach_name) {
  /* the listener (steamac-vrhost, or a test) answers with one end of a SOCK_DGRAM socketpair (SCM_RIGHTS):
     macOS has no AF_UNIX SOCK_SEQPACKET */
  int s = socket(AF_UNIX, SOCK_STREAM, 0);
  if (s < 0) return NULL;
  struct sockaddr_un a = {.sun_family = AF_UNIX};
  snprintf(a.sun_path, sizeof a.sun_path, "%s", path);
  int fd = -1;
  if (connect(s, (struct sockaddr *)&a, sizeof a) == 0) {
    char byte;
    struct iovec iov = {&byte, 1};
    union { struct cmsghdr h; char buf[CMSG_SPACE(sizeof(int))]; } c;
    struct msghdr m = {.msg_iov = &iov, .msg_iovlen = 1, .msg_control = c.buf, .msg_controllen = sizeof c.buf};
    if (recvmsg(s, &m, 0) == 1) {
      struct cmsghdr *ch = CMSG_FIRSTHDR(&m);
      if (ch && ch->cmsg_level == SOL_SOCKET && ch->cmsg_type == SCM_RIGHTS) memcpy(&fd, CMSG_DATA(ch), sizeof fd);
    }
  }
  close(s);
  if (fd < 0) return NULL;
  struct wmtr_vr *vr = wmtr_vr_create(fd, mach_name);
  if (!vr) close(fd);
  return vr;
}

void
wmtr_vr_destroy(struct wmtr_vr *vr) {
  if (!vr) return;
  /* completion handlers reference vr; a bound keeps destroy from hanging on a wedged GPU */
  for (int i = 0; i < 2000 && atomic_load(&vr->inflight); i++) usleep(1000);
  [vr->queue release];
  close(vr->fd);
  for (int e = 0; e < 2; e++) swapchain_free(&vr->sc[e]);
  if (vr->service) mach_port_deallocate(mach_task_self(), vr->service);
  [vr->device release];
  free(vr);
}

void
wmtr_vr_get_stats(struct wmtr_vr *vr, struct wmtr_vr_stats *o) {
  o->submits = vr->submits; o->sent = vr->sent; o->dropped = vr->dropped;
  o->released = vr->released; o->errors = vr->errors; o->swapchains = vr->swapchains;
}
