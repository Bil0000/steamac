// SPDX-License-Identifier: GPL-3.0-or-later
// End-to-end game-frame path, headless, one process:
//   producer (stands in for d3d11bench --vr: two sRGB eye render targets + MTLSharedEvent, as DXMT's
//   IMTLD3D11ExportableTexture hands them out) -> wmtr_vr_submit (the exporter call 146 runs in steamac-vm)
//   -> VR link (SOCK_DGRAM socketpair + Mach IOSurface ports) -> VrPipeline (VrLinkServer -> CompositorBridge ->
//   SessionEncoderSink) -> WivrnSession (VtEncoder, shards) -> loopback test headset (WiVRn client sequence,
//   VideoToolbox decode).
// Checks: decoded frames carry the producer's frame number (index blocks, identity foveation) and the eye's colour
// (left red, right green, like d3d11bench --vr); with a stream smaller than the eye image the foveation parameters
// in view_info are the compositor's (WiVRn-consistent) and the eye colours survive. Prints submit -> decoded latency.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "check.h"
#include "pattern/test_pattern.h"
#include "fake_headset.h"
#include "pipeline/vr_pipeline.h"
#include "session/clock.h"
#include "session/pose_history.h"
#include "wivrn/input_map.h"
#include "wivrn_packets.h"
#include "wivrn/wivrn_session.h"

#include <algorithm>
#include <csignal>
#include <filesystem>
#include <cstdio>
#include <map>
#include <mutex>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>
#include <vector>

#define WINEMETAL_API
#include "winemetal_thunks.h"
extern "C" {
#include "steamac_vr_guest.h"
#include "wmtr_vr.h"
}

using namespace vrhost;

// eye colour (linear, as d3d11bench --vr clears its eye targets) + 16 frame-index blocks of 16 px, top-left, the
// layout TestPattern::read_frame_index reads
static const char * kProducer = R"(
#include <metal_stdlib>
using namespace metal;
kernel void eye(texture2d<float, access::write> t [[texture(0)]], constant uint2 &arg [[buffer(0)]],
                uint2 g [[thread_position_in_grid]]) {
	if (g.x >= t.get_width() || g.y >= t.get_height()) return;
	uint eye = arg.x, frame = arg.y;
	float4 c = eye ? float4(0.05, 0.5, 0.08, 1) : float4(0.5, 0.05, 0.08, 1);
	if (g.y < 16 && g.x < 256) c = ((frame >> (g.x / 16)) & 1u) ? float4(1) : float4(0, 0, 0, 1);
	t.write(c, g);
}
)";

