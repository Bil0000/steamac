// SPDX-License-Identifier: GPL-3.0-or-later
// Test-only headset that follows the WiVRn v26.9 client connection sequence (client/wivrn_client.cpp, encryption
// disabled) over loopback, sends headset info / tracking / timesync answers / feedback, and reassembles and decodes the
// video shards with VideoToolbox. The end-to-end check against the real WiVRn client is done separately (docs/vr.md).
#pragma once
#include <array>
#include <atomic>
#include <cstdint>
#include <string>
#include <vector>

struct FakeHeadsetOptions
{
	int port = 9757;
	uint64_t protocol_version = 0; // 0 = ours
	int frames = 60;              // decoded frames wanted per eye
	int64_t drop_frame = -1;      // ignore all shards of this frame on stream 0 and report it lost
	uint16_t eye_width = 640, eye_height = 704;
	int timeout_ms = 20000;
	int64_t clock_offset_ns = 5'000'000'000; // headset clock = host clock + this
};

struct FakeHeadsetResult
{
	std::string error;            // empty on success of the protocol part
	std::string handshake_state;  // to_headset::crypto_handshake state name
	bool got_stream_description = false;
	bool got_tracking_control = false;
	int timesync_queries = 0;
	std::array<int, 2> decoded{};       // frames decoded per eye
	std::array<int, 2> index_mismatch{}; // decoded frame index != frame_idx
	std::array<int, 2> idr{};            // IDR access units received
	int idr_after_drop = 0;              // IDRs on stream 0 after the dropped frame
	int decoded_after_drop = 0;          // stream 0 frames decoded after the drop
	int shards = 0, max_shard_bytes = 0;
	bool view_info_ok = true;    // first shard carries view_info with identity foveation and plausible poses
	double display_time_offset_ms = 0; // view_info.display_time - (host now + clock_offset), last frame
};

FakeHeadsetResult run_fake_headset(const FakeHeadsetOptions &);
