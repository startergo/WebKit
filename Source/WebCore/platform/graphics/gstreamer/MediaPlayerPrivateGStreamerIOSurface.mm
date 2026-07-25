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
    ASSERT(isMainThread());

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
    GST_INFO("IOSurface bridge created: gst_ctx=%p ns_ctx=%p cgl=%p layer=%p",
             gstCtx, nsCtx, m_state->cglCtx, m_state->layer.get());
}

MediaPlayerPrivateGStreamerIOSurface::~MediaPlayerPrivateGStreamerIOSurface()
{
    ASSERT(isMainThread());

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
    ASSERT(isMainThread());
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
    ASSERT(isMainThread());
    if (!glMemory || width <= 0 || height <= 0)
        return;

    if (!m_state->cglCtx) {
        GST_WARNING("IOSurface bridge: presentGLMemory called with no CGL context");
        return;
    }

    if (!ensureSurfaceOfSize(width, height))
        return;

    // Make our context current so the copy targets the right share group.
    // copy_into_texture does its own thread-add internally into GstGL's
    // GL thread, but the destination texture id must be visible in that
    // thread's share context — which it is, because we share with the
    // GstGL context via PlatformDisplay.
    CGLContextObj prev = CGLGetCurrentContext();
    CGLSetCurrentContext(m_state->cglCtx);

    // gst_gl_memory_copy_into_texture signature (1.4.5):
    //   gboolean gst_gl_memory_copy_into_texture(GstGLMemory* gl_mem,
    //                                            guint tex_id,
    //                                            GstVideoGLTextureType tex_type,
    //                                            gint width, gint height,
    //                                            gint stride,
    //                                            gboolean respecify);
    // The dst (m_state->ioTexture) is GL_TEXTURE_RECTANGLE_ARB (from
    // CGLTexImageIOSurface2D). The src (glMemory) is whatever GstGL's
    // allocator picked — typically GL_TEXTURE_2D. The respecify=FALSE
    // arg asks GstGL to keep the dst target as-is; this is the
    // cross-target copy that the spike probe verified the API for but
    // did NOT verify the pixel correctness of. The first-frame
    // diagnostic below is the runtime check.
    GLenum preCopyErr = glGetError();
    gboolean copied = gst_gl_memory_copy_into_texture(
        glMemory,
        m_state->ioTexture,
        GST_VIDEO_GL_TEXTURE_TYPE_RGBA,
        width, height,
        width * BRIDGE_BYTES_PER_PIXEL,
        FALSE /* respecify — keep the RECTANGLE target from CGLTexImageIOSurface2D */);
    GLenum postCopyErr = glGetError();

    GST_DEBUG("IOSurface bridge: copy_into_texture src_tex=%u src_w=%d src_h=%d "
              "→ dst_tex=%u dst_target=RECTANGLE w=%d h=%d | copied=%d "
              "preGlErr=0x%x postGlErr=0x%x",
              glMemory->tex_id,
              width, height,
              m_state->ioTexture,
              width, height,
              (int)copied,
              (unsigned)preCopyErr, (unsigned)postCopyErr);

    if (!copied) {
        GST_WARNING("IOSurface bridge: gst_gl_memory_copy_into_texture returned FALSE "
                    "(src_tex=%u dst_tex=%u w=%d h=%d) — copy primitive rejected the args; "
                    "try respecify=TRUE",
                    glMemory->tex_id, m_state->ioTexture, width, height);
        if (prev)
            CGLSetCurrentContext(prev);
        else
            CGLSetCurrentContext(nullptr);
        return;
    }

    // Force a sync so Core Animation will see the updated bytes when it
    // reads the IOSurface on its render thread. glFlush + glFinish here
    // is the same pattern the spike probes used.
    glFlush();
    glFinish();

    // [leopard] First-frame diagnostic — the deferred runtime check for
    // the cross-target 2D→RECTANGLE copy. The spike probe verified the
    // API compiles; this is the runtime check that the pixels actually
    // land. Runs once per player lifetime (cheap — IOSurfaceLock +
    // 4 corner reads + IOSurfaceUnlock, all O(1)).
    //
    // Failure-mode attribution:
    //   all-zero BGRA           → copy was a silent no-op (respecify issue?)
    //   correct colors, flipped → 2D↔RECTANGLE coordinate origin flip
    //   sheared/garbled         → stride or format mismatch in the copy
    //   correct                 → copy primitive works; downstream issues
    //                             are environmental (CALayer/CAOpenGLLayer)
    if (!m_state->firstFrameDone) {
        m_state->firstFrameDone = true;
        uint32_t seed = 0;
        IOSurfaceLock(m_state->surface.get(), kIOSurfaceLockReadOnly, &seed);
        uint8_t *base = (uint8_t *)IOSurfaceGetBaseAddress(m_state->surface.get());
        size_t bpr = IOSurfaceGetBytesPerRow(m_state->surface.get());
        if (base && bpr >= (size_t)(width * 4)) {
            uint8_t *tl = base + (height - 1) * bpr + 0 * 4;
            uint8_t *tr = base + (height - 1) * bpr + (width - 1) * 4;
            uint8_t *bl = base + 0 * bpr + 0 * 4;
            uint8_t *br = base + 0 * bpr + (width - 1) * 4;
            GST_INFO("IOSurface bridge: FIRST-FRAME READBACK (BL=origin in IOSurface memory):");
            GST_INFO("  TL=BGRA(%d,%d,%d,%d)  TR=BGRA(%d,%d,%d,%d)",
                     tl[0], tl[1], tl[2], tl[3],
                     tr[0], tr[1], tr[2], tr[3]);
            GST_INFO("  BL=BGRA(%d,%d,%d,%d)  BR=BGRA(%d,%d,%d,%d)",
                     bl[0], bl[1], bl[2], bl[3],
                     br[0], br[1], br[2], br[3]);
            GST_INFO("  If all 4 corners read (0,0,0,0) → copy was a no-op. "
                     "If correct but flipped vertically → cross-target origin bug. "
                     "If sheared → stride mismatch. If correct → sink works end-to-end.");
        } else {
            GST_WARNING("IOSurface bridge: first-frame readback failed (base=%p bpr=%zu)",
                        base, bpr);
        }
        IOSurfaceUnlock(m_state->surface.get(), kIOSurfaceLockReadOnly, &seed);
    }

    if (prev)
        CGLSetCurrentContext(prev);
    else
        CGLSetCurrentContext(nullptr);

    // Hand the IOSurface to Core Animation. CA will retain + schedule
    // a cross-process (or cross-thread) display on the next vsync.
    id contents = (__bridge id)m_state->surface.get();
    [m_state->layer.get() setContents:contents];

    GST_TRACE("IOSurface bridge: presented %dx%d tex=%u → layer=%p",
              width, height, m_state->ioTexture, m_state->layer.get());
}

} // namespace WebCore

#endif // USE(GSTREAMER_GL) && PLATFORM(COCOA)
