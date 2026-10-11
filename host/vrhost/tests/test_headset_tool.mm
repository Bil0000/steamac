// SPDX-License-Identifier: GPL-3.0-or-later
// vrhost-test-headset: the loopback test headset (fake_headset.cpp, WiVRn v26.9 client sequence + VideoToolbox decode)
// as a tool, for checking a running steamac-vrhost on this Mac without a real headset (docs/vr.md):
//   vrhost-test-headset [--port N] [--pin NNNNNN] [--frames N] [--size WxH]
// Reports decoded frames per eye, frame numbers read from the image (d3d11bench --vr / test pattern blocks; readable
// when the stream size equals the eye size, i.e. no foveation), the eyes' colour difference (d3d11bench --vr: left
// red, right green), the foveation parameters received, and frame arrival intervals. Exit 0 when frames decoded,
// every readable frame number matched and the eyes differ as expected.
#include "fake_headset.h"
#include "pattern/test_pattern.h"
#include "session/clock.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <string>
#include <vector>

static double mean_cr(CVPixelBufferRef img)
{
	CVPixelBufferLockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
	auto * p = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(img, 1);
	size_t stride = CVPixelBufferGetBytesPerRowOfPlane(img, 1), w = CVPixelBufferGetWidthOfPlane(img, 1),
	       h = CVPixelBufferGetHeightOfPlane(img, 1);
	double sum = 0;
	size_t n = 0;
	for (size_t y = h / 8; y < h; y += 4) // below the frame number blocks
		for (size_t x = 0; x < w; x += 4, ++n)
			sum += p[y * stride + 2 * x + 1];
	CVPixelBufferUnlockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
	return n ? sum / n : 0;
}

static double pct(std::vector<double> v, double q)
{
	if (v.empty())
		return 0;
	std::sort(v.begin(), v.end());
	return v[std::min(v.size() - 1, size_t(q * (v.size() - 1) + 0.5))];
}

int main(int argc, char ** argv)
{
	FakeHeadsetOptions o{.frames = 300, .eye_width = 1024, .eye_height = 1092, .timeout_ms = 60000, .identity_foveation = false};
	for (int i = 1; i + 1 < argc; i += 2)
	{
		std::string a = argv[i], v = argv[i + 1];
		if (a == "--port")
			o.port = std::stoi(v);
		else if (a == "--pin")
			o.pin = v;
		else if (a == "--frames")
			o.frames = std::stoi(v);
		else if (a == "--size")
		{
			unsigned w, h;
			if (sscanf(v.c_str(), "%ux%u", &w, &h) == 2)
				o.eye_width = uint16_t(w), o.eye_height = uint16_t(h);
		}
		else
		{
			fprintf(stderr, "usage: vrhost-test-headset [--port N] [--pin NNNNNN] [--frames N] [--size WxH]\n");
			return 2;
		}
	}
	std::mutex m;
	int read_ok = 0, read_wrong = 0, unreadable = 0;
	double cr[2] = {}, n[2] = {};
	std::vector<double> interval_ms;
	int64_t last = 0;
	o.on_decoded = [&](int eye, uint64_t frame, CVPixelBufferRef img) {
		int64_t r = vrhost::TestPattern::read_frame_index(img);
		double c = mean_cr(img);
		std::lock_guard l(m);
		if (r < 0)
			unreadable++;
		else if (r == int64_t(frame & 0xffff))
			read_ok++;
		else if (read_wrong++ < 5)
			fprintf(stderr, "eye %d frame %llu carries frame %lld\n", eye, (unsigned long long)frame, (long long)r);
		cr[eye] += c;
		n[eye]++;
		if (eye == 0)
		{
			int64_t t = vrhost::now_ns();
			if (last)
				interval_ms.push_back((t - last) / 1e6);
			last = t;
		}
	};
	auto r = run_fake_headset(o);
	double cr0 = n[0] ? cr[0] / n[0] : 0, cr1 = n[1] ? cr[1] / n[1] : 0;
	printf("handshake %s, encrypted %d, decoded %d/%d, IDR %d/%d, frame numbers ok %d wrong %d unreadable %d, "
	       "mean Cr left %.1f right %.1f, foveation x %zu y %zu entries, frame interval ms p50 %.2f p99 %.2f, error '%s'\n",
	       r.handshake_state.c_str(), r.encrypted, r.decoded[0], r.decoded[1], r.idr[0], r.idr[1], read_ok, read_wrong,
	       unreadable, cr0, cr1, r.foveation_x[0].size(), r.foveation_y[0].size(), pct(interval_ms, .5), pct(interval_ms, .99),
	       r.error.c_str());
	bool ok = r.error.empty() and r.decoded[0] >= o.frames and r.decoded[1] >= o.frames and read_wrong == 0 and cr0 > cr1 + 10;
	printf(ok ? "vrhost-test-headset: PASS\n" : "vrhost-test-headset: FAIL\n");
	return ok ? 0 : 1;
}
