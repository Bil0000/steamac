/* wmtr_loopback: client and host executor in one process over an in-memory transport.
 * Oracle: each test calls a winemetal entry once directly (the native path: the implementation
 * reads the caller's memory) and once through __wine_unix_call_funcs of the wmtr client (params
 * relocated into the ring, executed by the host, outputs copied back). Results must be identical.
 * The implementations are small fakes with the real param layouts, plus real Metal for newBuffer. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sched.h>

#define WINEMETAL_API
#include "winemetal_thunks.h"
#include "airconv_thunks.h"
#include "wmtr_proto.h"
#include "wmtr_transport.h"
#include "wmtr_host.h"
#include "wmtr_vr.h"
#include "vrlink.h"
#include <IOSurface/IOSurface.h>
#include <servers/bootstrap.h>
#include <sys/socket.h>
#include <poll.h>

typedef int NTSTATUS;
typedef NTSTATUS (*fn_t)(void *);
extern const void *__wine_unix_call_funcs[];

static int failures;
#define CHECK(c, ...) do { if (!(c)) { failures++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)

/* ---------------- fake implementations (the "host Metal") ---------------- */
static NTSTATUS f_getcstring(void *a) {
  struct unixcall_nsstring_getcstring *p = a;
  const char *s = (const char *)p->str; /* the fake NSString handle is a C string */
  strncpy((char *)(uintptr_t)p->buffer_ptr, s, p->max_length);
  p->ret = 1;
  return 0;
}
static uint64_t encode_sum; static uint32_t encode_cmds, encode_vp;
static NTSTATUS f_render_encode(void *a) {
  struct unixcall_generic_obj_cmd_noret *p = a;
  for (const struct wmtcmd_base *c = p->cmd_head.ptr; c; c = c->next.ptr) {
    encode_cmds++;
    if (c->type == WMTRenderCommandSetFragmentBytes) {
      const struct wmtcmd_render_setbytes *b = (const void *)c;
      for (uint64_t i = 0; i < b->length; i++) encode_sum += ((const uint8_t *)b->bytes.ptr)[i];
    } else if (c->type == WMTRenderCommandSetViewports) {
      const struct wmtcmd_render_setviewports *v = (const void *)c;
      for (int i = 0; i < v->viewport_count; i++) encode_vp += (uint32_t)((const struct WMTViewport *)v->viewports.ptr)[i].width;
    }
  }
  return 0;
}
static NTSTATUS f_getbytes(void *a) {
  struct unixcall_mtltexture_replaceregion *p = a;
  uint8_t *d = p->data.ptr;
  for (uint64_t i = 0; i < p->bytes_per_row * p->size.height; i++) d[i] = (uint8_t)(i * 7 + p->level);
  return 0;
}
static uint64_t replace_sum;
static NTSTATUS f_replace(void *a) {
  struct unixcall_mtltexture_replaceregion *p = a;
  const uint8_t *d = p->data.ptr;
  for (uint64_t i = 0; i < p->bytes_per_row * p->size.height; i++) replace_sum += d[i] * (i + 1);
  return 0;
}
static NTSTATUS f_argsinfo(void *a) { (void)a; return 0; }
static NTSTATUS f_noop(void *a) { (void)a; return 0; }
static NTSTATUS f_fault(void *a) { (void)a; return *(volatile int *)(uintptr_t)0x10; }
/* an autoreleased result whose lifetime the test watches */
static int probe_alive;
@interface Probe : NSObject
@end
@implementation Probe
- (instancetype)init { if ((self = [super init])) probe_alive = 1; return self; }
- (void)dealloc { probe_alive = 0; [super dealloc]; }
@end
static NTSTATUS f_autoreleased(void *a) { ((struct unixcall_generic_obj_ret *)a)->ret = (obj_handle_t)[[[Probe alloc] init] autorelease]; return 0; }
static NTSTATUS f_pixelformat(void *a) { ((struct unixcall_generic_obj_uint64_ret *)a)->ret = 70; return 0; } /* RGBA8 */
static NTSTATUS f_release(void *a) { [(id)*(obj_handle_t *)a release]; return 0; }
static NTSTATUS f_newfunction(void *a) {
  struct unixcall_generic_obj_uint64_obj_ret *p = a;
  p->ret = strlen((const char *)(uintptr_t)p->arg) * 1000 + p->handle;
  return 0;
}
const void *wmtr_impl_funcs[WMTR_NCALLS] = {[1] = f_release, [8] = f_getcstring, [26] = f_newfunction, [38] = f_render_encode,
                                    [39] = f_pixelformat, [47] = f_noop, [53] = f_autoreleased, [5] = f_fault, [88] = f_argsinfo, [45] = f_replace, [145] = f_getbytes};

