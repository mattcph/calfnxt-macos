# calfNXT macOS — single CMake superbuild.
#
# Copyright (C) 2026 Matt Hardy — GPL-3.0-or-later.
#
# One graph: vst3sdk once, common/native (ParamBridge + WKWebView), the
# WebEditor, common/dsp + 25 dsp/<id> plugins, per-plugin Vite UI builds,
# bundle, ad-hoc sign. Driven by the adjacent Makefile.
cmake_minimum_required(VERSION 3.25)

# Apple Silicon only (decided). Deployment target matches UI build.target safari16.
set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "" FORCE)
set(CMAKE_OSX_DEPLOYMENT_TARGET "13.0" CACHE STRING "" FORCE)

set(SMTG_ENABLE_VST3_PLUGIN_EXAMPLES OFF CACHE BOOL "" FORCE)
set(SMTG_ENABLE_VST3_HOSTING_EXAMPLES OFF CACHE BOOL "" FORCE)
set(SMTG_ENABLE_VSTGUI_SUPPORT OFF CACHE BOOL "" FORCE)
set(SMTG_CREATE_PLUGIN_LINK OFF CACHE BOOL "" FORCE)

# Port release version (e.g. 2.3.1.1). No default — a silent fallback would
# bake the wrong tag into Info.plist. tools/release.sh always passes
# -DCALFNXT_PORT_VERSION=…; local `make` leaves the field unset.
set(CALFNXT_PORT_VERSION "" CACHE STRING "calfNXT macOS port release version")

if(CALFNXT_PORT_VERSION)
  project(calfnxt_macos
    VERSION ${CALFNXT_PORT_VERSION}
    DESCRIPTION "calfNXT — macOS VST3 port (in-process WKWebView)"
    LANGUAGES C CXX OBJCXX
  )
else()
  project(calfnxt_macos
    DESCRIPTION "calfNXT — macOS VST3 port (in-process WKWebView)"
    LANGUAGES C CXX OBJCXX
  )
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# --- Paths -----------------------------------------------------------------
# Self-contained: overlay root is one up, upstream is the calfnxt/ submodule,
# the bridge/webview code is vendored in common/, the VST3 SDK is the
# vst3sdk/ submodule. Only Node/npm + Python are external tools.
get_filename_component(CALFNXT_MACOS_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
set(CALFNXT_UPSTREAM "${CALFNXT_MACOS_ROOT}/calfnxt")
set(CALFNXT_COMMON "${CMAKE_CURRENT_SOURCE_DIR}/common")
set(VST3_SDK_ROOT "${CALFNXT_MACOS_ROOT}/vst3sdk" CACHE PATH
  "Path to the Steinberg VST3 SDK (the vst3sdk/ submodule)")
set(CALFNXT_UI_DIST "${CMAKE_BINARY_DIR}/ui-dist" CACHE PATH "Vite SPA UI output")

if(NOT EXISTS "${CALFNXT_UPSTREAM}/CMakeLists.txt")
  message(FATAL_ERROR
    "calfNXT upstream submodule missing at ${CALFNXT_UPSTREAM}.\n"
    "  Run: git submodule update --init")
endif()
if(NOT EXISTS "${VST3_SDK_ROOT}/CMakeLists.txt")
  message(FATAL_ERROR
    "VST3 SDK not found at ${VST3_SDK_ROOT}.\n"
    "  Run: git submodule update --init --recursive\n"
    "  or pass -DVST3_SDK_ROOT=/path/to/vst3sdk")
endif()

# --- VST3 SDK (once for all 25 plugins) ------------------------------------
add_subdirectory("${VST3_SDK_ROOT}" "${CMAKE_BINARY_DIR}/vst3sdk-build")
set(SDK_ROOT "${VST3_SDK_ROOT}")
set(public_sdk_SOURCE_DIR "${VST3_SDK_ROOT}/public.sdk")

find_package(Python3 REQUIRED COMPONENTS Interpreter)
find_program(NPM_EXECUTABLE npm)
find_program(NODE_EXECUTABLE node)

include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/CalfnxtMacros.cmake)

