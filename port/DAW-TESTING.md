# calfNXT macOS: DAW verification checklist

Manual checkpoint for the pilot plugins (**calfNXT Compressor**, **calfNXT
Equalizer**) in **Nuendo** and **Ableton Live**. All 25 bundles are installed
to `~/Library/Audio/Plug-Ins/VST3/`; start with these two.

If something misbehaves, note the plugin, the step, and grab
`/tmp/calfnxt-ui.log` (UI diagnostics) before quitting the DAW. The DAW
writes the log when it runs with `AUXVST_DEBUG=1` in its environment:

```bash
launchctl setenv AUXVST_DEBUG 1   # then launch the DAW normally
```

The same flag also enables Safari Web Inspector on the WebView (right-click →
Inspect Element) and the per-tick viz dump (`window.__calfnxtDumpViz()`).

## 1. Load & first paint

- [ ] Plugin scans and appears under **calfNXT** vendor (Effects → EQ /
  Dynamics).
- [ ] Editor opens at the correct size (Compressor 960×620, Equalizer
  1024×680), dark theme, clean first paint, fully rendered UI.
- [ ] UI matches the Linux calfNXT look: AUX knobs/faders, header with In/Out
  meters + gain knobs.

## 2. Parameters (UI → host)

- [ ] Turning a knob audibly changes the sound (threshold/ratio on the
  Compressor; band gain/freq on the Equalizer).
- [ ] Dragging a control creates an automation lane point/gesture in the DAW
  (begin/endEdit bracketing; check undo history shows one gesture per drag).

## 3. Parameters (host → UI)

- [ ] Write automation in the DAW, play it back: the UI control follows.
- [ ] Use the DAW's generic/parameter editor to change a value: the calfNXT
  UI updates live.
- [ ] Precision spot-check: set 20.0 kHz band freq via automation: UI shows
  20.0 kHz exactly.

## 4. Meters & viz (CNXB seam)

- [ ] Header In/Out meters animate with program material.
- [ ] Compressor: GR meter moves; the transfer-curve point tracks in/out.
- [ ] Equalizer: the response curve draws; moving a band updates it; enable
  the spectrum overlay and confirm it animates.
- [ ] Change the viz rate in the header prefs (30 → 10 Hz): motion slows;
  back to 30 Hz.

## 5. Session & state

- [ ] Save the project with modified settings, close, reopen: all params
  restored, UI shows the restored values.
- [ ] Close the editor, reopen it: state intact, meters resume.
- [ ] Duplicate the track: the copy has independent state.

## 6. Host edge cases

- [ ] Mono track (Nuendo): plugin may decline the mono bus and suggest
  stereo; note the host's behavior (known upstream arrangement policy).
- [ ] Bypass from the DAW: audio bypasses, UI reflects it.
- [ ] Drag the editor window corner: the UI follows the resize; minimum size
  is the design size (Compressor 960×620, Equalizer 1024×680).
- [ ] Editor open while window is minimized/occluded: CPU stays flat
  (Activity Monitor; the viz drain is occlusion-gated).
- [ ] Idle with editor open: CPU settles near zero (transport stopped, silent
  input).

## 7. Impulse (bonus, needs an IR folder)

- [ ] **Library…** opens a native macOS folder chooser (NSOpenPanel).
- [ ] Choose an IR folder: the tree populates; select a WAV/AIFF: it loads,
  the waveform draws, predelay/length handles work.
- [ ] Save/reopen the project: the IR is restored (embedded in the session
  chunk) and the library root is remembered for next time
  (`~/.config/calfnxt/impulse-library` until upstream merges patch 0004).

## Known limitations (by design, this release)

- Shipped binaries are **pristine upstream v2.3.0**: the RT-safety fixes live
  in `port/patches/` (0001-0003) until Markus merges them. Audio-thread locks
  remain in the shipped build.
- Impulse's default library dir is `~/.config/calfnxt` (Linux-style) until
  patch 0004 lands upstream.
- Mono bus arrangements are rejected by upstream `setBusArrangements`; the
  plugin suggests stereo.

## Known host issues

- **Ableton Live ≤ 12.3** has a confirmed plug-in window z-order bug on
  macOS: clicking one plug-in window may raise a different one, and new
  windows can open behind existing ones. Fixed in Live 12.4; update if you
  hit it.
