/*
 * Copyright (C) 2011-2019 Apple Inc. All Rights Reserved.
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

#import "config.h"
#import <wtf/MemoryPressureHandler.h>

#import <mach/mach.h>
#import <mach/task_info.h>
#import <malloc/malloc.h>
#import <notify.h>
#import <wtf/ResourceUsage.h>
#import <wtf/spi/darwin/DispatchSPI.h>

#define ENABLE_FMW_FOOTPRINT_COMPARISON 0

#if defined(__MAC_OS_X_VERSION_MIN_REQUIRED) && __MAC_OS_X_VERSION_MIN_REQUIRED < 1070
#ifndef DISPATCH_MEMORYPRESSURE_NORMAL
#define DISPATCH_MEMORYPRESSURE_NORMAL   0x1
#endif
#ifndef DISPATCH_MEMORYPRESSURE_WARN
#define DISPATCH_MEMORYPRESSURE_WARN     0x2
#endif
#ifndef DISPATCH_MEMORYPRESSURE_CRITICAL
#define DISPATCH_MEMORYPRESSURE_CRITICAL 0x4
#endif
#endif

extern "C" void cache_simulate_memory_warning_event(uint64_t);

namespace WTF {

void MemoryPressureHandler::platformReleaseMemory(Critical critical)
{
    if (critical == Critical::Yes && (!isUnderMemoryPressure() || m_isSimulatingMemoryPressure)) {
        // libcache listens to OS memory notifications, but for process suspension
        // or memory pressure simulation, we need to prod it manually:
#if !(defined(__MAC_OS_X_VERSION_MIN_REQUIRED) && __MAC_OS_X_VERSION_MIN_REQUIRED < 1070)
        cache_simulate_memory_warning_event(DISPATCH_MEMORYPRESSURE_CRITICAL);
#endif
    }
}

static dispatch_source_t memoryPressureEventSource = nullptr;
static dispatch_source_t timerEventSource = nullptr;
static int notifyTokens[3];

// Disable memory event reception for a minimum of s_minimumHoldOffTime
// seconds after receiving an event. Don't let events fire any sooner than
// s_holdOffMultiplier times the last cleanup processing time. Effectively 
// this is 1 / s_holdOffMultiplier percent of the time.
// These value seems reasonable and testing verifies that it throttles frequent
// low memory events, greatly reducing CPU usage.
static const Seconds s_minimumHoldOffTime { 5_s };
#if !PLATFORM(IOS_FAMILY)
static constexpr unsigned s_holdOffMultiplier = 20;
#endif

void MemoryPressureHandler::install()
{
    if (m_installed || timerEventSource)
        return;

    dispatch_async(m_dispatchQueue, ^{
#if PLATFORM(IOS_FAMILY)
        auto memoryStatusFlags = DISPATCH_MEMORYPRESSURE_NORMAL | DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL | DISPATCH_MEMORYPRESSURE_PROC_LIMIT_WARN | DISPATCH_MEMORYPRESSURE_PROC_LIMIT_CRITICAL;
#else // PLATFORM(MAC)
        auto memoryStatusFlags = DISPATCH_MEMORYPRESSURE_CRITICAL;
#endif
#if !(defined(__MAC_OS_X_VERSION_MIN_REQUIRED) && __MAC_OS_X_VERSION_MIN_REQUIRED < 1070)
        // DISPATCH_SOURCE_TYPE_MEMORYPRESSURE is 10.7+; 10.6 libdispatch has no
        // memory-pressure source. Skip registration on 10.6 -- the
        // notify_register_dispatch("org.WebKit.lowMemory") path below and the
        // timer fallback still provide pressure handling.
        memoryPressureEventSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0, memoryStatusFlags, m_dispatchQueue);

        dispatch_source_set_event_handler(memoryPressureEventSource, ^{
            auto status = dispatch_source_get_data(memoryPressureEventSource);
#if PLATFORM(IOS_FAMILY)
            switch (status) {
            // VM pressure events.
            case DISPATCH_MEMORYPRESSURE_NORMAL:
                setUnderMemoryPressure(false);
                break;
            case DISPATCH_MEMORYPRESSURE_WARN:
                setUnderMemoryPressure(false);
                respondToMemoryPressure(Critical::No);
                break;
            case DISPATCH_MEMORYPRESSURE_CRITICAL:
                setUnderMemoryPressure(true);
                respondToMemoryPressure(Critical::Yes);
                break;
            // Process memory limit events.
            case DISPATCH_MEMORYPRESSURE_PROC_LIMIT_WARN:
                respondToMemoryPressure(Critical::No);
                break;
            case DISPATCH_MEMORYPRESSURE_PROC_LIMIT_CRITICAL:
                respondToMemoryPressure(Critical::Yes);
                break;
            }
#else // PLATFORM(MAC)
            respondToMemoryPressure(Critical::Yes);
#endif
            if (m_shouldLogMemoryMemoryPressureEvents)
                WTFLogAlways("Received memory pressure event %lu vm pressure %d", status, isUnderMemoryPressure());
        });
        dispatch_resume(memoryPressureEventSource);
#else
        (void)memoryStatusFlags;
#endif
    });

    // Allow simulation of memory pressure with "notifyutil -p org.WebKit.lowMemory"
    notify_register_dispatch("org.WebKit.lowMemory", &notifyTokens[0], m_dispatchQueue, ^(int) {
#if ENABLE(FMW_FOOTPRINT_COMPARISON)
        auto footprintBefore = pagesPerVMTag();
#endif
        beginSimulatedMemoryPressure();

        WTF::releaseFastMallocFreeMemory();
#if !(defined(__MAC_OS_X_VERSION_MIN_REQUIRED) && __MAC_OS_X_VERSION_MIN_REQUIRED < 1070)
        // malloc_zone_pressure_relief is a 10.7+ malloc addition; on 10.6 the
        // bmalloc fast-malloc release above already reclaims the bulk of memory.
        malloc_zone_pressure_relief(nullptr, 0);
#endif

#if ENABLE(FMW_FOOTPRINT_COMPARISON)
        auto footprintAfter = pagesPerVMTag();
        logFootprintComparison(footprintBefore, footprintAfter);
#endif

        dispatch_async(m_dispatchQueue, ^{
            endSimulatedMemoryPressure();
        });
    });

    notify_register_dispatch("org.WebKit.lowMemory.begin", &notifyTokens[1], m_dispatchQueue, ^(int) {
        beginSimulatedMemoryPressure();
    });
    notify_register_dispatch("org.WebKit.lowMemory.end", &notifyTokens[2], m_dispatchQueue, ^(int) {
        endSimulatedMemoryPressure();
    });

    m_installed = true;
}

void MemoryPressureHandler::uninstall()
{
    if (!m_installed)
        return;

    dispatch_async(m_dispatchQueue, ^{
        if (memoryPressureEventSource) {
            dispatch_source_cancel(memoryPressureEventSource);
            memoryPressureEventSource = nullptr;
        }

        if (timerEventSource) {
            dispatch_source_cancel(timerEventSource);
            timerEventSource = nullptr;
        }
    });

    m_installed = false;

    for (auto& token : notifyTokens)
        notify_cancel(token);
}

void MemoryPressureHandler::holdOff(Seconds seconds)
{
    dispatch_async(m_dispatchQueue, ^{
        timerEventSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, m_dispatchQueue);
        if (timerEventSource) {
            dispatch_set_context(timerEventSource, this);
            // FIXME: The final argument `s_minimumHoldOffTime.seconds()` seems wrong.
            // https://bugs.webkit.org/show_bug.cgi?id=183277
            dispatch_source_set_timer(timerEventSource, dispatch_time(DISPATCH_TIME_NOW, seconds.seconds() * NSEC_PER_SEC), DISPATCH_TIME_FOREVER, s_minimumHoldOffTime.seconds());
            dispatch_source_set_event_handler(timerEventSource, ^{
                if (timerEventSource) {
                    dispatch_source_cancel(timerEventSource);
                    timerEventSource = nullptr;
                }
                MemoryPressureHandler::singleton().install();
            });
            dispatch_resume(timerEventSource);
        }
    });
}

void MemoryPressureHandler::respondToMemoryPressure(Critical critical, Synchronous synchronous)
{
#if !PLATFORM(IOS_FAMILY)
    uninstall();
    MonotonicTime startTime = MonotonicTime::now();
#endif

    releaseMemory(critical, synchronous);

#if !PLATFORM(IOS_FAMILY)
    Seconds holdOffTime = (MonotonicTime::now() - startTime) * s_holdOffMultiplier;
    holdOff(std::max(holdOffTime, s_minimumHoldOffTime));
#endif
}

Optional<MemoryPressureHandler::ReliefLogger::MemoryUsage> MemoryPressureHandler::ReliefLogger::platformMemoryUsage()
{
#if !(defined(__MAC_OS_X_VERSION_MIN_REQUIRED) && __MAC_OS_X_VERSION_MIN_REQUIRED < 1090)
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t err = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t) &vmInfo, &count);
    if (err != KERN_SUCCESS)
        return WTF::nullopt;

    return MemoryUsage {static_cast<size_t>(vmInfo.internal), static_cast<size_t>(vmInfo.phys_footprint)};
#else
    // [leopard] task_vm_info (internal/phys_footprint) is 10.9+; unavailable on 10.6.
    return WTF::nullopt;
#endif
}

} // namespace WTF