/* ---------------- loopback transport ---------------- */
static struct wmtr_host *H;
static void *blob_base[WMTR_MAX_BLOBS]; static uint64_t blob_size[WMTR_MAX_BLOBS];
static void *t_blob_ptr(void *c, uint32_t b, uint64_t *s) { *s = blob_size[b]; return blob_base[b]; }
static void t_wake(void *c, uint32_t s) {}
static uint64_t next_view = 0x1000, released[8]; static int n_released;
static uint64_t t_create_view(void *c, uint64_t hwnd, void *dev, uint64_t *layer) { *layer = 0x77; return next_view++; }
static void t_release_view(void *c, uint64_t v) { if (n_released < 8) released[n_released] = v; n_released++; }
static const struct wmtr_host_ops host_ops = {t_blob_ptr, t_wake, t_create_view, t_release_view, NULL};
static void *pages(uint64_t n) { void *p; posix_memalign(&p, WMTR_PAGE, n); memset(p, 0, n); return p; }
static void *t_open_ring(struct wmtr_transport *t, uint64_t size) {
  struct wmtr_ring *R = pages(size);
  R->magic = WMTR_RING_MAGIC; R->version = WMTR_VERSION;
  blob_base[0] = R; blob_size[0] = size;
  H = wmtr_host_create(R, &host_ops, NULL);
  return R;
}
static void *t_add_blob(struct wmtr_transport *t, uint32_t b, uint64_t size) { blob_base[b] = pages(size); blob_size[b] = size; return blob_base[b]; }
static void t_kick(struct wmtr_transport *t) { wmtr_host_kick(H); }
static void t_wait(struct wmtr_transport *t, volatile uint64_t *d, uint64_t seq, uint32_t slot, uint64_t spin_ns) { (void)spin_ns; while (__atomic_load_n(d, __ATOMIC_ACQUIRE) < seq) sched_yield(); }
struct wmtr_transport *wmtr_transport_create(void) {
  struct wmtr_transport *t = calloc(1, sizeof *t);
  t->open_ring = t_open_ring; t->add_blob = t_add_blob; t->kick = t_kick; t->wait = t_wait;
  return t;
}
static NTSTATUS remote(int call, void *p) { return ((fn_t)__wine_unix_call_funcs[call])(p); }
static NTSTATUS native(int call, void *p) { return ((fn_t)wmtr_impl_funcs[call])(p); }


