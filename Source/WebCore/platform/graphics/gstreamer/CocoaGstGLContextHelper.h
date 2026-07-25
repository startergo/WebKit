/*
 * Copyright (C) 2026 only int webkit contributors
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

#pragma once

#include <cstdint>

namespace WebCore {

// [leopard] Cocoa wrapped-context factory for the GstGL bridge.
//
// Creates an NSOpenGLContext pinned to the hardware renderer
// (NSOpenGLPFAAccelerated + NSOpenGLPFANoRecovery, verified on the
// 9400M in spikes/gstreamer-gl-investigation/) and returns its handle
// as a uintptr_t, ready to cast to guintptr and hand to
// gst_gl_context_new_wrapped() as GST_GL_PLATFORM_CGL.
//
// Returns uintptr_t (not guintptr) so this header doesn't drag in glib.
// The size is identical and the implicit conversion at the call site
// in PlatformDisplayGStreamer.cpp is fine.
//
// WHY NSOpenGLContext* (not raw CGLContextObj): gstglcontext_cocoa.m
// casts the wrapped handle to NSOpenGLContext*; a raw CGLContextObj
// reinterpreted as an ObjC object pointer is UB. The downstream
// IOSurface sink (MediaPlayerPrivateGStreamerIOSurface.mm) extracts
// the same handle via gst_gl_context_get_gl_context() and walks to
// CGLContextObj via -[NSOpenGLContext CGLContextObj]; both steps
// require the handle to actually be an NSOpenGLContext*.
//
// WHY no gst_gl_context_create / activate / fill_info on the returned
// context: see spikes/gstreamer-gl-investigation/README.md for the
// dispatch_sync(main_queue) deadlock topology. The short version:
// gst_gl_context_create spawns a worker that dispatches to the main
// queue, which deadlocks when the main thread is inside a CFRunLoopTimer
// callback (HTMLMediaElement::selectMediaResource). gst_gl_context_activate
// on a wrapped context asserts (g_assert_not_reached in 1.4.5's
// gst_gl_wrapped_context_activate). gst_gl_context_fill_info does not
// exist in 1.4.5. All three are skipped; the wrapped context's
// gl_api is set by gst_gl_context_new_wrapped's available_apis arg.
//
// Logs the resolved CGL renderer ID via GST_INFO for share-group
// diagnostics (see README "Open residual risk: renderer match").
//
// The returned NSOpenGLContext is intentionally leaked for process
// lifetime — PlatformDisplay (the sole consumer) is process-lifetime,
// and destroying the context while GstGLWrappedContext still references
// it would crash on the next GL call.
//
// Returns 0 on failure.
uintptr_t createCocoaGstGLShareContext();

} // namespace WebCore
