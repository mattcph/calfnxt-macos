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
git checkout -b rt-safety            # scratch branch off the pinned tag
# … edit upstream sources …
git commit -am "…"                   # one logical change per commit
git format-patch <pinned-tag> -o ../../calfnxt-macos/port/patches
```

Each `NNNN-<slug>.patch` is one upstream PR. Keep them small and independent.

## Submitting (PR artifacts)

All four apply cleanly to `v2.3.0` (verified with `git apply --check`).
Submit to Markus as GitHub PRs from a fork of `github.com/boomshop/calfnxt`,
or send the patch files directly (`git am` applies them, authorship
preserved). Suggested PRs:

1. **0001** — `compressor: RT-safety — drop per-sample vizMutex_ + per-block histMutex_`
   Body: "Removes audio-thread mutexes from the compressor viz path:
   per-sample operating point/GR move to relaxed atomics, the per-block
   envelope history moves to a seqlock. No behavior change; validated in the
   macOS port. Part of a series; see also the dynamics-tools patch."
2. **0002** — `dynamics: RT-safety atomics + seqlock pattern (8 plugins)`
   Body: "Same pattern as the compressor patch, applied to deesser, expander,
   limiter, mbcomp, mblimiter, octaver, transients, tuner."
3. **0003** — `impulse: lock-free IR swap + SPSC retire ring + waveform seqlock`
   Body: "Removes audio-thread locking/allocation from IR load/swap:
   lock-free pointer exchange for the convolver handoff, SPSC retire ring for
   the old IR, seqlock for the waveform display, scratch pre-allocated in
   setupProcessing()."
4. **0004** — `impulse: macOS library config dir + cross-platform session root fallback`
   Body: "Uses ~/Library/Application Support/calfNXT on macOS for the impulse
   library state (~/.config/calfnxt elsewhere). When a session restores a
   library root that doesn't exist locally (sessions travel across OSes),
   falls back to the last locally used library so the IR tree still
   populates."

## Queue

| Patch | Scope | Status |
| ----- | ----- | ------ |
| `0001-compressor-rt-safety.patch` | compressor: drop per-sample `vizMutex_` (atomics) + per-block `histMutex_` (seqlock) | ready for PR |
| `0002-dynamics-tools-rt-safety.patch` | deesser, expander, limiter, mbcomp, mblimiter, octaver, transients, tuner: same atomics + seqlock pattern | ready for PR |
| `0003-impulse-rt-safety.patch` | impulse: lock-free IR swap (atomic pointer exchange), SPSC retire ring, waveform seqlock, pre-allocated scratch | ready for PR |
| `0004-impulse-macos-paths.patch` | impulse: `~/Library/Application Support/calfNXT` config dir on macOS; session root fallback to last local library when the stored root doesn't exist (cross-platform sessions) | ready for PR |

## Realtime-safety rationale (applies to the whole series)

The audio thread (`process()` / `processSample()`) must never take a blocking
mutex or allocate. The pattern used throughout:

- **Per-sample scalars** (operating point, GR) → `std::atomic<float>`, relaxed.
- **Per-block array snapshots** (envelope, spectrum, response) → a **seqlock**
  (odd/even atomic sequence; the UI reader retries on a torn read, the audio
  thread never blocks).
- **Background → audio handoff** (impulse responses) → lock-free pointer swap.
- **Scratch buffers** → pre-allocated to `maxSamplesPerBlock` in
  `setupProcessing()`, never resized on the audio thread.
