/*
 * Copyright (C) 2013 Apple Inc. All Rights Reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#ifndef WebKit_WebKitAvailability_h
#define WebKit_WebKitAvailability_h

#import <TargetConditionals.h>

#if !TARGET_OS_IPHONE
#include <Foundation/NSObjCRuntime.h>

// [leopard] LEOPARD_AVAILABILITY_NOOP: on the 10.6 SDK the NS_*_DEPRECATED_MAC /
// NS_*_AVAILABLE_MAC macros do not cleanly consume version tokens like 10_14,
// leaking them as C++ user-defined-literals (10_4 / 10_14). Force all WebKit
// availability annotation macros to no-ops for the 10.6 build.
#if !defined(__MAC_OS_X_VERSION_MIN_REQUIRED) || __MAC_OS_X_VERSION_MIN_REQUIRED < 1070
#define LEOPARD_AVAILABILITY_NOOP 1
#define WEBKIT_AVAILABLE_MAC(introduced)
#define WEBKIT_CLASS_AVAILABLE_MAC(introduced)
#define WEBKIT_ENUM_AVAILABLE_MAC(introduced)
#define WEBKIT_DEPRECATED_MAC(introduced, deprecated, ...)
#define WEBKIT_CLASS_DEPRECATED_MAC(introduced, deprecated, ...)
#define WEBKIT_ENUM_DEPRECATED_MAC(introduced, deprecated, ...)
#endif

#ifndef LEOPARD_AVAILABILITY_NOOP

#define WEBKIT_AVAILABLE_MAC(introduced) NS_AVAILABLE_MAC(introduced)
#define WEBKIT_CLASS_AVAILABLE_MAC(introduced) NS_CLASS_AVAILABLE_MAC(introduced)
#define WEBKIT_ENUM_AVAILABLE_MAC(introduced) NS_ENUM_AVAILABLE_MAC(introduced)

#if !defined(DISABLE_LEGACY_WEBKIT_DEPRECATIONS) && !defined(BUILDING_WEBKIT)

#define WEBKIT_DEPRECATED_MAC(introduced, deprecated, ...) NS_DEPRECATED_MAC(introduced, deprecated, __VA_ARGS__)
#define WEBKIT_CLASS_DEPRECATED_MAC(introduced, deprecated, ...) NS_CLASS_DEPRECATED_MAC(introduced, deprecated, __VA_ARGS__)
#define WEBKIT_ENUM_DEPRECATED_MAC(introduced, deprecated, ...) NS_ENUM_DEPRECATED_MAC(introduced, deprecated, __VA_ARGS__)

#else

#define WEBKIT_DEPRECATED_MAC(introduced, deprecated, ...) NS_AVAILABLE_MAC(introduced)
#define WEBKIT_CLASS_DEPRECATED_MAC(introduced, deprecated, ...) NS_CLASS_AVAILABLE_MAC(introduced)
#define WEBKIT_ENUM_DEPRECATED_MAC(introduced, deprecated, ...) NS_ENUM_AVAILABLE_MAC(introduced)

#endif /* !defined(BUILDING_WEBKIT) && !defined(DISABLE_LEGACY_WEBKIT_DEPRECATIONS) */
#endif /* !LEOPARD_AVAILABILITY_NOOP */

#else

#define WEBKIT_AVAILABLE_MAC(introduced)
#define WEBKIT_CLASS_AVAILABLE_MAC(introduced)
#define WEBKIT_ENUM_AVAILABLE_MAC(introduced)
#define WEBKIT_DEPRECATED_MAC(introduced, deprecated, ...)
#define WEBKIT_CLASS_DEPRECATED_MAC(introduced, deprecated, ...)
#define WEBKIT_ENUM_DEPRECATED_MAC(introduced, deprecated, ...)

#endif /* !TARGET_OS_IPHONE */

#endif /* WebKit_WebKitAvailability_h */
