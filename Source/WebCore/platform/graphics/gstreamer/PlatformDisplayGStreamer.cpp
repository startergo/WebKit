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
#include "CocoaGstGLContextHelper.h"
// Note: no CGL header includes here. The Cocoa branch no longer touches
// CGL directly — NSOpenGLContext creation (and the CGL handle derivation
// for renderer-ID logging) is hidden inside CocoaGstGLContextHelper.mm,
// which is the only ObjC++ compilation unit in this GL path.
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
// No standalone-CGL helper anymore. The wrapped-context path creates its
// NSOpenGLContext inside WebCore::createCocoaGstGLShareContext() (see
// CocoaGstGLContextHelper.mm). That function is the only place in this
// GL path that touches AppKit / CGL directly.
#endif

bool PlatformDisplay::tryEnsureGstGLContext() const
{
    if (m_gstGLDisplay && m_gstGLContext)
        return true;

#if PLATFORM(COCOA)
    // [leopard] Cocoa wrapped-context bridge. See
    // spikes/gstreamer-gl-investigation/README.md for the full history,
    // including the dispatch_sync(main_queue) deadlock topology that
    // forced this design.
    //
    // Shape (fix #1):
    //   1. Create an NSOpenGLContext pinned to the hardware renderer
    //      (kCGLPFAAccelerated + kCGLPFANoRecovery).
    //   2. gst_gl_display_new() — Cocoa subclass is auto-selected.
    //   3. gst_gl_context_new_wrapped(display, nsctx_handle,
    //                                 GST_GL_PLATFORM_CGL,
    //                                 GST_GL_API_OPENGL) — no worker
    //      thread, no dispatch, no main-queue drain requirement.
    //
    // What we deliberately do NOT call, and why:
    //   - gst_gl_context_create(): spawns a GstGL worker thread that
    //     hits dispatch_barrier_sync(main_queue) inside
    //     gstglcontext_cocoa_create_context. When this function is
    //     reached from a CFRunLoopTimer callback
    //     (HTMLMediaElement::selectMediaResource -> createVideoSink ->
    //     webKitGLVideoSinkProbePlatform -> gstGLContext), the main
    //     thread is inside __CFRunLoopRun/timerFired and cannot drain
    //     the main dispatch queue -> circular deadlock, app hangs at
    //     startup. Removing the call removes the worker entirely.
    //
    //   - gst_gl_context_activate(wrapped, ...): GstGL 1.4.5's
    //     gst_gl_wrapped_context_activate is g_assert_not_reached()
    //     (gstglcontext.c). Calling it would abort the process, not
    //     return FALSE as the spike README asserted.
    //
    //   - gst_gl_context_fill_info(): does not exist in GstGL 1.4.5
    //     (no decl in gst/gl/gl.h, no def in gstglcontext.c). The
    //     wrapped context's gl_major/gl_minor/gl_exts/gl_vtable stay
    //     zero/NULL; downstream GstGL consumers use this context only
    //     as a share-parent NSOpenGLContext handle (via
    //     gst_gl_context_get_gl_context), not for capability queries.
    //
    // Wrap-handle contract: the handle MUST be an NSOpenGLContext*, not
    // a raw CGLContextObj. gstglcontext_cocoa.m casts the handle to
    // NSOpenGLContext*; a raw CGLContextObj reinterpreted as an ObjC
    // object pointer is UB (see README "What does NOT work" table).
    // MediaPlayerPrivateGStreamerIOSurface.mm extracts the handle via
    // gst_gl_context_get_gl_context and walks to CGLContextObj through
    // -[NSOpenGLContext CGLContextObj], which only works if the handle
    // really is an NSOpenGLContext*.
    m_gstGLDisplay = adoptGRef(gst_gl_display_new());
    if (!m_gstGLDisplay) {
        GST_WARNING("Cocoa GstGL bridge: gst_gl_display_new returned NULL");
        return false;
    }

    uintptr_t nsCtxHandle = WebCore::createCocoaGstGLShareContext();
    if (!nsCtxHandle) {
        GST_WARNING("Cocoa GstGL bridge: createCocoaGstGLShareContext returned 0 "
                    "(see prior log for NSOpenGLContext creation failure)");
        return false;
    }

    GRefPtr<GstGLContext> wrappedContext = adoptGRef(gst_gl_context_new_wrapped(
        m_gstGLDisplay.get(),
        static_cast<guintptr>(nsCtxHandle),
        GST_GL_PLATFORM_CGL,
        GST_GL_API_OPENGL));
    if (!wrappedContext) {
        GST_WARNING("Cocoa GstGL bridge: gst_gl_context_new_wrapped returned NULL");
        return false;
    }

    // Renderer-ID log is emitted inside createCocoaGstGLShareContext.
    // It's load-bearing now: under the wrapped-context design, if a
    // downstream GstGL element auto-creates a context that resolves to
    // a different CGL renderer than this one, cross-context texture
    // visibility fails and frames come through black. That looks
    // identical to the FBO-readback false-black the spike already
    // chased; the renderer IDs are the only thing that distinguishes
    // the two cases at runtime.
    GST_INFO("Cocoa GstGL bridge: wrapped gst_ctx=%p nsctx_handle=0x%llx",
             wrappedContext.get(), (unsigned long long)nsCtxHandle);

    m_gstGLContext = WTFMove(wrappedContext);
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