# --- Vendored bridge/webview: ParamBridge + WKWebView + scheme -------------
add_library(auxvst_native STATIC
  ${CALFNXT_COMMON}/param_bridge.cpp
  ${CALFNXT_COMMON}/param_bridge.h
  ${CALFNXT_COMMON}/base64.h
  ${CALFNXT_COMMON}/asset_scheme.h
  ${CALFNXT_COMMON}/asset_scheme.mm
  ${CALFNXT_COMMON}/webview_plugview.h
  ${CALFNXT_COMMON}/webview_plugview.mm
)
target_include_directories(auxvst_native PUBLIC
  ${CALFNXT_COMMON}
  ${VST3_SDK_ROOT}
)
target_link_libraries(auxvst_native PUBLIC sdk)
target_compile_features(auxvst_native PUBLIC cxx_std_17)
set_target_properties(auxvst_native PROPERTIES POSITION_INDEPENDENT_CODE ON)
set_source_files_properties(
  ${CALFNXT_COMMON}/webview_plugview.mm
  ${CALFNXT_COMMON}/asset_scheme.mm
  ${CMAKE_CURRENT_SOURCE_DIR}/native/macos_folder_panel.mm
  PROPERTIES COMPILE_FLAGS "-fobjc-arc"
)
if(APPLE)
  target_link_libraries(auxvst_native PUBLIC
    "-framework WebKit" "-framework Cocoa" "-framework Foundation")
endif()

# --- Editor library: web_editor.h + viz sources -----------------------------
# common/dsp/effect_base.cpp includes "web_editor.h" and links calfnxt_ui.
add_library(calfnxt_ui STATIC
  native/web_editor.cpp
  native/web_editor.h
  native/macos_folder_panel.h
  native/macos_folder_panel.mm
  ${CALFNXT_UPSTREAM}/common/ui/viz_source.h
  ${CALFNXT_UPSTREAM}/common/ui/viz_bin.h
  ${CALFNXT_UPSTREAM}/common/ui/viz_hz.cpp
  ${CALFNXT_UPSTREAM}/common/ui/viz_hz.h
)
target_include_directories(calfnxt_ui PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/native
  ${CALFNXT_UPSTREAM}/common/ui
  ${VST3_SDK_ROOT}
)
target_link_libraries(calfnxt_ui PUBLIC auxvst_native sdk ${CMAKE_DL_LIBS})
target_compile_features(calfnxt_ui PUBLIC cxx_std_17)
set_target_properties(calfnxt_ui PROPERTIES POSITION_INDEPENDENT_CODE ON)

# --- DSP base (SingleComponentEffect + stereo + WebEditor) ------------------
add_library(calfnxt_dsp STATIC
  ${CALFNXT_UPSTREAM}/common/dsp/effect_base.cpp
  ${CALFNXT_UPSTREAM}/common/dsp/effect_base.h
  ${VST3_SDK_ROOT}/public.sdk/source/vst/vstsinglecomponenteffect.cpp
)
target_include_directories(calfnxt_dsp PUBLIC
  ${CALFNXT_UPSTREAM}/common/dsp
  ${CALFNXT_UPSTREAM}/common/ui
  ${VST3_SDK_ROOT}
)
target_link_libraries(calfnxt_dsp PUBLIC calfnxt_ui)
target_compile_features(calfnxt_dsp PUBLIC cxx_std_17)
set_target_properties(calfnxt_dsp PROPERTIES POSITION_INDEPENDENT_CODE ON)

