/*
 * Copyright (C) 2016 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "config.h"
#import "RenderThemeCocoa.h"

#import "GraphicsContextCG.h"
#import "HTMLInputElement.h"
#import "RenderText.h"

#if ENABLE(APPLE_PAY)

#import <pal/cocoa/PassKitSoftLink.h>

#endif // ENABLE(APPLE_PAY)

#import "LocalizedStrings.h"
#import <wtf/BlockObjCExceptions.h>

namespace WebCore {

bool RenderThemeCocoa::shouldHaveCapsLockIndicator(const HTMLInputElement& element) const
{
    return element.isPasswordField();
}

#if ENABLE(APPLE_PAY)

static const auto applePayButtonMinimumWidth = 140;
static const auto applePayButtonPlainMinimumWidth = 100;
static const auto applePayButtonMinimumHeight = 30;

void RenderThemeCocoa::adjustApplePayButtonStyle(RenderStyle& style, const Element*) const
{
    if (style.applePayButtonType() == ApplePayButtonType::Plain)
        style.setMinWidth(Length(applePayButtonPlainMinimumWidth, Fixed));
    else
        style.setMinWidth(Length(applePayButtonMinimumWidth, Fixed));
    style.setMinHeight(Length(applePayButtonMinimumHeight, Fixed));

    if (!style.hasExplicitlySetBorderRadius()) {
        auto cornerRadius = PAL::get_PassKit_PKApplePayButtonDefaultCornerRadius();
        style.setBorderRadius({ { cornerRadius, Fixed }, { cornerRadius, Fixed } });
    }
}

static PKPaymentButtonStyle toPKPaymentButtonStyle(ApplePayButtonStyle style)
{
    switch (style) {
    case ApplePayButtonStyle::White:
        return PKPaymentButtonStyleWhite;
    case ApplePayButtonStyle::WhiteOutline:
        return PKPaymentButtonStyleWhiteOutline;
    case ApplePayButtonStyle::Black:
        return PKPaymentButtonStyleBlack;
    }
}

static PKPaymentButtonType toPKPaymentButtonType(ApplePayButtonType type)
{
    switch (type) {
    case ApplePayButtonType::Plain:
        return PKPaymentButtonTypePlain;
    case ApplePayButtonType::Buy:
        return PKPaymentButtonTypeBuy;
    case ApplePayButtonType::SetUp:
        return PKPaymentButtonTypeSetUp;
    case ApplePayButtonType::Donate:
        return PKPaymentButtonTypeDonate;
#if ENABLE(APPLE_PAY_SESSION_V4)
    case ApplePayButtonType::CheckOut:
        return PKPaymentButtonTypeCheckout;
    case ApplePayButtonType::Book:
        return PKPaymentButtonTypeBook;
    case ApplePayButtonType::Subscribe:
        return PKPaymentButtonTypeSubscribe;
#endif
    }
}

bool RenderThemeCocoa::paintApplePayButton(const RenderObject& renderer, const PaintInfo& paintInfo, const IntRect& paintRect)
{
    GraphicsContextStateSaver stateSaver(paintInfo.context());

    paintInfo.context().setShouldSmoothFonts(true);
    paintInfo.context().scale(FloatSize(1, -1));

    auto& style = renderer.style();
    auto largestCornerRadius = std::max<CGFloat>({
        style.borderTopLeftRadius().height.value(),
        style.borderTopLeftRadius().width.value(),
        style.borderTopRightRadius().height.value(),
        style.borderTopRightRadius().width.value(),
        style.borderBottomLeftRadius().height.value(),
        style.borderBottomLeftRadius().width.value(),
        style.borderBottomRightRadius().height.value(),
        style.borderBottomRightRadius().width.value()
    });

    PKDrawApplePayButtonWithCornerRadius(paintInfo.context().platformContext(), CGRectMake(paintRect.x(), -paintRect.maxY(), paintRect.width(), paintRect.height()), 1.0, largestCornerRadius, toPKPaymentButtonType(style.applePayButtonType()), toPKPaymentButtonStyle(style.applePayButtonStyle()), style.locale());
    return false;
}

#endif // ENABLE(APPLE_PAY)

#if ENABLE(VIDEO)
String RenderThemeCocoa::mediaControlsFormattedStringForDuration(const double durationInSeconds)
{
    if (!std::isfinite(durationInSeconds))
        return WEB_UI_STRING("indefinite time", "accessibility help text for an indefinite media controller time value");

    BEGIN_BLOCK_OBJC_EXCEPTIONS;
#if __MAC_OS_X_VERSION_MIN_REQUIRED >= 101000
    // [leopard-webkit-build] NSDateComponentsFormatter properties (unitsStyle,
    // allowedUnits, formattingContext, maximumUnitCount) + NSFormattingContext are
    // 10.8+/10.10+. On 10.6 the duration formatter is unconfigured → media controls
    // show "indefinite" (line 119) instead of formatted time. Acceptable on 10.6.
    if (!m_durationFormatter) {
        m_durationFormatter = adoptNS([NSDateComponentsFormatter new]);
        m_durationFormatter.get().unitsStyle = NSDateComponentsFormatterUnitsStyleFull;
        m_durationFormatter.get().allowedUnits = NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond;
        m_durationFormatter.get().formattingContext = NSFormattingContextStandalone;
        m_durationFormatter.get().maximumUnitCount = 2;
    }
    return [m_durationFormatter.get() stringFromTimeInterval:durationInSeconds];
#else
    // [leopard-webkit-build] LEOPARD_DURATION_ENDIF: NSDateComponentsFormatter is 10.10+.
    // On 10.6 return a simple seconds string (media controls are disabled anyway).
    UNUSED_PARAM(durationInSeconds);
    return WEB_UI_STRING("indefinite time", "accessibility help text for an indefinite media controller time value");
#endif
    END_BLOCK_OBJC_EXCEPTIONS;
}
#endif // ENABLE(VIDEO) [leopard]

}
