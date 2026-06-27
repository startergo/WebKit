//
// Copyright 2019 The ANGLE Project Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//

// driver_utils_mac.mm : provides mac-specific information about current driver.

#include "libANGLE/renderer/driver_utils.h"

#import <Foundation/Foundation.h>

namespace rx
{

#import <CoreServices/CoreServices.h>

OSVersion GetMacOSVersion()
{
    OSVersion result;

    // [leopard] NSProcessInfo.operatingSystemVersion is 10.10+. Use Gestalt on 10.6.
    SInt32 majv = 10, minv = 6, patchv = 8;
    Gestalt(gestaltSystemVersionMajor, &majv);
    Gestalt(gestaltSystemVersionMinor, &minv);
    Gestalt(gestaltSystemVersionBugFix, &patchv);
    result.majorVersion = static_cast<int>(majv);
    result.minorVersion = static_cast<int>(minv);
    result.patchVersion = static_cast<int>(patchv);

    return result;
}

}
