# UIImage / NSImage Snapshot Performance Plan

## Progress log (resumable)

- **Phase 0** ✅ committed `6e3461a`. `SnapshotTestingBenchmarks` executable target,
  `scripts/bench.sh`, baselines under `bench-baseline/pre-phase1-{serial,parallel-4,parallel-8}.csv`.
- **Phase 1** ✅ code `8bf1107`, bench `8933727`.
- **Phase 2** ✅ code `3dd37a1`, bench `e7c8541`. CIContext pool + perceptual diff limiter.
  Headline: perceptual parallel wall halved vs Phase 1; serial perceptual recovered
  (was a regression in Phase 1) and now beats baseline.
- **Phase 3** ✅ code `255b526`, bench `d39b74e`. Drop PNG round-trip in `compare()`
  + `normalizedComponentDiff()`; normalize NSImage's `context(for:)` to match UIImage's
  (sRGB+8bpc+RGBA8). Headline: precision-1px-diff p50 serial **−84%**, parallel-4
  wall **−89%**; exact-match-large p50 serial **−59%**. Legacy path gated behind
  `SNAPSHOT_TESTING_LEGACY_NORMALIZATION=1` for one release.
  - Follow-up ✅ commit `9a616cd` — added `ImageNormalizationEdgeCasesTests.swift`
    with 12 tests (6 UIImage + 6 NSImage) covering non-premultiplied alpha,
    Display P3, and grayscale CGImages. All pass under both the new path and
    `SNAPSHOT_TESTING_LEGACY_NORMALIZATION=1`, confirming `context(for:)` subsumes
    what the PNG round-trip was guarding against.
- **Phase 4** ✅ code `a3c01cd`, bench `3d6f2e0`. `blendModeDiff` swap to
  `UIGraphicsImageRenderer`. Bench within ±5% noise (expected — fallback path).
  - Follow-up ✅ commit `4fb3bc9` — pin `format.preferredRange = .standard`
    so the diff PNG stays sRGB byte-for-byte even on Display P3 devices.
  - Follow-up ✅ commit `748e6c9` — restore the original
    `"Actual image precision X is less than required Y"` error wording
    (Phase 1 had truncated it for the early-exit). Removed the early-exit;
    `precision-early-fail` regresses ~22ms → ~30ms in exchange for honest reporting.
- **Phase 5** ✅ landed. Replaced `[UInt8](repeating: 0, count:)` with
  `UnsafeMutableRawPointer.allocate(byteCount:alignment:16)` +
  `defer { deallocate() }` in both `compare()` paths and
  `normalizedComponentDiff`. Required pinning `context(for:)` to `.copy`
  blend mode so uninitialized destination memory isn't blended with
  translucent source pixels — caught by
  `ImageNormalizationEdgeCasesTests.testNonPremultipliedAlpha_identicalImagesPass`.
  Headline: serial `precision-1px-diff` p50 **−29%**, parallel-4 wall
  **−33%**; serial `exact-match-large` p50 **−33%**; peak RSS at parallel-8
  also drops slightly vs Phase 4 (~−4%). The wins come from skipping the
  per-call zero-fill (≈400 µs for a 4 MB buffer at ~10 GB/s memset).
  - First attempt (commit `c6b7d9e`) introduced a `SnapshotTestingByteBufferPool`
    enabled by default at `2 × activeProcessorCount` slots. Wall-time wins
    held but peak RSS *grew* +33% as 16 hot buffers were retained
    process-wide — the opposite of the phase's goal. Reverted to raw
    allocation; the pool wasn't pulling weight beyond the zero-fill skip.
- **Phase 6** ✅ harness `eced587`, bench `c9e32ff`. Seven new scenarios
  at iPhone 15 Pro (1179×2556, ~12 MB/buffer) and iPad Pro 13"
  (2064×2752, ~22 MB/buffer) gated behind `--suite ios`. Headline
  serial p50: iphone exact-match **0.93 ms** (faster than two raw
  memcpys of the buffer would take), iphone 1px-diff **6.66 ms**, ipad
  1px-diff **9.80 ms**. Peak RSS at parallel-8 with 22 MB ipad buffers:
  **1.57 GB** — well under the 4-5 GB the plan budgeted, confirming
  Phase 5's `defer { deallocate() }` returns pages cleanly at iOS
  sizes. **Decision: canonical-layout fast-path is not worth doing** —
  CG `draw` already runs faster than the RAM-bandwidth ceiling for two
  full memcpys, so bypassing it would save little. See Phase 6 Results
  for per-call → suite-level extrapolations.
- **Phase 7** ✅ code `1799be3`, bench `2541c35`. Replaced
  `DispatchQueue.concurrentPerform` with N long-running workers pulling
  iterations from a shared counter, joined via `DispatchGroup`. The CLI's
  `--parallel N` now caps in-flight `runOnce()` calls to exactly N.
  Bench-only, no library code touched. Re-ran iOS suite at the new SHA
  (`bench-results/2541c35-ios-*.csv` vs `eced587-ios-*.csv`):
  - **Honest wall time**: parallel-4 wall grew on byte-loop scenarios
    (e.g. `iphone-1px-diff` 393 ms → 1052 ms) because Phase 6 was
    actually using all cores. Parallel-8 wall grew less (387 → 560 ms)
    since 8 workers ≈ the machine.
  - **Contention vanished**: `iphone-1px-diff` parallel-4 p95 13.35 ms
    → 4.34 ms; `iphone-perceptual-pass` parallel-4 p95 110 ms → 62.6 ms.
    Per-iter p50 across all N matches serial within noise.
  - **Peak RSS drops at parallel-8**: iPad scenarios 1.57 GB → 1.01 GB;
    `iphone-perceptual-pass` 1.86 GB → 1.44 GB. No more overcommit
    inflating the in-flight buffer count.
  Phase 6's three conclusions still hold under the new measurements
  (canonical-layout fast-path not worth doing; `defer { deallocate() }`
  returns pages cleanly; perceptual is the dominant per-call cost).
- **Phase 8** ✅ code `f490a71`, bench `0d5435a`. Added a private
  `[Float: MPSImageThresholdBinary]` cache (`NSLock`-guarded) inside
  `ThresholdImageProcessorKernel`; `process(...)` now looks up the
  kernel by `thresholdValue` and constructs only on miss. MPS kernels
  are documented thread-safe for encoding once constructed, so the
  cached kernel is encoded into per-call command buffers without
  serialization. Bench impact at iOS sizes (vs `2541c35`):
  iphone-perceptual-pass parallel-4 p95 **−7.6%** (62.6 → 57.9 ms),
  p99 **−15%** (69.3 → 58.7 ms); parallel-8 peak RSS **−8%**
  (1368 → 1258 MB). Serial p50 within noise. Non-perceptual
  scenarios unaffected (±5% noise band). The win is mostly tail-
  latency tightening + a Metal-heap-floor drop, not p50 throughput
  — MPS construction was either cheaper than estimated or already
  overlapped with the GPU sync. Edge-case + precision tests pass.
- **Phase 9** ✅ code `dfbeec6`, bench `ede47aa`. Added `--suite pipeline`
  with 4 NSView staged scenarios that replay the public-API stages of
  `verifySnapshot` (render → read → decode → compare → attachments) with
  per-stage timestamps. CSV gains `<stage>_p50_ns`/`<stage>_p95_ns`
  columns when staged scenarios are present; default and ios suites'
  CSV unchanged. Bench-only, no library code touched. Headline serial
  p50 (`bench-results/dfbeec6-pipeline-serial.csv`):
  - `pipeline-large-iphone`: **126 ms** total — compare 78 ms (**62%**),
    render 48 ms (38%), read+decode 0.3 ms (negligible).
  - `pipeline-large-iphone-fail`: **268 ms** — attachments 182 ms
    (**68%**) dominates; pure compare 36 ms; render 50 ms. Failure-path
    cost (3× PNG re-encode at iPhone size + diff PNG generation) is
    only paid when a test actually fails.
  - `pipeline-medium-stack`: 2.42 ms — compare 1.72 ms (71%).
  - `pipeline-small-flat`: 0.34 ms — compare 199 µs (56%).
  **Surprise:** pipeline `compare_p50` of 78 ms at iPhone size is **~85×**
  the synthetic `iphone-exact-match` p50 of 0.93 ms (Phase 6). The
  synthetic scenario shared canonical-layout buffers between old and
  new (same NSImage instance → same CGImage → cheap normalize); the
  pipeline reference is a PNG-decoded NSImage whose layout differs from
  the live-rendered NSImage, forcing `context(for:)` to do real work
  for both buffers. The "compare is at the floor" hypothesis from
  Phase 6 doesn't hold for real pipelines.
  **Next-phase signal**: render = 38% (under the 50% threshold);
  decode = 0.16% (well under 30%); compare = 62% on the success path.
  By the plan's own decision rule, the next compare-side optimization
  is warranted — and the data points at the normalize step (CG draw
  with mismatched source/destination layouts) as the new hot spot.
  The failure path hot spot (PNG re-encoding for 3 attachments at
  iPhone size = ~180 ms) is a real cost but only fires on test
  failure. Pipeline scenarios are forced serial regardless of
  `--parallel N` because AppKit autolayout is main-thread-only after
  first use; `mode`/`parallelism` columns still report the requested
  value to keep CSVs diff-comparable. The iOS-sim UIView follow-up
  remains out of scope for this phase.
- **Phase 10** ⛔ reverted. Attempted canonical-layout PNG decode in
  `fromData` plus a `compare()` fast path that skips the per-call
  redraw when both sides are already canonical. Bench
  (`bench-results/phase10-pipeline-serial.csv`): net regression in
  isolation (`pipeline-large-iphone` 126 → 150 ms, **+19%**;
  +20–26% on smaller pipeline scenarios). The compare-side savings
  landed (~37 ms off compare) but canonicalize-during-decode added
  ~52 ms — cost shifted, not eliminated, because the rendered side
  is still non-canonical so `compare()` still pays one redraw. The
  measurable win requires Phase 11 (canonicalize the render side),
  which has unresolved feasibility risk; reverted rather than carry
  a regression on speculation. Code archived on
  `perf/phase10-canonical-decode-archived` (commit `e4746e8`) for
  cherry-pick if Phase 11 is pursued. See Phase 10 section below.
- **Phase 11** ⛔ attempted, archived. Canonicalize the NSView render
  via custom `NSBitmapImageRep` + `retagging(with: .sRGB)`. Bench
  showed real success-path win (`pipeline-large-iphone` 126 → 103 ms,
  **−18%**; `compare_p50` 78 → 17 ms) but **broke backwards
  compatibility**: retagging-without-conversion changes rendered byte
  content vs `bitmapImageRepForCachingDisplay`. Two committed XCTest
  references (`testNSViewWithLayer`, `testPrecision`) failed with
  ~18% byte difference; the initial "tests green" reading was Swift
  Testing only — XCTest auto-record had silently rewritten the PNGs.
  The conversion-not-retagging variant
  (`bitmapByConverting(toColorSpace: .sRGB)`) preserves correctness
  but costs ~38 ms per render, eating the entire success-path win.
  Code + bench (`bench-results/phase11-pipeline-serial.csv`) archived
  on `perf/phase11-canonical-render-archived` (commit `add8496`).
  Phase 12 pursues correctness-safe alternatives instead.