# --- UI: per-plugin Vite builds (source only; no prebuilt ui-dist) ---------
file(GLOB_RECURSE CALFNXT_UI_SRC_DEPS CONFIGURE_DEPENDS
  "${CALFNXT_UPSTREAM}/ui/src/*"
  "${CALFNXT_UPSTREAM}/ui/scripts/*"
)
list(APPEND CALFNXT_UI_SRC_DEPS
  "${CALFNXT_UPSTREAM}/ui/package.json"
  "${CALFNXT_UPSTREAM}/ui/package-lock.json"
  "${CALFNXT_UPSTREAM}/ui/vite.config.ts"
  "${CMAKE_CURRENT_SOURCE_DIR}/ui/aliases/bridge.ts"
  "${CMAKE_CURRENT_SOURCE_DIR}/ui/aliases/reportViewport.ts"
  "${CMAKE_CURRENT_SOURCE_DIR}/vite.config.port.ts"
)

set(CALFNXT_PLUGINS
  equalizer stereo transients compressor expander deesser delay reverb
  mbcomp limiter mblimiter harmonics analyzer filter ringmod pulsator
  crusher phaser flanger chorus split tuner octaver bender impulse
)

# npm ci once, stamped on the lockfile.
set(_npm_stamp "${CMAKE_BINARY_DIR}/.npm-ci.stamp")
add_custom_command(
  OUTPUT "${_npm_stamp}"
  COMMAND ${NPM_EXECUTABLE} ci
  COMMAND ${CMAKE_COMMAND} -E touch "${_npm_stamp}"
  WORKING_DIRECTORY "${CALFNXT_UPSTREAM}/ui"
  DEPENDS "${CALFNXT_UPSTREAM}/ui/package-lock.json"
  COMMENT "npm ci (calfNXT UI deps)"
  VERBATIM
)
add_custom_target(calfnxt_npm_deps DEPENDS "${_npm_stamp}")

# One Vite build per plugin → ui-dist/plugins/<id>/{index.html,assets/}.
set(CALFNXT_UI_PLUGIN_STAMPS)
set(CALFNXT_UI_PLUGIN_TARGETS)
foreach(_id IN LISTS CALFNXT_PLUGINS)
  set(_stamp "${CMAKE_BINARY_DIR}/ui-dist/plugins/${_id}/.stamp")
  set("CALFNXT_UI_PLUGIN_STAMP_${_id}" "${_stamp}")
  add_custom_command(
    OUTPUT "${_stamp}"
    COMMAND ${CMAKE_COMMAND} -E env
      "CALFNXT_PLUGIN=${_id}"
      "CALFNXT_UI_OUTDIR=${CMAKE_BINARY_DIR}/ui-dist"
      "CALFNXT_PORT_DIR=${CMAKE_CURRENT_SOURCE_DIR}"
      "CALFNXT_VITE_CONFIG=${CMAKE_CURRENT_SOURCE_DIR}/vite.config.port.ts"
      ${NODE_EXECUTABLE} "${CMAKE_CURRENT_SOURCE_DIR}/tools/build-plugin-ui.mjs" ${_id}
    COMMAND ${CMAKE_COMMAND} -E touch "${_stamp}"
    WORKING_DIRECTORY "${CALFNXT_UPSTREAM}/ui"
    DEPENDS calfnxt_npm_deps ${CALFNXT_UI_SRC_DEPS}
    COMMENT "Vite build ${_id} → ui-dist/plugins/${_id}"
    VERBATIM
  )
  add_custom_target(calfnxt_ui_${_id} DEPENDS "${_stamp}")
  list(APPEND CALFNXT_UI_PLUGIN_STAMPS "${_stamp}")
  list(APPEND CALFNXT_UI_PLUGIN_TARGETS calfnxt_ui_${_id})
endforeach()
# Target-level deps (not stamp-file deps): the Xcode new build system rejects a
# custom command output attached to more than one target.
add_custom_target(calfnxt_web_ui DEPENDS ${CALFNXT_UI_PLUGIN_TARGETS})

