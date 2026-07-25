/*
 * Copyright (C) 2010, 2011, 2012 Igalia S.L
 * Copyright (C) 2026 startergo (leopard-webkit-build)
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public License
 * along with this library; see the file COPYING.LIB.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 */

// [leopard] CG counterpart of ImageGStreamerCairo.cpp for the macOS Cocoa
// port (USE(CG) && !USE(CAIRO)). Without this file, ImageGStreamer's ctor
// and dtor are unresolved and the WebCore link fails; GStreamer.cmake:217
// guards the inclusion on (NOT USE_CAIRO).
//
// Structural parity with ImageGStreamerCairo.cpp where the CG path allows:
//   - Parse GstSample caps via gst_video_info_from_caps.
//   - Map the GstBuffer via gst_video_frame_map (READ).
//   - Hand the pixel data to the platform image wrapper (CGImageRef here,
//     cairo_surface_t in the Cairo version).
//   - BitmapImage::create(NativeImagePtr).
//   - Apply GstVideoCropMeta if present.
//
// Differences forced by CG vs cairo:
//   - NativeImagePtr is RetainPtr<CGImageRef> on Cocoa, not cairo_surface_t.
//   - ImageGStreamer.h's m_videoFrame / m_frameMapped fields are #if
//     USE(CAIRO) — CG does not retain them. This means CG cannot keep the
//     GstBuffer mapped for the image's lifetime (the cairo surface did so
//     because it referenced the buffer data in-place); the CG path must
//     COPY the data into CG-owned memory (CGBitmapContext) so the buffer
//     can be unmapped and reused before the BitmapImage is destroyed.
//   - GStreamer does not premultiply alpha; cairo (CAIRO_FORMAT_ARGB32)
//     and CG (kCGImageAlphaPremultipliedFirst) both do. Premultiply when
//     the source format has alpha, mirroring ImageGStreamerCairo.cpp's
//     premultiply step.
//
// Recovery note: this file is a recreation. The original was lost (an
// untracked working-tree file deleted by build_610.sh phase2's git clean
// during a --clean run). The interface contract comes from
// ImageGStreamer.h at HEAD; the structural template from
// ImageGStreamerCairo.cpp at HEAD. Behavioural risk: subtle byte-order
// or alpha-premultiply mistakes that compile and link cleanly but paint
// wrong colors. Verify at first deploy against a known test pattern
// (e.g. videotestsrc pattern=smpte75 with alpha) before trusting.

#include "config.h"
#include "ImageGStreamer.h"

#if ENABLE(VIDEO) && USE(GSTREAMER) && USE(CG)

#include "GStreamerCommon.h"

#include <CoreGraphics/CoreGraphics.h>
#include <CoreGraphics/CGBitmapContext.h>
#include <wtf/RetainPtr.h>

#include <gst/gst.h>
#include <gst/video/gstvideometa.h>

