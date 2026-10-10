/* wmtr host executor. Consumes the request ring in order on one thread; calls that may block or
 * compile shaders/pipelines run on dispatch queues (their callers wait for the reply, so program
 * order between client threads is preserved: anything that depends on such a call is enqueued only
 * after its reply). The Metal work itself is DXMT's winemetal_unix.c (wmtr_impl_funcs), unchanged,
 * except for the calls overridden here (memory, presentation, events, paths). */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <pthread.h>
#include <time.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define WINEMETAL_API
#include "winemetal_thunks.h"
#include "airconv_thunks.h"
#include "wmtr_wire.h"
#include "wmtr_host.h"

typedef int NTSTATUS;
typedef NTSTATUS (*impl_fn)(void *);
extern const void *wmtr_impl_funcs[];

#define STATUS_SUCCESS 0
#define STATUS_UNSUCCESSFUL ((NTSTATUS)0xC0000001)
#define STATUS_INVALID_PARAMETER ((NTSTATUS)0xC000000D)

#define WMTR_CLASS_A 0
#define WMTR_CLASS_S 1
#define WMTR_CLASS_B 2
#define WMTR_CLASS_C 3
#define WMTR_CLASS_N 4
static const uint8_t call_class[146] = {
#define X(i, n, t, c) [i] = WMTR_CLASS_##c,
#include "wmtr_calls.inc"
#undef X
};

struct wmtr_host {
  struct wmtr_ring *ring;
  uint8_t *data;
  struct wmtr_slot *slots;
  const struct wmtr_host_ops *ops;
  void *ctx;
  pthread_t thread;
  pthread_mutex_t lock;
  pthread_cond_t cond;
  int kicked, quit;
  dispatch_queue_t compile_q, block_q;
  pthread_mutex_t free_lock, event_lock;
  /* views the client created and has not released: released on destroy, so a client that exits
   * without ReleaseMetalView (DXMT never calls it at process exit) does not leave its layer behind */
  pthread_mutex_t view_lock;
  uint64_t *views;
  uint32_t n_views, cap_views;
  _Atomic uint64_t n_req, n_sync, n_bytes, n_worker, n_sleep;
};

static int log_level = 1;
#define LOG(lvl, ...) do { if (log_level >= (lvl)) fprintf(stderr, "wmtr-host: " __VA_ARGS__); } while (0)

/* ------------------------------------------------------------------------------------------- *
 * per-frame export (WMTR_FRAMES=<path>): one line per presented frame, in the steamac launcher's
 * STEAMAC_PERF_FRAMES format (t_ns,flush_ms,shown_ms,copy_ms,upload_ms,vsyncs) so its frame_stats.py
 * reads it unchanged. t_ns = completion of the command buffer that presents the drawable, on the mach
 * clock (CLOCK_UPTIME_RAW, the base of CACurrentMediaTime and of Python's time.monotonic_ns on macOS);
 * the other columns are 0 (they describe the scanout copy path, which wmtr frames do not take). Off
 * (one getenv) unless set. */
static pthread_mutex_t frames_lock = PTHREAD_MUTEX_INITIALIZER;
static FILE *
frames_out(void) {
  static FILE *f;
  static int tried;
  if (!tried) {
    pthread_mutex_lock(&frames_lock);
    if (!tried) {
      const char *p = getenv("WMTR_FRAMES");
      if (p && *p) {
        f = fopen(p, "a");
        if (f) setvbuf(f, NULL, _IOLBF, 0);
      }
      __atomic_store_n(&tried, 1, __ATOMIC_RELEASE);
    }
    pthread_mutex_unlock(&frames_lock);
  }
  return f;
}

static void
frame_record_on_completion(id<MTLCommandBuffer> cb) {
  [cb addCompletedHandler:^(id<MTLCommandBuffer> b) {
    (void)b;
    uint64_t t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    pthread_mutex_lock(&frames_lock);
    fprintf(frames_out(), "%llu,0,0,0,0,0\n", (unsigned long long)t);
    pthread_mutex_unlock(&frames_lock);
  }];
}

