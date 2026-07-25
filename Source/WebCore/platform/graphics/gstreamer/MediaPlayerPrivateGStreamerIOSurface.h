/*
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
 * aint with this library; see the file COPYING.LIB.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 */

// [leopard] PIMPL wrapper around the Cocoa IOSurface present bridge.
// See the .mm file for the full architecture. The class is intentionally
// C++ ABI only — no Cocoa types leak into the header so that the rest of
// the GStreamer player code can include this without #ifdef OBJC.

#pragma once

#if USE(GSTREAMER_GL) && PLATFORM(COCOA)

#include <wtf/Forward.h>
#include <wtf/Noncopyable.h>
#include <wtf/UniqueRef.h>

typedef struct _GstGLMemory GstGLMemory;

OBJC_CLASS CALayer;

namespace WebCore {

struct IOSurfaceBridgeState;

class MediaPlayerPrivateGStreamerIOSurface {
    WTF_MAKE_NONCOPYABLE(MediaPlayerPrivateGStreamerIOSurface);
    WTF_MAKE_FAST_ALLOCATED;
public:
    MediaPlayerPrivateGStreamerIOSurface();
    ~MediaPlayerPrivateGStreamerIOSurface();

    // Returns the CALayer that should be exposed via
    // MediaPlayerPrivateGStreamer::platformLayer(). The layer is owned
    // by this bridge; the caller must NOT release it.
    CALayer* layer() const;

    // Lazily (re)allocate the IOSurface + IOSurface-backed GL texture
    // for the given dimensions. Returns true on success or if a surface
    // of the requested size already exists. Returns false if allocation
    // failed (in which case presentGLMemory will also fail).
    bool ensureSurfaceOfSize(int width, int height);

    // Copy the source GstGLMemory's texture into our IOSurface texture,
    // then set the IOSurface as the CALayer's contents. Core Animation
    // composites the result on the next vsync. Must be called on the
    // main thread.
    void presentGLMemory(GstGLMemory*, int width, int height);

private:
    std::unique_ptr<IOSurfaceBridgeState> m_state;
};

} // namespace WebCore

#endif // USE(GSTREAMER_GL) && PLATFORM(COCOA)