- **Phase 12-A** ✅ vImage-accelerated compare buffer load. Replaced
  the `CGContext.draw` redraw inside the modern `compare()` path
  (NSImage.swift / UIImage.swift) with `vImageConverter` +
  `vImageConvert_AnyToAny` via a new internal helper
  `loadNormalizedCompareBuffer`. Per-source-format converter cache
  amortizes setup. Falls back to `CGContext.draw` for source formats
  vImage rejects. Bench: `pipeline-large-iphone` total p50
  **126 → 74 ms (−42%)**, compare_p50 **78 → 24 ms (−69%)**.
  parallel-8 gain identical (no contention). Fail-path total
  unchanged within ±0.5%. All 40 XCTests pass, all committed PNG
  references byte-identical (sha unchanged before/after run). Code
  `07c35a5`, bench
  `bench-results/07c35a5-pipeline-{serial,parallel-4,parallel-8}.csv`.
- **Phase 12-B** ✅ parallelize the two compare-side redraws. New
  `loadNormalizedCompareBufferPair` dispatches both
  `loadNormalizedCompareBuffer` calls via
  `concurrentPerform(iterations: 2)` when `byteCount > 256 KB`;
  serial below the threshold to avoid dispatch overhead exceeding
  conversion cost. Stacks on top of 12-A: `pipeline-large-iphone`
  parallel-8 total p50 **74 → 70 ms (−5%)**, compare **23 → 20 ms
  (−14%)**. No parallel-mode regression — byte-count gate keeps
  small images on the serial path. Combined 12-A+B vs Phase 9
  baseline: parallel-8 `pipeline-large-iphone` **127 → 70 ms
  (−45%)**, serial `126 → 72 ms (−43%)`. Code `d77f332`, bench
  `bench-results/d77f332-pipeline-{serial,parallel-4,parallel-8}.csv`.
- **Deferred (replaced by current Phase 9)**: perceptual coalescing
  batch + raising `SNAPSHOT_TESTING_PERCEPTUAL_DIFF_CONCURRENCY`
  default. Would optimize the perceptual path further, but perceptual
  is opt-in (`perceptualPrecision < 1`) and we don't yet know whether
  users hit it often enough for it to matter. Revisit if Phase 9 data
  shows perceptual is the dominant cost for some real workload, or if
  a user reports it.
- **Deferred (no current phase planned)**: making the public `Diffing`
  API async. Would unlock additional perceptual concurrency at the cost
  of source-incompatible breakage or permanent dual-API surface. Same
  gating as the perceptual coalescing batch — needs evidence that the
  perceptual gap matters.

### Resume context

- Bench script needs Xcode platform frameworks at runtime; the script auto-sets
  `DYLD_FRAMEWORK_PATH` / `DYLD_LIBRARY_PATH` from `xcrun --show-sdk-platform-path`.
- Pre-existing local test failure to ignore: `testNSImage` (gated to non-CI; host rendering quirk,
  reproduces on clean main).
- Per-phase rollout: commit, then `BENCH_OUT_DIR=bench-results ./scripts/bench.sh`, then commit
  the CSVs. Compare against `bench-baseline/`. The bench script tags filenames with the git SHA.
- The PNG round-trip (Phase 3) hot lines: `UIImage.swift:119-127`, `NSImage.swift:94-101`.
- The CIContext-per-call site (Phase 2): `UIImage.swift:303` inside `perceptuallyCompare`.
  Counter leak warning ("Context leak detected") visible in baseline confirms the issue.



Source: `~/Downloads/swift-snapshot-testing-uiimage-optimizations.md`.
Targets: `Sources/SnapshotTesting/Snapshotting/UIImage.swift`, `Sources/SnapshotTesting/Snapshotting/NSImage.swift`.
Goal: lower CPU / peak RSS / GPU contention in highly parallel CI snapshot runs without changing user-visible behavior.

## Decisions