/* ------------------------------------------------------------------------------------------- */
static void
view_track(struct wmtr_host *h, uint64_t v) {
  pthread_mutex_lock(&h->view_lock);
  if (h->n_views == h->cap_views) {
    uint32_t cap = h->cap_views ? h->cap_views * 2 : 4;
    uint64_t *n = realloc(h->views, cap * sizeof *n);
    if (n) { h->views = n; h->cap_views = cap; }
  }
  if (h->n_views < h->cap_views) h->views[h->n_views++] = v;
  pthread_mutex_unlock(&h->view_lock);
}

/* 1 if `v` was a live view of this client (then it is no longer tracked) */
static int
view_untrack(struct wmtr_host *h, uint64_t v) {
  int found = 0;
  pthread_mutex_lock(&h->view_lock);
  for (uint32_t i = 0; i < h->n_views; i++)
    if (h->views[i] == v) { h->views[i] = h->views[--h->n_views]; found = 1; break; }
  pthread_mutex_unlock(&h->view_lock);
  return found;
}

static void *
resolve(struct wmtr_host *h, uint64_t v, uint8_t *payload, uint32_t payload_size) {
  uint64_t tag = v & WMTR_REF_MASK;
  if (tag == WMTR_REF_EXTRA) {
    uint32_t off = (uint32_t)v;
    return off < payload_size ? payload + off : NULL;
  }
  if (tag == WMTR_REF_ARENA) {
    uint32_t blob = (uint32_t)((v >> 32) & 0xffff), off = (uint32_t)v;
    uint64_t size = 0;
    uint8_t *b = h->ops->blob_ptr(h->ctx, blob, &size);
    return (b && off < size) ? b + off : NULL;
  }
  return NULL;
}

static void
reply(struct wmtr_host *h, const struct wmtr_req_ext *r, const struct wmtr_out *outs, uint8_t *payload,
      NTSTATUS st) {
  if (!(r->h.flags & WMTR_F_SYNC) || r->h.slot >= WMTR_SLOTS) return;
  struct wmtr_slot *s = &h->slots[r->h.slot];
  uint32_t o = r->h.params_size;
  memcpy(s->data, payload, o);
  o = WMTR_ALIGN8(o);
  for (int i = 0; i < r->n_out; i++) {
    if (!outs[i].size) continue; /* arena output: already in shared memory */
    if (o + outs[i].size > WMTR_SLOT_BYTES || outs[i].off + outs[i].size > r->payload_size) break;
    memcpy(s->data + o, payload + outs[i].off, outs[i].size);
    o += WMTR_ALIGN8(outs[i].size);
  }
  s->status = (uint32_t)st;
  s->out_size = o;
  __atomic_store_n(&s->done_seq, r->h.seq, __ATOMIC_RELEASE);
  __atomic_thread_fence(__ATOMIC_SEQ_CST);
  if (__atomic_load_n(&s->waiting, __ATOMIC_SEQ_CST)) h->ops->wake(h->ctx, r->h.slot);
}

/* ------------------------------------------------------------------------------------------- *
 * virtual autorelease pools. Natively each Wine thread runs its unix calls on its own OS thread and
 * DXMT brackets work in NSAutoreleasePools, relying on them to keep autoreleased results alive. Here
 * all client threads share host threads, so real pools would interleave. Instead each client thread
 * (reply slot) has a stack of virtual pools; results that DXMT's implementation returns autoreleased
 * are retained into the slot's current virtual pool and released when DXMT releases that pool. */
struct vpool {
  struct vpool *parent;
  uint32_t slot, used;
  id *objs;
  uint32_t n, cap;
};
#define VPOOLS 4096
static struct vpool vpools[VPOOLS];
static pthread_mutex_t vpool_lock = PTHREAD_MUTEX_INITIALIZER;
static struct vpool *vpool_top[WMTR_SLOTS];

static int
is_vpool(uint64_t h) {
  return h >= (uint64_t)(uintptr_t)&vpools[0] && h < (uint64_t)(uintptr_t)&vpools[VPOOLS] &&
         (h - (uint64_t)(uintptr_t)&vpools[0]) % sizeof(struct vpool) == 0;
}