# UI builds import generated models across plugins (shared host code), so every
# per-plugin UI build must wait for all plugin codegen. The codegen targets are
# created in the dsp/<id> subdirs below; collect them and wire the dependency
# after the loop.

# --- Plugins ---------------------------------------------------------------
# dsp/<id>/CMakeLists.txt resolve the codegen script and the TS model output
# via CMAKE_SOURCE_DIR (fixed to this dir). Symlink the two referenced paths
# so those lookups resolve.
if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/tools/codegen/generate_plugin.py")
  file(CREATE_LINK
    "${CALFNXT_UPSTREAM}/tools/codegen"
    "${CMAKE_CURRENT_SOURCE_DIR}/tools/codegen"
    SYMBOLIC)
endif()
if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/ui/src")
  file(MAKE_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/ui")
  file(CREATE_LINK
    "${CALFNXT_UPSTREAM}/ui/src"
    "${CMAKE_CURRENT_SOURCE_DIR}/ui/src"
    SYMBOLIC)
endif()

foreach(_id IN LISTS CALFNXT_PLUGINS)
  add_subdirectory("${CALFNXT_UPSTREAM}/dsp/${_id}" "${CMAKE_BINARY_DIR}/dsp/${_id}")
  add_dependencies(calfnxt-${_id} calfnxt_ui_${_id})
endforeach()

# Every UI pack needs every generated model (cross-plugin host imports).
foreach(_id IN LISTS CALFNXT_PLUGINS)
  foreach(_gen IN LISTS CALFNXT_PLUGINS)
    add_dependencies(calfnxt_ui_${_id} ${_gen}_codegen)
  endforeach()
endforeach()

# Meta-target: all plugins + embedded UI packs.
set(_calfnxt_all)
foreach(_id IN LISTS CALFNXT_PLUGINS)
  list(APPEND _calfnxt_all calfnxt-${_id} calfnxt-${_id}-resources)
endforeach()
add_custom_target(calfnxt-plugins DEPENDS ${_calfnxt_all}
  COMMENT "Build all calfNXT macOS VST3 plugins (+ embedded UI)")

# --- Install: real copies into ~/Library/Audio/Plug-Ins/VST3 ---------------
get_property(_calfnxt_install_targets GLOBAL PROPERTY CALFNXT_INSTALL_TARGETS)
get_property(_calfnxt_install_names GLOBAL PROPERTY CALFNXT_INSTALL_VST3_NAMES)
set(CALFNXT_USER_VST3_DIR "$ENV{HOME}/Library/Audio/Plug-Ins/VST3" CACHE PATH
  "User VST3 install dir")

if(_calfnxt_install_targets)
  set(_copy_cmds)
  list(LENGTH _calfnxt_install_targets _n)
  math(EXPR _last "${_n} - 1")
  foreach(_i RANGE ${_last})
    list(GET _calfnxt_install_targets ${_i} _t)
    list(GET _calfnxt_install_names ${_i} _name)
    # SDK package path, not TARGET_FILE_DIR (Xcode genex resolves to *.bundle).
    get_target_property(_pkg_path ${_t} SMTG_PLUGIN_PACKAGE_PATH)
    list(APPEND _copy_cmds
      COMMAND ${CMAKE_COMMAND} -E rm -rf "${CALFNXT_USER_VST3_DIR}/${_name}.vst3"
      COMMAND ${CMAKE_COMMAND} -E copy_directory
        "${_pkg_path}"
        "${CALFNXT_USER_VST3_DIR}/${_name}.vst3"
    )
  endforeach()
  add_custom_target(install-user-vst3
    ${_copy_cmds}
    COMMENT "Install calfNXT plugins → ${CALFNXT_USER_VST3_DIR}"
    DEPENDS ${_calfnxt_install_targets}
    VERBATIM
  )
endif()

message(STATUS "calfnxt(macOS): ${CALFNXT_PLUGINS}")
message(STATUS "calfnxt(macOS): build all with --target calfnxt-plugins")
