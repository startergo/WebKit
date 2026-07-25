/*
 * Copyright (C) 2026 startergo (leopard-webkit-build)
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1.  Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer.
 * 2.  Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE AND ITS CONTRIBUTORS ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED.  IN NO EVENT SHALL APPLE OR ITS CONTRIBUTORS BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 * THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

// [leopard] Minimal concrete PlatformDisplay subclass for Cocoa. The base
// PlatformDisplay is abstract (type() = 0), so createPlatformDisplay() needs
// a concrete subclass to return. On Mac we don't have X11/Wayland/WPE — the
// "display" abstraction is just the CGL share-group that
// PlatformDisplayGStreamer.cpp's tryEnsureGstGLContext() builds. This class
// has no platform-specific state of its own; it exists solely to satisfy the
// abstract-base constraint and let sharedDisplayForCompositing() return a
// usable reference whose gstGLContext()/gstGLDisplay() methods work.

#pragma once

#if PLATFORM(COCOA)

#include "PlatformDisplay.h"

namespace WebCore {

class PlatformDisplayCocoa final : public PlatformDisplay {
    WTF_MAKE_FAST_ALLOCATED;
public:
    static std::unique_ptr<PlatformDisplayCocoa> create();

    Type type() const final { return Type::Cocoa; }

    // Public so WTF::makeUnique can reach it. Construction is via create()
    // to mirror the other PlatformDisplay subclasses' pattern.
    PlatformDisplayCocoa() : PlatformDisplay(NativeDisplayOwned::No) { }
};

} // namespace WebCore

#endif // PLATFORM(COCOA)