static uint64_t
vpool_push(uint32_t slot) {
  pthread_mutex_lock(&vpool_lock);
  struct vpool *p = NULL;
  for (int i = 0; i < VPOOLS; i++) if (!vpools[i].used) { p = &vpools[i]; break; }
  if (p) {
    p->used = 1; p->slot = slot; p->n = 0;
    p->parent = slot < WMTR_SLOTS ? vpool_top[slot] : NULL;
    if (slot < WMTR_SLOTS) vpool_top[slot] = p;
  }
  pthread_mutex_unlock(&vpool_lock);
  return (uint64_t)(uintptr_t)p;
}

static void
vpool_pop(struct vpool *target) {
  pthread_mutex_lock(&vpool_lock);
  uint32_t slot = target->slot;
  struct vpool *p = slot < WMTR_SLOTS ? vpool_top[slot] : target;
  /* release `target` and every pool pushed after it (released out of order = drained with it) */
  while (p) {
    struct vpool *parent = p->parent;
    for (uint32_t i = 0; i < p->n; i++) [p->objs[i] release];
    p->n = 0; p->used = 0;
    if (p == target) { p = parent; break; }
    p = parent;
  }
  if (slot < WMTR_SLOTS) vpool_top[slot] = p;
  pthread_mutex_unlock(&vpool_lock);
}

static void
vpool_keep(uint32_t slot, uint64_t obj) {
  if (!obj || slot >= WMTR_SLOTS) return;
  pthread_mutex_lock(&vpool_lock);
  struct vpool *p = vpool_top[slot];
  if (p) {
    if (p->n == p->cap) { p->cap = p->cap ? p->cap * 2 : 64; p->objs = realloc(p->objs, p->cap * sizeof(id)); }
    p->objs[p->n++] = [(id)obj retain];
  }
  pthread_mutex_unlock(&vpool_lock);
}

/* results returned autoreleased by DXMT's winemetal_unix.c (4ddb20e); +1 (new/alloc/copy) results and
 * non-object handles are not listed */
static void
keep_autoreleased(uint32_t slot, uint16_t call, uint8_t *params) {
  switch (call) {
  case 2: case 7: case 11: case 28: case 30: case 31: case 32: case 53: case 60: case 62: case 66: case 67:
  case 89: case 90: case 129: {
    /* `ret` is the last obj_handle_t of these generic structs; locate it by call */
    uint64_t ret = 0;
    switch (call) {
    case 2: case 31: case 32: ret = ((struct unixcall_generic_obj_uint64_obj_ret *)params)->ret; break;
    case 53: case 62: ret = ((struct unixcall_generic_obj_ret *)params)->ret; break;
    case 60: ret = ((struct unixcall_nsstring_string *)params)->ret; break;
    case 129: ret = ((struct unixcall_mtlcommandbuffer_blitcommandencoderwithsamplebuffers *)params)->ret; break;
    default: ret = ((struct unixcall_generic_obj_obj_ret *)params)->ret; break;
    }
    vpool_keep(slot, ret);
    break;
  }
  case 25: vpool_keep(slot, ((struct unixcall_mtldevice_newlibrary *)params)->ret_error); break;
  case 29: vpool_keep(slot, ((struct unixcall_mtldevice_newcomputepso *)params)->ret_error); break;
  case 34: case 131: vpool_keep(slot, ((struct unixcall_mtldevice_newrenderpso *)params)->ret_error); break;
  case 35: vpool_keep(slot, ((struct unixcall_mtldevice_newmeshrenderpso *)params)->ret_error); break;
  case 98: vpool_keep(slot, ((struct unixcall_mtllibrary_newfunction_with_constants *)params)->ret_error); break;
  case 112: vpool_keep(slot, ((struct unixcall_mtldevice_newbinaryarchive *)params)->ret_error); break;
  case 113: vpool_keep(slot, ((struct unixcall_mtlbinaryarchive_serialize *)params)->ret_error); break;
  case 132: vpool_keep(slot, ((struct unixcall_mtldevice_newresidencyset *)params)->ret_error); break;
  case 144: vpool_keep(slot, ((struct unixcall_mtldevice_newlibrarywithsource *)params)->ret_error); break;
  default: break;
  }
}

/* ------------------------------------------------------------------------------------------- *
 * overridden calls */
