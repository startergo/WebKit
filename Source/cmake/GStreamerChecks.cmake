if (ENABLE_VIDEO OR ENABLE_WEB_AUDIO)
    set(GSTREAMER_COMPONENTS app pbutils)
    SET_AND_EXPOSE_TO_BUILD(USE_GSTREAMER TRUE)
    if (ENABLE_VIDEO)
        list(APPEND GSTREAMER_COMPONENTS video mpegts tag gl)
    endif ()

    if (ENABLE_WEB_AUDIO)
        list(APPEND GSTREAMER_COMPONENTS audio fft)
        SET_AND_EXPOSE_TO_BUILD(USE_WEBAUDIO_GSTREAMER TRUE)
    endif ()

    find_package(GStreamer 1.4.5 REQUIRED COMPONENTS ${GSTREAMER_COMPONENTS})

    if (ENABLE_WEB_AUDIO)
        if (NOT PC_GSTREAMER_AUDIO_FOUND OR NOT PC_GSTREAMER_FFT_FOUND)
            message(FATAL_ERROR "WebAudio requires the audio and fft GStreamer libraries. Please check your gst-plugins-base installation.")
        else ()
            SET_AND_EXPOSE_TO_BUILD(USE_WEBAUDIO_GSTREAMER TRUE)
        endif ()
    endif ()

    if (ENABLE_VIDEO)
        if (NOT PC_GSTREAMER_APP_FOUND OR NOT PC_GSTREAMER_PBUTILS_FOUND OR NOT PC_GSTREAMER_TAG_FOUND OR NOT PC_GSTREAMER_VIDEO_FOUND)
            message(FATAL_ERROR "Video playback requires the following GStreamer libraries: app, pbutils, tag, video. Please check your gst-plugins-base installation.")
        endif ()
    endif ()

    if (USE_GSTREAMER_MPEGTS AND NOT PC_GSTREAMER_MPEGTS_FOUND)
        message(FATAL_ERROR "GStreamer MPEG-TS is needed for USE_GSTREAMER_MPEGTS.")
    endif ()

    if (USE_GSTREAMER_GL AND NOT PC_GSTREAMER_GL_FOUND)
        message(FATAL_ERROR "GStreamerGL is needed for USE_GSTREAMER_GL.")
    endif ()

    # [leopard] SET_AND_EXPOSE_TO_BUILD emits DUSE_GSTREAMER_GL=1 compile define.
    if (USE_GSTREAMER_GL)
        SET_AND_EXPOSE_TO_BUILD(USE_GSTREAMER_GL TRUE)
    endif ()

    SET_AND_EXPOSE_TO_BUILD(USE_GSTREAMER TRUE)
endif ()

# [leopard] The 1.14 gate was conservative — MSE was developed against 1.14,
# but the actual API surface it uses is 95.5% present in 1.4.5 (3 real
# calls patched with version gates). The 1.4.5 qtdemux has solid fMP4
# support (moof/traf/tfhd/trun parsing, push-mode chain function,
# adapter-based incremental parsing). See spikes/ for the full analysis.
if (ENABLE_MEDIA_SOURCE AND PC_GSTREAMER_VERSION VERSION_LESS "1.4.5")
    message(FATAL_ERROR "GStreamer 1.4.5 is needed for ENABLE_MEDIA_SOURCE.")
endif ()

if (ENABLE_MEDIA_STREAM OR ENABLE_WEB_RTC)
    if (PC_GSTREAMER_VERSION VERSION_LESS "1.12")
        message(FATAL_ERROR "GStreamer 1.12 is needed for ENABLE_WEB_RTC.")
    endif ()
    SET_AND_EXPOSE_TO_BUILD(USE_LIBWEBRTC TRUE)
    SET_AND_EXPOSE_TO_BUILD(WEBRTC_WEBKIT_BUILD TRUE)
else ()
    SET_AND_EXPOSE_TO_BUILD(USE_LIBWEBRTC FALSE)
    SET_AND_EXPOSE_TO_BUILD(WEBRTC_WEBKIT_BUILD FALSE)
endif ()
