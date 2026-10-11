// SPDX-License-Identifier: GPL-3.0-or-later
#include "fake_headset.h"
#include "pattern/test_pattern.h"
#include "session/clock.h"
#include "vt_decode.h"
#include "wivrn/annexb.h"

#include "protocol_version.h"
#include "wivrn_packets.h"
#include "wivrn_sockets.h"

#include <arpa/inet.h>
#include <chrono>
#include <cmath>
#include <magic_enum.hpp>
#include <map>
#include <poll.h>

namespace fh = wivrn::from_headset;
namespace th = wivrn::to_headset;
using control_socket = wivrn::typed_socket<wivrn::TCP, th::packets, fh::packets>;
using stream_socket = wivrn::typed_socket<wivrn::UDP, th::packets, fh::packets>;

namespace
{
struct pending_frame
{
	std::map<uint16_t, std::vector<uint8_t>> shards;
	int last = -1;
	std::optional<th::video_stream_data_shard::view_info_t> view_info;
};

XrPosef yaw_pose(float a)
{
	return XrPosef{.orientation = {0, std::sin(a / 2), 0, std::cos(a / 2)}, .position = {0, 1.6f, 0}};
}
} // namespace

FakeHeadsetResult run_fake_headset(const FakeHeadsetOptions & o)
{
	FakeHeadsetResult res;
	auto hs_now = [&] { return vrhost::now_ns() + o.clock_offset_ns; };
	try
	{
		sockaddr_in6 addr{};
		addr.sin6_family = AF_INET6;
		addr.sin6_port = htons(o.port);
		addr.sin6_addr = in6addr_loopback;
		control_socket control(addr);

		auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(o.timeout_ms);
		auto receive = [&](stream_socket * stream) -> th::packets {
			while (std::chrono::steady_clock::now() < deadline)
			{
				if (auto p = control.receive_pending())
					return std::move(*p);
				if (stream)
					if (auto p = stream->receive_pending())
						return std::move(*p);
				pollfd fds[2] = {{.fd = control.get_fd(), .events = POLLIN}, {.fd = stream ? stream->get_fd() : -1, .events = POLLIN}};
				if (::poll(fds, 2, 50) <= 0)
					continue;
				if (fds[0].revents & (POLLHUP | POLLERR))
					throw std::runtime_error("server closed the connection");
				if (fds[0].revents & POLLIN)
					if (auto p = control.receive())
						return std::move(*p);
				if (stream and (fds[1].revents & POLLIN))
					if (auto p = stream->receive())
						return std::move(*p);
			}
			throw std::runtime_error("timeout");
		};

		control.send(fh::crypto_handshake{
		        .protocol_version = o.protocol_version ? o.protocol_version : wivrn::protocol_version,
		        .public_key = "",
		        .name = "steamac fake headset",
		});
		auto ch = std::get<th::crypto_handshake>(receive(nullptr));
		res.handshake_state = std::string(magic_enum::enum_name(ch.state));
		if (ch.state != th::crypto_handshake::crypto_state::encryption_disabled)
			return res;
		control.send(fh::crypto_handshake{});
		auto h = std::get<th::handshake>(receive(nullptr));
		std::unique_ptr<stream_socket> stream;
		if (h.stream_port > 0)
		{
			stream = std::make_unique<stream_socket>();
			addr.sin6_port = htons(h.stream_port);
			stream->connect(addr);
			stream->send(fh::handshake{});
		}
		else
			control.send(fh::handshake{});
		std::get<th::handshake>(receive(stream.get()));

		fh::headset_info_packet info{};
		info.render_eye_width = o.eye_width;
		info.render_eye_height = o.eye_height;
		info.stream_eye_width = o.eye_width;
		info.stream_eye_height = o.eye_height;
		info.available_refresh_rates = {72, 90};
		info.settings.preferred_refresh_rate = 72;
		info.settings.bitrate_bps = 20'000'000;
		for (auto & f: info.fov)
			f = XrFovf{-0.9f, 0.8f, 0.85f, -0.9f};
		info.supported_codecs = {wivrn::video_codec::h265, wivrn::video_codec::h264};
		info.system_name = "fake";
		control.send(std::move(info));

		std::array<VtDecoder, 2> dec{VtDecoder(true), VtDecoder(true)};
		std::array<std::map<uint64_t, pending_frame>, 2> frames;
		std::array<bool, 2> need_idr{true, true};
		bool dropped = false;
		auto last_tracking = std::chrono::steady_clock::now();
		float t = 0;

		auto send_feedback = [&](uint8_t idx, uint64_t frame, bool ok) {
			fh::feedback fb{};
			fb.frame_index = frame;
			fb.stream_index = idx;
			fb.received_first_packet = hs_now();
			fb.received_last_packet = ok ? hs_now() : 0;
			fb.sent_to_decoder = ok ? hs_now() : 0;
			fb.received_from_decoder = ok ? hs_now() : 0;
			control.send(std::move(fb));
		};

		while (res.decoded[0] < o.frames or res.decoded[1] < o.frames)
		{
			auto now = std::chrono::steady_clock::now();
			if (now - last_tracking > std::chrono::milliseconds(5))
			{
				last_tracking = now;
				t += 0.005f;
				fh::tracking tr{};
				tr.production_timestamp = hs_now();
				tr.timestamp = hs_now();
				tr.view_flags = XR_VIEW_STATE_ORIENTATION_VALID_BIT | XR_VIEW_STATE_POSITION_VALID_BIT;
				for (int i = 0; i < 2; ++i)
					tr.views[i] = {.pose = {.orientation = {0, 0, 0, 1}, .position = {i ? 0.032f : -0.032f, 0, 0}},
					               .fov = {-0.9f, 0.8f, 0.85f, -0.9f}};
				tr.device_poses.push_back({.pose = yaw_pose(0.3f * std::sin(t)),
				                           .angular_velocity = {0, 0.3f * std::cos(t), 0},
				                           .device = wivrn::device_id::HEAD,
				                           .flags = wivrn::from_headset::orientation_valid | wivrn::from_headset::position_valid |
				                                    wivrn::from_headset::angular_velocity_valid});
				if (stream)
					stream->send(std::move(tr));
				else
					control.send(std::move(tr));
			}

			th::packets pkt = receive(stream.get());
			if (auto * q = std::get_if<th::timesync_query>(&pkt))
			{
				res.timesync_queries++;
				fh::timesync_response r{.query = q->query, .response = hs_now()};
				if (stream)
					stream->send(std::move(r));
				else
					control.send(std::move(r));
			}
			else if (std::holds_alternative<th::video_stream_description>(pkt))
			{
				auto & d = std::get<th::video_stream_description>(pkt);
				res.got_stream_description = d.width == o.eye_width and d.height == o.eye_height and d.codec[0] == wivrn::video_codec::h265;
			}
			else if (std::holds_alternative<th::tracking_control>(pkt))
				res.got_tracking_control = not std::get<th::tracking_control>(pkt).pattern.empty();
			else if (auto * s = std::get_if<th::video_stream_data_shard>(&pkt))
			{
				res.shards++;
				res.max_shard_bytes = std::max(res.max_shard_bytes, int(s->payload.size()));
				uint8_t idx = s->stream_item_idx;
				if (idx > 1)
					continue;
				if (o.drop_frame >= 0 and idx == 0 and int64_t(s->frame_idx) == o.drop_frame)
				{
					if (not dropped)
					{
						dropped = true;
						need_idr[0] = true; // decoder state lost until the next IDR
						send_feedback(0, s->frame_idx, false);
					}
					continue;
				}
				auto & f = frames[idx][s->frame_idx];
				f.shards[s->shard_idx].assign(s->payload.begin(), s->payload.end());
				if (s->view_info)
					f.view_info = s->view_info;
				if (s->timing_info)
					f.last = s->shard_idx;
				if (f.last < 0 or int(f.shards.size()) != f.last + 1 or not f.view_info)
					continue;

				std::vector<uint8_t> au;
				for (auto & [_, d]: f.shards)
					au.insert(au.end(), d.begin(), d.end());
				auto vi = *f.view_info;
				uint64_t frame_idx = s->frame_idx;
				frames[idx].erase(frames[idx].begin(), std::next(frames[idx].find(frame_idx)));

				bool is_idr = false;
				for (auto n: vrhost::annexb::split(au))
					is_idr |= vrhost::annexb::hevc_nal_type(n) == vrhost::annexb::hevc_vps;
				if (is_idr)
				{
					res.idr[idx]++;
					if (dropped and idx == 0)
						res.idr_after_drop++;
					need_idr[idx] = false;
				}
				if (need_idr[idx])
				{
					send_feedback(idx, frame_idx, false);
					continue;
				}

				// view_info checks: identity foveation, both eye poses 64 mm apart, display time in headset clock
				for (int e = 0; e < 2; ++e)
					if (vi.foveation[e].x != std::vector<uint16_t>{o.eye_width} or vi.foveation[e].y != std::vector<uint16_t>{o.eye_height})
						res.view_info_ok = false;
				float dx = vi.pose[1].position.x - vi.pose[0].position.x, dz = vi.pose[1].position.z - vi.pose[0].position.z;
				if (std::abs(std::sqrt(dx * dx + dz * dz) - 0.064f) > 0.002f)
					res.view_info_ok = false;
				res.display_time_offset_ms = (vi.display_time - hs_now()) / 1e6;

				CVPixelBufferRef img = dec[idx].decode(au);
				send_feedback(idx, frame_idx, img != nullptr);
				if (not img)
					continue;
				int64_t read = vrhost::TestPattern::read_frame_index(img);
				if (read != int64_t(frame_idx & 0xffff))
					res.index_mismatch[idx]++;
				res.decoded[idx]++;
				if (dropped and idx == 0)
					res.decoded_after_drop++;
				CVPixelBufferRelease(img);
			}
		}
	}
	catch (std::exception & e)
	{
		res.error = e.what();
	}
	return res;
}
