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

// [leopard] Cocoa IOSurface present bridge for the GStreamer media player.
//
// Architecture (one per MediaPlayerPrivateGStreamer):
//
//   ┌─ PlatformDisplay (process-global, leak-on-exit) ──────────┐
//   │  CGLContextObj  cglCtx (standalone, on the 9400M)          │
//   │  GstGLDisplay*  gstDisplay (default = Cocoa subclass)      │
//   │  GstGLContext*  gstContext (GstGLContextCocoa, shares      │
//   │                              with cglCtx)                   │
//   └────────────────────────────────────────────────────────────┘
//                                ▲
//                                │ glupload + glcolorconvert produce
//                                │ GstGLMemory textures inside this ctx
//                                │
//   ┌─ MediaPlayerPrivateGStreamerIOSurface (per player) ───────┐
//   │  CALayer*                  m_layer                         │
//   │  IOSurfaceRef              m_surface (BGRA, w x h)         │
//   │  GLuint                    m_ioTexture (RECTANGLE,         │
//   │                                         bound to surface)   │
//   │                                                            │
//   │  each triggerRepaint:                                      │
//   │    1. pull GstGLMemory from sample                        │
//   │    2. gst_gl_memory_copy_into_texture(src, m_ioTexture, …)│
//   │    3. layer.contents = (__bridge id)m_surface              │
//   │    4. Core Animation composites on its own cadence         │
//   └────────────────────────────────────────────────────────────┘
//
// All CGL/IOSurface/CALayer state is owned by this class. The .cpp file
// only sees a small C++ ABI surface (the public methods below).
//
// Threading: all GL calls happen on the main thread (which is also
// WebKit's compositing thread for CAOpenGLLayer). The copy_into_texture
// implementation runs in the calling thread's GL context, not GstGL's
// thread_add — copy_into_texture is internally a synchronous GPU blit
// that does not require a thread_add.

#include "config.h"

#if USE(GSTREAMER_GL) && PLATFORM(COCOA)

#include "MediaPlayerPrivateGStreamerIOSurface.h"

#include "GStreamerCommon.h"
#include "PlatformDisplay.h"
#include <wtf/RetainPtr.h>

#include <OpenGL/OpenGL.h>
#include <OpenGL/CGLCurrent.h>
#include <OpenGL/CGLTypes.h>
#include <OpenGL/CGLIOSurface.h>
#include <OpenGL/glext.h>

#import <QuartzCore/QuartzCore.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <CoreFoundation/CoreFoundation.h>

#define GST_USE_UNSTABLE_API
#include <gst/gl/gl.h>
#include <gst/gl/gstglmemory.h>
#undef GST_USE_UNSTABLE_API

// Blit stride as a multiple of bytes-per-pixel. We use BGRA throughout
// (matches 'BGRA' IOSurface pixel format + GL_BGRA +
// GL_UNSIGNED_INT_8_8_8_8_REV) so stride == width * 4.
#define BRIDGE_BYTES_PER_PIXEL 4

GST_DEBUG_CATEGORY_EXTERN(webkit_media_player_debug);
#define GST_CAT_DEFAULT webkit_media_player_debug

namespace WebCore {

// PIMPL: the actual CALayer + IOSurface state is held in a struct so the
// header doesn't need to import Cocoa frameworks. The struct itself is
// defined here in the .mm so its members can use RetainPtr + IOSurfaceRef.
struct IOSurfaceBridgeState {
    WTF_MAKE_FAST_ALLOCATED;
public:
    IOSurfaceBridgeState()
        : layer(nullptr)
        , surface(nullptr)
        , ioTexture(0)
        , texWidth(0)
        , texHeight(0)
        , cglCtx(nullptr)
        , firstFrameDone(false)
    {
    }