struct Producer
{
	id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
	id<MTLCommandQueue> q = [dev newCommandQueue];
	id<MTLComputePipelineState> pso;
	// A ring of eye textures, like an OpenVR runtime's copy: the exporter's blit (its own queue, after the event)
	// must not race the next frame's rendering into the same texture (docs/vr-interfaces.md section 3.1).
	static constexpr int ring = 3;
	id<MTLTexture> tex[ring][2];
	id<MTLSharedEvent> ev = [dev newSharedEvent];
	uint64_t ev_value = 0;
	Producer(uint32_t w, uint32_t h)
	{
		NSError * err = nil;
		id<MTLLibrary> lib = [dev newLibraryWithSource:@(kProducer) options:nil error:&err];
		pso = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"eye"] error:&err];
		MTLTextureDescriptor * d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB
		                                                                              width:w
		                                                                             height:h
		                                                                          mipmapped:NO];
		d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
		d.storageMode = MTLStorageModePrivate;
		for (auto & slot: tex)
			for (auto & t: slot)
				t = [dev newTextureWithDescriptor:d];
	}
	// renders into ring slot frame % ring and returns it
	id<MTLTexture> const * render(uint32_t frame)
	{
		auto & t = tex[frame % ring];
		id<MTLCommandBuffer> cb = [q commandBuffer];
		id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
		[ce setComputePipelineState:pso];
		for (uint32_t e = 0; e < 2; e++)
		{
			uint32_t arg[2] = {e, frame};
			[ce setTexture:t[e] atIndex:0];
			[ce setBytes:arg length:sizeof arg atIndex:0];
			[ce dispatchThreads:MTLSizeMake(t[e].width, t[e].height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
		}
		[ce endEncoding];
		[cb encodeSignalEvent:ev value:++ev_value];
		[cb commit];
		return t;
	}
};

// Cb/Cr at the image centre (away from the index blocks)
static void centre_chroma(CVPixelBufferRef img, int & cb, int & cr)
{
	CVPixelBufferLockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
	auto * p = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(img, 1);
	size_t stride = CVPixelBufferGetBytesPerRowOfPlane(img, 1);
	size_t x = CVPixelBufferGetWidthOfPlane(img, 1) / 2, y = CVPixelBufferGetHeightOfPlane(img, 1) / 2;
	cb = p[y * stride + 2 * x];
	cr = p[y * stride + 2 * x + 1];
	CVPixelBufferUnlockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
}

static double pct(std::vector<double> v, double q)
{
	if (v.empty())
		return 0;
	std::sort(v.begin(), v.end());
	return v[std::min(v.size() - 1, size_t(q * (v.size() - 1) + 0.5))];
}

// WiVRn parameter invariants (as m1_pipeline_test): odd length, covers the source, output count = stream size
static bool foveation_consistent(const std::vector<uint16_t> & v, uint32_t src, uint32_t out)
{
	if (v.size() % 2 == 0)
		return false;
	int mid = int(v.size() - 1) / 2;
	uint32_t sum = 0, cnt = 0;
	for (size_t i = 0; i < v.size(); i++)
	{
		sum += v[i] * (std::abs(mid - int(i)) + 1);
		cnt += v[i];
	}
	return sum == src and cnt == out and v[mid] > 0;
}

int main()
{
	@autoreleasepool
	{
		signal(SIGPIPE, SIG_IGN);
		// defaults keep the test short; VR_E2E_SRC / VR_E2E_OUT (WxH) / VR_E2E_FRAMES measure a headset-sized stream
		uint32_t src_w = 640, src_h = 704, out_w = 384, out_h = 416;
		int frames = 60;
		if (const char * e = getenv("VR_E2E_SRC"))
			REQUIRE(sscanf(e, "%ux%u", &src_w, &src_h) == 2);
		if (const char * e = getenv("VR_E2E_OUT"))
			REQUIRE(sscanf(e, "%ux%u", &out_w, &out_h) == 2);
		if (const char * e = getenv("VR_E2E_FRAMES"))
			frames = atoi(e);
		// the real configuration: encryption with PIN pairing (keys in a scratch file, not the user's)
		char dir[] = "/tmp/vr_e2e.XXXXXX";
		REQUIRE(mkdtemp(dir));
		WivrnSession session({.port = 0,
		                      .advertise = false,
		                      .encryption = WivrnConfig::Encryption::pairing,
		                      .pin = "271828",
		                      .known_keys_file = std::string(dir) + "/known_keys",
		                      .log = [](const std::string & s) { printf("[server] %s\n", s.c_str()); }});

		char name[96];
		snprintf(name, sizeof name, "com.steamac.vrhost.e2etest.%d", int(getpid()));
		int sv[2];
		REQUIRE(socketpair(AF_UNIX, SOCK_DGRAM, 0, sv) == 0);
		auto pipeline = std::make_unique<VrPipeline>(session, sv[1], name);
		session.start(pipeline.get()); // the pipeline forwards state / input to the guest
		REQUIRE(session.port() > 0);
		wmtr_vr * vr = wmtr_vr_create(sv[0], name);
		REQUIRE(vr);

		std::mutex m;
		std::map<uint64_t, int64_t> submit_ns;
		std::vector<double> latency_ms;
		std::atomic<bool> stop{false};
		std::atomic<int> frames_from_pacer{0};
		std::thread producer([&] {
			Producer prod(src_w, src_h);
			WMTVRSubmitInfo info{};
			uint64_t last_frame = 0;
			while (not stop)
			{
				// what the guest runtime's WaitGetPoses does (guest/vr, M2): SVR_FRAME through the exporter's query, which
				// answers from the host's newest VRL_TIMING / VRL_POSES / VRL_STATE
				svr_frame_rep r{};
				reinterpret_cast<svr_frame_req &>(r) = {{SVR_FRAME, sizeof(svr_frame_req)}, last_frame};
				if (wmtr_vr_query(vr, &r, sizeof r) != 0 or not r.connected or not (r.pose[SVR_DEV_HEAD].flags & SVR_POSE_VALID))
				{
					std::this_thread::sleep_for(std::chrono::milliseconds(2));
					continue; // no headset / no tracking yet: an OpenVR runtime reports no valid pose either
				}
				if (r.wake_up > now_ns())
					std::this_thread::sleep_for(std::chrono::nanoseconds(r.wake_up - now_ns()));
				uint64_t frame = r.frame_id; // the pacer's id: WiVRn matches the headset's feedback by it
				last_frame = frame;
				frames_from_pacer++;
				// per-eye pose = head pose +- IPD/2 along head x (as the guest runtime computes it)
				const svr_pose & head = r.pose[SVR_DEV_HEAD];
				Pose hp{.orientation = {head.orientation[0], head.orientation[1], head.orientation[2], head.orientation[3]},
				        .position = {head.position[0], head.position[1], head.position[2]}};
				std::array<Pose, 2> pose;
				std::array<Fov, 2> fov;
				for (int e = 0; e < 2; e++)
				{
					pose[e] = multiply(hp, Pose{.position = {(e ? 0.5f : -0.5f) * r.ipd_m, 0, 0}});
					fov[e] = {r.fov[e][0], r.fov[e][1], r.fov[e][2], r.fov[e][3]};
				}
				auto eye_tex = prod.render(uint32_t(frame));
				for (int e = 0; e < 2; e++)
					info.eye[e] = WMTVREye{(obj_handle_t)(__bridge void *)eye_tex[e], 0, 0, 0, 0, 0, 0};
				info.frame_id = frame;
				info.display_time = uint64_t(r.predicted_display);
				for (int e = 0; e < 2; e++)
				{
					float p[7] = {pose[e].orientation[0], pose[e].orientation[1], pose[e].orientation[2], pose[e].orientation[3],
					              pose[e].position[0], pose[e].position[1], pose[e].position[2]};
					float f[4] = {fov[e].left, fov[e].right, fov[e].up, fov[e].down};
					memcpy(info.pose[e], p, sizeof p);
					memcpy(info.fov[e], f, sizeof f);
				}
				info.wait_event = (obj_handle_t)(__bridge void *)prod.ev;
				info.wait_value = prod.ev_value;
				{
					std::lock_guard l(m);
					submit_ns[frame] = now_ns();
				}
				wmtr_vr_submit(vr, &info);
			}
		});

		int bad_colour = 0, checked = 0, wrong_index = 0, unreadable = 0;
		// guest protocol through the link while a headset is connected (once): state, input mapping, haptics
		bool guest_checked = false;
		auto check_guest = [&] {
			svr_hello_rep hello{};
			reinterpret_cast<svr_hello_req &>(hello) = {{SVR_HELLO, sizeof(svr_hello_req)}, SVR_VERSION, uint32_t(getpid()), "vr_e2e"};
			CHECK(wmtr_vr_query(vr, &hello, sizeof hello) == 0);
			printf("guest view: connected=%u eye %ux%u %.0f Hz ipd %.1f mm name '%s'\n", hello.connected, hello.eye_width,
			       hello.eye_height, hello.refresh_hz, hello.ipd_m * 1000, hello.name);
			CHECK(hello.connected and std::abs(hello.ipd_m - 0.064f) < 0.002f and hello.refresh_hz > 0);
			int hand = -1, idx = -1;
			CHECK(wivrn_input_to_vrl(uint32_t(wivrn::device_id::RIGHT_TRIGGER_VALUE), hand, idx) and hand == 1 and
			      idx == SVR_IN_TRIGGER_VALUE);
			InputValue iv{uint32_t(wivrn::device_id::RIGHT_TRIGGER_VALUE), 0.75f, now_ns()};
			pipeline->on_input(std::span(&iv, 1));
			bool input_seen = false;
			for (int i = 0; i < 100 and not input_seen; i++)
			{
				svr_frame_rep fr{};
				reinterpret_cast<svr_frame_req &>(fr) = {{SVR_FRAME, sizeof(svr_frame_req)}, 0};
				input_seen = wmtr_vr_query(vr, &fr, sizeof fr) == 0 and fr.input[1][SVR_IN_TRIGGER_VALUE] == 0.75f;
				std::this_thread::sleep_for(std::chrono::milliseconds(2));
			}
			CHECK(input_seen); // WiVRn input -> VRL_INPUT -> the guest's snapshot
			union
			{
				svr_haptic_req req;
				svr_ack ack;
			} hq{.req = {{SVR_HAPTIC, sizeof(svr_haptic_req)}, 1, 0.05f, 0, 0.5f}};
			CHECK(wmtr_vr_query(vr, &hq, sizeof hq) == 0 and hq.ack.status == 0);
			for (int i = 0; i < 100 and pipeline->haptics_routed() == 0; i++)
				std::this_thread::sleep_for(std::chrono::milliseconds(2));
			CHECK(pipeline->haptics_routed() == 1); // SVR_HAPTIC -> VRL_HAPTICS -> VrSession::haptics
			guest_checked = true;
		};
		auto on_decoded = [&](int eye, uint64_t frame, CVPixelBufferRef img) {
			if (not guest_checked and eye == 0 and frame > 10)
				check_guest();
			int64_t read = TestPattern::read_frame_index(img);
			int cb, cr;
			centre_chroma(img, cb, cr);
			// left: red (Cr high, Cb low), right: green (Cr and Cb low)
			bool ok = eye == 0 ? (cr > 160 and cb < 128) : (cr < 110 and cb < 128);
			std::lock_guard l(m);
			checked++;
			if (read < 0)
				unreadable++;
			else if (read != int64_t(frame & 0xffff) and wrong_index++ < 3)
				fprintf(stderr, "eye %d frame %llu: carries frame %lld\n", eye, (unsigned long long)frame, (long long)read);
			if (not ok and bad_colour++ < 3)
				fprintf(stderr, "eye %d frame %llu: centre Cb %d Cr %d\n", eye, (unsigned long long)frame, cb, cr);
			if (eye == 1 and submit_ns.count(frame))
				latency_ms.push_back((now_ns() - submit_ns[frame]) / 1e6);
		};

		// 1. stream size = eye size: identity foveation, frame numbers readable after the full path
		auto r = run_fake_headset({.port = session.port(), .frames = frames, .eye_width = uint16_t(src_w), .eye_height = uint16_t(src_h), .pin = "271828", .on_decoded = on_decoded});
		printf("identity: handshake=%s decoded=%d/%d mismatch=%d/%d idr=%d/%d view_info_ok=%d error='%s'\n",
		       r.handshake_state.c_str(), r.decoded[0], r.decoded[1], r.index_mismatch[0], r.index_mismatch[1], r.idr[0], r.idr[1],
		       r.view_info_ok, r.error.c_str());
		CHECK(r.error.empty());
		CHECK(r.handshake_state == "pin_needed"); // paired with the PIN, then AES-128-CTR on both channels
		CHECK(r.decoded[0] >= 60 and r.decoded[1] >= 60);
		// every readable frame number is the frame's own; a few blocks are blurred right after many bits flip
		printf("identity: frame numbers wrong %d, unreadable %d of %d\n", wrong_index, unreadable, checked);
		CHECK(wrong_index == 0);
		CHECK(unreadable * 20 <= checked);
		CHECK(r.view_info_ok); // identity foveation, eye poses 64 mm apart, display time in headset clock
		CHECK(bad_colour == 0 and checked >= 120);
		auto stages = [&](const char * label) {
			auto l = pipeline->take_latency();
			printf("%s: ms p50/p99 submit->copied %.2f/%.2f copied->host %.3f/%.3f host->sent %.2f/%.2f compositor GPU %.2f\n",
			       label, pct(l.submit_to_copied, .5), pct(l.submit_to_copied, .99), pct(l.copied_to_received, .5),
			       pct(l.copied_to_received, .99), pct(l.received_to_sent, .5), pct(l.received_to_sent, .99), pct(l.compose_gpu, .5));
		};
		stages("identity");
		printf("identity: submit -> decoded (both eyes) ms p50 %.2f p99 %.2f max %.2f (%zu frames)\n", pct(latency_ms, .5),
		       pct(latency_ms, .99), pct(latency_ms, 1), latency_ms.size());

		for (int i = 0; i < 100 and session.connected(); ++i)
			std::this_thread::sleep_for(std::chrono::milliseconds(20));
		{
			std::lock_guard l(m);
			bad_colour = checked = wrong_index = unreadable = 0;
			latency_ms.clear();
		}

		// 2. smaller stream: the compositor foveates; its parameters reach the headset in view_info
		auto f = run_fake_headset({.port = session.port(), .frames = frames, .eye_width = uint16_t(out_w), .eye_height = uint16_t(out_h),
		                           .pin = "271828", .identity_foveation = false, .on_decoded = on_decoded});
		printf("foveated: decoded=%d/%d idr=%d/%d foveation x %zu entries y %zu entries error='%s'\n", f.decoded[0], f.decoded[1],
		       f.idr[0], f.idr[1], f.foveation_x[0].size(), f.foveation_y[0].size(), f.error.c_str());
		CHECK(f.error.empty());
		CHECK(f.decoded[0] >= 60 and f.decoded[1] >= 60);
		for (int e = 0; e < 2; e++)
		{
			CHECK(f.foveation_x[e].size() > 1 and foveation_consistent(f.foveation_x[e], src_w, out_w));
			CHECK(f.foveation_y[e].size() > 1 and foveation_consistent(f.foveation_y[e], src_h, out_h));
		}
		CHECK(bad_colour == 0 and checked >= 120);
		stages("foveated");
		printf("foveated: submit -> decoded (both eyes) ms p50 %.2f p99 %.2f max %.2f (%zu frames)\n", pct(latency_ms, .5),
		       pct(latency_ms, .99), pct(latency_ms, 1), latency_ms.size());

		CHECK(frames_from_pacer >= 120);
		CHECK(pipeline->timings_sent() > 0);
		CHECK(guest_checked);
		stop = true;
		producer.join();
		wmtr_vr_stats st;
		wmtr_vr_get_stats(vr, &st);
		auto & ps = pipeline->stats();
		printf("exporter: submits %llu sent %llu dropped %llu errors %llu; pipeline: received %llu submitted %llu no-headset %llu\n",
		       st.submits, st.sent, st.dropped, st.errors, (unsigned long long)ps.received, (unsigned long long)ps.submitted,
		       (unsigned long long)ps.no_headset);
		CHECK(st.errors == 0);
		// 3. teardown as steamac-vm does it: closing the exporter closes the link, the host sees it
		wmtr_vr_destroy(vr);
		int64_t t_close = now_ns();
		for (int i = 0; i < 500 and not pipeline->peer_closed(); ++i)
			std::this_thread::sleep_for(std::chrono::milliseconds(10));
		printf("link close seen by the host after %.1f ms\n", (now_ns() - t_close) / 1e6);
		CHECK(pipeline->peer_closed());
		session.stop();
		pipeline.reset();
		std::filesystem::remove_all(dir);
	}
	return test_result("vr_e2e");
}
