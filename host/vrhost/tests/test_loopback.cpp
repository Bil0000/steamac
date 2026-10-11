// SPDX-License-Identifier: GPL-3.0-or-later
// End-to-end over loopback: WivrnSession + test pattern (as in `steamac-vrhost --testpattern`) against the fake
// headset: handshake, stream description, tracking control, timesync, shards over UDP (IDR over TCP), decode, frame
// identity, IDR after a lost frame, and the incompatible-version path; then the same with WiVRn's encryption on:
// PIN pairing (SMP), reconnect of a paired headset, wrong PIN, pairing disabled.
#include "check.h"
#include "fake_headset.h"
#include "pattern_server.h"
#include "pattern/test_pattern.h"
#include "session/clock.h"
#include "wivrn/wivrn_session.h"

#include <csignal>
#include <filesystem>
#include <cstdio>
#include <thread>
#include <unistd.h>

#include "crypto.h"

using namespace vrhost;

static void print(const char * what, const FakeHeadsetResult & r)
{
	printf("%s: handshake=%s encrypted=%d desc=%d tc=%d timesync=%d decoded=%d/%d mismatch=%d/%d idr=%d/%d "
	       "idr_after_drop=%d decoded_after_drop=%d shards=%d max_shard=%d view_info_ok=%d display_offset=%.1fms error='%s'\n",
	       what, r.handshake_state.c_str(), r.encrypted, r.got_stream_description, r.got_tracking_control,
	       r.timesync_queries, r.decoded[0], r.decoded[1], r.index_mismatch[0], r.index_mismatch[1], r.idr[0], r.idr[1],
	       r.idr_after_drop, r.decoded_after_drop, r.shards, r.max_shard_bytes, r.view_info_ok, r.display_time_offset_ms,
	       r.error.c_str());
}

int main()
{
	signal(SIGPIPE, SIG_IGN);
	{
		// 1. encryption disabled, a lost frame on stream 0
		Server srv({.encryption = WivrnConfig::Encryption::disabled});
		int port = srv.session.port();
		REQUIRE(port > 0);
		auto r = run_fake_headset({.port = port, .frames = 60, .drop_frame = 20});
		print("plain", r);
		CHECK(r.error.empty());
		CHECK(r.handshake_state == "encryption_disabled");
		CHECK(not r.encrypted);
		CHECK(r.got_stream_description);
		CHECK(r.got_tracking_control);
		CHECK(r.timesync_queries > 0);
		CHECK(r.decoded[0] >= 60 and r.decoded[1] >= 60);
		CHECK(r.index_mismatch[0] == 0 and r.index_mismatch[1] == 0);
		CHECK(r.idr_after_drop >= 1);    // the lost frame triggered a new IDR
		CHECK(r.decoded_after_drop > 0); // and decoding resumed
		CHECK(r.view_info_ok);
		// display time is announced in the headset clock (offset 5 s), predicted ahead of "now"
		CHECK(r.display_time_offset_ms > -20 and r.display_time_offset_ms < 100);
		CHECK(srv.session.stats().idr_requests >= 1);
		CHECK(srv.session.stats().tracking > 0);
		srv.wait_disconnect();

		// 2. wrong protocol version is refused like WiVRn does
		auto bad = run_fake_headset({.port = port, .protocol_version = 0x1234, .timeout_ms = 3000});
		CHECK(bad.handshake_state == "incompatible_version");
	}

	{
		// 1b. pacing from the headset's feedback: the headset decodes in 8 ms and blits on its own 72 Hz vsync grid
		// (phase 3.3 ms); WiVRn's pacer must phase-lock the announced display times to that grid.
		Server srv({.encryption = WivrnConfig::Encryption::disabled});
		const int64_t period = 13'888'889, phase = 3'300'000;
		auto r = run_fake_headset({.port = srv.session.port(), .frames = 250, .decode_ns = 8'000'000,
		                           .display_period_ns = period, .display_phase_ns = phase});
		print("paced", r);
		CHECK(r.error.empty());
		int on_grid = 0, n = 0;
		for (size_t i = r.display_times.size() > 40 ? r.display_times.size() - 40 : 0; i < r.display_times.size(); ++i, ++n)
		{
			int64_t off = ((r.display_times[i].second - phase) % period + period) % period;
			off = std::min(off, period - off);
			on_grid += off < 1'000'000;
		}
		printf("paced: %d/%d of the last display times within 1 ms of the headset vsync grid\n", on_grid, n);
		CHECK(n >= 30 and on_grid >= n * 9 / 10);
	}

	char dir_template[] = "/tmp/vrhost-keys.XXXXXX";
	REQUIRE(mkdtemp(dir_template) != nullptr);
	std::string keys_file = std::string(dir_template) + "/known_keys";
	std::string headset_key = crypto::key::generate_x448_keypair().private_key();
	{
		// 3. pairing: the headset proves the PIN (SMP), then everything is AES-128-CTR, UDP shards included
		Server srv({.encryption = WivrnConfig::Encryption::pairing, .pin = "481516", .known_keys_file = keys_file});
		int port = srv.session.port();
		CHECK(srv.session.pin() == "481516");
		auto r = run_fake_headset({.port = port, .frames = 40, .drop_frame = 10, .private_key = headset_key, .pin = "481516"});
		print("pairing", r);
		CHECK(r.error.empty());
		CHECK(r.handshake_state == "pin_needed");
		CHECK(r.encrypted);
		CHECK(r.got_stream_description and r.got_tracking_control and r.timesync_queries > 0);
		CHECK(r.decoded[0] >= 40 and r.decoded[1] >= 40);
		CHECK(r.index_mismatch[0] == 0 and r.index_mismatch[1] == 0);
		CHECK(r.idr_after_drop >= 1 and r.decoded_after_drop > 0);
		CHECK(r.view_info_ok);
		CHECK(srv.session.stats().paired == 1);
		srv.wait_disconnect();

		// 4. the paired headset reconnects without a PIN
		auto again = run_fake_headset({.port = port, .frames = 20, .private_key = headset_key, .pin = "000000"});
		print("paired", again);
		CHECK(again.error.empty());
		CHECK(again.handshake_state == "client_already_paired");
		CHECK(again.encrypted and again.decoded[0] >= 20 and again.decoded[1] >= 20);
		srv.wait_disconnect();

		// 5. a new headset with the wrong PIN is refused and not stored
		auto wrong = run_fake_headset({.port = port, .frames = 5, .timeout_ms = 5000, .pin = "111111"});
		print("wrong pin", wrong);
		CHECK(wrong.handshake_state == "pin_needed");
		CHECK(wrong.error == "Incorrect PIN");
		CHECK(wrong.decoded[0] == 0);
		CHECK(srv.session.stats().paired == 1);
		srv.wait_disconnect();
	}
	{
		// 6. encryption on, pairing off: the paired headset connects, an unknown one gets pairing_disabled
		Server srv({.encryption = WivrnConfig::Encryption::enabled, .known_keys_file = keys_file});
		int port = srv.session.port();
		CHECK(srv.session.pin().empty());
		auto known = run_fake_headset({.port = port, .frames = 10, .private_key = headset_key});
		print("enabled/known", known);
		CHECK(known.error.empty() and known.handshake_state == "client_already_paired" and known.decoded[0] >= 10);
		srv.wait_disconnect();
		auto unknown = run_fake_headset({.port = port, .frames = 5, .timeout_ms = 3000});
		CHECK(unknown.handshake_state == "pairing_disabled");
	}
	std::filesystem::remove_all(dir_template);
	return test_result("loopback");
}