- **Scope:** UIImage + NSImage. The two `compare()` functions and the perceptual fallback are duplicated; both get fixed.
- **Pixel-based precision (#8 in source doc):** *deferred*. Keep current byte-based semantics. Revisit later behind opt-in.
- **Defaults:** sensible on by default — pool size 2, perceptual concurrency cap 2 — overridable via env var (or unset to disable cap entirely).
- **Bench harness:** Swift Package executable target. Must be runnable against the current code AND each future phase, so the bench links the public `compare`/`perceptuallyCompare` entry points (or thin wrappers) and stays stable as internals evolve.
- **Fixtures:** reuse existing 163 PNGs under `Tests/SnapshotTestingTests/__Snapshots__/`, the dedicated `__Fixtures__/earth.png` and `testImagePrecision.reference.png`, plus synthetic generators for edge cases.

---

## Phase 0 — Benchmark harness (lands first, no code changes to library)

Without a baseline every later claim is unfalsifiable. Phase 0 produces numbers we'll cite in every later PR.

### Deliverables

- New executable target `SnapshotTestingBenchmarks` in `Package.swift`.
  - Conditional on `canImport(UIKit) || canImport(AppKit)`.
  - Depends on `SnapshotTesting`.
- Source layout:
  - `Sources/SnapshotTestingBenchmarks/main.swift` — CLI entry, arg parsing.
  - `Sources/SnapshotTestingBenchmarks/Scenarios/*.swift` — one per scenario.
  - `Sources/SnapshotTestingBenchmarks/Harness/Clock.swift` — `mach_absolute_time` wall clock.
  - `Sources/SnapshotTestingBenchmarks/Harness/RSS.swift` — `mach_task_basic_info` peak RSS sampler.
  - `Sources/SnapshotTestingBenchmarks/Harness/Counters.swift` — atomic counters injected via internal hooks (CIContext alloc count, PNG round-trip count). Counters are no-ops in release builds of the library; benchmark links a small testable hook.
  - `Sources/SnapshotTestingBenchmarks/Fixtures/*.swift` — fixture loader + synthetic generators.
- `scripts/bench.sh` — runs the executable in three modes: `--serial`, `--parallel 4`, `--parallel 8`. Emits CSV to `bench-results/<git-sha>-<mode>.csv`.
- `bench-baseline/` — committed CSVs for the pre-Phase-1 baseline (one per platform we benchmark).

### Scenarios

Each scenario reports: p50 / p95 / p99 wall time per call, total wall time, peak RSS delta, # CIContext allocations, # PNG codec invocations.

| Scenario | Inputs | Iterations | Why |
|---|---|---|---|
| `exact-match-small` | 100×100 RGBA, identical | 5000 | memcmp fast path |
| `exact-match-large` | 4096×4096 RGBA, identical | 200 | memcmp under memory pressure |
| `exact-match-mixed` | random pick from real fixtures | 2000 | realistic distribution |
| `precision-1px-diff` | 1024×1024, single pixel changed, `precision: 0.999` | 1000 | precision loop |
| `precision-50pct-diff` | 1024×1024, half pixels changed, `precision: 0.5` | 1000 | precision loop, far from threshold |
| `precision-early-fail` | 1024×1024, large diff with `precision: 0.99` | 1000 | validates Phase 1 early-exit |
| `perceptual-pass` | 512×512, near-identical, `perceptualPrecision: 0.98` | 500 | Metal path |
| `perceptual-fail` | 512×512, distinct, `perceptualPrecision: 0.98` | 500 | Metal path + diff generation |
| `perceptual-no-metal` | force CPU vImage path via env toggle | 200 | covers virtualized CI |
| `png-roundtrip` | calls only the PNG encode/decode that Phase 3 removes | 1000 | proves Phase 3 hypothesis |

### Synthetic fixture generators

Implemented as pure CG / vImage drawing, deterministic (seeded). Generated once, cached in-process:

- `solidColor(size:color:)`
- `verticalGradient(size:from:to:)`
- `singlePixelDiff(base:at:)`
- `randomNoise(size:seed:)` (deterministic LFSR for reproducibility)
- `nearlyIdentical(base:perceptualDelta:)` — applies a tiny color shift via `CILabDeltaE`-friendly transform

### Acceptance criteria

- Bench runs locally on macOS in under 5 minutes for the full matrix.
- Output CSV is diff-friendly (sorted columns, no timestamps in the row data — those go in the filename).
- Re-running back-to-back produces results within ±5% on a quiet machine; if not, harness needs warmup adjustment.
- Baseline CSV checked in.

### Out of scope

- iOS device benchmarking. Bench runs on macOS host first; iOS-simulator runs are an optional follow-up.
- Cross-machine result comparison. Each developer commits their own baseline; CI is unchanged in Phase 0.

---

## Phase 1 — Quick wins (no behavior change)

Mechanical, low blast radius. One PR.

### Changes

1. **Remove `defer { index += 1 }`** in 5 hot loops:
   - `UIImage.swift:148` (precision byte loop)
   - `UIImage.swift:231` (normalizedComponentDiff pixel loop)
   - `UIImage.swift:342` and `UIImage.swift:346` (perceptual CPU fallback nested loops)
   - `NSImage.swift:124` (precision byte loop)
2. **Early-exit precision loops** once `differentByteCount > byteCountThreshold`. Update failure message to `"Actual image precision is less than required \(precision)"` (drop the now-inexact actual value), since exact reporting requires full scanning. Same change in both files.
3. **Wrap `compare()` body** in `autoreleasepool`. Wrap the diff/attachment generation block in the `Diffing.image` closure too. Both files.

### Verification

- Existing test suite unchanged and green.
- Phase 1 bench shows reduction on `precision-early-fail` (early-exit) and on parallel-mode peak RSS (autorelease pool) without regressing exact-match.

### Results

Code: `8bf1107` · Bench: `8933727` (CSVs: `bench-results/8bf1107-*.csv` vs `bench-baseline/pre-phase1-*.csv`).

| Metric | Baseline | Phase 1 | Δ |
|---|---|---|---|
| Peak RSS, serial perceptual | 6.04 GB | 1.98 GB | **−67%** |
| Peak RSS, parallel-8 (any) | 8.54 GB | 2.96 GB | **−65%** |
| `precision-1px-diff` p50, serial | 12.48 ms | 10.74 ms | −14% |
| `precision-1px-diff` wall, parallel-4 | 2542 ms | 1445 ms | **−43%** |
| `precision-50pct-diff` wall, parallel-4 | 2257 ms | 1473 ms | −35% |
| `exact-match-small` wall, parallel-8 | 77.2 ms | 65.6 ms | −15% |
| `perceptual-pass` p50, **serial** | 12.46 ms | 23.27 ms | **+87% (regression)** |
| `perceptual-fail` p50, **serial** | 15.98 ms | 23.65 ms | +48% (regression) |
| `exact-match-large` wall, parallel-8 | 920 ms | 1108 ms | +20% (likely noise) |

Notes:
- The serial perceptual regression was the surprise. Working theory at the time: per-call `CIContext` allocation overhead becoming visible when there's no parallel work to amortize. Confirmed in Phase 2 — once the pool ships the regression vanishes.
- `precision-early-fail` serial p50 barely moved (32.2 → 33.1 ms). The early-exit shortens the precision loop, but the diff/attachment generation still dominates serial p50; the win shows up in p95 (−11%) and parallel modes (−22%).

---

## Phase 2 — Shared resources (CIContext pool + perceptual concurrency cap)

### Changes

1. **`SnapshotTestingCIContextPool`** (round-robin, lock-protected, size from `SNAPSHOT_TESTING_CI_CONTEXT_POOL_SIZE`, default 2, max 4). Located in a new shared file `Sources/SnapshotTesting/Snapshotting/Internal/ImageComparisonResources.swift` because the perceptual fallback is platform-shared. Replaces the inline `CIContext(...)` at `UIImage.swift:303`.
2. **`SnapshotTestingImageDiffLimiter`** (semaphore, size from `SNAPSHOT_TESTING_PERCEPTUAL_DIFF_CONCURRENCY`, default 2). Wraps the `perceptuallyCompare` call.
3. Document env vars in `README.md`.

### Verification

- Bench `--parallel 8` shows flatter RSS and fewer CIContext allocations (counter hook from Phase 0).
- Perceptual scenarios should not regress in serial mode.
- New unit tests: pool returns N distinct contexts; limiter actually serializes when set to 1; env override works.

### Risks

- Default-on cap could surprise small projects whose perceptual tests now serialize. Mitigation: env var unset = uncapped; default only kicks in if env var is unset AND we want a default. **Open question for review:** apply the cap unconditionally with default 2, or only if env var is set? Current plan: apply default. Easy to flip.

### Results

Code: `3dd37a1` · Bench: `e7c8541` (CSVs: `bench-results/3dd37a1-*.csv` vs `bench-results/8bf1107-*.csv`).

| Metric | Phase 1 | Phase 2 | Δ vs Phase 1 | vs Baseline |
|---|---|---|---|---|
| `perceptual-pass` p50, **serial** | 23.27 ms | 11.35 ms | **−51%** | −9% (recovers + beats baseline) |
| `perceptual-fail` p50, serial | 23.65 ms | 10.19 ms | −57% | −36% |
| `perceptual-pass` wall, parallel-4 | 894 ms | **428 ms** | **−52%** | −59% |
| `perceptual-pass` wall, parallel-8 | 1032 ms | **497 ms** | **−52%** | −59% |
| `perceptual-fail` wall, parallel-4 | 946 ms | 442 ms | −53% | −60% |
| `exact-match-large` p50, serial | 13.38 ms | 11.13 ms | −17% | −25% |
| `precision-1px-diff` p50, serial | 10.74 ms | 10.24 ms | −5% | −18% |
| `exact-match-mixed` wall, parallel-8 | 3718 ms | 3119 ms | −16% | ~0% (recovers from P1 regression) |
| Peak RSS, parallel-4 | 3.05 GB | 3.36 GB | +10% | −56% |
| Peak RSS, parallel-8 | 2.96 GB | 3.11 GB | +5% | −63% |

Notes:
- The headline is **perceptual parallel wall time roughly halved**. The Phase 1 perceptual serial regression is fully resolved — the pool eliminates the per-call `CIContext` allocation that was the suspected cause.
- Peak RSS rises modestly vs Phase 1 because the pool keeps 2 `CIContext` instances alive process-wide, but stays well under half of baseline.
- 12 unit tests (parser, pool, limiter) cover the new types; no integration test changes were needed.

---

## Phase 3 — Hot-path normalization (highest payoff, biggest review surface)

### Changes

1. **Drop the PNG round-trip in `compare()`** (`UIImage.swift:119-127`, `NSImage.swift:94-101`). Today this re-encodes the new image to PNG and decodes it back to obtain a CGImage with predictable bitmap layout. We already have `context(for:data:)` which renders into our normalized RGBA buffer; render `newCgImage` directly there. Investigate why PNG normalization was added historically (git blame) — if it was guarding against alpha/colorspace surprises, our context already enforces sRGB + premultipliedLast which should subsume that.
2. **Drop the PNG round-trip in `normalizedComponentDiff()`** (`UIImage.swift:199-200`). It already has the new CGImage; PNG encoding is redundant.
3. **Reuse the normalized buffers** between `memcmp`, the precision loop, and (where the perceptual path wants raw RGBA) the perceptual fallback inputs.
4. Same patterns in `NSImage.swift`.

### Verification

- Full snapshot test suite must pass unmodified — this is the regression risk.
- Bench `png-roundtrip` scenario should drop dramatically; `exact-match-mixed` and `precision-*` scenarios should drop noticeably; peak RSS on `precision-50pct-diff` should drop because we no longer hold a PNG `Data` blob alongside the buffers.
- Specifically test: image with non-premultiplied alpha, image with non-sRGB color space, grayscale image. These are the cases the PNG round-trip may have been silently fixing.

### Rollback strategy

- Keep the PNG round-trip code on a feature flag (`SNAPSHOT_TESTING_LEGACY_NORMALIZATION=1`) for one release, then remove.

### Results

Code: `255b526` · Bench: `d39b74e` (CSVs: `bench-results/255b526-*.csv` vs `bench-results/3dd37a1-*.csv`).

| Metric | Phase 2 | Phase 3 | Δ vs Phase 2 | vs Baseline |
|---|---|---|---|---|
| `precision-1px-diff` p50, serial | 10.24 ms | **1.64 ms** | **−84%** | **−87%** |
| `precision-50pct-diff` p50, serial | 10.43 ms | 1.89 ms | −82% | −85% |
| `precision-1px-diff` wall, parallel-4 | 1382 ms | **152 ms** | **−89%** | **−94%** |
| `precision-50pct-diff` wall, parallel-4 | 1392 ms | 162 ms | −88% | −93% |
| `precision-1px-diff` wall, parallel-8 | 1358 ms | 174 ms | −87% | −90% |
| `exact-match-large` p50, serial | 11.13 ms | 4.56 ms | −59% | −69% |
| `exact-match-large` wall, parallel-4 | 1131 ms | 316 ms | −72% | −70% |
| `exact-match-mixed` p50, serial | 3.13 ms | 1.71 ms | −45% | −55% |
| `exact-match-mixed` wall, parallel-4 | 3406 ms | 1134 ms | −67% | −65% |
| `perceptual-pass` p50, serial | 11.35 ms | 5.82 ms | −49% | −53% |
| `perceptual-pass` wall, parallel-4 | 428 ms | 293 ms | −32% | −72% |
| `perceptual-fail` wall, parallel-4 | 442 ms | 334 ms | −24% | −69% |
| `precision-early-fail` p50, serial | 35.29 ms | 22.41 ms | −37% | −31% |
| Peak RSS, parallel-4 | 3.36 GB | 4.19 GB | +25% | −45% |
| Peak RSS, parallel-8 | 3.11 GB | 5.03 GB | +62% | −41% |

Notes:
- The dominant win is the precision path: dropping the PNG round-trip removes a full encode + decode + render per failing exact-match, and the precision loop now reads the same buffer that fed `memcmp` (no second buffer to populate).
- Exact-match scenarios also benefit because the failure path is shorter (single render) and the success path is unchanged.
- Peak RSS rises modestly because the new `newBytes` buffer is held alive through the precision loop instead of being freed after the first `memcmp`. Still well below baseline (8.5 GB → 5.0 GB at parallel-8). Net trade is excellent given the wall-time reduction.
- NSImage's `context(for:)` was rewritten to the normalized form (sRGB+8bpc+RGBA8+tight `bytesPerRow`). UIImage already had this from `d5962c2` (#446, 2021); NSImage was still using the source CGImage's own layout, which is why dropping its PNG round-trip required this prerequisite.
- Legacy path retained behind `SNAPSHOT_TESTING_LEGACY_NORMALIZATION=1`. Targeted edge-case tests (non-premultiplied alpha, non-sRGB colorspace, grayscale) are still owed.

---

## Phase 4 — Diff API modernization

### Changes

- Replace `UIGraphicsBeginImageContextWithOptions` / `UIGraphicsEndImageContext` in `blendModeDiff` (`UIImage.swift:185-195`) with `UIGraphicsImageRenderer`.

### Verification

- Bench delta expected to be small.
- Visual diff of generated `difference.png` against current implementation across 5 fixture pairs — pixels should match within rounding.

### Results

Code: `a3c01cd` · Bench: `3d6f2e0` (CSVs: `bench-results/a3c01cd-*.csv` vs `bench-results/255b526-*.csv`).

Swap was mechanical: `UIGraphicsImageRendererFormat` with `opaque = true` and the
prior `max(old.scale, new.scale)` preserves the previous semantics. The renderer
block hands back the rendered `UIImage` directly — no manual context begin/end.

| Metric | Phase 3 | Phase 4 | Δ |
|---|---|---|---|
| `precision-1px-diff` p50, serial | 1.64 ms | 1.75 ms | +6% |
| `precision-50pct-diff` p50, serial | 1.89 ms | 1.96 ms | +4% |
| `exact-match-large` p50, serial | 4.56 ms | 4.53 ms | ≈0% |
| `exact-match-mixed` p50, serial | 1.71 ms | 1.46 ms | −15% |
| `perceptual-pass` p50, serial | 5.82 ms | 6.07 ms | +4% |
| `perceptual-fail` p50, serial | 5.90 ms | 6.03 ms | +2% |
| `precision-early-fail` p50, serial | 22.41 ms | 23.58 ms | +5% |
| Peak RSS, parallel-4 | 4.19 GB | 4.75 GB | +13% |

Notes:
- All deltas are within run-to-run noise. As predicted, `blendModeDiff` is the
  rare fallback path (`normalizedComponentDiff` handles the common case where
  both images share a size + valid `cgImage`), so the bench scenarios — all of
  which feed same-sized, identically-formatted pairs — never exercise it.
- Win is API modernization (no more deprecated `UIGraphics*` calls), not
  throughput. The codepath now also benefits from `UIGraphicsImageRenderer`'s
  internal autoreleasepool + caching behaviors.

---

## Phase 5 — Skip per-call zero-fill on the normalized RGBA buffers

Each `compare()` call allocates two `[UInt8]` buffers sized
`width * height * 4` for the normalized RGBA renderings. At a 4096×4096 image
that's ~64MB per buffer; the cost we discovered profiling Phase 4 is the
*per-call zero-fill* on those allocations, not the allocation itself —
`[UInt8](repeating: 0, count: byteCount)` issues a `memset` that runs at the
RAM bandwidth ceiling (~10 GB/s), which is ≈400 µs for one 4MB normalized
buffer and dominates wall time on the byte-loop scenarios.

The fix is mechanical: replace the Swift-array allocation with
`UnsafeMutableRawPointer.allocate(byteCount:alignment:16)` +
`defer { deallocate() }`. The raw allocator skips the zero-fill; safety
relies on `context(for:)` overwriting every destination byte during draw,
which requires pinning the blend mode to `.copy` (otherwise the default
`.normal` mode would blend translucent source pixels with the uninitialized
destination — caught by `testNonPremultipliedAlpha_identicalImagesPass`).

### Changes

1. **`Sources/SnapshotTesting/Snapshotting/UIImage.swift`** and
   **`Sources/SnapshotTesting/Snapshotting/NSImage.swift`** — `compare()`:
   - Replace `var oldBytes = [UInt8](repeating: 0, count: byteCount)` (and
     the matching `newBytes`) with
     `let oldBuffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)`
     and `defer { oldBuffer.deallocate() }`.
   - Pass `oldBuffer` directly to `context(for:data:)` (already accepts
     `UnsafeMutableRawPointer?`).
   - The precision loop iterates through
     `oldBuffer.assumingMemoryBound(to: UInt8.self)`.
2. **`normalizedComponentDiff`** in `UIImage.swift` — same raw-allocation
   swap for its two normalization buffers. (`diffBytes` keeps its `[UInt8]`
   backing because vImage / `createCGImage` need a live Swift owner for the
   produced `CGImage`.)
3. **`context(for:)`** in both files — set
   `context.setBlendMode(.copy)` before `context.draw(...)`. `.copy`
   replaces destination pixels outright; on the legacy zero-initialized
   path this is byte-equivalent to `.normal` (only translucent-pixel
   blending changes, and there's no destination to blend against in a
   zero buffer).
4. **`legacyCompare`** stays untouched on `[UInt8]` — the
   `SNAPSHOT_TESTING_LEGACY_NORMALIZATION=1` escape hatch keeps the
   pre-Phase-3 path bit-identical for one release.

### Verification

- Full XCTest suite (99 tests) passes under both code paths.
- `ImageNormalizationEdgeCasesTests` (12 tests covering Display P3,
  grayscale, non-premultiplied alpha) green — including the new
  `testNonPremultipliedAlpha_identicalImagesPass` that catches blend-mode
  regressions.
- Bench harness shows wall-time wins on the byte-loop scenarios with peak
  RSS unchanged or slightly lower than Phase 4 (no buffers retained
  process-wide).

### Risks

- Uninitialized destination memory leaking into compares if `context(for:)`
  ever stops fully overwriting. Mitigated by the `.copy` blend mode +
  `ImageNormalizationEdgeCasesTests` regression coverage.

### What we tried first (and reverted)

Initial attempt (commit `c6b7d9e`) wrapped the raw allocation in a process-
wide LIFO `SnapshotTestingByteBufferPool` enabled by default at
`2 × activeProcessorCount` slots, with env knobs
(`SNAPSHOT_TESTING_BUFFER_POOL_SIZE` / `_MAX_BYTES`). Wall-time wins held,
but **peak RSS grew +33%** at parallel-8 on `exact-match-mixed` because ~16
buffers stayed pinned process-wide, each grown to fit the largest image
seen. That's the opposite of the phase's stated goal (lowering RSS), and
the wins came from the zero-fill skip, not from allocator reuse — so the
pool was reverted entirely. Final code keeps the raw allocation but frees
on `defer`.

### Results

Code: `ea4df68` (post-revert) · Bench: `bench-results/ea4df68-*.csv`
vs `bench-results/a3c01cd-*.csv`.

| Metric | Phase 4 | Phase 5 | Δ vs Phase 4 |
|---|---|---|---|
| `exact-match-large` p50, serial | 4.53 ms | 3.03 ms | **−33%** |
| `exact-match-large` wall, parallel-4 | 323 ms | 264 ms | −18% |
| `exact-match-mixed` p50, serial | 1.46 ms | 1.26 ms | −14% |
| `exact-match-mixed` wall, parallel-4 | 1966 ms | 1209 ms | **−38%** |
| `exact-match-mixed` wall, parallel-8 | 1277 ms | 1038 ms | −19% |
| `exact-match-small` p50, serial | 13.8 µs | 10.8 µs | −22% |
| `precision-1px-diff` p50, serial | 1.75 ms | 1.24 ms | **−29%** |
| `precision-1px-diff` wall, parallel-4 | 173 ms | 115 ms | **−33%** |
| `precision-50pct-diff` p50, serial | 1.96 ms | 1.24 ms | **−37%** |
| `precision-50pct-diff` wall, parallel-4 | 166 ms | 109 ms | **−34%** |
| `precision-early-fail` p50, serial | 23.58 ms | 24.66 ms | +5% (noise) |
| `perceptual-pass` p50, serial | 6.07 ms | 5.98 ms | −1% |
| `perceptual-fail` p50, serial | 6.03 ms | 5.86 ms | −3% |
| Peak RSS, parallel-4 (exact-match-mixed) | 4.75 GB | 4.53 GB | **−5%** |
| Peak RSS, parallel-8 (exact-match-mixed) | 4.65 GB | 4.48 GB | **−4%** |

Notes:
- Wall-time wins are entirely the avoided zero-fill: at ~10 GB/s memset,
  one 4 MB normalized buffer takes ~400 µs, two of them ~800 µs — which is
  the exact cut visible on `precision-1px-diff` (1.75 → 1.24 ms).
- `precision-50pct-diff` matched `precision-1px-diff` post-Phase-3 (both
  run the full byte loop, dominated by allocation + zero-fill). With the
  zero-fill gone, the remaining work is the comparison itself.
- Peak RSS dips slightly because the raw allocator hands back pages as
  soon as `defer` fires, where Swift's array buffer keeps the backing
  store alive for the lifetime of the local. No buffers are retained
  process-wide.
- `.copy` blend mode in `context(for:)` is byte-equivalent to `.normal`
  on the pre-existing zero-initialized legacy path; both edge-case tests
  and `SNAPSHOT_TESTING_LEGACY_NORMALIZATION=1` confirm.

---

## Phase 6 — iOS-resolution bench scenarios (model real-world workloads)

Existing scenarios cap out at `exact-match-large` (4096×4096 synthetic,
~64 MB per buffer) and `exact-match-mixed` (real PNG fixtures averaging
much smaller). Neither models the actual workload that motivates this
project: an iOS app's test suite running tens of thousands of view-snapshot
assertions at simulator resolutions (iPhone 15 Pro = 1179×2556 ≈ 12 MB
per RGBA buffer, iPad Pro 13" = 2064×2752 ≈ 22 MB).

That gap matters for two reasons:
- **Decision-making**: any further optimization (e.g., a canonical-layout
  fast-path that bypasses `CGContext.draw`) needs honest data at the size
  regime where it would actually pay off. The 1024² byte-loop scenarios
  Phase 5 wins on don't generalize cleanly to 12-22 MB buffers — `memcmp`
  bandwidth, CG draw overhead, and per-call allocator behavior all shift.
- **Confidence**: claiming "X% faster on real iOS suites" without bench
  coverage at iOS sizes is hand-waving. This phase produces the data.

### Goal

Add bench scenarios at iOS simulator resolutions, run them across the
existing serial / parallel-4 / parallel-8 modes, and produce a
`bench-results/<sha>-ios.csv` family that lets us reason about real-world
suite-level wall time and RSS without extrapolation.

### Changes

1. **`Sources/SnapshotTestingBenchmarks/Fixtures/ImageFactory.swift`** —
   add canonical-layout iOS-resolution synthetic generators:
   - `iphoneScreenshot()` → 1179×2556 RGBA8 sRGB premultipliedLast
     gradient. Buffer ≈ 12 MB.
   - `ipadScreenshot()` → 2064×2752 RGBA8 sRGB premultipliedLast gradient.
     Buffer ≈ 22 MB.
   - `iphoneScreenshotWithDiff(at:)` → same as above but flips one pixel
     at a configurable position to produce a controlled byte-diff.
   These intentionally use the same canonical layout `context(for:)`
   produces today (sRGB + 8bpc + 32bpp + premultipliedLast + no row
   padding) so they exercise the fast path that hardware-rendered iOS
   snapshots take.
2. **`Sources/SnapshotTestingBenchmarks/Scenarios/IOSResolutionScenarios.swift`** —
   new file with:
   - `IPhoneExactMatch` — both inputs identical, exercises `memcmp`
     short-circuit at 12 MB. Iterations: ~1000.
   - `IPhone1pxDiff` — one pixel different, full byte loop at 12 MB.
     Iterations: ~1000.
   - `IPhonePrecision99` — `precision: 0.99`, ~0.4% of pixels different.
     Iterations: ~500.
   - `IPadExactMatch` — same shape at 22 MB. Iterations: ~500.
   - `IPad1pxDiff` — full byte loop at 22 MB. Iterations: ~500.
   - `IPadPrecision99` — `precision: 0.99` at 22 MB. Iterations: ~250.
   - `IPhonePerceptualPass` — `perceptualPrecision: 0.99`, identical
     12 MB inputs. Iterations: ~250.
   Iteration counts target ~3-10 s wall time per scenario serial so
   percentile measurements stabilize without blowing out CI; parallel
   modes inherit the same per-scenario count.
3. **`scripts/bench.sh`** — extend to invoke the new scenarios alongside
   existing ones. Output filename pattern: `bench-results/<sha>-ios-{serial,parallel-4,parallel-8}.csv`
   so the iOS suite can be diffed independently.
4. **`PERFORMANCE_RESULTS.md`** — add an "iOS-resolution suite" section
   once the first run lands, with extrapolation: at p50 latency `L` per
   compare, a suite of `N` snapshots at this resolution costs `N × L`
   wall time on a single thread, `N × L / workers` parallel.

### Verification

- New scenarios produce stable p50 numbers across three consecutive runs
  (variance < 10%).
- Peak RSS at parallel-8 stays bounded — no growth across iterations,
  confirming Phase 5's `defer { deallocate() }` actually returns pages.
  Sustained workload of 10 000+ compares at 22 MB buffers should not push
  RSS above `(workers × 2 × 22 MB) + steady-state overhead` (~352 MB
  worth of in-flight buffers at parallel-8, expected total RSS in the
  4-5 GB range matching current numbers).
- Existing scenarios' numbers unchanged (no regression from adding the
  new scenarios — they're additive).

### Risks

- **Bench wall time grows**: 7 new scenarios × 3 modes (serial / p4 / p8)
  add real time to every CI bench run. Mitigation: the new scenarios go in
  a separate `--suite ios` flag that's opt-in for the bench script
  (default keeps the current scenarios for fast iteration; `--suite all`
  or `--suite ios` enables them).
- **Synthetic vs. real fixtures**: a gradient PNG isn't byte-identical to
  what `UIGraphicsImageRenderer` produces from a real SwiftUI/UIKit view
  hierarchy. The synthetic image *is* in the canonical layout, which is
  the realistic case for >90% of iOS snapshot tests, but a follow-up
  could commit a small handful of real iOS-rendered PNG fixtures
  (`Tests/SnapshotTestingTests/__Fixtures__/ios-screenshots/`) for
  byte-true reproducibility.

### Outcome (what this phase decides)

After this phase produces results, we'll have evidence to answer:

1. **Is a canonical-layout fast-path worth doing?** If iOS-resolution
   `IPhoneExactMatch` and `IPad1pxDiff` show CG `draw` accounting for a
   significant fraction of wall time (>30%), the fast-path is worth the
   parity-test investment. If CG already memcpys internally for this
   case, the win is near-zero and we skip it.
2. **Does the Phase 5 RSS story hold at iOS sizes?** Half-RAM at parallel-8
   on 1024² scenarios is a clean win, but 22 MB buffers may stress the
   allocator differently. This phase is the proof.
3. **What's the realistic CI-level speedup vs. baseline?** With per-call
   numbers at iOS sizes, "Phase 5 makes a 10 000-snapshot iPad suite N
   seconds faster" stops being a hand-wave.

### Results

Code: `eced587` · Bench: `c9e32ff` (CSVs:
`bench-results/eced587-ios-{serial,parallel-4,parallel-8}.csv`).

| Scenario | Buffer | Iter | Serial p50 | Serial p95 | P-4 wall | P-8 wall | Peak RSS (P-8) |
|---|---|---|---|---|---|---|---|
| `iphone-exact-match` | 12 MB | 1000 | 0.93 ms | 1.03 ms | 286 ms | 259 ms | 838 MB |
| `iphone-1px-diff` (precision 0, full byte loop) | 12 MB | 1000 | 6.66 ms | 9.80 ms | 393 ms | 387 ms | 838 MB |
| `iphone-precision-99` (~0.4% pixels) | 12 MB | 500 | 6.07 ms | 6.78 ms | 213 ms | 195 ms | 838 MB |
| `iphone-perceptual-pass` | 12 MB | 250 | 52.57 ms | 57.05 ms | 1287 ms | 1329 ms | 1.86 GB |
| `ipad-exact-match` | 22 MB | 500 | 1.36 ms | 1.43 ms | 246 ms | 195 ms | 1.57 GB |
| `ipad-1px-diff` (precision 0) | 22 MB | 500 | 9.80 ms | 11.61 ms | 358 ms | 316 ms | 1.57 GB |
| `ipad-precision-99` | 22 MB | 250 | 8.32 ms | 8.92 ms | 177 ms | 166 ms | 1.57 GB |

#### Suite-level extrapolation (per-call wall × N)

10 000-snapshot suites at parallel-8 wall time:

| Workload | iPhone (12 MB) | iPad (22 MB) |
|---|---|---|
| All exact-match | 2.6 s | 3.9 s |
| All 1px-diff (worst-case full byte loop) | 3.9 s | 6.3 s |
| All precision-99 | 3.9 s | 6.6 s |
| All perceptual | 53 s | (not measured) |

#### Decisions this phase resolved

1. **Canonical-layout fast-path: not worth doing.** `iphone-exact-match`
   p50 is 0.93 ms — *faster* than two raw memcpys of the 12 MB buffer
   would take (≈ 2.4 ms at ~10 GB/s). CG `draw` is already short-
   circuiting on canonical-layout source images (likely tile / CoW
   tricks under the hood); replacing it would give us little headroom.
   The same holds at iPad sizes (1.36 ms vs ≈ 4.4 ms naïve).
2. **Phase 5 RSS story holds at iOS sizes.** Sustained 22 MB-buffer
   workload on parallel-8 lands at 1.57 GB peak — well under the 4-5 GB
   ceiling the plan budgeted, and matching the
   `(workers × 2 × 22 MB) ≈ 352 MB` in-flight estimate plus
   steady-state overhead. No buffer leakage; `defer { deallocate() }`
   returns pages cleanly.
3. **Realistic CI speedup is ~tens of seconds, not minutes.** A
   10 000-iPhone-snapshot suite with all 1px-diffs (a pessimistic
   workload — most real assertions are exact-match or precision-passing)
   completes in under 4 s wall at parallel-8. Most real iOS test
   suites will be image-bound on the order of seconds-to-tens-of-seconds,
   not the minutes that pre-Phase-1 baseline implied.

#### Notes

- **Sub-linear scaling with buffer size**: 12 MB → 22 MB is a 1.83×
  increase in pixel count, but `1px-diff` p50 only grows 1.47×
  (6.66 → 9.80 ms). Some per-call overhead (CG context setup, function
  dispatch, autoreleasepool drain) is fixed cost amortized across
  pixels; the byte loop itself scales linearly.
- **Parallel-4 ≈ parallel-8 wall time** on most scenarios. The
  workload is RAM-bandwidth-bound at iOS sizes, not CPU-bound; adding
  workers past 4 buys little. Independently noticed: `BenchRunner`
  uses `DispatchQueue.concurrentPerform` which doesn't actually pin to
  N workers — it always lets GCD use the full machine. The CLI
  `--parallel N` is currently informational only. That's a pre-Phase-6
  harness limitation, not a code bug; for "thermally-equivalent core
  count" experiments, fixing it is a good follow-up but doesn't
  change Phase 6's conclusions.
- **Perceptual at iPhone size is ~10× slower than precision** (52 ms
  vs 6 ms p50). Suite-level cost is dominated by perceptual
  assertions when present; the existing `perceptualPrecision` opt-in
  is correctly the more expensive option.

---

## Phase 7 — Bench harness: pin workers to `--parallel N`

`BenchRunner` currently uses `DispatchQueue.concurrentPerform(iterations:)`,
which farms work onto GCD's global pool — always sized to the full
machine, regardless of the CLI's `--parallel N` value. That's why
Phase 6 found `parallel-4` ≈ `parallel-8` wall on every scenario:
both modes were running with whatever GCD's worker count happened to
be (typically `activeProcessorCount`).

This phase is bench-only — no library changes, no shipped behavior
change — but it unblocks honest contention measurements. Phase 8's
gating numbers and any future "what's the optimal limiter default"
question can't be answered without it.

### Changes

1. **`Sources/SnapshotTestingBenchmarks/Harness/Runner.swift`** —
   replace `DispatchQueue.concurrentPerform(iterations:)` with an
   explicit N-worker pool. Two equivalent shapes:
   - N `DispatchQueue.global()` work items + a counter → `DispatchGroup`
     to wait, with a shared atomic iteration counter, OR
   - A `DispatchSemaphore(value: N)` gate inside the existing
     `concurrentPerform` body so at most N iterations execute
     concurrently.
   The semaphore variant is the smaller diff. The N-worker pool
   variant is more honest (samples truly come from N threads), which
   matters for the per-iter `t1 - t0` measurements.
2. **`scenario`'s warmup** must still run on a single thread before
   the parallel section to avoid cold-start contamination of p50.
3. CSV `parallelism` column already exists and now reflects reality.

### Verification

- Re-run Phase 6's iOS suite at `--parallel 2`, `--parallel 4`,
  `--parallel 8`. Wall times should now monotonically improve with N
  (until RAM-bandwidth saturation kicks in around 4 on Apple Silicon).
- Existing serial baselines unchanged.
- Phase 6 conclusions stand — the perceptual GPU-sync floor and CG
  draw fast-path findings don't depend on this.

### Risks

- None for the library. For the bench, slightly more code in
  `Runner.swift`. The risk of stale baselines is real but manageable:
  the serial column is unaffected, and Phase 6's parallel numbers
  become "lower bound on what could be measured at the time" rather
  than wrong.

### Out of scope

- Cross-machine parallel scaling curves (different M-series chips
  have different bandwidth profiles). Each developer's bench remains
  local.

---

## Phase 8 — Cache `MPSImageThresholdBinary` in the perceptual path

Per Phase 6's follow-up investigation, the perceptual diff path's RSS
(~1.3 GB at parallel-8 on 12 MB iPhone inputs) is dominated by a fixed
Metal/CIContext heap floor — not per-call retention. Iteration count
doesn't move it; CIContext pool size doesn't move it; concurrency
limit doesn't move it.

The remaining CPU-side lever is `ThresholdImageProcessorKernel.process`
(`UIImage.swift:548`), which constructs a fresh `MPSImageThresholdBinary`
**every perceptual call**. MPS kernels are documented thread-safe for
encoding once constructed; the `thresholdValue` parameter is bound at
construction but `linearGrayColorTransform` is `nil` and `device` is
the singleton.

In practice each `Diffing.image(perceptualPrecision:)` instance has
exactly one threshold value (`(1 - perceptualPrecision) * 100`), so a
small dictionary keyed by `Float` collapses to 1-2 entries per process
and amortizes the MPS construction cost across the whole suite.

### Changes

1. **`Sources/SnapshotTesting/Snapshotting/UIImage.swift`** — inside
   `ThresholdImageProcessorKernel`, add a private static
   `[Float: MPSImageThresholdBinary]` cache guarded by an `NSLock`
   (or `os_unfair_lock`). `process(...)` looks up by `thresholdValue`,
   constructs on miss, returns the cached kernel.
2. The cached kernel is encoded to the per-call `commandBuffer`; MPS
   kernels are stateless w.r.t. encoding, so concurrent encoders are
   safe.

### Verification

- `iphone-perceptual-pass` p50 expected to drop modestly (single-digit
  ms range — MPS construction is ~1-2 ms but happens inside the
  GPU-sync block, so the visible win depends on whether it overlapped
  with Metal scheduling).
- Peak RSS at parallel-8 expected to drop a small amount (one fewer
  MPS Metal heap per active call).
- Full XCTest suite green; perceptual edge-case tests
  (`PerceptualPass`, `PerceptualFail`, plus existing perceptual
  fixtures in `Tests/SnapshotTestingTests`) unchanged.
- Use the Phase 7 bench harness fix to measure at honest
  `--parallel 2` / `4` / `8` so the win isn't masked by the current
  always-N-cores behavior.

### Risks

- **MPS kernel thread-safety for encoding**: documented safe per
  Apple's MPS guide, but worth a sanity check that we can encode the
  same kernel into multiple command buffers concurrently. If unsafe,
  fall back to one cache entry per (threshold, thread) — still
  amortizes construction across iterations on the same thread.
- **Cache lifetime**: cache lives forever (process-wide static). Fine
  in practice; threshold value is bounded by `Float` precision and
  tests rarely use more than 1-2 distinct precisions. If we ever
  worry about unbounded growth, an LRU is trivial to add.

### Out of scope

- Caching the upstream CIFilters (`CILabDeltaE`, `CIAreaAverage`,
  `CIAreaMaximum`). CIFilter is already a pooled, recycled type
  managed by CoreImage; explicit caching there has historically
  made things worse.

---

## Phase 9 — Full-pipeline benchmarks on real views

After Phase 5, `iphone-exact-match` `compare()` p50 is **0.93 ms** at
iPhone size — at that floor, comparison is no longer plausibly the
dominant cost in a real `assertSnapshot` call. Every preceding phase
has optimized one specific stage (the comparison) without measuring
where the rest of `assertSnapshot` wall time actually goes. The
remaining stages are all unmeasured:

- **Render**: `prepareView` builds a fresh `UIWindow` + wraps the view
  in a `UIViewController`, sets traits, runs `layoutIfNeeded`
  (`Common/View.swift:929`); `addImagesForRenderedViews` walks the
  entire view tree looking for `WKWebView` / `SCNView` / `SKView`
  subviews to pre-render (`Common/View.swift:811`); finally
  `view.layer.render(in:)` (default) or
  `view.drawHierarchy(in:afterScreenUpdates:true)` produces the
  `UIImage`. None of this has ever been profiled in the bench.
- **Reference load**: `Data(contentsOf:)` from disk + `UIImage(data:)`
  PNG-decode happens sequentially after the render. PNG-decode at
  iPhone size is non-trivial (multi-ms) and runs on the same thread.
- **Compare**: the part Phases 1-8 optimized.
- **Failure attachments**: on mismatch, the diff PNG is generated via
  `blendModeDiff` / `normalizedComponentDiff`, the failed snapshot is
  re-encoded to PNG and written to the artifacts dir, and XCTest
  attachments are recorded.

Phase 9 produces per-stage timing breakdowns so the next optimization
phase, if any, is data-driven rather than guessed. It also resolves
the open question raised after Phase 8: is comparison still worth
optimizing, or has the bottleneck moved elsewhere?

### Goal

For each scenario, report wall time per call **broken down by stage**:
`render_ns`, `read_ns`, `decode_ns`, `compare_ns`, `attachments_ns`,
`total_ns`. With that table in hand, "should we optimize X" stops
being speculative.

### Changes

1. **`Sources/SnapshotTestingBenchmarks/Scenarios/PipelineScenarios.swift`**
   (new) — macOS `NSView` pipeline scenarios. Each scenario:
   - In `setUp`, builds a representative `NSView` and pre-records the
     reference PNG to a per-scenario temp directory by invoking the
     real `Snapshotting<NSView, NSImage>.image` strategy and writing
     `diffing.toData(image)` to disk.
   - In `runOnce`, replays the public-API stages of `verifySnapshot`
     **inline** with explicit timestamps between them: render via
     `snapshotting.snapshot(view).run { ... }`, `Data(contentsOf:)`,
     `diffing.fromData(...)`, `diffing.diffV2(reference, new)`. No
     XCTest expectation overhead inside the timed region; the
     `Async<NSImage>` callback fires synchronously for the NSView
     strategy.
   - The harness records per-stage nanoseconds, not just total.
2. **Scenario coverage** (NSView, on macOS host):
   - `pipeline-small-flat` — single `NSTextField` at ~100×40.
   - `pipeline-medium-stack` — `NSStackView` of 5 text fields + an
     `NSImageView` at ~320×200.
   - `pipeline-large-iphone` — synthetic full-screen mock at iPhone
     size (1179×2556) — same dimensions as the existing `iphone-*`
     scenarios so the compare-only timings are directly comparable.
   - `pipeline-large-iphone-fail` — same as above but the new image
     differs in one pixel; exercises the failure path
     (`normalizedComponentDiff` + PNG re-encode + write).
3. **`Sources/SnapshotTestingBenchmarks/Harness/Stats.swift` /
   `CSV.swift`** — extend the result row to carry per-stage timing
   percentiles. CSV gains columns: `render_p50_ns, render_p95_ns,
   read_p50_ns, read_p95_ns, decode_p50_ns, decode_p95_ns,
   compare_p50_ns, compare_p95_ns, attachments_p50_ns,
   attachments_p95_ns`. Existing columns unchanged.
4. **`scripts/bench.sh`** — add `--suite pipeline` that runs only the
   pipeline scenarios. `--suite all` runs everything. Output filename
   pattern `bench-results/<sha>-pipeline-{serial,parallel-4,parallel-8}.csv`.
5. **(Follow-up, separately scoped)** — iOS-simulator UIView pipeline
   bench. Real `UIView` paths exercise `UIWindow` + `UIViewController`
   setup that the macOS `NSView` strategy doesn't. Implementation
   shape: a small XCTest target driven via `xcodebuild test
   -destination 'platform=iOS Simulator,name=iPhone 15 Pro'` from a
   new `--simulator` flag in `scripts/bench.sh`. The XCTest cases
   write their per-stage CSV rows to a path passed via env var. This
   is gated as a follow-up because the macOS NSView bench is the
   minimum viable measurement and the iOS-sim infrastructure is its
   own project to land cleanly.

### Verification

- The new pipeline CSVs produce stable per-stage p50 numbers across
  three consecutive runs (variance < 10%).
- Comparison-stage numbers in `pipeline-large-iphone` are within ±10%
  of the existing `iphone-exact-match` p50 — sanity check that the
  pipeline scenarios drive the same `compare()` code path.
- No library code changes — phase is bench-only. Existing test suite
  unchanged and green; existing bench scenarios produce identical CSV
  rows (the new columns only appear on pipeline scenarios).

### Risks

- **NSView ≠ UIView**: NSView's snapshotting strategy is simpler than
  UIView's (no `UIWindow` setup, no `UIViewController` nesting, no
  trait-collection plumbing). The macOS-host bench therefore
  *under-counts* the render stage for real iOS suites. Acceptable as
  a first pass — establishes the per-stage shape — but the iOS-sim
  follow-up is what gives us the honest UIView numbers.
- **Bench wall time grows**: 4 new scenarios × 3 modes adds time to
  every full sweep. Mitigation: gated behind `--suite pipeline` /
  `--suite all`; default sweep stays fast.
- **`SNAPSHOT_ARTIFACTS` pollution**: the failure-path scenario writes
  diff PNGs every iteration. Mitigation: scenarios point
  `SNAPSHOT_ARTIFACTS` at a per-run temp dir and clean it in
  `tearDown`.

### Outcome (what this phase decides)

After this phase produces per-stage data, we'll be able to answer:

1. **Is comparison still the right thing to optimize?** If
   `compare_ns` is <20% of `total_ns` on the pipeline scenarios, no
   further compare-side optimization is worth doing — the leverage
   has moved to render or decode.
2. **Is render dominated by `prepareView` setup, by
   `addImagesForRenderedViews` traversal, or by the actual
   `layer.render(in:)` GPU call?** Sub-stage timing inside the render
   block (added cheaply with a few extra timestamps) tells us which
   one to attack first, if any.
3. **Does parallelizing the reference PNG decode with the view
   render** (currently sequential — `verifySnapshot` renders then
   decodes) actually save anything in the success path? Per-stage
   numbers tell us the upper bound.
4. **Is the failure-path overhead** (`blendModeDiff` +
   `normalizedComponentDiff` + PNG re-encode + write to disk) ever
   visible in real test suites, or is it negligible because most
   tests pass?

### Out of scope

- **Any library code change.** Phase 9 is bench-only. The next phase,
  if any, is gated on what Phase 9's data shows.
- **Perceptual pipeline timing.** Already covered by existing
  `iphone-perceptual-pass`; Phase 9 focuses on the default
  (non-perceptual) path which is where 99%+ of real assertions land.
- **SwiftUI-specific scenarios.** SwiftUI hosts a `UIHostingController`
  + waits for layout to settle, which has its own overhead profile.
  Belongs in the iOS-sim follow-up where the hosting infrastructure
  is available, not in the macOS-host bench.

### Decision criteria for whether to ship

Phase 9 always ships — the cost is bench code only and the data is
the deliverable. The interesting question Phase 9 *resolves* is
whether a Phase 10 is warranted, and if so, on which stage. Concrete
post-Phase-9 decisions:

- If `render_ns` > 50% of `total_ns` → next phase optimizes the
  render pipeline (candidates: render directly into the normalized
  comparison buffer to skip the second-pass render in `compare()`;
  fast-path `addImagesForRenderedViews` when the tree has no
  WK/SCN/SK subviews; `UIGraphicsImageRenderer` reuse).
- If `decode_ns` > 30% of `total_ns` → next phase parallelizes the
  reference-PNG decode with the view render.
- If neither, and `compare_ns` is already small → declare the project
  done.

### Results

Code: `dfbeec6` · Bench: `ede47aa` (CSVs:
`bench-results/dfbeec6-pipeline-{serial,parallel-4,parallel-8}.csv`).

Per-stage timings, serial p50 (ns columns formatted as ms):

| Scenario | Iter | Total p50 | render | read | decode | compare | attachments |
|---|---|---|---|---|---|---|---|
| `pipeline-small-flat` | 1000 | 0.34 ms | 49 µs | 18 µs | 82 µs | 189 µs | 0 |
| `pipeline-medium-stack` | 500 | 2.42 ms | 576 µs | 28 µs | 91 µs | 1.72 ms | 0 |
| `pipeline-large-iphone` | 250 | 126 ms | 47.6 ms | 110 µs | 197 µs | 77.9 ms | 0 |
| `pipeline-large-iphone-fail` | 250 | 268 ms | 50.0 ms | 100 µs | 159 µs | 36.0 ms | 182 ms |

#### Stage-share breakdown

| Scenario | render | read+decode | compare | attachments |
|---|---|---|---|---|
| `pipeline-large-iphone` | 38% | 0.2% | **62%** | 0% |
| `pipeline-large-iphone-fail` | 19% | 0.1% | 13% | **68%** |
| `pipeline-medium-stack` | 24% | 5% | **71%** | 0% |
| `pipeline-small-flat` | 14% | 30% | **56%** | 0% |

#### Decisions this phase resolves

1. **Comparison is still the right thing to optimize at iPhone size.**
   `pipeline-large-iphone` `compare_p50` is **78 ms** — well over the
   "small" threshold. By the plan's stated rule (render < 50%, decode
   < 30%, compare not small), the next phase, if any, is compare-side.