namespace WebCore {

ImageGStreamer::ImageGStreamer(GstSample* sample)
{
    GstCaps* caps = gst_sample_get_caps(sample);
    GstVideoInfo videoInfo;
    gst_video_info_init(&videoInfo);
    if (!gst_video_info_from_caps(&videoInfo, caps))
        return;

    // The CG path only supports single-plane formats (same constraint as
    // the Cairo path). Multi-plane formats (e.g. NV12) would need separate
    // handling per plane.
    ASSERT(GST_VIDEO_INFO_N_PLANES(&videoInfo) == 1);

    m_hasAlpha = GST_VIDEO_INFO_HAS_ALPHA(&videoInfo);

    GstBuffer* buffer = gst_sample_get_buffer(sample);
    if (UNLIKELY(!GST_IS_BUFFER(buffer)))
        return;

    GstVideoFrame videoFrame;
    if (!gst_video_frame_map(&videoFrame, &videoInfo, buffer, GST_MAP_READ))
        return;

    unsigned char* bufferData = reinterpret_cast<unsigned char*>(GST_VIDEO_FRAME_PLANE_DATA(&videoFrame, 0));
    int stride = GST_VIDEO_FRAME_PLANE_STRIDE(&videoFrame, 0);
    int width = GST_VIDEO_FRAME_WIDTH(&videoFrame);
    int height = GST_VIDEO_FRAME_HEIGHT(&videoFrame);
    GstVideoFormat format = GST_VIDEO_FRAME_FORMAT(&videoFrame);

    // CG destination format. On little-endian macOS:
    //   kCGBitmapByteOrder32Host | kCGImageAlphaPremultipliedFirst
    // yields byte order B,G,R,A in memory (the 32-bit ARGB word stored
    // little-endian), which matches the GStreamer BGRA byte order
    // directly. For non-alpha formats we use kCGImageAlphaNoneSkipFirst
    // (still B,G,R,X byte order in memory).
    CGBitmapInfo bitmapInfo = kCGBitmapByteOrder32Host |
        (m_hasAlpha ? kCGImageAlphaPremultipliedFirst : kCGImageAlphaNoneSkipFirst);

    RetainPtr<CGColorSpaceRef> colorSpace = adoptCF(CGColorSpaceCreateDeviceRGB());
    RetainPtr<CGContextRef> context = adoptCF(CGBitmapContextCreate(
        nullptr, width, height, 8, stride, colorSpace.get(), bitmapInfo));
    if (!context) {
        gst_video_frame_unmap(&videoFrame);
        return;
    }

    void* contextData = CGBitmapContextGetData(context.get());

    // GStreamer does not premultiply alpha; CG requires it (we declared
    // kCGImageAlphaPremultipliedFirst above). Premultiply in-place into
    // the CG-owned buffer. Mirrors ImageGStreamerCairo.cpp's premultiply
    // step; the only difference is the destination is CG memory rather
    // than a fastMalloc'd buffer.
    //
    // Two source byte orders are handled:
    //   - GST_VIDEO_FORMAT_BGRA: B,G,R,A in memory. CG on little-endian
    //     with PremultipliedFirst/32Host is also B,G,R,A. Straight
    //     premultiply, no channel swap.
    //   - GST_VIDEO_FORMAT_RGBA: R,G,B,A in memory. Same word in 32-bit
    //     terms but byte order differs from CG. Swap R and B during
    //     premultiply (matches the Cairo version's byte mapping).
    if (m_hasAlpha) {
        unsigned char* src = bufferData;
        unsigned char* dst = static_cast<unsigned char*>(contextData);
        if (format == GST_VIDEO_FORMAT_RGBA) {
            for (int i = 0; i < width * height; ++i) {
                unsigned char a = src[3];
#if G_BYTE_ORDER == G_LITTLE_ENDIAN
                // src RGBA (LE) -> dst BGRA (CG LE premult-first)
                dst[0] = (src[2] * a + 128) / 255;  // B <= src[2]=B
                dst[1] = (src[1] * a + 128) / 255;  // G
                dst[2] = (src[0] * a + 128) / 255;  // R <= src[0]=R
                dst[3] = a;
#else
                dst[0] = a;
                dst[1] = (src[0] * a + 128) / 255;
                dst[2] = (src[1] * a + 128) / 255;
                dst[3] = (src[2] * a + 128) / 255;
#endif
                src += 4;
                dst += 4;
            }
        } else {
            // Assume BGRA (or any 32-bit format with A in byte 3 and
            // matching CG byte order). Straight premultiply in place.
            for (int i = 0; i < width * height; ++i) {
                unsigned char a = src[3];
                dst[0] = (src[0] * a + 128) / 255;
                dst[1] = (src[1] * a + 128) / 255;
                dst[2] = (src[2] * a + 128) / 255;
                dst[3] = a;
                src += 4;
                dst += 4;
            }
        }
    } else {
        // No alpha: straight memcpy. Format is xRGB or BGRx; both
        // byte-match CG's premultiplied-first/skip-first layout.
        memcpy(contextData, bufferData, static_cast<size_t>(height) * stride);
    }

    // The GstBuffer's data is no longer referenced after this point — the
    // CGImageRef owns its own copy via the CGBitmapContext. Safe to unmap.
    gst_video_frame_unmap(&videoFrame);

    RetainPtr<CGImageRef> cgImage = adoptCF(CGBitmapContextCreateImage(context.get()));
    if (!cgImage)
        return;

    m_image = BitmapImage::create(WTFMove(cgImage));

    if (GstVideoCropMeta* cropMeta = gst_buffer_get_video_crop_meta(buffer))
        setCropRect(FloatRect(cropMeta->x, cropMeta->y, cropMeta->width, cropMeta->height));
}

ImageGStreamer::~ImageGStreamer()
{
    if (m_image)
        m_image = nullptr;
    // No GstVideoFrame to unmap on the CG path — ImageGStreamer.h's
    // m_videoFrame / m_frameMapped fields are #if USE(CAIRO) only. The
    // buffer was unmapped inline in the ctor after the data copy.
}

} // namespace WebCore

#endif // ENABLE(VIDEO) && USE(GSTREAMER) && USE(CG)
