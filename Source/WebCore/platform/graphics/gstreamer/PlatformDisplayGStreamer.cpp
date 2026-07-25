/*
 * Copyright (C) 2020 Igalia S.L
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

#include "config.h"
#include "PlatformDisplay.h"

#include "GStreamerCommon.h"

#if USE(GLX)
#include "GLContextGLX.h"
#include <gst/gl/x11/gstgldisplay_x11.h>
#endif

#if USE(EGL)
#include "GLContextEGL.h"
#include <gst/gl/egl/gstgldisplay_egl.h>
#endif

#if PLATFORM(X11)
#include "PlatformDisplayX11.h"
#endif

#if PLATFORM(WAYLAND)
#include "PlatformDisplayWayland.h"
#endif

#if USE(WPE_RENDERER)
#include "PlatformDisplayLibWPE.h"
#endif

// [leopard] Cocoa uses CGL + IOSurface for the GstGL bridge, not the
// EGL/GLX sharing-context model that the rest of this file implements.
// The Cocoa path creates a standalone CGL context and wraps it as the
// share parent for a native GstGLContextCocoa. See
// spikes/gstreamer-gl-investigation/ for the architecture + probe
// history that landed on this design.
#if PLATFORM(COCOA)
#include <OpenGL/OpenGL.h>
#include <OpenGL/CGLCurrent.h>
#include <OpenGL/CGLTypes.h>
#endif

#define GST_USE_UNSTABLE_API
#include <gst/gl/gl.h>
#undef GST_USE_UNSTABLE_API

GST_DEBUG_CATEGORY_EXTERN(webkit_media_player_debug);
#define GST_CAT_DEFAULT webkit_media_player_debug

using namespace WebCore;

static GstGLDisplay* createGstGLDisplay(const PlatformDisplay& sharedDisplay)
{
#if USE(WPE_RENDERER)
    if (is<PlatformDisplayLibWPE>(sharedDisplay))
        return GST_GL_DISPLAY(gst_gl_display_egl_new_with_egl_display(downcast<PlatformDisplayLibWPE>(sharedDisplay).eglDisplay()));
#endif

#if PLATFORM(X11)
#if USE(GLX)
    if (is<PlatformDisplayX11>(sharedDisplay))
        return GST_GL_DISPLAY(gst_gl_display_x11_new_with_display(downcast<PlatformDisplayX11>(sharedDisplay).native()));
#elif USE(EGL)
    if (is<PlatformDisplayX11>(sharedDisplay))
        return GST_GL_DISPLAY(gst_gl_display_egl_new_with_egl_display(downcast<PlatformDisplayX11>(sharedDisplay).eglDisplay()));
#endif
#endif

#if PLATFORM(WAYLAND)
    if (is<PlatformDisplayWayland>(sharedDisplay))
        return GST_GL_DISPLAY(gst_gl_display_egl_new_with_egl_display(downcast<PlatformDisplayWayland>(sharedDisplay).eglDisplay()));
#endif

    return nullptr;
}

#if PLATFORM(COCOA)
// [leopard] Create a standalone CGL context on the hardware renderer.
// This is the share parent for GstGL — glupload/gldownload will create
// their own NSOpenGLContexts that share with this one via
// gst_gl_context_create(native, wrapped_share_parent, &err).
// kCGLPFAAccelerated + kCGLPFANoRecovery force the hardware renderer
// (verified on the 9400M in spikes/gstreamer-gl-investigation/).
//
// Returns a CGLContextObj (caller owns; must CGLDestroyContext) or NULL
// on failure. The context is activated on the calling thread.
static CGLContextObj createStandaloneCGLContext()
{
    CGLPixelFormatAttribute attribs[] = {
        kCGLPFAColorSize,     (CGLPixelFormatAttribute)24,
        kCGLPFAAlphaSize,     (CGLPixelFormatAttribute)8,
        kCGLPFADoubleBuffer,
        kCGLPFAAccelerated,
        kCGLPFANoRecovery,
        (CGLPixelFormatAttribute)0
    };
    CGLPixelFormatObj pf = nullptr;
    GLint nvirt = 0;
    CGLError cerr = CGLChoosePixelFormat(attribs, &pf, &nvirt);
    if (cerr != kCGLNoError || !pf) {
        GST_WARNING("CGLChoosePixelFormat failed: err=%d", (int)cerr);
        return nullptr;
    }
    CGLContextObj ctx = nullptr;
    cerr = CGLCreateContext(pf, nullptr, &ctx);
    CGLDestroyPixelFormat(pf);
    if (cerr != kCGLNoError || !ctx) {
        GST_WARNING("CGLCreateContext failed: err=%d", (int)cerr);
        return nullptr;
    }
    CGLSetCurrentContext(ctx);
    return ctx;
}
#endif // PLATFORM(COCOA)

bool PlatformDisplay::tryEnsureGstGLContext() const
{
    if (m_gstGLDisplay && m_gstGLContext)
        return true;

#if PLATFORM(COCOA)
    // [leopard] Cocoa IOSurface bridge — see spikes/gstreamer-gl-investigation/
    // for the design history. The short version:
    //
    //   1. Build a standalone CGL context on the hardware renderer.
    //   2. Create a default GstGLDisplay (Cocoa subclass is automatic).
    //   3. Wrap our CGL context as the share parent.
    //   4. Create a native GstGLContext (GstGLContextCocoa) that shares
    //      with our wrapped context via gst_gl_context_create().
    //
    // The resulting m_gstGLContext is what GLVideoSinkGStreamer hands to
    // glupload/gldownload via GstContext propagation. Those elements then
    // allocate GstGLMemory textures in their own NSOpenGLContext (which
    // shares with ours), and the IOSurface bridge in
    // MediaPlayerPrivateGStreamerIOSurface.mm copies each frame into a
    // CALayer-bound IOSurface.
    CGLContextObj cglContext = createStandaloneCGLContext();
    if (!cglContext) {
        GST_WARNING("Cocoa GstGL bridge: could not create standalone CGL context");
        return false;
    }

    m_gstGLDisplay = adoptGRef(gst_gl_display_new());
    if (!m_gstGLDisplay) {
        GST_WARNING("Cocoa GstGL bridge: gst_gl_display_new returned NULL");
        CGLDestroyContext(cglContext);
        CGLSetCurrentContext(nullptr);
        return false;
    }

    // Wrap our CGL context as the share parent. The share parent is what
    // gst_gl_context_create will pass to NSOpenGLContext's
    // initWithFormat:shareContext: when building the native GstGL context.
    GRefPtr<GstGLContext> shareParent = adoptGRef(gst_gl_context_new_wrapped(
        m_gstGLDisplay.get(),
        reinterpret_cast<guintptr>(cglContext),
        GST_GL_PLATFORM_CGL,
        GST_GL_API_OPENGL));
    if (!shareParent) {
        GST_WARNING("Cocoa GstGL bridge: gst_gl_context_new_wrapped returned NULL");
        CGLDestroyContext(cglContext);
        CGLSetCurrentContext(nullptr);
        return false;
    }

    // Create the native GstGL context. This will spawn GstGL's internal
    // GL thread and call dispatch_sync(main_queue, ...) inside
    // gstglcontext_cocoa.m — which is safe here because WebKit's main
    // thread runs NSApplication's run loop (unlike standalone probes,
    // which had to be reworked to avoid this deadlock; see the spike
    // README for the false-positive history).
    GRefPtr<GstGLContext> nativeContext = adoptGRef(gst_gl_context_new(m_gstGLDisplay.get()));
    if (!nativeContext) {
        GST_WARNING("Cocoa GstGL bridge: gst_gl_context_new returned NULL");
        CGLDestroyContext(cglContext);
        CGLSetCurrentContext(nullptr);
        return false;
    }

    GUniqueOutPtr<GError> error;
    if (!gst_gl_context_create(nativeContext.get(), shareParent.get(), &error.outPtr())) {
        GST_WARNING("Cocoa GstGL bridge: gst_gl_context_create failed: %s",
                    error ? error->message : "(unknown)");
        CGLDestroyContext(cglContext);
        CGLSetCurrentContext(nullptr);
        return false;
    }

    gst_gl_context_activate(nativeContext.get(), TRUE);

    // Diagnostics: log the renderer ID. This is the "open residual risk"
    // from the spike README — if the 9400M is not the resolved renderer,
    // texture sharing with the WebKit compositor will fail. The IOSurface
    // bridge doesn't actually depend on share-group match (it does an
    // intra-context copy), so this is informational, not gating.
    GLint rendererID = 0;
    CGLGetParameter(cglContext, kCGLCPCurrentRendererID, &rendererID);
    GST_INFO("Cocoa GstGL bridge established: cgl=%p renderer=0x%x (%s) gst_ctx=%p",
             cglContext, (unsigned)rendererID,
             (rendererID & 0x00020000) ? "GEFORCE" :
             (rendererID & 0x00040000) ? "SOFTWARE" : "unknown",
             nativeContext.get());

    m_gstGLContext = WTFMove(nativeContext);

    // NOTE: we intentionally leak cglContext here. GstGLWrappedContext
    // does not own the wrapped handle (verified in the spike), and
    // destroying cglContext while the native GstGL context still holds
    // a share reference would crash on the next GL call. The context
    // lives for the lifetime of the PlatformDisplay, which is effectively
    // process-lifetime.
    return true;
#else
#if USE(OPENGL_ES)
    GstGLAPI glAPI = GST_GL_API_GLES2;
#elif USE(OPENGL)
    GstGLAPI glAPI = GST_GL_API_OPENGL;
#else
    return false;
#endif

    auto* sharedContext = const_cast<PlatformDisplay*>(this)->sharingGLContext();
    if (!sharedContext)
        return false;
    PlatformGraphicsContextGL contextHandle = sharedContext->platformContext();
    if (!contextHandle)
        return false;

    bool shouldAdoptRef = webkitGstCheckVersion(1, 14, 0);

    if (shouldAdoptRef)
        m_gstGLDisplay = adoptGRef(createGstGLDisplay(*this));
    else
        m_gstGLDisplay = createGstGLDisplay(*this);
    if (!m_gstGLDisplay)
        return false;

    GstGLPlatform glPlatform = sharedContext->isEGLContext() ? GST_GL_PLATFORM_EGL : GST_GL_PLATFORM_GLX;

    if (shouldAdoptRef)
        m_gstGLContext = adoptGRef(gst_gl_context_new_wrapped(m_gstGLDisplay.get(), reinterpret_cast<guintptr>(contextHandle), glPlatform, glAPI));
    else
        m_gstGLContext = gst_gl_context_new_wrapped(m_gstGLDisplay.get(), reinterpret_cast<guintptr>(contextHandle), glPlatform, glAPI);

    // Activate and fill the GStreamer wrapped context with the Webkit's shared one.
    auto* previousActiveContext = GLContext::current();
    sharedContext->makeContextCurrent();
    if (gst_gl_context_activate(m_gstGLContext.get(), TRUE)) {
        GUniqueOutPtr<GError> error;
        if (!gst_gl_context_fill_info(m_gstGLContext.get(), &error.outPtr()))
            GST_WARNING("Failed to fill in GStreamer context: %s", error->message);
    } else
        GST_WARNING("Failed to activate GStreamer context %" GST_PTR_FORMAT, m_gstGLContext.get());
    if (previousActiveContext)
        previousActiveContext->makeContextCurrent();

    return true;
#endif // !PLATFORM(COCOA)
}

GstGLDisplay* PlatformDisplay::gstGLDisplay() const
{
    if (!tryEnsureGstGLContext())
        return nullptr;
    return m_gstGLDisplay.get();
}

GstGLContext* PlatformDisplay::gstGLContext() const
{
    if (!tryEnsureGstGLContext())
        return nullptr;
    return m_gstGLContext.get();
}