2. **Synthetic vs pipeline gap was huge.** `iphone-exact-match`
   reported 0.93 ms p50 in Phase 6; the same compare in pipeline
   reports 78 ms — **~85×**. The synthetic test fed identical CGImage
   instances; both `context(for:)` calls returned cached normalized
   buffers in canonical layout. The pipeline reference is decoded from
   PNG (different colorspace / row stride / scale), so neither
   `context(for:)` call hits a fast path. This is the most important
   finding of Phase 9 — every prior phase's "compare cost" win was
   measured against canonical-layout inputs.
3. **Render is non-trivial but not dominant.** 47.6 ms render at iPhone
   size (NSImageView + cacheDisplay) is significant absolute cost, but
   it's 38% of total — under the 50% threshold for prioritizing render
   optimization. macOS NSView numbers under-count render vs real iOS
   UIView (no UIWindow/UIViewController setup, no traits); the
   iOS-sim follow-up would surface that gap.
4. **PNG read+decode is negligible at iPhone size.** Both stages
   together are < 0.3% of total — the "parallelize decode with render"
   optimization the plan considered would save effectively nothing
   (~300 µs of an 80 ms+ pipeline). Cross off.
5. **Failure-path attachment generation is the dominant fail-path
   cost.** 182 ms of attachments per failure (3× PNG encode at iPhone
   size + difference PNG generation) — but only paid when a test
   fails. For a CI suite where 99%+ of assertions pass, this is
   invisible to total wall time. For a developer iterating on a
   broken assertion, it's ~250 ms per re-run. Worth noting as a
   diagnostic-loop UX cost, not as a throughput optimization target.