static void
push_free(struct wmtr_host *h, uint32_t blob, uint32_t off, uint64_t size) {
  pthread_mutex_lock(&h->free_lock);
  struct wmtr_ring *R = h->ring;
  uint64_t head = R->free_head;
  while (head - __atomic_load_n(&R->free_tail, __ATOMIC_ACQUIRE) >= WMTR_FREE_RING) {
    pthread_mutex_unlock(&h->free_lock); /* client drains on its next allocation */
    usleep(100);
    pthread_mutex_lock(&h->free_lock);
    head = R->free_head;
  }
  R->free_ring[head % WMTR_FREE_RING] = (struct wmtr_free_entry){blob, off, (uint32_t)size, 0};
  __atomic_store_n(&R->free_head, head + 1, __ATOMIC_RELEASE);
  pthread_mutex_unlock(&h->free_lock);
}

static NTSTATUS
host_new_buffer(struct wmtr_host *h, struct unixcall_mtldevice_newbuffer *p, uint64_t arena_ref) {
  id<MTLDevice> device = (id<MTLDevice>)p->device;
  struct WMTBufferInfo *info = p->info.ptr;
  id<MTLBuffer> buffer;
  if (info->memory.ptr) {
    uint32_t blob = (uint32_t)((arena_ref >> 32) & 0xffff), off = (uint32_t)arena_ref;
    uint64_t len = (info->length + WMTR_PAGE - 1) & ~(uint64_t)(WMTR_PAGE - 1);
    buffer = [device newBufferWithBytesNoCopy:info->memory.ptr
                                       length:len
                                      options:(MTLResourceOptions)info->options
                                  deallocator:^(void *pointer, NSUInteger length) {
                                    push_free(h, blob, off, length);
                                  }];
  } else {
    buffer = [device newBufferWithLength:info->length options:(MTLResourceOptions)info->options];
  }
  info->memory.ptr = NULL; /* the client keeps its own mapping */
  p->ret = (obj_handle_t)buffer;
  info->gpu_address = buffer ? [buffer gpuAddress] : 0;
  return buffer ? STATUS_SUCCESS : STATUS_UNSUCCESSFUL;
}

struct host_listener { MTLSharedEventListener *listener; };

static void
push_event(struct wmtr_host *h, uint64_t listener, uint64_t event_handle) {
  pthread_mutex_lock(&h->event_lock);
  struct wmtr_ring *R = h->ring;
  uint64_t head = R->event_head;
  if (head - __atomic_load_n(&R->event_tail, __ATOMIC_ACQUIRE) < WMTR_EVENT_RING) {
    R->event_ring[head % WMTR_EVENT_RING] = (struct wmtr_event){listener, event_handle};
    __atomic_store_n(&R->event_head, head + 1, __ATOMIC_RELEASE);
  } else LOG(0, "event ring full, dropping\n");
  pthread_mutex_unlock(&h->event_lock);
  h->ops->wake(h->ctx, WMTR_EVENT_SLOT);
}

