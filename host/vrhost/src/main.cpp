// SPDX-License-Identifier: GPL-3.0-or-later
// steamac-vrhost: Mac-native VR host. M0 modes:
//   --audio-fd N           game audio / headset microphone via the VR audio region (docs/vr-interfaces.md section 6)
//   --testpattern          serve a world-locked test pattern to a WiVRn client (Quest/Pico app, Steam Frame client)
//   --selftest-encoder     headless VideoToolbox latency self-test (no network, no headset)
//   --protocol             print the pinned WiVRn protocol hash and exit
//   --link-fd N --mach-name NAME   game frames from steamac-vm (VR link, docs/vr-interfaces.md section 3)
//   --show-pin             print the PIN of the running host (pairing mode)
//   --list-headsets / --unpair NAME / --unpair-all   manage paired headsets
#include "audio/audio_bridge.h"
#include "encoder/vt_encoder.h"
#include "pattern/test_pattern.h"
#include "pipeline/vr_pipeline.h"
#include "session/clock.h"
#include "wivrn/annexb.h"
#include "wivrn/known_keys.h"
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
#include <ctime>
#include <fstream>
#include <memory>
#include <sys/mman.h>
#include <sys/stat.h>
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
	        "       steamac-vrhost --show-pin | --list-headsets | --unpair NAME | --unpair-all\n"
	        "  --audio-fd N        VR audio region fd from steamac-vm (game audio to the headset, its microphone back)\n"
	        "  --pair              accept new headsets (PIN pairing); default only when no headset is paired yet\n"
	        "  --pin NNNNNN        pairing PIN (default: random, printed and readable with --show-pin)\n"
	        "  --no-encryption     WiVRn's 'encryption disabled' mode (trusted LAN only)\n"
	        "  --port N            TCP/UDP port (default 9757)\n"
	        "  --no-advertise      do not publish _wivrn._tcp via Bonjour\n"
	        "  --tcp-only          send everything over TCP\n"
	        "  --size WxH          stream size per eye (default: headset's; self-test 1832x1920)\n"
	        "  --frames N          self-test frames (default 600)\n"
	        "  --fps F             self-test frame rate (default 90)\n"
	        "  --codec hevc|h264   self-test codec (default hevc)\n"
	        "  --bitrate BPS       total bitrate (default 50000000)\n"
	        "  self-test tuning:   --layout eyes|serial|sbs  --prioritize-speed  --max-frame-delay N  --qp N\n"
	        "                      --no-low-latency-rc  --csv (one summary line)\n");
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

struct SelftestOptions
{
	uint32_t w = 1832, h = 1920; // per eye
	int frames = 600;
	float fps = 90;
	EncoderConfig enc;           // codec, bitrate per eye and tuning knobs
	enum class Layout
	{
		eyes,   // one session per eye, encoded concurrently (what WivrnSession does)
		serial, // one session per eye, one after the other
		sbs,    // one session, both eyes side by side (2W x H)
	} layout = Layout::eyes;
	bool csv = false;
};