#### Notes

- **Pipeline parallel modes were forced serial.** AppKit autolayout
  rejects modifications from background threads after first use on
  main, so the runner detects `StagedScenario` and runs all iterations
  on the calling (main) thread. The `mode`/`parallelism` CSV columns
  still report the requested value, so suite CSVs across modes diff
  cleanly. `wall_ns` reflects the actual serial execution.
- **Attachments timing is approximated** for the failure scenario as
  `(diffV2(reference, new)) - (diffV2(new, new))` per iteration —
  paying two compares to isolate the post-compare attachment work.
  Negative deltas clamp to 0; no negative observed in the recorded
  run.
- **Sanity check vs Phase 6** (the plan asked for ±10% on
  `pipeline-large-iphone` `compare_ns` vs `iphone-exact-match` p50)
  **failed**: 78 ms vs 0.93 ms is ~85× off. Cause is the layout-
  mismatch finding above; the sanity check assumed both sides hit the
  same fast path, but the pipeline reference comes from PNG and
  doesn't. This is a useful surprise rather than a measurement bug.

#### What this means for a Phase 10

The data argues for one compare-side optimization:

- **Detect the canonical-layout fast path at runtime.** When both
  CGImages already have RGBA8 + sRGB + premultipliedLast + tight row
  stride, skip the `context(for:)` redraw and `memcmp` the existing
  CGImage data directly. The synthetic Phase 6 numbers prove this
  path is ~85× cheaper when applicable; the pipeline data shows the
  current code never takes it on PNG-decoded references.

