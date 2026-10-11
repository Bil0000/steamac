// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#include "vr_pipeline.h"
#include "session/clock.h"

namespace vrhost
{
SessionEncoderSink::SessionEncoderSink(VrSession & session, uint32_t w, uint32_t h) : session(session)
{
	NSDictionary * attrs = @{
		(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
		(id)kCVPixelBufferWidthKey: @(w),
		(id)kCVPixelBufferHeightKey: @(h),
		(id)kCVPixelBufferIOSurfacePropertiesKey: @{},
		(id)kCVPixelBufferMetalCompatibilityKey: @YES,
	};
	if (CVPixelBufferPoolCreate(nullptr, nullptr, (__bridge CFDictionaryRef)attrs, &pool) != kCVReturnSuccess)
		throw std::runtime_error("CVPixelBufferPoolCreate failed");
}

SessionEncoderSink::~SessionEncoderSink()
{
	for (auto b: pending)
		if (b)
			CVPixelBufferRelease(b);
	CVPixelBufferPoolRelease(pool);
}

CVPixelBufferRef SessionEncoderSink::acquire(int)
{
	CVPixelBufferRef b = nullptr;
	CVPixelBufferPoolCreatePixelBuffer(nullptr, pool, &b);
	return b;
}

void SessionEncoderSink::encode(int eye, CVPixelBufferRef buffer, const LinkFrame & lf, const FoveationParams & p)
{
	if (pending[eye])
		CVPixelBufferRelease(pending[eye]);
	pending[eye] = CVPixelBufferRetain(buffer);
	params[eye] = p;
	if (eye != 1 or not pending[0])
		return;
	Frame f;
	f.frame_id = lf.frame_id;
	f.display_time = lf.display_time;
	for (int e = 0; e < 2; ++e)
	{
		f.pose[e].orientation = {lf.pose[e][0], lf.pose[e][1], lf.pose[e][2], lf.pose[e][3]};
		f.pose[e].position = {lf.pose[e][4], lf.pose[e][5], lf.pose[e][6]};
		f.fov[e] = {lf.fov[e].left, lf.fov[e].right, lf.fov[e].up, lf.fov[e].down};
		f.eye[e].surface = CVPixelBufferGetIOSurface(pending[e]);
		f.foveation[e] = {params[e].x, params[e].y};
	}
	session.submit(f); // synchronous: encoded and sent
	for (auto & b: pending)
	{
		CVPixelBufferRelease(b);
		b = nullptr;
	}
}

VrPipeline::VrPipeline(VrSession & session, int link_fd, const std::string & mach_name) : session(session)
{
	server = std::make_unique<VrLinkServer>(link_fd, mach_name, [this](const LinkFrame & f) { on_frame(f); });
}

VrPipeline::~VrPipeline()
{
	server.reset(); // joins the link thread before the bridge goes away
}

bool VrPipeline::peer_closed() const
{
	return server->peer_closed();
}

void VrPipeline::on_frame(const LinkFrame & f)
{
	st.received++;
	auto info = session.connected() ? session.headset() : std::nullopt;
	if (not info or not info->eye_width)
	{
		st.no_headset++;
		return; // VrLinkServer releases the images
	}
	std::lock_guard lock(m);
	if (info->eye_width != w or info->eye_height != h)
	{
		bridge.reset();
		sink = std::make_unique<SessionEncoderSink>(session, info->eye_width, info->eye_height);
		bridge = std::make_unique<CompositorBridge>(info->eye_width, info->eye_height, *sink);
		w = info->eye_width;
		h = info->eye_height;
	}
	(*bridge)(f);
	st.submitted++;
	st.last_compose_gpu_ns = bridge->last_timing().compose_gpu_ns;
	st.last_latency_ns = now_ns() - f.app_submit_time;
}
} // namespace vrhost
