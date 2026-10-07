# source assets will be installed from this directory
set(SUNSHINE_SOURCE_ASSETS_DIR "${CMAKE_SOURCE_DIR}/src_assets")

# enable system tray, we will disable this later if we cannot find the required package config on linux
set(SUNSHINE_TRAY 1)
# Razer Cortex integration (named pipe, Razer ID pairing, IDD virtual display,
# UI scale helper) is Windows-only. Default it on for Windows and off elsewhere;
# override with -DRAZER_MOD=0/1.
if(NOT DEFINED RAZER_MOD)
    if(WIN32)
        set(RAZER_MOD 1)
    else()
        set(RAZER_MOD 0)
    endif()
endif()
