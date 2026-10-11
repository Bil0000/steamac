// SPDX-License-Identifier: GPL-3.0-or-later
// steamac-vrhost: Mac-native VR host. M0 modes:
//   --testpattern          serve a world-locked test pattern to a WiVRn client (Quest/Pico app, Steam Frame client)
//   --selftest-encoder     headless VideoToolbox latency self-test (no network, no headset)
//   --protocol             print the pinned WiVRn protocol hash and exit
//   --link-fd N --mach-name NAME   game frames from steamac-vm (VR link, docs/vr-interfaces.md section 3)
#include "encoder/vt_encoder.h"
#include "pattern/test_pattern.h"
#include "pipeline/vr_pipeline.h"
#include "session/clock.h"
#include "wivrn/annexb.h"
#include "wivrn/wivrn_session.h"

#include <CoreVideo/CoreVideo.h>
#include <IOSurface/IOSurface.h>
#include <algorithm>
#include <atomic>
#include <cinttypes>
#include <cmath>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <string>
#include <memory>
#include <thread>
#include <vector>

using namespace vrhost;

static std::atomic<bool> g_quit{false};

static void usage()
{
	fprintf(stderr,
	        "usage: steamac-vrhost [--testpattern] [--selftest-encoder] [--protocol]\n"
	        "  --link-fd N         serve game frames from steamac-vm over this SOCK_DGRAM fd (with --mach-name)\n"
	        "  --mach-name NAME    bootstrap name for the swapchain IOSurface ports\n"
	        "  --link-socket PATH  manual runs: accept the link from wmtr_vr_connect at PATH\n"
	        "  --port N            TCP/UDP port (default 9757)\n"
	        "  --no-advertise      do not publish _wivrn._tcp via Bonjour\n"
	        "  --tcp-only          send everything over TCP\n"
	        "  --size WxH          stream size per eye (default: headset's; self-test 1832x1920)\n"
	        "  --frames N          self-test frames (default 600)\n"
	        "  --fps F             self-test frame rate (default 90)\n"
	        "  --codec hevc|h264   self-test codec (default hevc)\n"
	        "  --bitrate BPS       total bitrate (default 50000000)\n");
}

