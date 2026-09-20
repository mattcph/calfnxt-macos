# calfNXT macOS VST3 port (forkable drop-in)

**calfNXT ported to macOS, with subtle changes, by Matt Hardy.**

A self-contained, forkable port of [calfNXT](https://calfnxt.org/) (Markus Schmidt's Linux VST3 suite, successor to Calf Studio Gear) to macOS. DSP, parameter model, and the React/AUX UI are upstream's; the platform layer, in-process WKWebView editor over the auxVST ParamBridge.

License: **GPL-3.0-or-later**. See [port/COPYRIGHT](port/COPYRIGHT).

## Layout

- `calfnxt/`: upstream calfNXT, a pinned **git submodule** (read-only).
- `port/`: the macOS overlay with the WKWebView editor, React glue,
CMake/Makefile superbuild, drift/sync tooling, and the `patches/` queue of
upstream-bound changes.



## Requirements


| Tool                                   | Role                                              |
| -------------------------------------- | ------------------------------------------------- |
| **macOS 13+**, Apple Silicon (`arm64`) | Target platform (VST3 only)                       |
| **Xcode**                              | Build generator (CMake drives Xcode) + Clang      |
| **CMake** ≥ 3.25                       | Build (`brew install cmake`)                      |
| **Python 3**                           | Parameter codegen (system `python3` is fine)      |
| **Node.js** + **npm**                  | Build the React/AUX UI (`brew install node`)      |




## Get the sources

One repo, two submodules. Clone, then fetch the submodules:

```bash
git clone <your-fork-url> calfnxt-macos
cd calfnxt-macos
git submodule update --init --recursive
```

That pulls in:

```
calfnxt-macos/
├── calfnxt/    ← upstream calfNXT (submodule, pinned tag)
├── vst3sdk/    ← Steinberg VST3 SDK (submodule, v3.8.0_build_66)
├── port/       ← the macOS overlay (editor, build, patches)
└── README.md
```

> The VST3 SDK is the `vst3sdk/` submodule. To use a different checkout,
> pass `-DVST3_SDK_ROOT=/path/to/vst3sdk` to the build.



## Build

```bash
cd calfnxt-macos/port

make                    # all 25 plugins: UI + DSP + bundle + ad-hoc sign
make PLUGIN=compressor  # one plugin (fast iterate)
make install            # copy to ~/Library/Audio/Plug-Ins/VST3
make check              # seam drift checks + Steinberg validator (all 25)
make release VERSION=2.3.1.1            # clean rebuild + Developer ID sign → Releases/2.3.1.1/
make release VERSION=2.3.1.1 NOTARIZE=1 #   + notarize + staple
make clean              # remove build output (keep configure)
make distclean          # remove the whole build tree + UI dist
```

Then rescan in your DAW. Bundles land in
`~/Library/Audio/Plug-Ins/VST3/calfNXT<Plugin>.vst3`.

## Sync with upstream

When upstream calfNXT tags a new release:

```bash
cd calfnxt-macos/port
make sync-upstream TAG=vX.Y.Z   # bump submodule, classify changes, rebuild + validate
```

See [port/AGENTS.md](port/AGENTS.md) for the seam rules and the
never-reintroduce list.

## Documentation

- [port/README.md](port/README.md): what the fork changes (parameter bridge,
architecture, macOS differences) and the full layout.
- [port/AGENTS.md](port/AGENTS.md): port-tree rules: the four seams, the
sync ritual, and the never-reintroduce list. Read this before editing.
- [port/DAW-TESTING.md](port/DAW-TESTING.md): manual DAW verification
checklist.
- [port/HOWTO-DISTRIBUTE.md](port/HOWTO-DISTRIBUTE.md): Developer ID
signing, notarization, and release.

