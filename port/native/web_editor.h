// calfNXT macOS — VST3 editor over in-process WKWebView + ParamBridge.
//
// Copyright (C) 2026 Matt Hardy — GPL-3.0-or-later.
//
// Wire conventions:
//   - params are plain (dB/Hz) in both directions; the controller Parameter
//     converts to VST-normalized at the boundary
//   - viz arrays are batched per tick as CNXB via evalBinaryBase64
#pragma once

#include "public.sdk/source/common/pluginview.h"
#include "public.sdk/source/vst/vsteditcontroller.h"
#include "public.sdk/source/vst/vstparameters.h"

#include "param_bridge.h"
#include "viz_source.h"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstddef>
#include <string>
#include <vector>

namespace calfNXT {
namespace Ui {

/** In-process WKWebView editor (macOS). */
class WebEditor : public Steinberg::CPluginView,
                  public Steinberg::Vst::IWebViewTransport
{
public:
  WebEditor(Steinberg::Vst::EditController* controller, Steinberg::ViewRect size,
            const char* entryHtml = "index.html");
  ~WebEditor() override;

  void setVizSource(IVizSource* source) { vizSource_ = source; }

  Steinberg::tresult PLUGIN_API isPlatformTypeSupported(Steinberg::FIDString type) SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API attached(void* parent, Steinberg::FIDString type) SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API removed() SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API onSize(Steinberg::ViewRect* newSize) SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API canResize() SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API checkSizeConstraint(Steinberg::ViewRect* rect) SMTG_OVERRIDE;

  /** Param change notification (EditController dependent). */
  void PLUGIN_API update(Steinberg::FUnknown* changedUnknown,
                         Steinberg::int32 message) SMTG_OVERRIDE;

  OBJ_METHODS(WebEditor, Steinberg::CPluginView)
  REFCOUNT_METHODS(Steinberg::CPluginView)

  /** Evaluate JS in the WebView (main thread). */
  void evalJs(const char* js);
  /** Push one plain param value to the UI (converted to normalized). */
  void pushParamPlain(Steinberg::Vst::ParamID id, double plain);
  void pushAllParams();
  void pushIoChannels();

  Steinberg::Vst::EditController* controller() const { return controller_; }

  /** IWebViewTransport: ParamBridge drain target. */
  void evalJS(const std::string& js) SMTG_OVERRIDE;
  void evalBinaryBase64(const std::string& base64) SMTG_OVERRIDE;

  /** UI→host message from the WKScriptMessage handler (JSON text). */
  void onScriptMessage(const char* json);

  /** Physical mouse gesture boundaries in the WebView (main thread).
      Brackets {t:"set"} streams with beginEdit/endEdit so the host does
      not have to synthesize gesture boundaries. */
  void gestureMouseDown();
  void gestureMouseUp();

protected:
  virtual void onPageReady();
  virtual bool onWebMessage(const char* json);

private:
  void attachParamListeners();
  void detachParamListeners();
  /** ParamBridge viz drain (registered via setVizDrain): throttled to vizHz,
      drains every IVizSource channel and fills one base64 CNXB batch. */
  void drainViz(std::string& outB64);
  void flushVizArray(const char* streamId, const char* kind, float* values, int n);
  int queryBusChannelCount(Steinberg::Vst::BusDirection dir, int busIndex) const;
  int queryIoChannelCount() const;

  Steinberg::Vst::EditController* controller_ = nullptr;
  IVizSource* vizSource_ = nullptr;
  char entryHtml_[256] {};

  Steinberg::Vst::ParamBridge* bridge_ = nullptr; // owned
  void* plugView_ = nullptr;                      // WebViewPlugView*, owned

  bool listeningParams_ = false;
  bool suppressParamPush_ = false;
  bool pageReady_ = false;
  /** Mouse is down in the WebView; sets during this window are bracketed. */
  bool gestureMouseDown_ = false;
  /** Params whose beginEdit was issued within the current mouse gesture. */
  std::vector<Steinberg::Vst::ParamID> gestureParams_;
  /** Editor visible (attach + occlusion). Gates the viz drain. */
  bool editorVisible_ = false;

  std::chrono::steady_clock::time_point lastVizFlush_ {};
  /** Envelope/pitch/midi tier has its own clock (mirrors upstream). */
  std::chrono::steady_clock::time_point lastEnvVizFlush_ {};
  /** Accumulates CNXV frames during one flushViz() for a single CNXB send. */
  std::vector<char> vizBatchFrames_;
  std::uint32_t vizBatchCount_ = 0;
  bool vizBatchOpen_ = false;

  Steinberg::int32 designWidth_ = 360;
  Steinberg::int32 designHeight_ = 420;
};

} // namespace Ui
} // namespace calfNXT