/* ---------------- VR export (call 146) ---------------- */
extern kern_return_t bootstrap_register2(mach_port_t, name_t, mach_port_t, uint64_t);
static mach_port_t vr_port;
static IOSurfaceRef vr_surf[16][VRL_MAX_IMAGES];
static uint32_t vr_fmt[16];
/* the steamac-vrhost end, minimal: next packet; swapchain ports are taken from the Mach port */
static int vr_recv(int fd, void *buf, size_t n, int timeout_ms) {
  struct pollfd pf = {fd, POLLIN, 0};
  if (poll(&pf, 1, timeout_ms) != 1) return -1;
  int r = (int)recv(fd, buf, n, 0);
  struct vrl_header *h = buf;
  if (r >= (int)sizeof(struct vrl_swapchain) && h->type == VRL_SWAPCHAIN) {
    struct vrl_swapchain *sc = buf;
    struct vrl_mach_swapchain_rcv m;
    memset(&m, 0, sizeof m);
    if (mach_msg(&m.msg.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof m, vr_port, 2000, MACH_PORT_NULL) == KERN_SUCCESS &&
        m.msg.swapchain_id == sc->id && sc->id < 16) {
      for (uint32_t i = 0; i < m.msg.image_count; i++) {
        vr_surf[sc->id][i] = IOSurfaceLookupFromMachPort(m.msg.ports[i].name);
        mach_port_deallocate(mach_task_self(), m.msg.ports[i].name);
      }
      vr_fmt[sc->id] = sc->pixel_format;
    }
  }
  return r;
}
static int vr_next(int fd, uint32_t type, void *buf, size_t n) {
  for (int i = 0; i < 16; i++) {
    if (vr_recv(fd, buf, n, 3000) <= 0) return 0;
    if (((struct vrl_header *)buf)->type == type) return 1;
  }
  return 0;
}
static uint32_t pattern(int eye, uint32_t x, uint32_t y) { return 0xff000000u | ((eye ? 0x00ff00u : 0x0000ffu) ^ (((x * 3 + y * 5) & 0xff) << 16)); }
static int surface_matches(IOSurfaceRef s, int eye, uint32_t ox, uint32_t oy, uint32_t w, uint32_t h) {
  IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL);
  const uint8_t *b = IOSurfaceGetBaseAddress(s); size_t bpr = IOSurfaceGetBytesPerRow(s);
  int ok = IOSurfaceGetWidth(s) == w && IOSurfaceGetHeight(s) == h;
  for (uint32_t y = 0; ok && y < h; y++)
    for (uint32_t x = 0; ok && x < w; x++) ok = ((const uint32_t *)(b + y * bpr))[x] == pattern(eye, ox + x, oy + y);
  IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
  return ok;
}
static void test_vr(id<MTLDevice> dev) {
  struct unixcall_wmtvr_submit sub;
  memset(&sub, 0, sizeof sub);
  CHECK(wmtr_vr_submit(NULL, &sub.info) == (int)0xC00000BB, "no exporter: not STATUS_NOT_SUPPORTED");
  char name[64]; snprintf(name, sizeof name, "com.steamac.vrhost.test.%d", (int)getpid());
  mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &vr_port);
  mach_port_insert_right(mach_task_self(), vr_port, vr_port, MACH_MSG_TYPE_MAKE_SEND);
  kern_return_t kr = bootstrap_register2(bootstrap_port, name, vr_port, 0);
  CHECK(kr == KERN_SUCCESS, "bootstrap_register2: %d", kr);
  int sv[2]; socketpair(AF_UNIX, SOCK_DGRAM, 0, sv);
  struct wmtr_vr *vr = wmtr_vr_create(sv[0], name);
  wmtr_host_set_vr(H, vr);
  union { struct vrl_header h; struct vrl_hello hello; struct vrl_submit s; uint8_t raw[1024]; } u;
  CHECK(vr_next(sv[1], VRL_HELLO, &u, sizeof u) && u.hello.version == VRL_VERSION, "no VRL_HELLO");
  /* two eye textures: an atlas-style left eye (sub-rect) and a whole right eye */
  id<MTLTexture> tex[2];
  uint32_t TW = 320, TH = 200;
  for (int e = 0; e < 2; e++) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB width:TW height:TH mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    tex[e] = [dev newTextureWithDescriptor:d];
    uint32_t *px = malloc(TW * TH * 4);
    for (uint32_t y = 0; y < TH; y++) for (uint32_t x = 0; x < TW; x++) px[y * TW + x] = pattern(e, x, y);
    [tex[e] replaceRegion:MTLRegionMake2D(0, 0, TW, TH) mipmapLevel:0 withBytes:px bytesPerRow:TW * 4];
    free(px);
  }
  /* the guest's rendering is ordered through a shared event: the export must wait for it */
  id<MTLSharedEvent> ev = [dev newSharedEvent];
  sub.info.frame_id = 7; sub.info.display_time = 123456789;
  sub.info.eye[0] = (struct WMTVREye){(obj_handle_t)tex[0], 16, 8, 256, 128, WMTVR_EYE_FLIP_Y, 0};
  sub.info.eye[1] = (struct WMTVREye){(obj_handle_t)tex[1], 0, 0, 0, 0, 0, 0};
  for (int e = 0; e < 2; e++) {
    float pose[7] = {0, 0, 0, 1, e ? 0.032f : -0.032f, 1.6f, 0};
    float fov[4] = {-0.9f, 0.8f, 0.85f, -0.95f};
    memcpy(sub.info.pose[e], pose, sizeof pose); memcpy(sub.info.fov[e], fov, sizeof fov);
  }
  sub.info.wait_event = (obj_handle_t)ev; sub.info.wait_value = 1;
  remote(146, &sub);
  struct unixcall_generic_obj_uint64_ret sync = {0}; remote(39, &sync);
  /* not signalled yet: nothing may arrive */
  struct pollfd pf = {sv[1], POLLIN, 0};
  int got_early = 0;
  while (poll(&pf, 1, 200) == 1) { vr_recv(sv[1], &u, sizeof u, 0); if (u.h.type == VRL_SUBMIT) got_early = 1; }
  CHECK(!got_early, "VRL_SUBMIT before the guest's work completed");
  ev.signaledValue = 1;
  int ok = vr_next(sv[1], VRL_SUBMIT, &u, sizeof u);
  CHECK(ok && u.s.frame_id == 7 && u.s.display_time == 123456789 && u.s.ready_time >= u.s.app_submit_time, "VRL_SUBMIT");
  if (ok) {
    CHECK(u.s.eye[0].w == 256 && u.s.eye[0].h == 128 && (u.s.eye[0].flags & VRL_EYE_FLIP_Y) && u.s.eye[1].w == TW && u.s.eye[1].h == TH,
          "eye rects %ux%u %ux%u", u.s.eye[0].w, u.s.eye[0].h, u.s.eye[1].w, u.s.eye[1].h);
    CHECK(u.s.pose[1][4] == 0.032f && u.s.fov[0][3] == -0.95f, "pose/fov not passed through");
    for (int e = 0; e < 2; e++) {
      IOSurfaceRef sf = u.s.eye[e].swapchain < 16 ? vr_surf[u.s.eye[e].swapchain][u.s.eye[e].image] : NULL;
      CHECK(sf && vr_fmt[u.s.eye[e].swapchain] == MTLPixelFormatRGBA8Unorm_sRGB, "eye %d: no surface", e);
      if (sf) CHECK(surface_matches(sf, e, e ? 0 : 16, e ? 0 : 8, e ? TW : 256, e ? TH : 128), "eye %d pixels differ", e);
    }
  }
  /* back-pressure: 3 images per eye, one still held by the host -> of 3 more frames, 2 go out and 1 drops */
  struct vrl_submit held = u.s;
  sub.info.wait_event = 0; sub.info.wait_value = 0;
  for (int i = 0; i < 3; i++) { sub.info.frame_id = 8 + i; remote(146, &sub); }
  remote(39, &sync);
  int n = 0;
  while (n < 2 && vr_next(sv[1], VRL_SUBMIT, &u, sizeof u)) n++;
  struct wmtr_vr_stats st; wmtr_vr_get_stats(vr, &st);
  CHECK(n == 2 && st.dropped == 1 && st.swapchains == 2, "back-pressure: %d sent, %llu dropped, %llu swapchains", n, st.dropped, st.swapchains);
  /* releasing the held image lets the next frame through */
  struct vrl_release rel = {{VRL_RELEASE, sizeof rel}, held.eye[0].swapchain, held.eye[0].image, held.frame_id, 0};
  send(sv[1], &rel, sizeof rel, 0);
  rel.swapchain = held.eye[1].swapchain; rel.image = held.eye[1].image; send(sv[1], &rel, sizeof rel, 0);
  sub.info.frame_id = 20; remote(146, &sub); remote(39, &sync);
  CHECK(vr_next(sv[1], VRL_SUBMIT, &u, sizeof u) && u.s.frame_id == 20, "frame after release not sent");
  /* a size change recreates the swapchain (new ports, new id) */
  sub.info.eye[0].w = 128; sub.info.eye[0].h = 64; sub.info.frame_id = 21;
  remote(146, &sub); remote(39, &sync);
  /* all images of eye 1 may be busy now; free everything first */
  ok = vr_next(sv[1], VRL_SUBMIT, &u, sizeof u);
  wmtr_vr_get_stats(vr, &st);
  CHECK(st.swapchains == 3, "resize: %llu swapchains", st.swapchains);
  /* a bad handle (MSAA / missing) is rejected without touching the link */
  sub.info.eye[1].texture = 0; uint64_t errs = st.errors;
  CHECK(wmtr_vr_submit(vr, &sub.info) == (int)0xC000000D, "null eye texture accepted");
  wmtr_vr_get_stats(vr, &st);
  CHECK(st.errors == errs + 1, "error not counted");
  wmtr_host_set_vr(H, NULL);
  wmtr_vr_destroy(vr);
  close(sv[1]);
  [tex[0] release]; [tex[1] release]; [ev release];
  printf("vr: submits=%llu sent=%llu dropped=%llu released=%llu swapchains=%llu\n", st.submits, st.sent, st.dropped, st.released, st.swapchains);
}