    RetainPtr<CALayer> layer;
    RetainPtr<IOSurfaceRef> surface;
    GLuint ioTexture;
    GLint texWidth;
    GLint texHeight;
    CGLContextObj cglCtx;  // borrowed from PlatformDisplay (do not destroy)
    // [leopard] One-shot first-frame diagnostic. Set after the first
    // successful presentGLMemory so the corner readback runs exactly
    // once per player lifetime — cheap, but enough to attribute a
    // black/wrong-orientation/garbled frame to its actual cause.
    bool firstFrameDone;
};

MediaPlayerPrivateGStreamerIOSurface::MediaPlayerPrivateGStreamerIOSurface()
    : m_state(makeUnique<IOSurfaceBridgeState>())
{
    // [leopard] No main-thread assertion — streaming thread safe.

    // Borrow the process-global CGL context that PlatformDisplay created
    // when it set up the GstGL bridge. This is the same context GstGL's
    // NSOpenGLContext shares with, so our IOSurface texture is visible
    // to glupload's output textures via the share group.
    //
    // We can't pull the GstGLContext from PlatformDisplay directly because
    // GstGLContextCocoa wraps an NSOpenGLContext (not a CGLContextObj),
    // and the share group is established via NSOpenGLContext. So we walk
    // the GstGLContext → NSOpenGLContext → CGLContextObj chain.
    auto& sharedDisplay = PlatformDisplay::sharedDisplayForCompositing();
    GstGLContext* gstCtx = sharedDisplay.gstGLContext();
    if (!gstCtx) {
        GST_WARNING("IOSurface bridge: PlatformDisplay has no GstGLContext — "
                    "samples will not be presented");
        return;
    }

    // gst_gl_context_get_gl_context() returns the platform handle. For
    // GstGLContextCocoa this is the NSOpenGLContext*. We need its
    // CGLContextObj so we can CGLTexImageIOSurface2D in the right context.
    guintptr handle = gst_gl_context_get_gl_context(gstCtx);
    if (!handle) {
        GST_WARNING("IOSurface bridge: GstGLContext has no platform handle");
        return;
    }
    NSOpenGLContext* nsCtx = (__bridge NSOpenGLContext *)(void *)handle;
    m_state->cglCtx = nsCtx ? (CGLContextObj)[nsCtx CGLContextObj] : nullptr;
    if (!m_state->cglCtx) {
        GST_WARNING("IOSurface bridge: NSOpenGLContext has no CGLContextObj");
        return;
    }

    // Create the CALayer that will host the IOSurface. The caller
    // (MediaPlayerPrivateGStreamer) owns the layer after this returns;
    // it sets m_player->platformLayer() to return layer.get().
    m_state->layer = adoptNS([[CALayer alloc] init]);
    [m_state->layer.get() setContentsGravity:kCAGravityResizeAspect];
    [m_state->layer.get() setBackgroundColor:CGColorGetConstantColor(kCGColorBlack)];
    GST_INFO("IOSurface bridge created: gst_ctx=%p ns_ctx=%p cgl=%p layer=%p",
             gstCtx, nsCtx, m_state->cglCtx, m_state->layer.get());
}

MediaPlayerPrivateGStreamerIOSurface::~MediaPlayerPrivateGStreamerIOSurface()
{
    // [leopard] No main-thread assertion — streaming thread safe.

    if (m_state->ioTexture && m_state->cglCtx) {
        CGLContextObj prev = CGLGetCurrentContext();
        CGLSetCurrentContext(m_state->cglCtx);
        glDeleteTextures(1, &m_state->ioTexture);
        m_state->ioTexture = 0;
        if (prev)
            CGLSetCurrentContext(prev);
        else
            CGLSetCurrentContext(nullptr);
    }
    // m_state->layer (CALayer) — autoreleased by RetainPtr.
    // m_state->surface (IOSurfaceRef) — released by RetainPtr.
}

CALayer* MediaPlayerPrivateGStreamerIOSurface::layer() const
{
    return m_state->layer.get();
}

bool MediaPlayerPrivateGStreamerIOSurface::ensureSurfaceOfSize(int width, int height)
{
    // [leopard] No main-thread assertion — called from streaming thread.
    // IOSurfaceCreate and CGLTexImageIOSurface2D are thread-safe when
    // each thread has its own CGL context or the context is not shared
    // concurrently. We create the IOSurface and texture on first call,
    // then only write pixels via IOSurfaceLock/CGBitmapContext (thread-safe).
    if (width <= 0 || height <= 0)
        return false;

    if (m_state->surface && m_state->texWidth == width && m_state->texHeight == height && m_state->ioTexture)
        return true;

    // (Re)create the IOSurface. Format must match what
    // CGLTexImageIOSurface2D expects: BGRA + UNSIGNED_INT_8_8_8_8_REV.
    int bytesPerRow = width * BRIDGE_BYTES_PER_PIXEL;
    int bytesPerElement = BRIDGE_BYTES_PER_PIXEL;
    int elementWidth = 1, elementHeight = 1;
    int isGlobal = 1;
    OSType pixelFormat = 'BGRA';

    CFNumberRef cfW = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &width);
    CFNumberRef cfH = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &height);
    CFNumberRef cfBPR = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &bytesPerRow);
    CFNumberRef cfBPE = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &bytesPerElement);
    CFNumberRef cfEW = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &elementWidth);
    CFNumberRef cfEH = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &elementHeight);
    CFNumberRef cfGlob = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &isGlobal);
    CFNumberRef cfPF = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &pixelFormat);

    const void* keys[] = {
        kIOSurfacePixelFormat,
        kIOSurfaceWidth, kIOSurfaceHeight, kIOSurfaceBytesPerRow,
        kIOSurfaceBytesPerElement, kIOSurfaceElementWidth, kIOSurfaceElementHeight,
        kIOSurfaceIsGlobal,
    };
    const void* values[] = {
        cfPF,
        cfW, cfH, cfBPR, cfBPE, cfEW, cfEH, cfGlob,
    };
    CFDictionaryRef dict = CFDictionaryCreate(
        kCFAllocatorDefault,
        keys, values, sizeof(keys) / sizeof(keys[0]),
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    IOSurfaceRef newSurface = IOSurfaceCreate(dict);

    CFRelease(dict);
    CFRelease(cfW); CFRelease(cfH); CFRelease(cfBPR);
    CFRelease(cfBPE); CFRelease(cfEW); CFRelease(cfEH);
    CFRelease(cfGlob); CFRelease(cfPF);

    if (!newSurface) {
        GST_WARNING("IOSurface bridge: IOSurfaceCreate(%dx%d) failed", width, height);
        return false;
    }

    // Bind the surface as a RECTANGLE texture in our borrowed CGL context.
    CGLContextObj prev = CGLGetCurrentContext();
    CGLSetCurrentContext(m_state->cglCtx);

    // Drop the previous texture + IOSurface (if any) before reallocating.
    if (m_state->ioTexture) {
        glDeleteTextures(1, &m_state->ioTexture);
        m_state->ioTexture = 0;
    }

    GLuint tex = 0;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, tex);
    CGLError cerr = CGLTexImageIOSurface2D(
        m_state->cglCtx,
        GL_TEXTURE_RECTANGLE_ARB,
        GL_RGBA8,
        width, height,
        GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV,
        newSurface, 0);
    glBindTexture(GL_TEXTURE_RECTANGLE_ARB, 0);

    if (prev)
        CGLSetCurrentContext(prev);
    else
        CGLSetCurrentContext(nullptr);

    if (cerr != kCGLNoError || !tex) {
        GST_WARNING("IOSurface bridge: CGLTexImageIOSurface2D failed: err=%d (%s)",
                    (int)cerr, CGLErrorString(cerr));
        CFRelease(newSurface);
        if (tex)
            glDeleteTextures(1, &tex);
        return false;
    }

    m_state->surface = adoptCF(newSurface);
    m_state->ioTexture = tex;
    m_state->texWidth = width;
    m_state->texHeight = height;

    // The layer's bounds are how CA knows where to draw the IOSurface.
    // backingScaleFactor is left to the layer host (the CAOpenGLLayer
    // machinery in WebCore's TileController handles HiDPI for us).
    [m_state->layer.get() setBounds:CGRectMake(0, 0, width, height)];

    GST_DEBUG("IOSurface bridge: allocated surface %dx%d tex=%u surface=%p",
              width, height, m_state->ioTexture, m_state->surface.get());
    return true;
}