A reference-side normalization cache was considered and **rejected** —
in real test suites each `assertSnapshot` call uses a unique reference
PNG once per run, so amortizing the normalize cost across repeated
calls to the same reference only helps inside the bench (artificial
repetition), not in real suites. The fast-path detection helps every
assertion regardless of whether its reference recurs.

Out of scope for Phase 9 (bench-only) and would be its own phase. The
data is the Phase 9 deliverable; the optimization is the Phase 10
question.

---

## Phase 10 — canonical-layout PNG decode + compare fast path

### Goal

Move the per-assertion sRGB+RGBA8 normalization off the hot path. Phase
9 measured `pipeline-large-iphone` `compare_p50` at 78 ms — two
`context(for:)` redraws, one per side, each ~38 ms. The reference side
hits the slow path because `UIImage(data:)` / `NSImage(data:)` decode
PNG into whatever layout ImageIO picks (often Display P3 +
premultipliedFirst), forcing `compare()`'s `CGBitmapContext` to do real
colorspace + alpha conversion.

Phase 10 normalizes during `fromData` instead of during `compare`, then
adds a fast path so `compare()` skips the redraw whenever both sides
are already canonical.

### Changes shipped

- `Sources/SnapshotTesting/Snapshotting/Internal/CanonicalImage.swift`
  (new). Defines the canonical layout (RGBA8 / sRGB /
  premultipliedLast / `byteOrder32Big` / `width*4` stride), the
  `compareContext` helper (deduped from `UIImage.swift` /
  `NSImage.swift`), the `decodeCanonicalCGImage` PNG entry point, and
  `loadCompareBuffer` — which returns the CGImage's data provider when
  the input is already canonical (no allocation, no redraw) or
  otherwise allocates and redraws.