static int selftest_encoder(const SelftestOptions & o)
{
	using Layout = SelftestOptions::Layout;
	const char * layout_name = o.layout == Layout::eyes ? "eyes" : o.layout == Layout::serial ? "serial" : "sbs";
	const char * codec_name = o.enc.codec == EncoderConfig::Codec::hevc ? "hevc" : "h264";
	int sessions = o.layout == Layout::sbs ? 1 : 2;
	uint32_t sw = o.layout == Layout::sbs ? 2 * o.w : o.w;
	EncoderConfig ec = o.enc;
	ec.width = sw;
	ec.height = o.h;
	ec.fps = o.fps;
	if (o.layout == Layout::sbs)
		ec.bitrate_bps *= 2;
	if (not o.csv)
		printf("encoder self-test: %s %ux%u per eye, layout %s (%d session(s) of %ux%u), %d frames at %.0f fps, "
		       "%.1f Mbit/s per eye, low-latency RC %s, prioritize speed %s, max frame delay %d, QP %d\n",
		       codec_name, o.w, o.h, layout_name, sessions, sw, o.h, o.frames, o.fps, o.enc.bitrate_bps / 1e6,
		       o.enc.low_latency_rc ? "on" : "off", o.enc.prioritize_speed ? "on" : "off", o.enc.max_frame_delay, o.enc.qp);
	std::vector<std::unique_ptr<VtEncoder>> enc;
	for (int i = 0; i < sessions; ++i)
		enc.push_back(std::make_unique<VtEncoder>(ec));
	if (not o.csv)
	{
		printf("hardware encoder: %s, low-latency rate control: %s\n", enc[0]->hardware() ? "yes" : "no", enc[0]->low_latency() ? "yes" : "no");
		for (auto & r: enc[0]->rejected())
			printf("property not accepted: %s\n", r.c_str());
	}
	TestPattern pattern;
	std::vector<CVPixelBufferRef> buf;
	for (int i = 0; i < sessions; ++i)
		buf.push_back(make_nv12(sw, o.h));

	std::vector<double> eye_ms, frame_ms, render_ms;
	size_t bytes = 0;
	int idr = 0, bad_ps = 0;
	Fov fov{-0.9f, 0.8f, 0.85f, -0.9f};
	ns period = ns(1e9 / o.fps);
	ns next = now_ns();
	int late = 0;
	for (int i = 0; i < o.frames; ++i)
	{
		float yaw = 0.5f * std::sin(i * 0.02f);
		Pose eye{.orientation = {0, std::sin(yaw / 2), 0, std::cos(yaw / 2)}};
		ns r0 = now_ns();
		for (auto b: buf)
			pattern.render(b, eye, fov, i);
		ns r1 = now_ns();
		bool force = (i % 120) == 0 and i > 0; // exercise IDR on request
		std::vector<EncodedFrame> f(sessions);
		if (o.layout == Layout::eyes)
		{
			std::thread t([&] { f[1] = enc[1]->encode(buf[1], r1, force); });
			f[0] = enc[0]->encode(buf[0], r1, force);
			t.join();
		}
		else
			for (int e = 0; e < sessions; ++e)
				f[e] = enc[e]->encode(buf[e], r1, force);
		ns r2 = now_ns();
		frame_ms.push_back((r2 - r1) / 1e6);
		render_ms.push_back((r1 - r0) / 1e6);
		if (r2 - r1 > period)
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
			bool ok = o.enc.codec != EncoderConfig::Codec::hevc or
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
	double mbps = bytes * 8.0 * o.fps / o.frames / 1e6;
	if (o.csv)
	{
		// codec,layout,eye_w,eye_h,fps,lowlat,speed,delay,qp,session_p50,session_p95,frame_p50,frame_p95,frame_p99,budget,late,mbps
		printf("%s,%s,%u,%u,%.0f,%d,%d,%d,%d,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%d,%.1f\n", codec_name, layout_name, o.w, o.h,
		       o.fps, o.enc.low_latency_rc, o.enc.prioritize_speed, o.enc.max_frame_delay, o.enc.qp, pct(eye_ms, 0.5),
		       pct(eye_ms, 0.95), pct(frame_ms, 0.5), pct(frame_ms, 0.95), pct(frame_ms, 0.99), period / 1e6, late, mbps);
		fflush(stdout);
	}
	else
	{
		auto line = [](const char * name, const std::vector<double> & v) {
			printf("%-34s min %6.2f  p50 %6.2f  p95 %6.2f  p99 %6.2f  max %6.2f\n", name, pct(v, 0), pct(v, 0.5), pct(v, 0.95),
			       pct(v, 0.99), pct(v, 1));
		};
		line("encode latency per session (ms):", eye_ms);
		line("both eyes, submit to last NAL (ms):", frame_ms);
		line("pattern render (ms):", render_ms);
		printf("frames %d, frames over the %.2f ms budget: %d, IDR %d (expected %d), %.1f Mbit/s total, "
		       "IDR without VPS/SPS/PPS: %d\n",
		       o.frames, period / 1e6, late, idr, 1 + (o.frames - 1) / 120, mbps, bad_ps);
	}
	return bad_ps == 0 and idr == 1 + (o.frames - 1) / 120 ? 0 : 1;
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

static std::filesystem::path pin_file()
{
	return KnownKeys::default_dir() / "pin";
}

// PIN for a new headset (printed and readable with --show-pin), or the pairing state.
static void announce_pairing(WivrnSession & session, const WivrnConfig & cfg)
{
	if (auto pin = session.pin(); not pin.empty())
	{
		printf("To pair a new headset use PIN code: %s\n", pin.c_str());
		std::filesystem::create_directories(pin_file().parent_path());
		std::ofstream(pin_file(), std::ios::trunc) << pin << '\n';
		chmod(pin_file().c_str(), 0600);
	}
	else
		printf("encryption %s, pairing disabled (--pair to pair a new headset)\n",
		       cfg.encryption == WivrnConfig::Encryption::disabled ? "disabled" : "on");
}

static int g_audio_fd = -1;

static int testpattern(WivrnConfig cfg)
{
	cfg.log = [](const std::string & s) {
		printf("[vrhost] %s\n", s.c_str());
		fflush(stdout);
	};
	WivrnSession session(cfg);
	PatternSource src;
	std::unique_ptr<AudioBridge> audio;
	if (g_audio_fd >= 0)
	{
		vra_region * region = AudioBridge::map(g_audio_fd);
		if (not region)
			return 1;
		audio = std::make_unique<AudioBridge>(region, session, &src);
	}
	session.start(audio ? static_cast<SessionListener *>(audio.get()) : &src);
	printf("steamac-vrhost: listening on port %d, protocol %016" PRIx64 " (WiVRn v26.9)%s\n", session.port(),
	       WivrnSession::protocol_version(), cfg.advertise ? ", advertised as _wivrn._tcp" : "");
	announce_pairing(session, cfg);
	fflush(stdout);

	TestPattern pattern;
	std::array<CVPixelBufferRef, 2> bufs{};
	uint32_t bw = 0, bh = 0;
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
		f.frame_id = t.frame_id;
		f.display_time = t.predicted_display;
		session.views_at(t.predicted_display, f.pose, f.fov);
		for (int i = 0; i < 2; ++i)
		{
			pattern.render(bufs[i], f.pose[i], f.fov[i], f.frame_id);
			f.eye[i].surface = CVPixelBufferGetIOSurface(bufs[i]);
		}
		session.submit(f);
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
	audio.reset();
	if (not session.pin().empty())
		std::filesystem::remove(pin_file());
	for (auto b: bufs)
		if (b)
			CVPixelBufferRelease(b);
	return 0;
}

// Game frames: VR link -> compositor -> WiVRn session. Ends on SIGTERM/SIGINT or when steamac-vm closes the link.
static int serve_link(WivrnConfig cfg, int link_fd, const std::string & link_socket, const std::string & mach_name,
                      int audio_fd)
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
	VrPipeline pipeline(session, link_fd, mach_name);
	vra_region * audio_region = nullptr;
	std::unique_ptr<AudioBridge> audio;
	if (audio_fd >= 0)
	{
		audio_region = AudioBridge::map(audio_fd);
		if (not audio_region)
			return 1;
		audio = std::make_unique<AudioBridge>(audio_region, session, &pipeline);
	}
	session.start(audio ? static_cast<SessionListener *>(audio.get()) : &pipeline); // state / input / audio to the guest
	printf("steamac-vrhost: VR link fd %d, mach name %s, listening on port %d, protocol %016" PRIx64 " (WiVRn v26.9)%s\n",
	       link_fd, mach_name.c_str(), session.port(), WivrnSession::protocol_version(),
	       cfg.advertise ? ", advertised as _wivrn._tcp" : "");
	announce_pairing(session, cfg);
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
			auto l = pipeline.take_latency();
			auto q = [](const std::vector<double> & v, double p) { return v.empty() ? 0.0 : pct(v, p); };
			printf("link frames %" PRIu64 " submitted %" PRIu64 " (no headset %" PRIu64 ") sent %" PRIu64 " idr %" PRIu64
			       " | ms p50/p99: submit->copied %.2f/%.2f copied->host %.3f/%.3f host->sent %.2f/%.2f total %.2f/%.2f"
			       " compositor GPU %.2f | last encode %.2f, headset decode %.2f\n",
			       ps.received.load(), ps.submitted.load(), ps.no_headset.load(), s.frames_sent.load(), s.idr_sent.load(),
			       q(l.submit_to_copied, .5), q(l.submit_to_copied, .99), q(l.copied_to_received, .5),
			       q(l.copied_to_received, .99), q(l.received_to_sent, .5), q(l.received_to_sent, .99), q(l.total, .5),
			       q(l.total, .99), q(l.compose_gpu, .5), s.last_encode_ns / 1e6, s.last_feedback_decode_ns / 1e6);
			fflush(stdout);
			last_report = now_ns();
		}
	}
	printf("steamac-vrhost: %s\n", g_quit ? "stopping" : "VR link closed by steamac-vm, stopping");
	fflush(stdout);
	session.stop();
	audio.reset(); // joins its tick thread and clears the guest-facing headset capability word
	if (audio_region)
		munmap(audio_region, VRA_REGION_BYTES);
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
		protocol,
		show_pin,
		list_headsets,
		unpair,
	} mode = none;
	std::string unpair_name;
	bool pair = false;
	WivrnConfig cfg;
	uint32_t w = 0, h = 0;
	SelftestOptions st;
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
		else if (a == "--show-pin")
			mode = show_pin;
		else if (a == "--list-headsets")
			mode = list_headsets;
		else if (a == "--unpair")
		{
			mode = unpair;
			unpair_name = next();
		}
		else if (a == "--unpair-all")
			mode = unpair;
		else if (a == "--audio-fd")
			g_audio_fd = std::stoi(next());
		else if (a == "--pair")
			pair = true;
		else if (a == "--pin")
		{
			cfg.pin = next();
			pair = true;
			if (cfg.pin.size() != 6 or cfg.pin.find_first_not_of("0123456789") != std::string::npos)
			{
				fprintf(stderr, "steamac-vrhost: the PIN is 6 digits\n");
				return 2;
			}
		}
		else if (a == "--no-encryption")
			cfg.encryption = WivrnConfig::Encryption::disabled;
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
			st.frames = std::stoi(next());
		else if (a == "--fps")
			st.fps = std::stof(next());
		else if (a == "--layout")
		{
			auto l = next();
			st.layout = l == "sbs" ? SelftestOptions::Layout::sbs : l == "serial" ? SelftestOptions::Layout::serial : SelftestOptions::Layout::eyes;
		}
		else if (a == "--no-low-latency-rc")
			st.enc.low_latency_rc = false;
		else if (a == "--prioritize-speed")
			st.enc.prioritize_speed = true;
		else if (a == "--max-frame-delay")
			st.enc.max_frame_delay = std::stoi(next());
		else if (a == "--qp")
			st.enc.qp = std::stoi(next());
		else if (a == "--csv")
			st.csv = true;
		else if (a == "--bitrate")
			cfg.bitrate_bps = std::stoul(next());
		else if (a == "--codec")
			st.enc.codec = next() == "h264" ? EncoderConfig::Codec::h264 : EncoderConfig::Codec::hevc;
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
				st.w = w ? w : 1832;
				st.h = h ? h : 1920;
				st.enc.bitrate_bps = cfg.bitrate_bps / 2;
				return selftest_encoder(st);
			case show_pin: {
				std::ifstream f(pin_file());
				std::string pin;
				if (not (f >> pin))
				{
					fprintf(stderr, "steamac-vrhost: no host is waiting for a new headset (start it with --pair)\n");
					return 1;
				}
				printf("%s\n", pin.c_str());
				return 0;
			}
			case list_headsets: {
				KnownKeys keys(KnownKeys::default_dir() / "known_keys");
				for (auto & k: keys.list())
				{
					time_t t = k.last_connection;
					char when[32];
					strftime(when, sizeof when, "%Y-%m-%d %H:%M", localtime(&t));
					printf("%-32s last connected %s\n", k.name.c_str(), when);
				}
				return 0;
			}
			case unpair: {
				KnownKeys keys(KnownKeys::default_dir() / "known_keys");
				printf("removed %d headset(s)\n", keys.remove(unpair_name));
				return 0;
			}
			case pattern:
			case link:
				if (mode == link and mach_name.empty())
				{
					usage();
					return 2;
				}
				// WiVRn's main.cpp: encryption on, pairing when asked or while no headset is paired yet.
				if (cfg.encryption != WivrnConfig::Encryption::disabled)
					cfg.encryption = pair or KnownKeys(KnownKeys::default_dir() / "known_keys").list().empty()
					                         ? WivrnConfig::Encryption::pairing
					                         : WivrnConfig::Encryption::enabled;
				cfg.width = w;
				cfg.height = h;
				return mode == link ? serve_link(cfg, link_fd, link_socket, mach_name, g_audio_fd) : testpattern(cfg);
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