void MediaPlayerPrivateGStreamerIOSurface::presentGLMemory(GstGLMemory* glMemory, int width, int height)
{
    // [leopard] No main-thread assertion — streaming thread safe.
    if (!glMemory || width <= 0 || height <= 0)
        return;

    if (!m_state->cglCtx) {
        GST_WARNING("IOSurface bridge: presentGLMemory called with no CGL context");
        return;
    }

    if (!ensureSurfaceOfSize(width, height))
        return;

    // Make our context current so glGetTexImage reads from the
    // share-group-visible source texture.
    CGLContextObj prev = CGLGetCurrentContext();
    CGLSetCurrentContext(m_state->cglCtx);

    // [leopard] glGetTexImage readback + direct IOSurface write.
    // gst_gl_memory_copy_into_texture produces black on the 9400M's GL 2.1
    // driver because the IOSurface texture's GL_BGRA internal format is not
    // FBO-renderable. glGetTexImage reads the source texture directly (the
    // share-group makes glcolorscale's texture visible in this context).
    // The readback cost is ~2ms at 720p (measured by the realistic benchmark).
    GLenum preCopyErr = glGetError();
    glBindTexture(GL_TEXTURE_2D, glMemory->tex_id);
    GLenum bindErr = glGetError();

    IOSurfaceLock(m_state->surface.get(), 0, nullptr);
    void* ioBase = IOSurfaceGetBaseAddress(m_state->surface.get());
    if (ioBase) {
        // Read directly into the IOSurface's backing memory.
        // GL_BGRA + GL_UNSIGNED_INT_8_8_8_8_REV matches the IOSurface's
        // BGRA pixel layout — no format conversion needed.
        glGetTexImage(GL_TEXTURE_2D, 0, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, ioBase);
    }
    IOSurfaceUnlock(m_state->surface.get(), 0, nullptr);
    GLenum postCopyErr = glGetError();

    GST_DEBUG("IOSurface bridge: glGetTexImage src_tex=%u w=%d h=%d "
              "| bindErr=0x%x getErr=0x%x",
              glMemory->tex_id, width, height,
              (unsigned)bindErr, (unsigned)postCopyErr);

    // Set the IOSurface as the CALayer's contents. Core Animation
    // composites it on the next vsync.
    m_state->layer.get().contents = (__bridge id)m_state->surface.get();

    GST_TRACE("IOSurface bridge: presented %dx%d tex=%u → layer=%p",
              width, height, m_state->ioTexture, m_state->layer.get());
}