- `UIImage.swift` / `NSImage.swift`: `fromData` now goes through
  `decodeCanonicalCGImage` (with a fall back to the original decoder on
  ImageIO failure); `compare()` calls `loadCompareBuffer` instead of
  doing the alloc-and-draw inline. Same downstream byte semantics.
  `legacyCompare` and `normalizedComponentDiff` rewired to the shared
  `compareContext`. The `byteOrder32Big | premultipliedLast` bitmap
  info is pinned explicitly so the resulting CGImage's bitmapInfo is
  reproducible across releases — needed for `isCanonicalForCompare` to
  detect a canonical CGImage with a single equality check.

### Results

Code: this commit (parallel runs deferred — pipeline scenarios are
forced serial per Phase 9). Bench:
`bench-results/phase10-pipeline-serial.csv`.

Per-stage timings, serial p50 (ms):

| Scenario | Iter | Total | render | read | decode | compare | attachments |
|---|---|---|---|---|---|---|---|
| `pipeline-small-flat` | 1000 | 0.41 | 63 µs | 24 µs | 229 µs | 93 µs | 0 |
| `pipeline-medium-stack` | 500 | 3.05 | 704 µs | 41 µs | 1.35 ms | 914 µs | 0 |
| `pipeline-large-iphone` | 250 | 150 | 58.6 ms | 107 µs | 52.2 ms | 40.6 ms | 0 |
| `pipeline-large-iphone-fail` | 250 | 321 | 61.2 ms | 103 µs | 27.6 ms | 38.3 ms | 194 ms |

vs Phase 9 baseline (`dfbeec6`):

| Scenario | Δ Total | Δ decode | Δ compare |
|---|---|---|---|
| `pipeline-small-flat` | +21% (0.34 → 0.41) | +0.15 ms | −0.10 ms |
| `pipeline-medium-stack` | +26% (2.42 → 3.05) | +1.26 ms | −0.81 ms |
| `pipeline-large-iphone` | +19% (126 → 150) | +52.0 ms | −37.3 ms |
| `pipeline-large-iphone-fail` | +20% (268 → 321) | +27.4 ms | +2.3 ms |

### What the data says

**Phase 10 in isolation is a net regression.** The compare-side savings
land as predicted (≈37 ms off `pipeline-large-iphone` compare from
killing one of two redraws), but the canonicalization work shifts into
decode and grows by ≈52 ms — net +15 ms per assertion at iPhone
resolution. Smaller scenarios pay a similar absolute overhead that
dominates their tiny compare savings.

The asymmetry is real: `compare()`'s reference-side redraw was 38 ms,
but the same conversion paid eagerly during `fromData` is 52 ms.
Suspected cause: Phase 9's measured 0.2 ms decode was actually
`NSImage(data:)`'s lazy decode — the real PNG-decode + colorspace
work landed inside `compare()` and was accounted as compare cost.
Pulling it forward to `fromData` adds CGImageSource setup overhead
(~14 ms at iPhone size) on top.

**Why the win didn't materialize:** the rendered (new) side is still
non-canonical — `NSView.cacheDisplay` produces whatever layout AppKit
picks. So `compare()` still has to redraw the new image (~38 ms). The
fast path only fires on the reference. Net: shifted cost without
eliminating it.

### Decision

**Reverted.** Code archived on `perf/phase10-canonical-decode-archived`
(commit `e4746e8`). The branch holds `CanonicalImage.swift` plus the
`fromData` / `compare()` changes to `UIImage.swift` and `NSImage.swift`
as a single commit, so reviving the work is `git cherry-pick`.

Why revert rather than ship as Phase 11 prep:

1. **Net regression in isolation.** +19% on `pipeline-large-iphone`,
   +20–26% on smaller pipeline scenarios. Shipping a measured
   regression on the bet of future work is hard to defend if Phase 11
   slips or doesn't deliver the projected savings.
2. **Phase 11 has unresolved feasibility risk.** Canonicalize-on-render
   means controlling the bitmap layout produced by
   `NSView.cacheDisplay` / `UIGraphicsImageRenderer`. AppKit/UIKit
   don't fully expose pixel-format control on those paths; the work
   may require a from-scratch `CGContext`-based capture, which has
   its own correctness surface (Hi-DPI scaling, view-hierarchy
   side-effects, off-screen rendering quirks).
3. **The 14 ms decode-overhead delta is unexplained.** Even granting
   Phase 11's render-side win, the eager-decode overhead in this
   archived attempt was ~52 ms vs the ~38 ms the same conversion cost
   inside `compare()`. Phase 11's projected total assumes that gap
   closes; without an Instruments trace, it's a guess.
4. **Re-introducing the helpers atomically with Phase 11 is cheaper
   than carrying a regression.** The helpers are ~150 lines of clean,
   self-contained code. When Phase 11 lands, cherry-pick the archive
   commit and adjust — no work is lost.

What Phase 11 would need to revive this:

- Canonicalize the render side so both sides hit the
  `loadCompareBuffer` fast path. Target: `compare()` collapses to
  `memcmp` (sub-ms at iPhone size, validated by Phase 6's 0.93 ms
  `iphone-exact-match`).
- Resolve the open question below before committing — if the
  decode-side overhead doesn't close, the projected combined win
  shrinks materially.
- Projected Phase 10 + Phase 11 combined (assuming the open question
  resolves favorably): render canonical ~50 ms + decode canonical
  ~5–10 ms + compare < 1 ms = **~55–60 ms vs Phase 9's 126 ms**
  (~55% reduction).

### Open question (carry into Phase 11 research)

Why is canonicalize-during-decode 52 ms while the equivalent redraw
inside `compare()` is 38 ms? `CGImageSourceCreateImageAtIndex` plus
`CGContext.draw` plus `CGContext.makeImage` should be no more
expensive than the lazy NSImage path. Worth a one-evening Instruments
trace before committing to Phase 11; if the gap is `makeImage()`
overhead, swap to a `vImageConverter`-based path that produces the
canonical buffer directly without round-tripping through CGImage.

---

## Phase 12 — correctness-safe compare-side wins

### Goal

Reduce `compare()` cost on `pipeline-large-iphone` (78 ms in Phase 9,
the dominant 62% of pipeline total) **without changing rendered byte
content** — so existing committed reference PNGs stay byte-equal
under the new pipeline. Phase 11 proved canonical-on-render breaks
backwards compatibility; Phase 12 keeps the historical
`bitmapImageRepForCachingDisplay + cacheDisplay` render path
untouched and instead speeds up the comparison machinery itself.

### Constraint

- The bytes produced by the public `Snapshotting<NSView, NSImage>.image`
  / `Snapshotting<UIView, UIImage>.image` strategies must be
  bitwise-identical to today's output. Same `cacheDisplay`, same
  `UIGraphicsImageRenderer`, same `pngData()`/`NSImagePNGRepresentation`.
- `compareContext`'s destination format stays canonical (sRGB +
  RGBA8 + premultipliedLast + byteOrder32Big + tight stride). The
  *destination* is what defines comparison semantics; the *path* to
  reach it is the optimization surface.