static NTSTATUS
host_call(struct wmtr_host *h, uint16_t call, uint8_t *params, const struct wmtr_req_ext *r, const uint32_t *relocs,
          const uint64_t *orig) {
  switch (call) {
  case 0: /* NSObject_retain */
    if (is_vpool(*(uint64_t *)params)) return STATUS_SUCCESS;
    break;
  case 1: /* NSObject_release: a virtual pool drains */
    if (is_vpool(*(uint64_t *)params)) { vpool_pop((struct vpool *)(uintptr_t)*(uint64_t *)params); return STATUS_SUCCESS; }
    break;
  case 10: /* NSAutoreleasePool_alloc_init */
    ((struct unixcall_generic_obj_ret *)params)->ret = vpool_push(r->h.slot);
    return ((struct unixcall_generic_obj_ret *)params)->ret ? STATUS_SUCCESS : STATUS_UNSUCCESSFUL;
  case 18: { /* newBuffer: memory field relocation carries the arena reference */
    uint64_t arena_ref = 0;
    struct unixcall_mtldevice_newbuffer *p = (void *)params;
    uint32_t mem_field = 0;
    for (int i = 0; i < r->n_reloc; i++)
      if ((orig[i] & WMTR_REF_MASK) == WMTR_REF_ARENA) { arena_ref = orig[i]; mem_field = relocs[i]; }
    (void)mem_field;
    return host_new_buffer(h, p, arena_ref);
  }
  case 72: { /* CreateMetalViewFromHWND */
    struct unixcall_create_metal_view_from_hwnd *p = (void *)params;
    if (!h->ops->create_view) return STATUS_UNSUCCESSFUL;
    uint64_t layer = 0;
    p->ret_view = h->ops->create_view(h->ctx, p->hwnd, (void *)p->device, &layer);
    p->ret_layer = layer;
    if (p->ret_view) view_track(h, p->ret_view);
    return p->ret_view ? STATUS_SUCCESS : STATUS_UNSUCCESSFUL;
  }
  case 73: {
    uint64_t v = ((struct unixcall_generic_obj_noret *)params)->handle;
    if (view_untrack(h, v) && h->ops->release_view) h->ops->release_view(h->ctx, v);
    return STATUS_SUCCESS;
  }
  case 104: { /* setWin32EventAtValue: queue (listener, handle) for the client to NtSetEvent */
    struct unixcall_mtlsharedevent_setevent *p = (void *)params;
    struct host_listener *l = (struct host_listener *)p->shared_event_listener;
    uint64_t lid = p->shared_event_listener, ev = p->event_handle;
    if (!l) return STATUS_INVALID_PARAMETER;
    [(id<MTLSharedEvent>)p->shared_event notifyListener:l->listener
                                                atValue:p->value
                                                  block:^(id<MTLSharedEvent> e, uint64_t v) {
                                                    push_event(h, lid, ev);
                                                  }];
    return STATUS_SUCCESS;
  }
  case 108: {
    struct host_listener *l = calloc(1, sizeof *l);
    l->listener = [[MTLSharedEventListener alloc] init];
    ((struct unixcall_generic_obj_ret *)params)->ret = (obj_handle_t)l;
    return STATUS_SUCCESS;
  }
  case 110: { /* destroy: tell the client's listener thread to return; the listener object is kept
                 (late notifications for it are harmless and are dropped by the client) */
    uint64_t lid = ((struct unixcall_generic_obj_noret *)params)->handle;
    if (lid) push_event(h, lid, 0);
    return STATUS_SUCCESS;
  }
  case 112: case 113: case 115: case 117: case 119: if (h->ops->map_path) {
    /* the path is the first relocated field of these calls */
    for (int i = 0; i < r->n_reloc; i++) {
      if (relocs[i] >= r->h.params_size) continue;
      char **field = (char **)(params + relocs[i]);
      if (!*field) continue;
      char *buf = malloc(1024);
      const char *m = h->ops->map_path(h->ctx, *field, buf, 1024);
      if (m) *field = (char *)m;
      NTSTATUS st = ((impl_fn)wmtr_impl_funcs[call])(params);
      keep_autoreleased(r->h.slot, call, params);
      free(buf);
      return st;
    }
  }
  /* fallthrough */
  default:
    break;
  }
  impl_fn f = (impl_fn)wmtr_impl_funcs[call];
  if (!f) return STATUS_UNSUCCESSFUL;
  if ((call == 47 || call == 48) && frames_out()) /* presentDrawable: record when the frame is done */
    frame_record_on_completion((id<MTLCommandBuffer>)((struct unixcall_generic_obj_obj_noret *)params)->handle);
  NTSTATUS st = f(params);
  keep_autoreleased(r->h.slot, call, params);
  return st;
}

/* ------------------------------------------------------------------------------------------- */
struct job { struct wmtr_host *h; uint8_t *copy; uint32_t len; };