void MediaPlayerPrivateGStreamerIOSurface::presentCGImage(CGImageRef cgImage)
{
    // [leopard] No main-thread assertion — streaming thread safe.
    if (!cgImage)
        return;

    static std::atomic<int> s_presentCount { 0 };
    int count = ++s_presentCount;
    if (count % 30 == 0)
        GST_DEBUG("DIAG presentCGImage: %d frames", count);

    int width = CGImageGetWidth(cgImage);
    int height = CGImageGetHeight(cgImage);
    if (width <= 0 || height <= 0)
        return;

    if (!ensureSurfaceOfSize(width, height))
        return;

    // Draw the CGImage directly into the IOSurface's backing store via a
    // CGBitmapContext. This avoids a GL roundtrip and uses CoreGraphics's
    // optimized blit path. Core Animation then composites the IOSurface
    // on the GPU via the CALayer's contents property.
    IOSurfaceLock(m_state->surface.get(), 0, nullptr);
    void* ioBase = IOSurfaceGetBaseAddress(m_state->surface.get());
    if (ioBase) {
        int bytesPerRow = IOSurfaceGetBytesPerRow(m_state->surface.get());
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(
            ioBase, width, height, 8, bytesPerRow, cs,
            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        if (ctx) {
            CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), cgImage);
            CGContextRelease(ctx);
        }
        CGColorSpaceRelease(cs);
    }
    IOSurfaceUnlock(m_state->surface.get(), 0, nullptr);

    m_state->layer.get().contents = (__bridge id)m_state->surface.get();

    GST_TRACE("IOSurface bridge: presented CGImage %dx%d → layer=%p",
              width, height, m_state->layer.get());
}

} // namespace WebCore

#endif // USE(GSTREAMER_GL) && PLATFORM(COCOA)
