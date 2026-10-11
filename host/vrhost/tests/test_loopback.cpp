// SPDX-License-Identifier: GPL-3.0-or-later
// End-to-end over loopback: WivrnSession + test pattern (as in `steamac-vrhost --testpattern`) against the fake
// headset: handshake, stream description, tracking control, timesync, shards over UDP (IDR over TCP), decode, frame
// identity, IDR after a lost frame, and the incompatible-version path.
#include "check.h"
#include "fake_headset.h"
#include "pattern/test_pattern.h"
#include "session/clock.h"
#include "wivrn/wivrn_session.h"

#include <csignal>
#include <cstdio>
#include <thread>

using namespace vrhost;

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
	return buf;
}

int main()
{
	signal(SIGPIPE, SIG_IGN);
	WivrnSession session({.port = 0, .advertise = false, .log = [](const std::string & s) { printf("[server] %s\n", s.c_str()); }});
	session.start(nullptr);
	int port = session.port();
	REQUIRE(port > 0);

	std::atomic<bool> stop{false};
	std::thread producer([&] {
		TestPattern pattern;
		std::array<CVPixelBufferRef, 2> bufs{};
		uint64_t frame = 0;
		while (not stop)
		{
			auto info = session.headset();
			if (not session.connected() or not info)
			{
				std::this_thread::sleep_for(std::chrono::milliseconds(10));
				continue;
			}
			if (not bufs[0])
				for (auto & b: bufs)
					b = make_nv12(info->eye_width, info->eye_height);
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
		}
		for (auto b: bufs)
			if (b)
				CVPixelBufferRelease(b);
	});

	// 1. normal session with a lost frame on stream 0
	FakeHeadsetOptions o{.port = port, .frames = 60, .drop_frame = 20};
	auto r = run_fake_headset(o);
	printf("handshake=%s desc=%d tc=%d timesync=%d decoded=%d/%d mismatch=%d/%d idr=%d/%d idr_after_drop=%d "
	       "decoded_after_drop=%d shards=%d max_shard=%d view_info_ok=%d display_offset=%.1fms error='%s'\n",
	       r.handshake_state.c_str(), r.got_stream_description, r.got_tracking_control, r.timesync_queries, r.decoded[0],
	       r.decoded[1], r.index_mismatch[0], r.index_mismatch[1], r.idr[0], r.idr[1], r.idr_after_drop,
	       r.decoded_after_drop, r.shards, r.max_shard_bytes, r.view_info_ok, r.display_time_offset_ms, r.error.c_str());
	CHECK(r.error.empty());
	CHECK(r.handshake_state == "encryption_disabled");
	CHECK(r.got_stream_description);
	CHECK(r.got_tracking_control);
	CHECK(r.timesync_queries > 0);
	CHECK(r.decoded[0] >= 60 and r.decoded[1] >= 60);
	CHECK(r.index_mismatch[0] == 0 and r.index_mismatch[1] == 0);
	CHECK(r.idr_after_drop >= 1);      // the lost frame triggered a new IDR
	CHECK(r.decoded_after_drop > 0);   // and decoding resumed
	CHECK(r.view_info_ok);
	// display time is announced in the headset clock (offset 5 s), predicted ahead of "now"
	CHECK(r.display_time_offset_ms > -20 and r.display_time_offset_ms < 100);
	CHECK(session.stats().idr_requests >= 1);
	CHECK(session.stats().tracking > 0);

	// wait for the server to notice the disconnect
	for (int i = 0; i < 100 and session.connected(); ++i)
		std::this_thread::sleep_for(std::chrono::milliseconds(20));

	// 2. wrong protocol version is refused like WiVRn does
	auto bad = run_fake_headset({.port = port, .protocol_version = 0x1234, .timeout_ms = 3000});
	CHECK(bad.handshake_state == "incompatible_version");

	stop = true;
	producer.join();
	session.stop();
	return test_result("loopback");
}