static void
execute(struct wmtr_host *h, uint8_t *rec, uint32_t len) {
  const struct wmtr_req_ext *r = (const void *)rec;
  const uint32_t *relocs = (const void *)(rec + sizeof *r);
  const struct wmtr_out *outs = (const void *)(rec + sizeof *r + 4u * r->n_reloc);
  uint32_t poff = wmtr_req_payload_offset(r);
  uint8_t *payload = rec + poff;
  if (poff + r->payload_size > len || r->h.params_size > r->payload_size) {
    LOG(0, "malformed request call=%u\n", r->h.call);
    reply(h, r, outs, payload, STATUS_INVALID_PARAMETER);
    return;
  }
  uint64_t orig_small[512];
  uint64_t *orig = r->n_reloc <= 512 ? orig_small : malloc(8u * r->n_reloc);
  int nr = r->n_reloc;
  NTSTATUS st = STATUS_SUCCESS;
  for (int i = 0; i < nr; i++) {
    if (relocs[i] + 8 > r->payload_size) { st = STATUS_INVALID_PARAMETER; break; }
    uint64_t v;
    memcpy(&v, payload + relocs[i], 8);
    orig[i] = v;
    void *p = v ? resolve(h, v, payload, r->payload_size) : NULL;
    if (v && !p) { st = STATUS_INVALID_PARAMETER; LOG(0, "call %u: bad reference %llx\n", r->h.call, (unsigned long long)v); break; }
    memcpy(payload + relocs[i], &p, 8);
  }
  if (st == STATUS_SUCCESS) {
    if (r->h.flags & WMTR_F_CONTROL) {
      st = STATUS_SUCCESS; /* PING and HELLO need no work */
    } else if (r->h.call < 146) {
      @autoreleasepool {
        st = host_call(h, r->h.call, payload, r, relocs, orig);
      }
    } else st = STATUS_INVALID_PARAMETER;
  }
  reply(h, r, outs, payload, st);
  if (orig != orig_small) free(orig);
}

static void
job_run(void *arg) {
  struct job *j = arg;
  execute(j->h, j->copy, j->len);
  free(j->copy);
  free(j);
}

static void *
executor(void *arg) {
  struct wmtr_host *h = arg;
  struct wmtr_ring *R = h->ring;
  uint8_t *scratch = malloc(1 << 20);
  uint32_t scratch_cap = 1 << 20;
  pthread_setname_np("wmtr-executor");
  for (;;) {
    uint64_t tail = R->tail;
    uint64_t head = __atomic_load_n(&R->head, __ATOMIC_ACQUIRE);
    if (tail == head) {
      /* spin briefly, then sleep until kicked */
      int got = 0;
      for (int i = 0; i < 2000 && !got; i++) {
        if (__atomic_load_n(&R->head, __ATOMIC_ACQUIRE) != tail) got = 1;
        else __asm__ __volatile__("yield");
      }
      if (got) continue;
      pthread_mutex_lock(&h->lock);
      __atomic_store_n(&R->host_idle, 1, __ATOMIC_SEQ_CST);
      __atomic_thread_fence(__ATOMIC_SEQ_CST);
      while (!h->quit && !h->kicked && __atomic_load_n(&R->head, __ATOMIC_ACQUIRE) == tail) {
        atomic_fetch_add(&h->n_sleep, 1);
        pthread_cond_wait(&h->cond, &h->lock);
      }
      h->kicked = 0;
      __atomic_store_n(&R->host_idle, 0, __ATOMIC_SEQ_CST);
      int quit = h->quit;
      pthread_mutex_unlock(&h->lock);
      if (quit) break;
      continue;
    }
    uint32_t pos = (uint32_t)(tail % WMTR_RING_BYTES);
    uint32_t to_end = WMTR_RING_BYTES - pos;
    if (to_end < sizeof(struct wmtr_req_ext)) { __atomic_store_n(&R->tail, tail + to_end, __ATOMIC_RELEASE); continue; }
    struct wmtr_req hdr;
    memcpy(&hdr, h->data + pos, sizeof hdr);
    if (hdr.flags & WMTR_F_WRAP) { __atomic_store_n(&R->tail, tail + to_end, __ATOMIC_RELEASE); continue; }
    if (hdr.size < sizeof(struct wmtr_req_ext) || hdr.size > to_end || (hdr.size & 7)) {
      LOG(0, "ring corrupt at %llu (size %u); stopping\n", (unsigned long long)tail, hdr.size);
      break;
    }
    if (hdr.size > scratch_cap) { scratch_cap = hdr.size; scratch = realloc(scratch, scratch_cap); }
    memcpy(scratch, h->data + pos, hdr.size);
    __atomic_store_n(&R->tail, tail + hdr.size, __ATOMIC_RELEASE);
    atomic_fetch_add(&h->n_req, 1);
    atomic_fetch_add(&h->n_bytes, hdr.size);
    if (hdr.flags & WMTR_F_SYNC) atomic_fetch_add(&h->n_sync, 1);
    uint8_t cls = hdr.call < 146 && !(hdr.flags & WMTR_F_CONTROL) ? call_class[hdr.call] : WMTR_CLASS_S;
    if (cls == WMTR_CLASS_B || cls == WMTR_CLASS_C) {
      struct job *j = malloc(sizeof *j);
      j->h = h; j->len = hdr.size; j->copy = malloc(hdr.size);
      memcpy(j->copy, scratch, hdr.size);
      atomic_fetch_add(&h->n_worker, 1);
      dispatch_async_f(cls == WMTR_CLASS_B ? h->block_q : h->compile_q, j, job_run);
      continue;
    }
    execute(h, scratch, hdr.size);
  }
  free(scratch);
  return NULL;
}

