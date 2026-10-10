/* wmtr_loopback: client and host executor in one process over an in-memory transport.
 * Oracle: each test calls a winemetal entry once directly (the native path: the implementation
 * reads the caller's memory) and once through __wine_unix_call_funcs of the wmtr client (params
 * relocated into the ring, executed by the host, outputs copied back). Results must be identical.
 * The implementations are small fakes with the real param layouts, plus real Metal for newBuffer. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
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
static NTSTATUS f_pixelformat(void *a) { ((struct unixcall_generic_obj_uint64_ret *)a)->ret = 70; return 0; } /* RGBA8 */
static NTSTATUS f_release(void *a) { [(id)*(obj_handle_t *)a release]; return 0; }
static NTSTATUS f_newfunction(void *a) {
  struct unixcall_generic_obj_uint64_obj_ret *p = a;
  p->ret = strlen((const char *)(uintptr_t)p->arg) * 1000 + p->handle;
  return 0;
}
const void *wmtr_impl_funcs[146] = {[1] = f_release, [8] = f_getcstring, [26] = f_newfunction, [38] = f_render_encode,
                                    [39] = f_pixelformat, [45] = f_replace, [145] = f_getbytes};

/* ---------------- loopback transport ---------------- */
static struct wmtr_host *H;
static void *blob_base[WMTR_MAX_BLOBS]; static uint64_t blob_size[WMTR_MAX_BLOBS];
static void *t_blob_ptr(void *c, uint32_t b, uint64_t *s) { *s = blob_size[b]; return blob_base[b]; }
static void t_wake(void *c, uint32_t s) {}
static const struct wmtr_host_ops host_ops = {t_blob_ptr, t_wake, NULL, NULL, NULL};
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
static void t_wait(struct wmtr_transport *t, volatile uint64_t *d, uint64_t seq, uint32_t slot) { while (__atomic_load_n(d, __ATOMIC_ACQUIRE) < seq) sched_yield(); }
struct wmtr_transport *wmtr_transport_create(void) {
  struct wmtr_transport *t = calloc(1, sizeof *t);
  t->open_ring = t_open_ring; t->add_blob = t_add_blob; t->kick = t_kick; t->wait = t_wait;
  return t;
}
static NTSTATUS remote(int call, void *p) { return ((fn_t)__wine_unix_call_funcs[call])(p); }
static NTSTATUS native(int call, void *p) { return ((fn_t)wmtr_impl_funcs[call])(p); }

int main(void) {
  @autoreleasepool {
    /* 1. output buffer through a uint64 pointer field */
    char a[32] = {0}, b[32] = {0};
    struct unixcall_nsstring_getcstring pa = {(obj_handle_t)"metal string", (uint64_t)(uintptr_t)a, sizeof a, 4, 0}, pb = pa;
    pb.buffer_ptr = (uint64_t)(uintptr_t)b;
    native(8, &pa); remote(8, &pb);
    CHECK(!strcmp(a, b) && pb.ret == 1 && pb.buffer_ptr == (uint64_t)(uintptr_t)b, "getCString: '%s' vs '%s'", a, b);

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
    struct wmtr_host_stats st; wmtr_host_get_stats(H, &st);
    printf("requests=%llu sync=%llu bytes=%llu\n", st.requests, st.sync_requests, st.bytes);
  }
  printf(failures ? "wmtr_loopback: %d FAILED\n" : "wmtr_loopback: all passed\n", failures);
  return failures != 0;
}