static CVPixelBufferRef make_nv12(uint32_t w, uint32_t h)
{
	CFDictionaryRef empty = CFDictionaryCreate(nullptr, nullptr, nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	const void * k[] = {kCVPixelBufferIOSurfacePropertiesKey, kCVPixelBufferMetalCompatibilityKey};
	const void * v[] = {empty, kCFBooleanTrue};
	CFDictionaryRef attrs = CFDictionaryCreate(nullptr, k, v, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CVPixelBufferRef buf = nullptr;
	CVPixelBufferCreate(nullptr, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs, &buf);
	CFRelease(attrs);
	CFRelease(empty);
	if (not buf)
		throw std::runtime_error("CVPixelBufferCreate failed");
	return buf;
}

static double pct(std::vector<double> v, double q)
{
	std::sort(v.begin(), v.end());
	return v[std::min(v.size() - 1, size_t(q * (v.size() - 1) + 0.5))];
}

static int selftest_encoder(uint32_t w, uint32_t h, int frames, float fps, EncoderConfig::Codec codec, uint32_t bitrate)
{
	printf("encoder self-test: %s %ux%u per eye, 2 eyes encoded concurrently, %d frames at %.0f fps, %.1f Mbit/s per eye, "
	       "hardware + low-latency RC required\n",
	       codec == EncoderConfig::Codec::hevc ? "HEVC" : "H.264", w, h, frames, fps, bitrate / 1e6);
	std::array<std::unique_ptr<VtEncoder>, 2> enc;
	for (auto & e: enc)
		e = std::make_unique<VtEncoder>(EncoderConfig{.codec = codec, .width = w, .height = h, .fps = fps, .bitrate_bps = bitrate});
	printf("hardware encoder: %s, low-latency rate control: %s\n", enc[0]->hardware() ? "yes" : "no", enc[0]->low_latency() ? "yes" : "no");
	TestPattern pattern;
	std::array<CVPixelBufferRef, 2> buf{make_nv12(w, h), make_nv12(w, h)};

	std::vector<double> eye_ms, frame_ms, render_ms;
	size_t bytes = 0;
	int idr = 0, bad_ps = 0;
	Fov fov{-0.9f, 0.8f, 0.85f, -0.9f};
	ns period = ns(1e9 / fps);
	ns next = now_ns();
	int late = 0;
	for (int i = 0; i < frames; ++i)
	{
		float yaw = 0.5f * std::sin(i * 0.02f);
		Pose eye{.orientation = {0, std::sin(yaw / 2), 0, std::cos(yaw / 2)}};
		ns r0 = now_ns();
		for (auto b: buf)
			pattern.render(b, eye, fov, i);
		ns r1 = now_ns();
		bool force = (i % 120) == 0 and i > 0; // exercise IDR on request
		std::array<EncodedFrame, 2> f;
		std::thread t([&] { f[1] = enc[1]->encode(buf[1], r1, force); });
		f[0] = enc[0]->encode(buf[0], r1, force);
		t.join();
		ns r2 = now_ns();
		frame_ms.push_back((r2 - r1) / 1e6);
		render_ms.push_back((r1 - r0) / 1e6);
		if (r2 - r0 > period)
			++late;
		for (auto & e: f)
		{
			eye_ms.push_back((e.encode_end - e.encode_begin) / 1e6);
			bytes += e.annexb.size();
		}
		if (f[0].idr)
		{
			++idr;
			auto nals = annexb::split(f[0].annexb);
			bool ok = codec != EncoderConfig::Codec::hevc or
			          (nals.size() >= 4 and annexb::hevc_nal_type(nals[0]) == annexb::hevc_vps and
			           annexb::hevc_nal_type(nals[1]) == annexb::hevc_sps and annexb::hevc_nal_type(nals[2]) == annexb::hevc_pps);
			if (not ok)
				++bad_ps;
		}
		next += period;
		ns now = now_ns();
		if (next > now)
		{
			timespec ts{.tv_sec = 0, .tv_nsec = long(next - now)};
			nanosleep(&ts, nullptr);
		}
	}
	for (auto b: buf)
		CVPixelBufferRelease(b);
	auto line = [](const char * name, const std::vector<double> & v) {
		printf("%-34s min %6.2f  p50 %6.2f  p95 %6.2f  p99 %6.2f  max %6.2f\n", name, pct(v, 0), pct(v, 0.5), pct(v, 0.95),
		       pct(v, 0.99), pct(v, 1));
	};
	line("encode latency per eye (ms):", eye_ms);
	line("both eyes, submit to last NAL (ms):", frame_ms);
	line("pattern render 2 eyes (ms):", render_ms);
	printf("frames %d, frames over the %.2f ms budget: %d, IDR %d (expected %d), avg %.1f KB/eye-frame, %.1f Mbit/s total, "
	       "IDR without VPS/SPS/PPS: %d\n",
	       frames, period / 1e6, late, idr, 1 + (frames - 1) / 120, bytes / 2048.0 / frames, bytes * 8.0 * fps / frames / 1e6, bad_ps);
	return bad_ps == 0 and idr == 1 + (frames - 1) / 120 ? 0 : 1;
}

class PatternSource : public SessionListener
{
public:
	void on_connected(const HeadsetInfo & h) override
	{
		printf("connected: %s, %ux%u, %.0f Hz\n", h.name.c_str(), h.eye_width, h.eye_height, h.preferred_refresh_rate);
	}
	void on_disconnected() override { printf("disconnected\n"); }
};

static int testpattern(WivrnConfig cfg)
{
	cfg.log = [](const std::string & s) {
		printf("[vrhost] %s\n", s.c_str());
		fflush(stdout);
	};
	WivrnSession session(cfg);
	PatternSource src;
	session.start(&src);
	printf("steamac-vrhost: listening on port %d, protocol %016" PRIx64 " (WiVRn v26.9)%s\n", session.port(),
	       WivrnSession::protocol_version(), cfg.advertise ? ", advertised as _wivrn._tcp" : "");
	fflush(stdout);

	TestPattern pattern;
	std::array<CVPixelBufferRef, 2> bufs{};
	uint32_t bw = 0, bh = 0;
	uint64_t frame = 0;
	ns last_report = now_ns();
	while (not g_quit)
	{
		auto info = session.headset();
		if (not session.connected() or not info)
		{
			timespec ts{0, 50'000'000};
			nanosleep(&ts, nullptr);
			continue;
		}
		if (bw != info->eye_width or bh != info->eye_height)
		{
			for (auto & b: bufs)
			{
				if (b)
					CVPixelBufferRelease(b);
				b = make_nv12(info->eye_width, info->eye_height);
			}
			bw = info->eye_width;
			bh = info->eye_height;
		}
		FrameTiming t = session.next_frame_timing();
		Frame f;
		f.frame_id = frame;
		f.display_time = t.predicted_display;
		session.views_at(t.predicted_display, f.pose, f.fov);
		for (int i = 0; i < 2; ++i)
		{
			pattern.render(bufs[i], f.pose[i], f.fov[i], frame);
			f.eye[i].surface = CVPixelBufferGetIOSurface(bufs[i]);
		}
		session.submit(f);
		++frame;
		if (now_ns() - last_report > 5'000'000'000)
		{
			auto & s = session.stats();
			printf("frames %" PRIu64 " idr %" PRIu64 " (requests %" PRIu64 ") feedback %" PRIu64 " tracking %" PRIu64
			       " last encode %.2f ms, headset decode %.2f ms, %.1f Mbit/s\n",
			       s.frames_sent.load(), s.idr_sent.load(), s.idr_requests.load(), s.feedback.load(), s.tracking.load(),
			       s.last_encode_ns / 1e6, s.last_feedback_decode_ns / 1e6, s.bytes_sent * 8 / 1e6 / ((now_ns() - last_report) / 1e9));
			fflush(stdout);
			last_report = now_ns();
		}
	}
	session.stop();
	for (auto b: bufs)
		if (b)
			CVPixelBufferRelease(b);
	return 0;
}

// Game frames: VR link -> compositor -> WiVRn session. Ends on SIGTERM/SIGINT or when steamac-vm closes the link.
static int serve_link(WivrnConfig cfg, int link_fd, const std::string & link_socket, const std::string & mach_name)
{
	cfg.log = [](const std::string & s) {
		printf("[vrhost] %s\n", s.c_str());
		fflush(stdout);
	};
	if (link_fd < 0)
	{
		printf("steamac-vrhost: waiting for the VR link on %s\n", link_socket.c_str());
		fflush(stdout);
		while (link_fd < 0 and not g_quit)
			link_fd = VrLinkServer::accept_one(link_socket, 1000);
		if (link_fd < 0)
			return 0;
	}
	WivrnSession session(cfg);
	session.start(nullptr);
	VrPipeline pipeline(session, link_fd, mach_name);
	printf("steamac-vrhost: VR link fd %d, mach name %s, listening on port %d, protocol %016" PRIx64 " (WiVRn v26.9)\n",
	       link_fd, mach_name.c_str(), session.port(), WivrnSession::protocol_version());
	fflush(stdout);
	ns last_report = now_ns();
	while (not g_quit and not pipeline.peer_closed())
	{
		timespec ts{0, 50'000'000};
		nanosleep(&ts, nullptr);
		if (now_ns() - last_report > 5'000'000'000)
		{
			auto & s = session.stats();
			auto & ps = pipeline.stats();
			printf("link frames %" PRIu64 " submitted %" PRIu64 " (no headset %" PRIu64 ") sent %" PRIu64 " idr %" PRIu64
			       " compositor GPU %.2f ms, app submit -> sent %.2f ms, encode %.2f ms, headset decode %.2f ms\n",
			       ps.received.load(), ps.submitted.load(), ps.no_headset.load(), s.frames_sent.load(), s.idr_sent.load(),
			       ps.last_compose_gpu_ns / 1e6, ps.last_latency_ns / 1e6, s.last_encode_ns / 1e6, s.last_feedback_decode_ns / 1e6);
			fflush(stdout);
			last_report = now_ns();
		}
	}
	printf("steamac-vrhost: %s\n", g_quit ? "stopping" : "VR link closed by steamac-vm, stopping");
	fflush(stdout);
	session.stop();
	return 0;
}

int main(int argc, char ** argv)
{
	signal(SIGPIPE, SIG_IGN); // wivrn_sockets uses MSG_NOSIGNAL, which macOS lacks
	signal(SIGINT, [](int) { g_quit = true; });
	signal(SIGTERM, [](int) { g_quit = true; });

	enum
	{
		none,
		pattern,
		link,
		selftest,
		protocol
	} mode = none;
	WivrnConfig cfg;
	uint32_t w = 0, h = 0;
	int frames = 600;
	float fps = 90;
	auto codec = EncoderConfig::Codec::hevc;
	int link_fd = -1;
	std::string mach_name, link_socket;
	for (int i = 1; i < argc; ++i)
	{
		std::string a = argv[i];
		auto next = [&]() -> std::string {
			if (i + 1 >= argc)
			{
				usage();
				exit(2);
			}
			return argv[++i];
		};
		if (a == "--testpattern")
			mode = pattern;
		else if (a == "--selftest-encoder")
			mode = selftest;
		else if (a == "--protocol")
			mode = protocol;
		else if (a == "--link-fd")
		{
			mode = link;
			link_fd = std::stoi(next());
		}
		else if (a == "--link-socket")
		{
			mode = link;
			link_socket = next();
		}
		else if (a == "--mach-name")
			mach_name = next();
		else if (a == "--port")
			cfg.port = std::stoi(next());
		else if (a == "--no-advertise")
			cfg.advertise = false;
		else if (a == "--tcp-only")
			cfg.tcp_only = true;
		else if (a == "--size")
		{
			auto s = next();
			if (sscanf(s.c_str(), "%ux%u", &w, &h) != 2)
			{
				usage();
				return 2;
			}
		}
		else if (a == "--frames")
			frames = std::stoi(next());
		else if (a == "--fps")
			fps = std::stof(next());
		else if (a == "--bitrate")
			cfg.bitrate_bps = std::stoul(next());
		else if (a == "--codec")
			codec = next() == "h264" ? EncoderConfig::Codec::h264 : EncoderConfig::Codec::hevc;
		else
		{
			usage();
			return 2;
		}
	}
	try
	{
		switch (mode)
		{
			case protocol:
				printf("%016" PRIx64 "\n", WivrnSession::protocol_version());
				return 0;
			case selftest:
				return selftest_encoder(w ? w : 1832, h ? h : 1920, frames, fps, codec, cfg.bitrate_bps / 2);
			case pattern:
				cfg.width = w;
				cfg.height = h;
				return testpattern(cfg);
			case link:
				if (mach_name.empty())
				{
					usage();
					return 2;
				}
				cfg.width = w;
				cfg.height = h;
				return serve_link(cfg, link_fd, link_socket, mach_name);
			case none:
				usage();
				return 2;
		}
	}
	catch (std::exception & e)
	{
		fprintf(stderr, "steamac-vrhost: %s\n", e.what());
		return 1;
	}
}
