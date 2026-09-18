# calfNXT macOS port: agent handoff

This file governs the **port tree** (`calfnxt-macos/port/`). It supersedes the
upstream `AGENTS.md` for anything built here. Read it before editing.

The port is calfNXT (upstream: Markus Schmidt, Linux) ported to macOS by Matt
Hardy. DSP, the parameter model, and the React/AUX UI are upstream's; the
platform layer is the port's. GPL-3.0-or-later throughout.

---

## The one rule that matters

**The upstream submodule stays zero-diff.** Everything macOS-specific lives in
the overlay (`calfnxt-macos/port/`). If a change needs to touch upstream, it goes
through the `patches/` queue and a PR to Markus.

- **Upstream (read-only):** `../calfnxt/`: DSP,
  `*.plugin.json` descriptors, React/AUX UI sources, upstream codegen.
- **Port (editable):** `native/`, `common/`, `ui/aliases/`, `ui/react-aux/`,
  `cmake/`, `tools/`, `Makefile`, `CMakeLists.txt`, `vite.config.port.ts`.
- **Vendored platform layer:** `common/` (ParamBridge, WKWebView, asset
  scheme, base64). The CNXV/CNXB wire format header is upstream's
  `common/ui/viz_bin.h`.

## Seam rules

The port integrates with upstream at exactly four seams. Keep them clean.

1. **Editor**: `native/web_editor.{h,cpp}` provides `calfnxt::Ui::WebEditor`
   over ParamBridge/WKWebView. Upstream `common/dsp/effect_base.cpp` includes
   `"web_editor.h"` and links `calfnxt_ui`; the port dir shadows the include.
2. **UI transport**: `ui/aliases/bridge.ts` + `reportViewport.ts` are selected
   by `vite.config.port.ts` in place of the upstream `utils/` files. Same
   exports, same message shapes.
3. **CMake macros**: `cmake/CalfnxtMacros.cmake` defines
   `calfnxt_copy_plugin_ui` / `calfnxt_copy_web_host` that upstream
   `dsp/<id>/CMakeLists.txt` call.
4. **Codegen**: upstream `tools/codegen/generate_plugin.py` is the only
   codegen and the SSOT: each `*.plugin.json` descriptor emits the C++
   parameter header and the TS model. The port builds the ParamBridge catalog
   at runtime from the controller's registered parameters
   (`WebEditor::attached`).

`tools/check-seam.sh` verifies the seams (viz kinds, UI→host message types,
codegen schema). It runs in `make check` and must stay green.

## Wire conventions

- Params are **plain** (dB/Hz) in both directions: UI→host `{t:"set",id,v}`
  and host→UI ParamBridge `params` frames. WKScriptMessage preserves doubles
  losslessly.
- **All viz** (levels, GR, correlation, envelope, spectrum, response, IR
  wave, …) rides the CNXV/CNXB seam via per-stream seqlock buffers → **one**
  base64 batch per tick.
- The audio thread never takes a mutex for visualization. If a viz path needs
  a lock, that's a bug; use the seqlock.

## Sync ritual (upstream → port)

When upstream tags a new release:

```bash
make sync-upstream TAG=vX.Y.Z   # bumps the submodule, classifies changes
make                            # rebuild
make check                      # seam drift + validator (all 25)
```

`tools/upstream-sync.sh` classifies each changed upstream path as **PORTABLE**
(take it: DSP, UI, descriptors), **SEAM** (review against the overlay), or
**IGNORED** (Linux-only: web_host, GTK, X11). Then re-run the seam checks.

## Never reintroduce

- The editor UI is one in-process WKWebView: no out-of-process web host, `posix_spawn`, Unix socketpairs, or platform toolkits.
- No `use-aux-widgets` (GPL-2-only).
- No per-block `Parameter::toPlain` in `process()` (audio-thread perf).
- No audio-thread mutexes on the viz path.
- No Google Fonts / network fetches from the UI (GDPR).

## Build

```bash
make                    # all 25 plugins (UI + DSP + bundle + ad-hoc sign)
make PLUGIN=compressor  # one plugin
make install            # ~/Library/Audio/Plug-Ins/VST3
make check              # seam drift + Steinberg validator (all 25)
make release            # Developer ID sign → dist/ (NOTARIZE=1 adds notarize+staple)
```

Apple Silicon (`arm64`) only, macOS 13+, VST3 only. See `README.md`.