/* WMTR_VR_FD (steamac-vm's attach path): the first context claims a dup of the launcher's socketpair end, a
 * second one gets none while the first lives, and destroying the owner leaves the launcher's end (and so the
 * host's session) open for the next context. */
static void *pages(uint64_t n);
static struct wmtr_host *idle_host(void) {
  struct wmtr_ring *R = pages(1 << 20);
  R->magic = WMTR_RING_MAGIC; R->version = WMTR_VERSION;
  return wmtr_host_create(R, &host_ops, NULL);
}
static void test_vr_fd(void) {
  char name[64]; snprintf(name, sizeof name, "com.steamac.vrhost.fdtest.%d", (int)getpid());
  mach_port_t port;
  mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
  mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
  CHECK(bootstrap_register2(bootstrap_port, name, port, 0) == KERN_SUCCESS, "bootstrap_register2");
  int sv[2]; socketpair(AF_UNIX, SOCK_DGRAM, 0, sv);
  char fd[16]; snprintf(fd, sizeof fd, "%d", sv[0]);
  setenv("WMTR_VR_FD", fd, 1); setenv("WMTR_VR_MACH_NAME", name, 1);
  union { struct vrl_header h; struct vrl_hello hello; uint8_t raw[1024]; } u;
  struct wmtr_host *a = idle_host();
  CHECK(vr_recv(sv[1], &u, sizeof u, 2000) > 0 && u.h.type == VRL_HELLO, "WMTR_VR_FD: first context sent no VRL_HELLO");
  struct wmtr_host *b = idle_host();
  CHECK(vr_recv(sv[1], &u, sizeof u, 300) <= 0, "WMTR_VR_FD: second context attached too");
  wmtr_host_destroy(b);
  wmtr_host_destroy(a);
  CHECK(fcntl(sv[0], F_GETFD) != -1, "WMTR_VR_FD: launcher's end closed");
  struct wmtr_host *c = idle_host();
  CHECK(vr_recv(sv[1], &u, sizeof u, 2000) > 0 && u.h.type == VRL_HELLO, "WMTR_VR_FD: link not reusable after the owner ended");
  wmtr_host_destroy(c);
  unsetenv("WMTR_VR_FD"); unsetenv("WMTR_VR_MACH_NAME");
  close(sv[0]); close(sv[1]);
  printf("vr fd attach: ok\n");
}