struct wmtr_host *
wmtr_host_create(void *ring, const struct wmtr_host_ops *ops, void *ctx) {
  const char *l = getenv("WMTR_LOG");
  if (l) log_level = atoi(l);
  struct wmtr_ring *R = ring;
  if (R->magic != WMTR_RING_MAGIC || R->version != WMTR_VERSION) {
    LOG(0, "ring magic/version mismatch (%x/%u)\n", R->magic, R->version);
    return NULL;
  }
  struct wmtr_host *h = calloc(1, sizeof *h);
  h->ring = R;
  h->data = (uint8_t *)ring + WMTR_RING_DATA_OFFSET;
  h->slots = (struct wmtr_slot *)((uint8_t *)ring + WMTR_SLOTS_OFFSET);
  h->ops = ops; h->ctx = ctx;
  pthread_mutex_init(&h->lock, NULL); pthread_cond_init(&h->cond, NULL);
  pthread_mutex_init(&h->free_lock, NULL); pthread_mutex_init(&h->event_lock, NULL);
  pthread_mutex_init(&h->view_lock, NULL);
  h->compile_q = dispatch_queue_create("wmtr.compile", DISPATCH_QUEUE_CONCURRENT);
  h->block_q = dispatch_queue_create("wmtr.block", DISPATCH_QUEUE_CONCURRENT);
  pthread_attr_t a;
  pthread_attr_init(&a);
  pthread_attr_set_qos_class_np(&a, QOS_CLASS_USER_INTERACTIVE, 0);
  pthread_create(&h->thread, &a, executor, h);
  return h;
}

void
wmtr_host_kick(struct wmtr_host *h) {
  pthread_mutex_lock(&h->lock);
  h->kicked = 1;
  pthread_cond_signal(&h->cond);
  pthread_mutex_unlock(&h->lock);
}

void
wmtr_host_destroy(struct wmtr_host *h) {
  pthread_mutex_lock(&h->lock);
  h->quit = 1;
  pthread_cond_signal(&h->cond);
  pthread_mutex_unlock(&h->lock);
  pthread_join(h->thread, NULL);
  /* let queued compile/blocking jobs finish: they call back into the embedder */
  dispatch_barrier_sync(h->compile_q, ^{});
  dispatch_barrier_sync(h->block_q, ^{});
  /* the client is gone: take down the views it never released */
  pthread_mutex_lock(&h->view_lock);
  for (uint32_t i = 0; i < h->n_views; i++)
    if (h->ops->release_view) h->ops->release_view(h->ctx, h->views[i]);
  h->n_views = 0;
  free(h->views); h->views = NULL; h->cap_views = 0;
  pthread_mutex_unlock(&h->view_lock);
}

uint64_t
wmtr_host_progress(struct wmtr_host *h, uint32_t slot) {
  if (slot < WMTR_SLOTS) return __atomic_load_n(&h->slots[slot].done_seq, __ATOMIC_ACQUIRE);
  return __atomic_load_n(&h->ring->event_head, __ATOMIC_ACQUIRE);
}

void
wmtr_host_get_stats(struct wmtr_host *h, struct wmtr_host_stats *o) {
  o->requests = h->n_req; o->sync_requests = h->n_sync; o->bytes = h->n_bytes;
  o->worker_calls = h->n_worker; o->idle_sleeps = h->n_sleep;
}

