# patches/ — upstream contribution queue

Changes the macOS port needs in **upstream** calfNXT (DSP, `common/dsp`, codegen)
are developed on a branch of the submodule, exported here as reviewable
patches, and submitted as PRs to Markus. The goal is for this queue to **trend
to zero** — each patch should land upstream and drop out on the next sync.

The submodule stays **zero-diff** on the pinned tag in the shipped tree. These
patches are *not* applied to the build; they exist so the work is reviewable
and mergeable upstream. Once a patch merges, `make sync-upstream TAG=…` pulls
it in and the file here is deleted.

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

The remaining patch applies cleanly to `v2.7.0` (verified with
`git apply --check`). Submit to Markus as a GitHub PR from a fork of
`github.com/boomshop/calfnxt`, or send the patch file directly (`git am`
applies it, authorship preserved).

1. **0004** — `impulse: macOS library config dir + cross-platform session root fallback`
   Body: "Uses ~/Library/Application Support/calfNXT on macOS for the impulse
   library state (~/.config/calfnxt elsewhere). When a session restores a
   library root that doesn't exist locally (sessions travel across OSes),
   falls back to the last locally used library so the IR tree still
   populates."

## Queue

| Patch | Scope | Status |
| ----- | ----- | ------ |
| `0004-impulse-macos-paths.patch` | impulse: `~/Library/Application Support/calfNXT` config dir on macOS; session root fallback to last local library when the stored root doesn't exist (cross-platform sessions) | ready for PR, rebased on v2.7.0 |
