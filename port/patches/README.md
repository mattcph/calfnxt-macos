# patches/ — upstream contribution queue

Changes the macOS port needs in **upstream** calfNXT (DSP, `common/dsp`, codegen)
are developed on a branch of the submodule, exported here as reviewable
patches, and submitted as GitHub PRs. The goal is for this queue to **trend
to zero** — each patch should land upstream and drop out on the next sync.

Until a patch lands upstream, the submodule may carry it as local commits so
the build includes the fix. `make sync-upstream TAG=…` checks out the new tag,
then reapplies each file here only when that patch is still needed. Delete the
file once the tag already has the behavior.

## Workflow

```bash
cd ../calfnxt
git checkout -b macos-impulse-paths   # scratch branch off the pinned tag
# … edit upstream sources …
git commit -am "…"                    # one logical change per commit
git format-patch <pinned-tag> -o ../../calfnxt-macos/port/patches
```

Each `NNNN-<slug>.patch` is one upstream PR. Keep them small and independent.

## Landed upstream (dropped on the v2.7.0 sync)

Realtime-safety for the dynamics plugins and Impulse shipped in calfNXT 2.4.0
(`046773f`, "Make dynamics/Impulse viz paths realtime-safe"). The old queue
entries are gone:

- compressor per-sample atomics + envelope seqlock
- the same pattern on deesser, expander, limiter, mbcomp, mblimiter, octaver,
  transients, tuner
- impulse lock-free IR swap, SPSC retire ring, waveform seqlock

## Submitting (PR artifacts)

These patches apply cleanly to `v2.7.0` (verified with `git apply --check`).
Submit as a GitHub PR from a fork of `github.com/boomshop/calfnxt`,
or send the patch file directly (`git am` applies it, authorship preserved).

On the next sync, a patch is reapplied only when the old behavior is still in
the tree. `git apply --reverse --check` catches a verbatim landing. Otherwise:

- **0004** — still needed when `configDir()` has no `Library/Application Support/calfNXT`
- **0005** — still needed when `tamer_dsp.cpp` has no `channelBuffers64`
- **0006** — still needed when `crusher_dsp.cpp` has no `channelBuffers64`

`symbolicSampleSize != kSample32` is not the signal for 0005/0006. The fix
keeps that comparison as the branch between float and double buffers. If the
hunks no longer match and the check still says the patch is needed, sync stops
so that one file can be rebased by hand. A new queue file needs its own
predicate in `tools/upstream-sync.sh`. Without one, a clean forward apply is
treated as still needed.

1. **0004** — `impulse: macOS library config dir + cross-platform session root fallback`
   Body: "Uses ~/Library/Application Support/calfNXT on macOS for the impulse
   library state (~/.config/calfnxt elsewhere). When a session restores a
   library root that doesn't exist locally (sessions travel across OSes),
   falls back to the last locally used library so the IR tree still
   populates."
2. **0005** — `tamer: run the STFT when the host processes in 64-bit`
   Body: "Reaper sends 64-bit samples. canProcessSampleSize accepts them and
   IoStage already copies and meters, but process() returned before the STFT,
   so the graph stayed at the floor."
3. **0006** — `crusher: run bit reduction when the host processes in 64-bit`
   Body: "The quantizer only read channelBuffers32 and returned on a 64-bit
   block, so the signal passed through with gain only. The response curve is
   drawn from the knobs, so the UI still looked active."

## Queue

| Patch | Scope | Status |
| ----- | ----- | ------ |
| `0004-impulse-macos-paths.patch` | impulse: `~/Library/Application Support/calfNXT` config dir on macOS; session root fallback to last local library when the stored root doesn't exist (cross-platform sessions) | ready for PR, rebased on v2.7.0 |
| `0005-tamer-64bit-process.patch` | tamer: float scratch so a 64-bit host block still runs the STFT | ready for PR, on top of v2.7.0 |
| `0006-crusher-64bit-process.patch` | crusher: same scratch path so bit reduction runs on a 64-bit block | ready for PR, on top of v2.7.0 |
