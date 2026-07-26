find_library(COCOA_LIBRARY Cocoa)
find_library(COREFOUNDATION_LIBRARY CoreFoundation)
find_library(READLINE_LIBRARY Readline)
list(APPEND WTF_LIBRARIES
    ${COREFOUNDATION_LIBRARY}
    ${COCOA_LIBRARY}
    ${READLINE_LIBRARY}
)

    # [leopard] Compile the GLib source files that the GStreamer code depends on.
    list(APPEND WTF_SOURCES
        glib/GLibUtilities.cpp
        glib/GRefPtr.cpp
    )

list(APPEND WTF_PUBLIC_HEADERS
    WeakObjCPtr.h

    cf/CFURLExtras.h
    cf/TypeCastsCF.h

    cocoa/CrashReporter.h
    cocoa/Entitlements.h
    cocoa/NSURLExtras.h
    cocoa/RuntimeApplicationChecksCocoa.h
    cocoa/SoftLinking.h
    cocoa/VectorCocoa.h

    darwin/WeakLinking.h

    spi/cf/CFBundleSPI.h
    spi/cf/CFStringSPI.h

    spi/cocoa/CFXPCBridgeSPI.h
    spi/cocoa/CrashReporterClientSPI.h
    spi/cocoa/MachVMSPI.h
    spi/cocoa/NSLocaleSPI.h
    spi/cocoa/SecuritySPI.h
    spi/cocoa/objcSPI.h

    spi/darwin/DataVaultSPI.h
    spi/darwin/OSVariantSPI.h
    spi/darwin/ProcessMemoryFootprint.h
    spi/darwin/SandboxSPI.h
    spi/darwin/XPCSPI.h
    spi/darwin/dyldSPI.h

    spi/mac/MetadataSPI.h

    text/cf/TextBreakIteratorCF.h
)

list(APPEND WTF_SOURCES
    BlockObjCExceptions.mm

    cf/CFURLExtras.cpp
    cf/FileSystemCF.cpp
    cf/LanguageCF.cpp
    cf/RunLoopCF.cpp
    cf/RunLoopTimerCF.cpp
    cf/SchedulePairCF.cpp
    cf/URLCF.cpp

    cocoa/AutodrainedPool.cpp
    cocoa/CPUTimeCocoa.cpp
    cocoa/CrashReporter.cpp
    cocoa/Entitlements.mm
    cocoa/FileSystemCocoa.mm
    cocoa/LanguageCocoa.mm
    cocoa/MachSendRight.cpp
    cocoa/MainThreadCocoa.mm
    cocoa/MemoryFootprintCocoa.cpp
    cocoa/MemoryPressureHandlerCocoa.mm
    cocoa/NSURLExtras.mm
    cocoa/ResourceUsageCocoa.cpp
    cocoa/RuntimeApplicationChecksCocoa.cpp
    cocoa/SystemTracingCocoa.cpp
    cocoa/URLCocoa.mm
    cocoa/WorkQueueCocoa.cpp

    mac/FileSystemMac.mm
    mac/SchedulePairMac.mm

    posix/FileSystemPOSIX.cpp
    posix/OSAllocatorPOSIX.cpp
    posix/ThreadingPOSIX.cpp

    text/cf/AtomStringImplCF.cpp
    text/cf/StringCF.cpp
    text/cf/StringImplCF.cpp
    text/cf/StringViewCF.cpp

    text/cocoa/StringCocoa.mm
    text/cocoa/StringImplCocoa.mm
    text/cocoa/StringViewCocoa.mm
    text/cocoa/TextBreakIteratorInternalICUCocoa.cpp
)

# [leopard] GStreamer media backend pulls in GLib headers via WebCore's
# platform/graphics/gstreamer/* code. Stage those GLib headers from WTF
# into ForwardingHeaders so WebCore can find <wtf/glib/GRefPtr.h> etc.
if (USE_GSTREAMER)
    # [leopard] Compile the GLib source files that the GStreamer code depends on.
    list(APPEND WTF_SOURCES
        glib/GLibUtilities.cpp
        glib/GRefPtr.cpp
    )

    list(APPEND WTF_PUBLIC_HEADERS
        glib/GLibUtilities.h
        glib/GMutexLocker.h
        glib/GRefPtr.h
        glib/RunLoopSourcePriority.h
        glib/GTypedefs.h
        glib/GUniquePtr.h
        glib/GSocketMonitor.h
        glib/SocketConnection.h
        glib/WTFGType.h
    )

    # [leopard] USE_GSTREAMER transitively pulls in USE(GLIB) (see patch 15),
    # which makes wtf/CurrentTime.cpp + others include <glib.h>. Find GLib via
    # pkg-config (mirror at dist/macports-mirror) and add it to WTF's link.
    # Include the full GLib family so FileSystem.cpp's <gio/gfile*.h> etc. work.
    # gio-unix-2.0 provides gfiledescriptorbased.h (Unix file-descriptor GIO).
    find_package(PkgConfig QUIET)
    if (PkgConfig_FOUND)
        pkg_check_modules(PC_GLIB IMPORTED_TARGET glib-2.0 gobject-2.0 gio-2.0 gmodule-2.0 gio-unix-2.0)
    endif ()
    if (PC_GLIB_FOUND)
        list(APPEND WTF_LIBRARIES PkgConfig::PC_GLIB)
        link_directories(${PC_GLIB_LIBRARY_DIRS})
    else ()
        message(FATAL_ERROR "USE_GSTREAMER requires GLib on macOS -- set PKG_CONFIG_PATH to the MacPorts mirror.")
    endif ()
endif ()

file(COPY mac/MachExceptions.defs DESTINATION ${WTF_DERIVED_SOURCES_DIR})

add_custom_command(
    OUTPUT
        ${WTF_DERIVED_SOURCES_DIR}/MachExceptionsServer.h
        ${WTF_DERIVED_SOURCES_DIR}/mach_exc.h
        ${WTF_DERIVED_SOURCES_DIR}/mach_excServer.c
        ${WTF_DERIVED_SOURCES_DIR}/mach_excUser.c
    MAIN_DEPENDENCY mac/MachExceptions.defs
    WORKING_DIRECTORY ${WTF_DERIVED_SOURCES_DIR}
    COMMAND mig -sheader MachExceptionsServer.h MachExceptions.defs
    VERBATIM)
list(APPEND WTF_SOURCES
    ${WTF_DERIVED_SOURCES_DIR}/mach_excServer.c
    ${WTF_DERIVED_SOURCES_DIR}/mach_excUser.c
)

WEBKIT_CREATE_FORWARDING_HEADERS(WebKitLegacy DIRECTORIES ${WebKitLegacy_FORWARDING_HEADERS_DIRECTORIES} FILES ${WebKitLegacy_FORWARDING_HEADERS_FILES})
WEBKIT_CREATE_FORWARDING_HEADERS(WebKit DIRECTORIES ${FORWARDING_HEADERS_DIR}/WebKitLegacy)