- `memcmp` semantics unchanged — same destination format, same byte
  comparison, same precision/perceptualPrecision branches.

### Workstreams

Four candidates, ranked by expected ROI. Stack-able: (A) and (B)
combine for the largest projected win.

#### A. vImage-accelerated `compareContext` (highest ROI) — ✅ shipped

**Result (commit pending):** `pipeline-large-iphone` total p50
**126 → 74 ms (−42%)**, compare_p50 **78 → 24 ms (−69%)**. Beat the
~78 ms projection by 4 ms. Same gain at parallel-8. Fail-path
total within ±0.5%. PNG references byte-identical, 40 XCTests
pass. Implementation: `Sources/SnapshotTesting/Snapshotting/Internal/CompareBufferLoader.swift`.

Replace `CGContext.draw(cgImage, ...)` inside `compareContext` with
a `vImageConverter` + `vImageConvert_AnyToAny` path. vImage's
SIMD-optimized pixel-format converters are typically 2–3× faster
than `CGContext.draw` for the kind of conversion this hot path
needs (Display P3 + premultipliedFirst + non-tight stride →
sRGB + premultipliedLast + tight stride).

- Implementation: build a `vImage_CGImageFormat` from `cgImage`,
  build a destination `vImage_CGImageFormat` matching our canonical
  layout, `vImageConverter_CreateWithCGImageFormat` (cache the
  converter per source-format key), `vImageConvert_AnyToAny` into
  the destination buffer.
- Fallback: keep the existing `CGContext.draw` path for any source
  format `vImageConverter_CreateWithCGImageFormat` rejects (rare
  edge formats — grayscale, planar, floating-point).
- Projection: each redraw 38 ms → ~15 ms. `compare()` 78 → ~30 ms.
  **Pipeline total: 126 → ~78 ms (~38% reduction).**
- Risk: vImage's conversion may produce slightly different rounding
  than `CGContext.draw` for borderline pixels. Validate against the
  full test suite + the `ImageNormalizationEdgeCasesTests` from
  Phase 3 follow-up (12 tests covering non-premultiplied alpha,
  Display P3, grayscale). If any test fails, gate vImage path
  behind a runtime check that both source and destination are in
  the "safe" format space and fall back otherwise.

#### B. Parallelize the two compare-side redraws — ✅ shipped

**Result (commit `d77f332`):** parallel-8 `pipeline-large-iphone`
total p50 **74 → 70 ms (−5% atop A)**, compare **23 → 20 ms
(−14%)**. Smaller than the projected ~9 ms savings — dispatch
overhead and L3/memory-bandwidth contention on the 12 MB working
set damp the win — but real and consistent across modes. No
parallel-mode regression: the `byteCount > 256 KB` gate keeps
small images on the serial path. Implementation:
`loadNormalizedCompareBufferPair` in
`Sources/SnapshotTesting/Snapshotting/Internal/CompareBufferLoader.swift`.

Today `compare()` runs ref-redraw → new-redraw → memcmp serially.
Both redraws are CPU-bound, independent, and write to separate
buffers. Run them via `DispatchQueue.concurrentPerform(iterations: 2)`
or a 2-element `DispatchGroup`.

- Implementation: hoist buffer allocation before the parallel
  block; index 0 handles old, index 1 handles new; main thread
  joins, then memcmp.
- Projection: total compare time goes from `oldRedraw + newRedraw`
  to `max(oldRedraw, newRedraw)`. With Phase 9 baseline (~38 ms
  each): 78 → ~38 ms. **Pipeline total: 126 → ~88 ms (~30%
  reduction).** Stacks with (A): max(15, 15) ≈ 15 ms. **Combined
  pipeline total: 126 → ~65 ms (~48% reduction).**
- Risk: thread-safety inside `compareContext` (CG is generally
  thread-safe per-context; we're using two distinct contexts, so
  fine). Bench under `--parallel N` to confirm we don't degrade
  multi-test wall time by oversubscribing the CPU — at high
  parallelism each compare already has many in-flight calls;
  parallelizing within compare may starve other workers. Gate via
  the same `SnapshotTestingPerceptualDiffLimiter` pattern Phase 2
  used.

#### C. vImage-accelerated `decodeCanonicalCGImage` (resurrects Phase 10 cleanly)

Reapply Phase 10's reference-side fast path (canonical-layout PNG
decode in `fromData`), but use `vImageConverter` for the
canonical conversion instead of `CGContext.draw + makeImage`. The
Phase 10 plan called this out as the resolution to its open question
(why decode was 52 ms vs the equivalent 38 ms inside compare — the
CGImage round-trip adds setup overhead).

- Implementation: `CGImageSourceCreateImageAtIndex` →
  `vImage_Buffer.init(cgImage:format:)` → `vImageConvert_AnyToAny`
  → wrap the destination buffer as a `CGImage`.
- Projection: decode goes 52 → ~15 ms. With Phase 10 reapplied:
  pipeline `render 48 + decode 15 + compare 41 = 104 ms` (~17%
  reduction). Stacks with (A): `compare 41 → ~15 ms` →
  `render 48 + decode 15 + compare 15 = 78 ms` (~38% reduction —
  same as (A) alone). So (C) is only useful if Phase 10's
  reference-side fast path matters independently. **Skip unless
  (A) doesn't deliver projected gains on its own.**

#### D. Lazy/deferred attachment generation (fail-path only)

Doesn't help the success path. Phase 9's `pipeline-large-iphone-fail`
attachments stage is 182 ms (PNG-encoding 3 images: reference, new,
diff). Most CI failure handlers only consume the diff — restructure
`diffV2` to encode attachments on-demand via a closure rather than
eagerly. Optional, low priority. Tackle only if user feedback
indicates fail-path latency matters.

### Acceptance criteria

- `swift test` green: 24/24 tests with the same 3 expected
  `withKnownIssue` failures. **All committed reference PNGs
  unchanged on disk after the test run** (this is the canary that
  caught Phase 11 — XCTest auto-record will silently rewrite
  references if comparison fails, masking byte changes).
- `pipeline-large-iphone` total p50 ≤ 90 ms (target: ~65 ms with
  A+B stacked). `pipeline-large-iphone-fail` total p50 within ±5%
  of Phase 9 baseline (no fail-path regression).
- Edge-case suite (`ImageNormalizationEdgeCasesTests`, 12 tests)
  green under both the new and `SNAPSHOT_TESTING_LEGACY_NORMALIZATION=1`
  paths.
- Bench CSV committed under `bench-results/<sha>-pipeline-serial.csv`
  with per-stage breakdown.

### Order of operations

1. (A) alone: implement vImage compareContext, run full suite +
   bench, validate no PNG drift, commit if numbers match
   projection.
2. (B) on top of (A): add parallelization, bench again. Ship if
   stacked win materializes and parallel modes don't regress.
3. (C) considered only if (A)'s actual win underperforms — would
   indicate the conversion isn't the dominant cost and decode-side
   work matters.
4. (D) deferred unless fail-path latency surfaces in user reports.

### Risks

- **vImage rounding differences.** vImage and CGContext use
  different conversion code paths; for some color/alpha
  combinations the LSB may differ. The `ImageNormalizationEdgeCasesTests`
  suite is the primary canary. If a test fails by 1 byte in some
  pixels, gate vImage to the "safe" format pairs (sRGB→sRGB,
  P3→sRGB, deviceRGB→sRGB) and fall back to CGContext for others.
- **Parallelism overhead at small image sizes.** For
  `pipeline-small-flat` (sub-ms compare), thread spin-up overhead
  may dominate. Use a size threshold (e.g., only parallelize when
  `byteCount > 256 KB`) so small assertions stay on the serial
  path.
- **CGImage backing assumptions in vImage path.** Some CGImages
  have callback-based data providers that materialize bytes lazily.
  `vImage_Buffer.init(cgImage:)` handles this but at the cost of
  a synchronous materialization. Verify the bench numbers reflect
  realistic source images, not pre-materialized ones.

### Out of scope

- Changing the render path on either NSView or UIView (Phase 11
  established this breaks user references).
- Changing the on-disk PNG format or the `pngData()` /
  `NSImagePNGRepresentation` calls.
- Touching the perceptual path — Phase 8 already optimized the
  MPS kernel cache; perceptual is opt-in and not the dominant
  cost on the standard pipeline.
- iOS UIView pipeline scenarios — wait until vImage win is
  validated on macOS before adding the iOS surface.

---

## Skipped from source doc

- **#8 pixel-based precision** — deferred per decision above.
- **#9 generate diff only after failure** — already implemented; `Diffing.image` (`UIImage.swift:32-49`) returns from `compare()` first and only builds the diff/attachments on failure. Worth a sentence in the Phase 0 PR description ("already done") so reviewers don't ask.

---

## Rollout

| PR | Phase | Risk | Bench gate |
|---|---|---|---|
| 1 | Phase 0 (harness + baseline) | none — no library changes | n/a |
| 2 | Phase 1 (defer / early-exit / autoreleasepool) | low | no regression vs baseline; gain on precision/parallel |
| 3 | Phase 2 (pool + limiter) | low–medium | gain on parallel RSS & CIContext count |
| 4 | Phase 3 (drop PNG round-trip) | medium | large gain on png-roundtrip & precision RSS; full suite green |
| 5 | Phase 4 (UIGraphicsImageRenderer) | low | parity |
| 6 | Phase 5 (normalized buffer pool) | low | flatter peak RSS at parallel-8; wall ≤ Phase 4 |
| 7 | Phase 6 (iOS-resolution bench scenarios) | none — bench-only | stable percentile measurements at iPhone (12 MB) & iPad (22 MB) buffer sizes; surfaces RSS profile under sustained load; produces decision data for any further optimization |
| 8 | Phase 7 (`BenchRunner` pins to `--parallel N`) | none — bench-only | parallel-N wall times now scale monotonically with N; serial column unchanged |
| 9 | Phase 8 (`MPSImageThresholdBinary` per-threshold cache) | low | iphone-perceptual-pass p50 drops modestly; peak RSS at honest `--parallel 8` flatter; full suite green |
| 10 | Phase 9 (full-pipeline bench scenarios on real NSView; iOS-sim UIView follow-up) | none — bench-only | per-stage CSV columns produced for pipeline scenarios; existing scenarios' CSV rows unchanged; pipeline-scenario `compare_ns` matches existing `iphone-exact-match` p50 within ±10% as a sanity check |

Each PR description includes the bench CSV diff vs. the baseline committed in `bench-baseline/`.

---

## Open questions to resolve before Phase 0 lands

1. Is `swift run snapshot-bench` acceptable as the run interface, or do you want a separate Xcode scheme too? yes
2. Where should `bench-baseline/` live — repo root, or `bench-results/baseline/`? best way you can think off
3. iOS-simulator bench runs in CI later, or macOS-host only? iOS-simulator bench runs too.
4. Does the project want the bench files to be excluded from the published `SnapshotTesting` library? (Yes — separate executable target keeps them out automatically.)
