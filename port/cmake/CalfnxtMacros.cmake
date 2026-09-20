# calfNXT macOS — CMake helper macros.
#
# Copyright (C) 2026 Matt Hardy — GPL-3.0-or-later.

# Embed this plugin's packed SPA into the VST3 bundle Resources/webui.
# Registers the target for `make install` (CALFNXT_INSTALL_TARGETS).
function(calfnxt_copy_plugin_ui target plugin_id vst3_dirname)
  # Stamp the bundle metadata (identifier + version). The SDK only fills the
  # generated Info.plist when smtg_target_set_bundle runs; the upstream
  # dsp/<id> CMakeLists never call it, so do it here for all 25 plugins.
  # PROJECT_VERSION comes from -DCALFNXT_PORT_VERSION (required for release;
  # local `make` leaves it unset — no fallback tag).
  smtg_target_set_bundle(${target}
    BUNDLE_IDENTIFIER "com.deuso.calfnxt.${plugin_id}"
    COMPANY_NAME "Matt Hardy"
  )

  set(plugin_dist "${CALFNXT_UI_DIST}/plugins/${plugin_id}")
  set(res_stamp "${CMAKE_BINARY_DIR}/${target}.resources.stamp")

  # Embed into the .vst3 package via the SDK's package-path property — NOT
  # TARGET_FILE_DIR: under the Xcode generator that resolves to a phantom
  # *.bundle (CMake doesn't model XCODE_ATTRIBUTE_WRAPPER_EXTENSION).
  get_target_property(_pkg_path ${target} SMTG_PLUGIN_PACKAGE_PATH)

  add_custom_command(
    OUTPUT "${res_stamp}"
    COMMAND ${CMAKE_COMMAND} -E rm -rf
      "${_pkg_path}/Contents/Resources/webui"
    COMMAND ${CMAKE_COMMAND} -E make_directory
      "${_pkg_path}/Contents/Resources/webui"
    COMMAND ${CMAKE_COMMAND} -E copy_directory
      "${plugin_dist}"
      "${_pkg_path}/Contents/Resources/webui"
    COMMAND ${CMAKE_COMMAND} -E rm -f
      "${_pkg_path}/Contents/Resources/webui/.stamp"
    # GPL + copyright notices ship inside every bundle.
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/../COPYRIGHT"
      "${_pkg_path}/Contents/Resources/COPYRIGHT"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${CALFNXT_UPSTREAM}/LICENSE"
      "${_pkg_path}/Contents/Resources/LICENSE"
    COMMAND ${CMAKE_COMMAND} -E touch "${res_stamp}"
    DEPENDS
      ${target}
      "${CALFNXT_UI_PLUGIN_STAMP_${plugin_id}}"
    COMMENT "Embed ${plugin_id} UI + licenses into ${target} Resources"
    VERBATIM
  )
  add_custom_target(${target}-resources ALL DEPENDS "${res_stamp}")

  set_property(GLOBAL APPEND PROPERTY CALFNXT_INSTALL_TARGETS "${target}")
  set_property(GLOBAL APPEND PROPERTY CALFNXT_INSTALL_VST3_NAMES "${vst3_dirname}")
endfunction()

# The editor is in-process WKWebView; there is no separate web-host binary.
function(calfnxt_copy_web_host target)
  # no-op
endfunction()
