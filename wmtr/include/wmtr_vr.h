/* wmtr VR export (vm side of the VR link, docs/vr-interfaces.md section 3).
 * WMTVRSubmit (winemetal call 146) arrives on the executor thread with the guest's eye textures (host
 * MTLTexture handles from DXMT's IMTLD3D11ExportableTexture). The exporter copies each eye into an
 * IOSurface-backed swapchain image shared with steamac-vrhost (one GPU blit per eye, ordered after the
 * guest's rendering through the DXMT shared event), and sends VRL_SUBMIT when the copy has completed.
 * It never blocks the executor: a frame with no free swapchain image is dropped (counted). */
#ifndef WMTR_VR_H
#define WMTR_VR_H
#include <stdint.h>

struct wmtr_vr;
struct WMTVRSubmitInfo;
struct wmtr_host;

/* link_fd: one end of an AF_UNIX SOCK_DGRAM socketpair to steamac-vrhost (ownership passes to the exporter).
 * mach_name: bootstrap name under which the host receives swapchain ports. NULL on failure. */
struct wmtr_vr *wmtr_vr_create(int link_fd, const char *mach_name);
/* connect to a listener at `path` (SOCK_STREAM) that hands over the link fd by SCM_RIGHTS (tests, manual runs) */
struct wmtr_vr *wmtr_vr_connect(const char *path, const char *mach_name);
void wmtr_vr_destroy(struct wmtr_vr *vr);
/* returns an NTSTATUS (0 = queued or dropped, see stats) */
int wmtr_vr_submit(struct wmtr_vr *vr, const struct WMTVRSubmitInfo *info);

/* WMTR_CTL_VR_QUERY: `buf` holds one request of the guest VR protocol (guest/vr/include/steamac_vr_guest.h:
 * SVR_HELLO, SVR_FRAME, SVR_HAPTIC) in `size` bytes and is overwritten with the reply. Answered from the newest
 * VRL_STATE/VRL_TIMING/VRL_POSES/VRL_INPUT the host sent, without waiting; SVR_HAPTIC becomes VRL_HAPTICS.
 * vr == NULL (no VR host attached) answers HELLO with connected = 0. Returns an NTSTATUS. */
int wmtr_vr_query(struct wmtr_vr *vr, void *buf, uint32_t size);

struct wmtr_vr_stats {
  uint64_t submits;   /* WMTVRSubmit calls */
  uint64_t sent;      /* VRL_SUBMIT packets sent */
  uint64_t dropped;   /* no free swapchain image */
  uint64_t released;  /* VRL_RELEASE received */
  uint64_t errors;    /* bad textures, unsupported formats, link errors */
  uint64_t swapchains;/* swapchains (re)created */
  uint64_t queries;   /* WMTR_CTL_VR_QUERY requests answered */
  uint64_t haptics;   /* VRL_HAPTICS sent */
};
void wmtr_vr_get_stats(struct wmtr_vr *vr, struct wmtr_vr_stats *out);

/* attach an exporter to an executor (call 146); NULL detaches. Without one, call 146 fails with
 * STATUS_NOT_SUPPORTED. wmtr_host_create attaches one itself when WMTR_VR_MACH_NAME is set together with
 * WMTR_VR_FD (a socketpair end open in this process, as steamac-vm passes it; shared by live contexts)
 * or WMTR_VR_SOCKET (a listener path, tests and manual runs). */
void wmtr_host_set_vr(struct wmtr_host *h, struct wmtr_vr *vr);
/* the context's VR link (WMTR_VR_FD: the process-wide shared one), or NULL */
struct wmtr_vr *wmtr_host_vr(struct wmtr_host *h);

#endif
