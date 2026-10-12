// SPDX-License-Identifier: GPL-3.0-or-later
#include "fake_headset.h"
#include "pattern/test_pattern.h"
#include "session/clock.h"
#include "vt_decode.h"
#include "wivrn/annexb.h"

#include "crypto.h"
#include "protocol_version.h"
#include "secrets.h"
#include "smp.h"
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
		bool from_control = false; // the last packet receive() returned came over TCP
		auto receive = [&](stream_socket * stream) -> th::packets {
			while (std::chrono::steady_clock::now() < deadline)
			{
				from_control = true;
				if (auto p = control.receive_pending())
					return std::move(*p);
				from_control = false;
				if (stream)
					if (auto p = stream->receive_pending())
						return std::move(*p);
				pollfd fds[2] = {{.fd = control.get_fd(), .events = POLLIN}, {.fd = stream ? stream->get_fd() : -1, .events = POLLIN}};
				if (::poll(fds, 2, 50) <= 0)
					continue;
				if (fds[0].revents & POLLIN)
				{
					// the last packet before a close (e.g. pin_check_4 with a wrong PIN) is still readable
					try
					{
						if (auto p = control.receive())
						{
							from_control = true;
							return std::move(*p);
						}
					}
					catch (wivrn::socket_shutdown &)
					{
						throw std::runtime_error("server closed the connection");
					}
				}
				else if (fds[0].revents & (POLLHUP | POLLERR))
					throw std::runtime_error("server closed the connection");
				if (stream and (fds[1].revents & POLLIN))
					if (auto p = stream->receive())
						return std::move(*p);
			}
			throw std::runtime_error("timeout");
		};

		// Client side of the crypto handshake: WiVRn v26.9 client/wivrn_client.cpp wivrn_session::handshake().
		crypto::key headset_keypair = o.private_key.empty() ? crypto::key::generate_x448_keypair()
		                                                    : crypto::key::from_private_key(o.private_key);
		control.send(fh::crypto_handshake{
		        .protocol_version = o.protocol_version ? o.protocol_version : wivrn::protocol_version,
		        .public_key = headset_keypair.public_key(),
		        .name = "steamac fake headset",
		});
		auto ch = std::get<th::crypto_handshake>(receive(nullptr));
		res.handshake_state = std::string(magic_enum::enum_name(ch.state));
		using cs = th::crypto_handshake::crypto_state;
		std::optional<secrets> sec;
		switch (ch.state)
		{
			case cs::encryption_disabled:
				break;
			case cs::pin_needed: {
				crypto::smp pin_check;
				auto msg1 = pin_check.step1(o.pin);
				control.send(fh::pin_check_1{msg1});
				auto msg2 = std::get<th::pin_check_2>(receive(nullptr)).message;
				auto msg3 = pin_check.step3(msg2);
				control.send(fh::pin_check_3{msg3});
				auto msg4 = std::get<th::pin_check_4>(receive(nullptr)).message;
				if (not pin_check.step5(msg4))
					throw std::runtime_error("Incorrect PIN");
			}
				[[fallthrough]];
			case cs::client_already_paired: {
				crypto::key server_key = crypto::key::from_public_key(ch.public_key);
				sec.emplace(headset_keypair, server_key, ch.state == cs::pin_needed ? o.pin : std::string("000000"));
				control.set_aes_key_and_ivs(sec->control_key, sec->control_iv_to_headset, sec->control_iv_from_headset);
				res.encrypted = true;
				break;
			}
			default:
				return res;
		}
		control.send(fh::crypto_handshake{});
		auto h = std::get<th::handshake>(receive(nullptr));
		std::unique_ptr<stream_socket> stream;
		if (h.stream_port > 0)
		{
			stream = std::make_unique<stream_socket>();
			if (sec)
				stream->set_aes_key_and_ivs(sec->stream_key, sec->stream_iv_header_to_headset, sec->stream_iv_header_from_headset);
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
		if (o.speaker_channels)
			info.speaker = fh::headset_info_packet::audio_description{o.speaker_channels, o.speaker_rate};
		if (o.mic_channels)
			info.microphone = fh::headset_info_packet::audio_description{o.mic_channels, o.mic_rate};
		control.send(std::move(info));

		std::array<VtDecoder, 2> dec{VtDecoder(true), VtDecoder(true)};
		std::array<std::map<uint64_t, pending_frame>, 2> frames;
		std::array<bool, 2> need_idr{true, true};
		bool dropped = false;
		std::array<std::optional<uint64_t>, 2> last_frame; // newest frame index seen per stream
		auto last_tracking = std::chrono::steady_clock::now();
		float t = 0;

		std::array<std::map<uint64_t, int64_t>, 2> first_packet; // frame -> headset time of its first shard
		auto send_feedback = [&](uint8_t idx, uint64_t frame, bool ok) {
			fh::feedback fb{};
			fb.frame_index = frame;
			fb.stream_index = idx;
			auto fp = first_packet[idx].find(frame);
			fb.received_first_packet = fp != first_packet[idx].end() ? fp->second : hs_now();
			fb.received_last_packet = ok ? hs_now() : 0;
			fb.sent_to_decoder = ok ? hs_now() : 0;
			fb.received_from_decoder = ok ? std::max(hs_now(), fb.received_first_packet + o.decode_ns) : 0;
			if (ok and o.display_period_ns > 0)
			{
				// blit at the next headset vsync after decoding, displayed one vsync later
				int64_t t = fb.received_from_decoder - o.display_phase_ns;
				int64_t blit = (t / o.display_period_ns + 1) * o.display_period_ns + o.display_phase_ns;
				fb.blitted = blit;
				fb.displayed = blit + o.display_period_ns;
				fb.times_displayed = 1;
			}
			control.send(std::move(fb));
		};

		bool mic_on = false;
		int64_t mic_start = 0;
		auto send_mic = [&] {
			if (not mic_on or not o.mic_channels)
				return;
			int64_t now = vrhost::now_ns();
			size_t due = size_t((now - mic_start) * double(o.mic_rate) / 1e9);
			size_t marker_at = size_t(o.mic_rate) * o.mic_marker_ms / 1000;
			while (res.mic_frames_sent + o.mic_rate / 200 <= due)
			{
				size_t n = o.mic_rate / 200;
				std::vector<int16_t> pcm(n * o.mic_channels);
				for (size_t f = 0; f < n; ++f)
				{
					size_t k = res.mic_frames_sent + f;
					int16_t v = int16_t(std::lround(8000 * std::sin(2 * M_PI * o.mic_tone_hz * double(k) / o.mic_rate)));
					if (k >= marker_at and k < marker_at + 48)
					{
						v = 30000;
						if (k == marker_at)
							res.mic_marker_sent_ns = vrhost::now_ns();
					}
					for (int c = 0; c < o.mic_channels; ++c)
						pcm[f * o.mic_channels + c] = v;
				}
				res.mic_frames_sent += n;
				control.send(wivrn::audio_data{
				        .timestamp = hs_now(),
				        .payload = std::span(reinterpret_cast<uint8_t *>(pcm.data()), pcm.size() * 2),
				});
			}
		};

		while (res.decoded[0] < o.frames or res.decoded[1] < o.frames)
		{
			send_mic();
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
			else if (auto * ad = std::get_if<th::audio_stream_description>(&pkt))
			{
				bool spk = o.speaker_channels ? ad->speaker and ad->speaker->num_channels == o.speaker_channels and
				                                        ad->speaker->sample_rate == o.speaker_rate
				                              : not ad->speaker;
				bool mic = o.mic_channels ? ad->microphone and ad->microphone->num_channels == o.mic_channels and
				                                    ad->microphone->sample_rate == o.mic_rate
				                          : not ad->microphone;
				res.got_audio_description = spk and mic;
			}
			else if (auto * fc = std::get_if<th::feature_control>(&pkt))
			{
				if (fc->f == th::feature_control::microphone)
				{
					res.mic_feature.push_back(fc->state);
					if (fc->state and not mic_on)
						mic_start = vrhost::now_ns();
					mic_on = fc->state;
				}
			}
			else if (auto * a = std::get_if<wivrn::audio_data>(&pkt))
			{
				const int16_t * p = reinterpret_cast<const int16_t *>(a->payload.data());
				size_t samples = a->payload.size() / 2;
				res.speaker.insert(res.speaker.end(), p, p + samples);
				res.speaker_packets++;
				if (o.speaker_channels)
				{
					res.max_speaker_packet_frames = std::max(res.max_speaker_packet_frames, int(samples / o.speaker_channels));
					res.speaker_arrivals.emplace_back(vrhost::now_ns(), res.speaker.size() / o.speaker_channels);
				}
			}
			else if (auto * hp = std::get_if<th::haptics>(&pkt))
				res.haptics.push_back({int(hp->id), int64_t(hp->duration.count()), hp->frequency, hp->amplitude});
			else if (std::holds_alternative<th::tracking_control>(pkt))
				res.got_tracking_control = not std::get<th::tracking_control>(pkt).pattern.empty();
			else if (auto * s = std::get_if<th::video_stream_data_shard>(&pkt))
			{
				res.shards++;
				if (from_control and stream)
					res.control_shards++;
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
				// WiVRn's shard accumulator: a newer frame's shard ends the wait for the indices before it, which are
				// reported as "not sent because no shard was received"
				if (last_frame[idx] and s->frame_idx > *last_frame[idx] + 1)
					for (uint64_t lost = *last_frame[idx] + 1; lost < s->frame_idx and lost < *last_frame[idx] + 9; ++lost)
					{
						res.index_gaps[idx]++;
						send_feedback(idx, lost, false);
					}
				if (not last_frame[idx] or s->frame_idx > *last_frame[idx])
					last_frame[idx] = s->frame_idx;
				first_packet[idx].try_emplace(s->frame_idx, hs_now());
				if (first_packet[idx].size() > 64)
					first_packet[idx].erase(first_packet[idx].begin());
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
				{
					res.foveation_x[e] = vi.foveation[e].x;
					res.foveation_y[e] = vi.foveation[e].y;
				}
				for (int e = 0; e < 2 and o.identity_foveation; ++e)
					if (vi.foveation[e].x != std::vector<uint16_t>{o.eye_width} or vi.foveation[e].y != std::vector<uint16_t>{o.eye_height})
						res.view_info_ok = false;
				// (frames rendered before the first tracking packet arrived carry the default, all-zero view poses)
				bool tracked = vi.pose[0].position.x != 0 or vi.pose[1].position.x != 0;
				float dx = vi.pose[1].position.x - vi.pose[0].position.x, dz = vi.pose[1].position.z - vi.pose[0].position.z;
				if (tracked and std::abs(std::sqrt(dx * dx + dz * dz) - 0.064f) > 0.002f)
					res.view_info_ok = false;
				res.display_time_offset_ms = (vi.display_time - hs_now()) / 1e6;
				if (idx == 0)
					res.display_times.emplace_back(frame_idx, vi.display_time);

				CVPixelBufferRef img = dec[idx].decode(au);
				send_feedback(idx, frame_idx, img != nullptr);
				if (not img)
					continue;
				int64_t read = vrhost::TestPattern::read_frame_index(img);
				if (o.on_decoded)
					o.on_decoded(idx, frame_idx, img);
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
