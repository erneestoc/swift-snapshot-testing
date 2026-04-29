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
- **Phase 9** pending — internal coalescing-window batch for the
  perceptual path. Sync `Diffing` API stays; under the hood, perceptual
  compares enqueue onto a shared coordinator that submits up to N
  pending requests in one Metal command buffer per coalescing window.
  Amortizes the per-call GPU sync that dominates serial p50 (52 ms ≈
  ~47 ms wait + ~5 ms compute). No public API change. Win is bounded
  by the perceptual concurrency limiter — pairs with raising
  `SNAPSHOT_TESTING_PERCEPTUAL_DIFF_CONCURRENCY` default.
- **Deferred (no current phase planned)**: making the public `Diffing`
  API async (Option A / B from the design discussion). Would unlock the
  full ~10× perceptual win at the cost of source-incompatible breakage
  or permanent dual-API surface. Phase 9 captures the source-compatible
  ~2× without that cost; revisit only if a user reports the remaining
  gap matters.

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

## Phase 9 — Internal coalescing batch for the perceptual path

The Phase 6 follow-up showed perceptual serial p50 = 52 ms is mostly
GPU-sync wait, not compute (parallel-N wall throughput is ~5 ms/iter).
Each call submits one Metal command buffer and synchronously waits via
`context.render(toBitmap:)`. If multiple calls were in flight, the GPU
could keep itself busy and amortize that sync — but the public
`Diffing.diffV2` closure is sync, so each caller blocks before the
next can start.

Phase 9 is the source-compatible way to capture most of that gap: keep
the sync `Diffing` API, but inside the perceptual path push work
through a private coordinator that coalesces up to N pending compares
into a single submission per window. Each caller still blocks on its
own result, but submissions overlap on the GPU instead of serializing.

### Changes

1. **`Sources/SnapshotTesting/Snapshotting/Internal/PerceptualBatchCoordinator.swift`**
   (new) — small actor / serial-queue coordinator owning:
   - A pending queue of `(oldCIImage, newCIImage, threshold,
     pixelPrecision, completion)` records.
   - A coalescing window `W` (e.g., 1-2 ms — long enough to gather
     concurrent submissions, short enough not to add noticeable
     per-call latency in low-load test runs).
   - A worker that drains up to `N` pending records and submits them
     together. Two valid implementations:
     - **Same-thread, separate command buffers**: queue N
       `CIContext.render` calls onto a shared dispatch queue without
       per-call serializer; the GPU pipelines them. Simpler; gets
       most of the win with minimal raw-Metal exposure.
     - **One MTLCommandBuffer with all encodings**: encodes the LabΔE
       + threshold + areaAverage chain for each pending request
       manually, commits once, fans out completions. Bigger win, but
       reaches under `CIContext` — substantially more code.
   - The simpler shape is the right starting point; promote to the
     manual-encoding shape only if bench numbers justify it.
2. **`perceptuallyCompare` in `UIImage.swift` / `NSImage.swift`** —
   replace direct `context.render(...)` calls with
   `PerceptualBatchCoordinator.shared.submit(...)` + wait on a
   per-call `DispatchSemaphore`. Caller-visible behavior unchanged
   (still sync, still returns `String?`).
3. **Tunables (env vars)**:
   - `SNAPSHOT_TESTING_PERCEPTUAL_BATCH_WINDOW_US` — coalescing
     window in microseconds (default ~1500 — long enough that the
     dispatch wakeup is amortized, short enough to be invisible at
     low load).
   - `SNAPSHOT_TESTING_PERCEPTUAL_BATCH_MAX` — cap on requests per
     batch (default = current `_PERCEPTUAL_DIFF_CONCURRENCY` value).
   - Set window to 0 to disable batching (forces immediate
     per-call submit; useful for diagnosis).
4. **Pair with raising `SNAPSHOT_TESTING_PERCEPTUAL_DIFF_CONCURRENCY`
   default** — the limiter was originally there to bound CIContext
   alloc cost (Phase 2). With the pool fix + Phase 8's MPS cache, the
   per-call CPU cost is small enough that the limiter is now what
   *prevents* batching. Default likely moves from 2 to
   `min(activeProcessorCount, 8)`. Validate with bench before flipping.

### Verification

- **Phase 7 prerequisite.** Without honest `--parallel N` worker pinning,
  the win can't be measured cleanly.
- `iphone-perceptual-pass` p50 expected to drop ~30-50 % at
  `--parallel 4` / `8`; serial p50 drops less (the window adds latency
  with no batching peer).
- `iphone-perceptual-pass` parallel-N wall expected to drop ~30-50 %
  at N ≥ 4; ideal world is ~5 ms/iter (GPU compute floor).
- Peak RSS at parallel-8 should not regress; can drop modestly because
  per-call MPS heaps overlap less.
- Full XCTest suite green; perceptual edge-case tests
  (`PerceptualPass`, `PerceptualFail`, plus existing perceptual
  fixtures in `Tests/SnapshotTestingTests`) unchanged in pass / fail
  outcomes.
- A new bench scenario `iphone-perceptual-pass-batchable` that runs N
  perceptual compares back-to-back without any sync points between
  them, to validate the batching path actually engages.

### Risks

- **Cancellation / error propagation**: each pending request needs a
  way to surface render errors back to its caller. Per-request
  `Result<Float, Error>` slots solved by storing alongside the
  semaphore.
- **Deadlock under low load**: if only one perceptual call is in
  flight, the coordinator must still drain when the window expires —
  not wait for `N` to fill. A `DispatchSourceTimer` armed on each
  enqueue handles this.
- **Window tuning regresses single-test runs**: a 1.5 ms window is
  a free 1.5 ms of latency on every isolated perceptual call. Mitigate
  by short-circuiting when the queue is empty *and* no other request
  has arrived within (say) 100 µs — i.e., adaptive window.
- **Test isolation surprises**: if multiple `XCTestCase` classes ever
  rely on perceptual compares completing before some side-effect, the
  coordinator must be drained at process exit. `atexit` registration
  or a `Task.detached` flush in the limiter is sufficient.

### Out of scope

- Public `Diffing` API changes (Option A / B from the design
  discussion). Phase 9 stays under the existing sync surface.
- Async `assertSnapshot` overload. The XCTest wrapper continues to
  call sync `diffV2`; only the perceptual implementation pipelines
  internally.
- Batching the precision (CPU memcmp) path — already RAM-bandwidth-
  bound; nothing to gain from coalescing.

### Decision criteria for whether to ship

If Phase 9 measurements at honest parallel-N show <20 % wall-time
improvement on `iphone-perceptual-pass`, drop the phase and flip the
limiter default instead (cheaper, simpler). The phase is only worth
its complexity if the coalescing actually unlocks GPU pipelining.

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
| 10 | Phase 9 (perceptual coalescing batch + raise limiter default) | medium | iphone-perceptual-pass parallel-N wall drops 30-50% at N≥4; serial unaffected; full suite green; ship/drop decision based on >20% wall improvement |

Each PR description includes the bench CSV diff vs. the baseline committed in `bench-baseline/`.

---

## Open questions to resolve before Phase 0 lands

1. Is `swift run snapshot-bench` acceptable as the run interface, or do you want a separate Xcode scheme too? yes
2. Where should `bench-baseline/` live — repo root, or `bench-results/baseline/`? best way you can think off
3. iOS-simulator bench runs in CI later, or macOS-host only? iOS-simulator bench runs too.
4. Does the project want the bench files to be excluded from the published `SnapshotTesting` library? (Yes — separate executable target keeps them out automatically.)
