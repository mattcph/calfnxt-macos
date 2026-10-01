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

## Landed upstream

Realtime-safety for the dynamics plugins and Impulse shipped in calfNXT 2.4.0
(`046773f`, "Make dynamics/Impulse viz paths realtime-safe"). Dropped on the
v2.7.0 sync:

- compressor per-sample atomics + envelope seqlock
- the same pattern on deesser, expander, limiter, mbcomp, mblimiter, octaver,
  transients, tuner
- impulse lock-free IR swap, SPSC retire ring, waveform seqlock

Tamer and Crusher 64-bit processing shipped in calfNXT 2.10.0 (`c6c21ca`,
shared `Sample64Scratch`). Dropped on this sync:

- `0005-tamer-64bit-process.patch`
- `0006-crusher-64bit-process.patch`

## Submitting (PR artifacts)

The remaining patch applies cleanly to `v2.12.3` (verified with
`git apply --check`). Submit as a GitHub PR from a fork of
`github.com/boomshop/calfnxt`, or send the patch file directly (`git am`
applies it, authorship preserved).

On the next sync, a patch is reapplied only when the old behavior is still in
the tree. `git apply --reverse --check` catches a verbatim landing. Otherwise:

- **0004** — still needed when `configDir()` has no `Library/Application Support/calfNXT`

If the hunks no longer match and the check still says the patch is needed,
sync stops so that one file can be rebased by hand. A new queue file needs its
own predicate in `tools/upstream-sync.sh`. Without one, a clean forward apply
is treated as still needed.

1. **0004** — `impulse: macOS library config dir + cross-platform session root fallback`
   Body: "Uses ~/Library/Application Support/calfNXT on macOS for the impulse
   library state (~/.config/calfnxt elsewhere). When a session restores a
   library root that doesn't exist locally (sessions travel across OSes),
   falls back to the last locally used library so the IR tree still
   populates."

## Queue

| Patch | Scope | Status |
| ----- | ----- | ------ |
| `0004-impulse-macos-paths.patch` | impulse: `~/Library/Application Support/calfNXT` config dir on macOS; session root fallback to last local library when the stored root doesn't exist (cross-platform sessions) | ready for PR, applied on v2.12.3 |
