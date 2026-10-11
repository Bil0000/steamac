// SPDX-License-Identifier: GPL-3.0-or-later
// WiVRn adapter: a minimal WiVRn-compatible server (protocol of WiVRn v26.9, see third_party/wivrn/UPSTREAM.md)
// behind the VrSession interface. Replaces WiVRn's Monado-bound server/driver with what a stream needs:
// handshake (wivrn_connection.cpp), timesync (clock_offset.cpp), tracking_control, pose history, IDR handling
// (idr_handler.cpp), shard/timing logic (video_encoder.cpp SendData).
#pragma once

#include "session/pose_history.h"
#include "session/vr_session.h"

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

namespace vrhost
{
struct WivrnConfig
{
	int port = 9757;      // WiVRn default_port (TCP control + UDP stream)
	bool advertise = true; // Bonjour _wivrn._tcp
	bool tcp_only = false;
	uint32_t bitrate_bps = 50'000'000;
	// 0 = use the headset's stream_eye_width/height
	uint32_t width = 0, height = 0;
	std::function<void(const std::string &)> log = nullptr;
};

// Server-side statistics, for tests and the self-test report.
struct WivrnStats
{
	std::atomic<uint64_t> frames_sent{0}, idr_sent{0}, idr_requests{0}, feedback{0}, tracking{0}, timesync{0},
	        bytes_sent{0};
	std::atomic<int64_t> last_encode_ns{0};
	std::atomic<int64_t> last_feedback_decode_ns{0}; // received_from_decoder - received_first_packet, headset clock
};

class WivrnSession final : public VrSession
{
public:
	explicit WivrnSession(WivrnConfig);
	~WivrnSession() override;

	void start(SessionListener *) override;
	void stop() override;
	bool connected() const override;
	std::optional<HeadsetInfo> headset() const override;
	FrameTiming next_frame_timing() override;
	bool views_at(ns t, std::array<Pose, 2> & pose, std::array<Fov, 2> & fov) override;
	std::optional<TrackedPose> pose_at(Device, ns t) override;
	void submit(const Frame &) override;
	void haptics(Device, float duration_s, float frequency, float amplitude) override;
	void request_idr() override;

	int port() const; // bound port (useful with port = 0 in tests)
	const WivrnStats & stats() const;
	static uint64_t protocol_version();

private:
	struct impl;
	std::unique_ptr<impl> p;
};
} // namespace vrhost