/* DXMT's unix side references ntdll's NtSetEvent for the CFRunLoop listener path, which the
 * host replaces (calls 104/108-110 above); this definition only satisfies the linker. */
NTSTATUS NtSetEvent(void *handle, void *prev) { (void)handle; (void)prev; return STATUS_UNSUCCESSFUL; }

/* ------------------------------------------------------------------------------------------- *
 * default presenter: one window per client HWND, created on the main thread of the embedding
 * application (wmtr-server, or the steamac launcher that hosts libkrun). It never activates, so it
 * does not take focus from the user's apps. */
/* WMTR_PRESENT=overlay (used inside the steamac launcher): the game's CAMetalLayer becomes an aspect-fit
 * sublayer of the launcher's VM view (class VMView, a layer-backed NSView whose backing layer shows the
 * guest scanout), so the game appears in the VM window and input keeps going to the guest unchanged.
 * Otherwise (wmtr-server): one window per HWND. */
static NSView *
find_vm_view(NSView *v) {
  if ([NSStringFromClass([v class]) hasSuffix:@"VMView"]) return v;
  for (NSView *c in [v subviews]) {
    NSView *f = find_vm_view(c);
    if (f) return f;
  }
  return nil;
}

__attribute__((visibility("default"))) uint64_t
wmtr_present_create_view(void *ctx, uint64_t hwnd, void *device, uint64_t *layer_out) {
  const char *mode = getenv("WMTR_PRESENT");
  int overlay = mode && !strcmp(mode, "overlay");
  __block NSView *view = nil;
  __block CAMetalLayer *layer = nil;
  dispatch_sync(dispatch_get_main_queue(), ^{
    layer = [CAMetalLayer layer];
    layer.device = (id<MTLDevice>)device;
    if (overlay) {
      for (NSWindow *w in [NSApp windows]) {
        NSView *vm = find_vm_view([w contentView]);
        if (!vm || !vm.layer) continue;
        view = [vm retain];
        layer.frame = vm.layer.bounds;
        layer.contentsScale = w.backingScaleFactor;
        layer.contentsGravity = kCAGravityResizeAspect;
        layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
        layer.opaque = YES;
        [vm.layer addSublayer:layer];
        break;
      }
      if (!view) NSLog(@"wmtr: no VMView found for the overlay presenter");
      return;
    }
    NSRect r = NSMakeRect(80, 80, 1280, 800);
    NSWindow *w = [[NSWindow alloc] initWithContentRect:r
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    [w setTitle:[NSString stringWithFormat:@"wmtr hwnd %llx", (unsigned long long)hwnd]];
    view = [[NSView alloc] initWithFrame:r];
    view.wantsLayer = YES;
    layer.contentsScale = 1.0;
    view.layer = layer;
    [w setContentView:view];
    [w orderFront:nil]; /* never activate: do not take focus from the user's apps */
  });
  if (!view) return 0;
  *layer_out = (uint64_t)[layer retain];
  /* the handle released by ReleaseMetalView: remember the layer to detach it */
  objc_setAssociatedObject(view, (const void *)hwnd, layer, OBJC_ASSOCIATION_RETAIN);
  return (uint64_t)view;
}

__attribute__((visibility("default"))) void
wmtr_present_release_view(void *ctx, uint64_t v) {
  NSView *view = (NSView *)v;
  const char *mode = getenv("WMTR_PRESENT");
  int overlay = mode && !strcmp(mode, "overlay");
  dispatch_async(dispatch_get_main_queue(), ^{
    if (overlay) {
      for (CALayer *l in [[view.layer sublayers] copy])
        if ([l isKindOfClass:[CAMetalLayer class]] && l != view.layer) [l removeFromSuperlayer];
    } else {
      [[view window] close];
    }
    [view release];
  });
}

/* ring layout for embedders' tests (offsets within blob 0) */
__attribute__((visibility("default"))) void
wmtr_layout(uint64_t *ring_bytes, uint64_t *data_offset, uint64_t *slots_offset, uint64_t *slot_size) {
  *ring_bytes = WMTR_RING_BLOB_BYTES;
  *data_offset = WMTR_RING_DATA_OFFSET;
  *slots_offset = WMTR_SLOTS_OFFSET;
  *slot_size = sizeof(struct wmtr_slot);
}
