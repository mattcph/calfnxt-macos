# calfNXT macOS VST3 port

**calfNXT ported to macOS, with subtle changes, by Matt Hardy.**

This is a fork of the Linux project [calfNXT](https://calfnxt.org/) by Markus
Schmidt, the successor to [Calf Studio Gear](https://calf-studio-gear.org), a VST3 suite with a React + AUX web UI. The DSP algorithms, the parameter model, and the React/AUX interface are preserved. 

License: **GNU GPL v3 or later**. See `[COPYRIGHT](COPYRIGHT)`. Upstream
notices are retained; new code is Copyright (C) 2026 Matt Hardy.

---

## What the fork changes

### A different parameter bridge

Upstream calfNXT runs the editor **out of process**: the plugin `.so` spawns a
`calfnxt-web-host` helper (GTK `GtkPlug` + WebKitGTK, XEmbedded into the host's
X11 window) and talks to it over a **Unix socketpair**: JSON lines one way,
base64 binary frames the other.

The calfNXT-macos port runs the editor **in process**. Each plugin hosts a **WKWebView**
directly on its `NSView`, and parameters flow through the auxVST **ParamBridge** (found at `common/param_bridge.cpp`).


|                          | upstream (Linux)                          | this port (macOS)                                          |
| ------------------------ | ----------------------------------------- | ---------------------------------------------------------- |
| Web view                 | WebKitGTK in a helper process             | WKWebView in the plugin                                    |
| IPC                      | Unix `socketpair` + `posix_spawn`         | in-process `WKScriptMessage` / `evaluateJavaScript`        |
| Param values on the wire | plain (dB, Hz) + a `q/d` fixed-point form | plain (dB, Hz) in both directions                          |
| UI assets                | `calfnxt://` scheme from `Resources/`     | `auxvst://` scheme from `Resources/webui`                  |
| Editor scaling           | XEmbed scale ladder                       | WKWebView backing scale (design size from `*.plugin.json`) |


### Architecture

```
VST3 DAW (Nuendo, Live, Bitwig, Reaper, Studio One)
  └─ calfNXT<Plugin>.vst3            (arm64, Apple Silicon only)
       ├─ Processor                  upstream DSP, SingleComponentEffect
       ├─ EditController
       │    └─ ParamBridge           coalesced ~16 ms drain, change-gated
       └─ WKWebView (in-process)
            └─ React + AUX SPA       upstream UI, per-plugin pack
```

- **Parameters** stay the single source of truth in the upstream
`*.plugin.json` descriptors; codegen emits the C++ catalog and the TS model.
The wire is plain (dB, Hz); the controller `Parameter` converts to
VST-normalized at the boundary.
- **All visualization** (levels, gain reduction, envelope, spectrum, EQ
response, IR wave, …) rides the CNXV/CNXB array seam, published from the
audio thread through per-stream lock-free buffers and drained as **one**
base64 batch per tick. The audio thread never takes a mutex for
visualization.

### Other differences

- **Apple Silicon only** (deployment target macOS 13).
- **VST3 only.**
- **One build process.** A single `Makefile` over one CMake superbuild builds
the SDK once, all 25 DSP targets, and all per-plugin UI packs. `make`,
`make PLUGIN=compressor`, `make install`, `make check`.
- **React glue is port-owned.** `ui/react-aux/` implements the React ↔ AUX
bindings over AWML `Bindings`/`DynamicValue`, wired in by a Vite alias.
- **Install layout** is the macOS `~/Library/Audio/Plug-Ins/VST3/`, with
bundles, locally signed; Developer ID + notarization via `make release`
(`tools/release.sh`).

### What is intentionally kept identical

- VST3 UIDs, bundle names, and `setState`/`getState` chunk formats, so
sessions and presets round-trip with the Linux build.
- The DSP math and the React/AUX styling, layout, and interaction.

---

## Build

Requires the VST3 SDK submodule at `../vst3sdk` and the upstream submodule
checked out (`git submodule update --init --recursive` from the repo root).

```bash
make                    # all 25 plugins: UI + DSP + bundle + ad-hoc sign
make PLUGIN=compressor  # one plugin
make install            # copy to ~/Library/Audio/Plug-Ins/VST3
make check              # seam drift checks + Steinberg validator (all plugins)
```

## Layout

- `common/`: the vendored platform layer (ParamBridge, WKWebView, asset
scheme, base64)
- `native/`: the WKWebView editor (`web_editor.*`) over ParamBridge
- `ui/aliases/`: bridge / viewport shims selected by the Vite config
- `ui/react-aux/`: port-owned React ↔ AUX/AWML glue
- `cmake/`, `tools/`: build macros, per-plugin UI build, drift checks
- `../calfnxt`: upstream submodule (pinned tag)

