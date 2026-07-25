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
 * along with this library; see the file COPYING.LIB.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 */

// [leopard] Cocoa wrapped-context factory for the GstGL bridge.
//
// This file exists ONLY to put NSOpenGLContext creation behind a C-linkage
// entry point, so PlatformDisplayGStreamer.cpp (a C++ file) can build an
// NSOpenGLContext* without itself being compiled as Objective-C++. The
// returned handle is wrapped via gst_gl_context_new_wrapped() and never
// passed through gst_gl_context_create (which would deadlock the main
// thread) or gst_gl_context_activate (which asserts on wrapped contexts
// in 1.4.5). See CocoaGstGLContextHelper.h for the full rationale.

#include "config.h"
#include "CocoaGstGLContextHelper.h"

#include <OpenGL/OpenGL.h>
#include <OpenGL/CGLTypes.h>

#import <AppKit/NSOpenGL.h>

#define GST_USE_UNSTABLE_API
#include <gst/gl/gl.h>
#undef GST_USE_UNSTABLE_API

GST_DEBUG_CATEGORY_EXTERN(webkit_media_player_debug);
#define GST_CAT_DEFAULT webkit_media_player_debug

namespace WebCore {

uintptr_t createCocoaGstGLShareContext()
{
    // Pixel format MUST match GstGL's Cocoa backend (gstglcontext_cocoa.m:228-231):
    // DoubleBuffer + AccumSize=32. Any deviation (ColorSize, AlphaSize, Accelerated,
    // NoRecovery) causes "invalid share context" via Apple's pixel-format-compatibility
    // sharing rules. On a machine with a discrete GPU (9400M), the default renderer
    // resolves to hardware without explicit kCGLPFAAccelerated — verified by the
    // renderer-ID log (0x102260e = GEFORCE). This was proven by the glcolorscale
    // share-group probe (spikes/gstreamer-gl-investigation/README.md "Share-group
    // victory" section).
    NSOpenGLPixelFormatAttribute attribs[] = {
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFAAccumSize, (NSOpenGLPixelFormatAttribute)32,
        (NSOpenGLPixelFormatAttribute)0
    };

    NSOpenGLPixelFormat* pf = [[NSOpenGLPixelFormat alloc] initWithAttributes:attribs];
    if (!pf) {
        GST_WARNING("Cocoa GstGL bridge: NSOpenGLPixelFormat allocation failed");
        return 0;
    }

    NSOpenGLContext* nsCtx = [[NSOpenGLContext alloc] initWithFormat:pf shareContext:nil];
    [pf release];
    if (!nsCtx) {
        GST_WARNING("Cocoa GstGL bridge: -[NSOpenGLContext initWithFormat:shareContext:] returned nil");
        return 0;
    }

    CGLContextObj cglCtx = (CGLContextObj)[nsCtx CGLContextObj];

    // Renderer-ID log is load-bearing under the wrapped-context design:
    // if downstream GstGL's auto-created glupload context resolves to a
    // different renderer than this one, share-group texture visibility
    // fails and frames go black across the cross-context boundary.
    // Distinguishing that from a real decoder bug requires this number.
    // Bit constants per CGLTypes.h: 0x00020000 = GEFORCE, 0x00040000 = SOFTWARE.
    GLint rendererID = 0;
    if (cglCtx)
        CGLGetParameter(cglCtx, kCGLCPCurrentRendererID, &rendererID);
    GST_INFO("Cocoa GstGL bridge established (wrapped path): nsctx=%p cgl=%p renderer=0x%x (%s)",
             nsCtx, cglCtx, (unsigned)rendererID,
             (rendererID & 0x00020000) ? "GEFORCE" :
             (rendererID & 0x00040000) ? "SOFTWARE" : "unknown");

    // Intentionally leaked: GstGLWrappedContext holds this handle for
    // process-lifetime. Releasing here would cause the next GL call from
    // any sharing context to crash.
    return reinterpret_cast<uintptr_t>(nsCtx);
}

} // namespace WebCore