static char frames_path[64];
int main(void) {
  @autoreleasepool {
    snprintf(frames_path, sizeof frames_path, "/tmp/wmtr_frames_%d.csv", (int)getpid());
    unlink(frames_path);
    setenv("WMTR_FRAMES", frames_path, 1);
    char stats_path[] = "/tmp/wmtr_callstats_XXXXXX";
    close(mkstemp(stats_path));
    /* WMTR_TEST_TRIGGER=1: statistics turned on at runtime through the trigger file instead of the environment */
    int trigger_mode = getenv("WMTR_TEST_TRIGGER") != NULL;
    char trigger_path[64];
    snprintf(trigger_path, sizeof trigger_path, "/tmp/wmtr_trigger_%d", (int)getpid());
    if (trigger_mode) {
      unsetenv("WMTR_CALLSTATS");
      setenv("WMTR_CALLSTATS_TRIGGER", trigger_path, 1);
      setenv("WMTR_CALLSTATS_POLL_MS", "20", 1);
      FILE *tf = fopen(trigger_path, "w");
      fprintf(tf, "%s\n", stats_path);
      fclose(tf);
    } else {
      setenv("WMTR_CALLSTATS", stats_path, 1);
    }
    /* 1. output buffer through a uint64 pointer field */
    char a[32] = {0}, b[32] = {0};
    struct unixcall_nsstring_getcstring pa = {(obj_handle_t)"metal string", (uint64_t)(uintptr_t)a, sizeof a, 4, 0}, pb = pa;
    pb.buffer_ptr = (uint64_t)(uintptr_t)b;
    native(8, &pa); remote(8, &pb);
    CHECK(!strcmp(a, b) && pb.ret == 1 && pb.buffer_ptr == (uint64_t)(uintptr_t)b, "getCString: '%s' vs '%s'", a, b);
    if (trigger_mode) usleep(200000); /* the first call started the statistics thread; it sees the trigger */

    /* 2. C-string input in a uint64 arg, value result */
    struct unixcall_generic_obj_uint64_obj_ret fa = {5, (uint64_t)(uintptr_t)"vertex_main", 0}, fb = fa;
    native(26, &fa); remote(26, &fb);
    CHECK(fa.ret == fb.ret, "newFunction ret %llu vs %llu", fa.ret, fb.ret);

    /* 3. command list with embedded pointers (async call, then a sync call orders it) */
    struct WMTViewport vps[3] = {{0, 0, 640, 480, 0, 1}, {0, 0, 320, 240, 0, 1}, {0, 0, 7, 7, 0, 1}};
    uint8_t bytes[300]; for (int i = 0; i < 300; i++) bytes[i] = (uint8_t)(i * 13);
    struct wmtcmd_render_setviewports cv = {0}; cv.type = WMTRenderCommandSetViewports; cv.viewports.ptr = vps; cv.viewport_count = 3;
    struct wmtcmd_render_setbytes cbytes = {0}; cbytes.type = WMTRenderCommandSetFragmentBytes; cbytes.bytes.ptr = bytes; cbytes.length = 300; cbytes.index = 2;
    struct wmtcmd_base nop = {0}; nop.type = WMTRenderCommandNop;
    cv.next.ptr = &cbytes; cbytes.next.ptr = &nop; nop.next.ptr = NULL;
    struct unixcall_generic_obj_cmd_noret ce = {0x1234, {&cv}};
    native(38, &ce);
    uint64_t n_sum = encode_sum; uint32_t n_cmds = encode_cmds, n_vp = encode_vp;
    encode_sum = 0; encode_cmds = 0; encode_vp = 0;
    remote(38, &ce);
    remote(26, &fb); /* sync: the async encode before it has executed */
    CHECK(n_sum == encode_sum && n_cmds == encode_cmds && n_vp == encode_vp, "encode sum %llu/%llu cmds %u/%u vp %u/%u",
          n_sum, encode_sum, n_cmds, encode_cmds, n_vp, encode_vp);

    /* 3b. a command list longer than any fixed relocation budget (DXMT batches ~100+ draws per call) */
    {
      enum { N = 2000 };
      static struct wmtcmd_render_setbytes cmds[N]; static uint8_t payload[N][16];
      for (int i = 0; i < N; i++) {
        memset(&cmds[i], 0, sizeof cmds[i]); cmds[i].type = WMTRenderCommandSetFragmentBytes;
        for (int k = 0; k < 16; k++) payload[i][k] = (uint8_t)(i + k);
        cmds[i].bytes.ptr = payload[i]; cmds[i].length = 16; cmds[i].next.ptr = i + 1 < N ? &cmds[i + 1] : NULL;
      }
      struct unixcall_generic_obj_cmd_noret cl = {0x1234, {&cmds[0]}};
      encode_sum = 0; encode_cmds = 0; native(38, &cl);
      uint64_t s1 = encode_sum; uint32_t c1 = encode_cmds;
      encode_sum = 0; encode_cmds = 0; NTSTATUS st = remote(38, &cl); remote(26, &fb);
      CHECK(st == 0 && s1 == encode_sum && c1 == encode_cmds, "long list st=%x sum %llu/%llu cmds %u/%u", st, s1, encode_sum, c1, encode_cmds);
    }
    /* 3c. zero-length output array (SM50GetArgumentsInfo of a shader without constant buffers) */
    {
      struct MTL_SM50_SHADER_ARGUMENT none[1];
      struct sm50_get_arguments_info_params ga = {(sm50_shader_t)0x77, none, none};
      NTSTATUS st = remote(88, &ga);
      CHECK(st == 0 && ga.constant_buffers == none, "zero-length output st=%x", st);
    }

    /* 4. large input (arena staging) and large output (arena) */
    uint32_t W = 1024, Hh = 512; uint8_t *src = malloc(W * 4 * Hh), *o1 = malloc(W * 4 * Hh), *o2 = malloc(W * 4 * Hh);
    for (uint32_t i = 0; i < W * 4 * Hh; i++) src[i] = (uint8_t)(i ^ (i >> 9));
    struct unixcall_mtltexture_replaceregion rr = {0}; rr.texture = 0x9000; rr.size = (struct WMTSize){W, Hh, 1};
    rr.data.ptr = src; rr.bytes_per_row = W * 4; rr.level = 3;
    native(45, &rr); uint64_t n_rs = replace_sum; replace_sum = 0;
    remote(45, &rr); remote(26, &fb);
    CHECK(n_rs == replace_sum, "replaceRegion checksum %llu vs %llu", n_rs, replace_sum);
    rr.data.ptr = o1; native(145, &rr); rr.data.ptr = o2; remote(145, &rr);
    CHECK(!memcmp(o1, o2, W * 4 * Hh) && rr.data.ptr == o2, "getBytes output differs");

    /* 5. newBuffer: client arena memory backs a real MTLBuffer; CPU writes are GPU-visible
          (blit to a private buffer and back); release returns the range through the free queue */
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    struct WMTBufferInfo bi = {100000, WMTResourceStorageModeShared, {NULL}, 0};
    struct unixcall_mtldevice_newbuffer nb = {(obj_handle_t)dev, {&bi}, 0};
    remote(18, &nb);
    CHECK(nb.ret && bi.memory.ptr && bi.gpu_address, "newBuffer ret %llx mem %p gpu %llx", nb.ret, bi.memory.ptr, bi.gpu_address);
    if (nb.ret && bi.memory.ptr) {
      id<MTLBuffer> buf = (id<MTLBuffer>)nb.ret;
      memset(bi.memory.ptr, 0x5a, 100000);
      id<MTLBuffer> tmp = [dev newBufferWithLength:100000 options:MTLResourceStorageModeShared];
      id<MTLCommandQueue> q = [dev newCommandQueue];
      id<MTLCommandBuffer> cb = [q commandBuffer];
      id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
      [be copyFromBuffer:buf sourceOffset:0 toBuffer:tmp destinationOffset:0 size:100000];
      [be fillBuffer:buf range:NSMakeRange(0, 64) value:0x11];
      [be endEncoding]; [cb commit]; [cb waitUntilCompleted];
      CHECK(((uint8_t *)tmp.contents)[99999] == 0x5a, "GPU did not see client writes");
      CHECK(((uint8_t *)bi.memory.ptr)[10] == 0x11, "client did not see GPU writes");
      [tmp release]; [q release];
      struct wmtr_ring *R = blob_base[0];
      uint64_t fh = R->free_head;
      obj_handle_t h = nb.ret;
      remote(1, &h); remote(26, &fb);
      for (int i = 0; i < 1000 && R->free_head == fh; i++) usleep(1000);
      CHECK(R->free_head == fh + 1, "buffer range not returned (free_head %llu)", R->free_head);
    }
    /* 6. caller-placed memory (DXMT CpuPlaced): initial bytes kept, pointer replaced by arena memory */
    {
      uint8_t *own; posix_memalign((void **)&own, 16384, 65536); memset(own, 0x3c, 65536);
      struct WMTBufferInfo ci = {65536, WMTResourceStorageModeShared, {own}, 0};
      struct unixcall_mtldevice_newbuffer cb2 = {(obj_handle_t)dev, {&ci}, 0};
      remote(18, &cb2);
      CHECK(cb2.ret && ci.memory.ptr && ci.memory.ptr != own && ((uint8_t *)ci.memory.ptr)[65535] == 0x3c,
            "caller-placed buffer ret %llx mem %p", cb2.ret, ci.memory.ptr);
      free(own);
    }
    test_vr(dev);
    test_vr_fd();
    struct wmtr_host_stats st; wmtr_host_get_stats(H, &st);
    printf("requests=%llu sync=%llu bytes=%llu\n", st.requests, st.sync_requests, st.bytes);
    { /* an autoreleased result outside any client pool must outlive the request (DXMT reads it next) */
      struct unixcall_generic_obj_ret ar = {0};
      remote(53, &ar);
      struct unixcall_generic_obj_uint64_ret pf3 = {0}; remote(39, &pf3);
      CHECK(ar.ret && probe_alive, "autoreleased result without a pool was freed with the request");
    }
    { /* WMTR_FRAMES: a presenting command buffer adds one line when it completes */
      id<MTLCommandQueue> q = [MTLCreateSystemDefaultDevice() newCommandQueue];
      id<MTLCommandBuffer> cb = [q commandBuffer];
      struct unixcall_generic_obj_obj_noret pd = {.handle = (obj_handle_t)cb, .arg = 0};
      remote(47, &pd);
      struct unixcall_generic_obj_uint64_ret pf2 = {0}; remote(39, &pf2); /* the async present is done */
      [cb commit]; [cb waitUntilCompleted];
      usleep(100000); /* completion handlers run after waitUntilCompleted returns */
      FILE *f = fopen(frames_path, "r"); char line[128] = ""; int n = 0; unsigned long long t = 0;
      while (f && fgets(line, sizeof line, f)) { n++; sscanf(line, "%llu,", &t); }
      if (f) fclose(f);
      CHECK(n == 1 && t > 0 && strstr(line, ",0,0,0,0,0"), "WMTR_FRAMES: %d lines, last '%s'", n, line);
      unlink(frames_path);
    }
    { /* views: ReleaseMetalView releases once; views the client never released go on destroy */
      struct unixcall_create_metal_view_from_hwnd v1 = {.hwnd = 1, .device = 2}, v2 = {.hwnd = 3, .device = 2};
      CHECK(remote(72, &v1) == 0 && remote(72, &v2) == 0 && v1.ret_view && v2.ret_view && v1.ret_layer == 0x77,
            "CreateMetalViewFromHWND %llx %llx", v1.ret_view, v2.ret_view);
      struct unixcall_generic_obj_noret r1 = {.handle = v1.ret_view};
      remote(73, &r1);
      remote(73, &r1); /* a second release of the same view is ignored */
      struct unixcall_generic_obj_uint64_ret pf = {0}; remote(39, &pf); /* sync call: the releases above are done */
      CHECK(n_released == 1 && released[0] == v1.ret_view, "ReleaseMetalView: %d releases", n_released);
      /* a call that faults (bad handle) fails, the process lives, and the client is refused from then on */
      struct unixcall_generic_obj_uint64_ret fz = {0};
      NTSTATUS fs = remote(5, &fz);
      struct unixcall_generic_obj_uint64_ret pf4 = {0};
      NTSTATUS fs2 = remote(39, &pf4);
      CHECK(fs == (NTSTATUS)0xC0000005 && fs2 == (NTSTATUS)0xC0000005, "fault containment: %x then %x", fs, fs2);
      { /* executor spin budget: with a budget longer than the gaps between requests it never sleeps */
        struct wmtr_host_stats st0, st1, st2;
        wmtr_host_set_spin(H, 0);
        wmtr_host_get_stats(H, &st0);
        for (int i = 0; i < 20; i++) { struct unixcall_generic_obj_uint64_ret q = {0}; remote(39, &q); usleep(300); }
        wmtr_host_get_stats(H, &st1);
        wmtr_host_set_spin(H, 20000000);
        { struct unixcall_generic_obj_uint64_ret q = {0}; remote(39, &q); }
        wmtr_host_get_stats(H, &st1);
        for (int i = 0; i < 20; i++) { struct unixcall_generic_obj_uint64_ret q = {0}; remote(39, &q); usleep(300); }
        wmtr_host_get_stats(H, &st2);
        CHECK(st1.idle_sleeps - st0.idle_sleeps >= 15, "no spin: %llu sleeps in 20 gaps", st1.idle_sleeps - st0.idle_sleeps);
        CHECK(st2.idle_sleeps - st1.idle_sleeps <= 1, "20 ms spin: %llu sleeps in 20 gaps of 0.3 ms", st2.idle_sleeps - st1.idle_sleeps);
        wmtr_host_set_spin(H, WMTR_HOST_SPIN_US_DEFAULT * 1000);
      }
      wmtr_host_destroy(H);
      CHECK(n_released == 2 && released[1] == v2.ret_view, "destroy did not release the leftover view (%d releases)", n_released);
      /* WMTR_CALLSTATS: destroy wrote a snapshot; call 39 (sync, above) is in it with its sync count */
      FILE *sf = fopen(stats_path, "r");
      char sl[256]; int found = 0;
      while (sf && fgets(sl, sizeof sl, sf)) {
        unsigned long long t, n, sy, ns; int call; char name[96]; unsigned cls;
        if (sscanf(sl, "%llu,%d,%95[^,],%u,%llu,%llu,%llu", &t, &call, name, &cls, &n, &sy, &ns) == 7 && call == 39 && n >= 1 && sy >= 1)
          found = 1;
      }
      if (sf) fclose(sf);
      CHECK(found, "WMTR_CALLSTATS: no snapshot line for call 39");
      sf = fopen(stats_path, "r"); found = 0;
      while (sf && fgets(sl, sizeof sl, sf)) if (strstr(sl, ",200,_executor_sleeps,9,")) found = 1;
      if (sf) fclose(sf);
      CHECK(found, "WMTR_CALLSTATS: no executor sleep row");
      unlink(stats_path);
      unlink(trigger_path);
    }
  }
  printf(failures ? "wmtr_loopback: %d FAILED\n" : "wmtr_loopback: all passed\n", failures);
  return failures != 0;
}
