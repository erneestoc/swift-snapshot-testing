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
- **Phase 5** ✅ code `c6b7d9e`. `SnapshotTestingByteBufferPool` (LIFO,
  size-bounded, `SNAPSHOT_TESTING_BUFFER_POOL_SIZE` / `_MAX_BYTES`).
  Required pinning `context(for:)` to `.copy` blend mode so the uninitialized
  pool memory doesn't blend with translucent source pixels — caught by
  `ImageNormalizationEdgeCasesTests.testNonPremultipliedAlpha_identicalImagesPass`.
  Headline: serial `precision-1px-diff` p50 −29%, parallel-4 wall −31%;
  `exact-match-large` serial p50 −33%. Trade-off: peak RSS on
  `exact-match-mixed` rises (pool retains hot buffers) but stays well below
  the original baseline.
- **Phase 6** pending — fast-path `context(for:)` for already-normalized images.
  Highest remaining wall-time impact; depends on Phase 5.

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

## Phase 5 — Normalized buffer pool (low risk / high impact)

Each `compare()` call allocates two `[UInt8]` buffers sized
`width * height * 4` for the normalized RGBA renderings. At parallel-8 on
4096×4096 images this is ~8 × 2 × 64MB ≈ 1GB of transient `[UInt8]` per
window — visible in the peak RSS climb across phases (5.0GB at parallel-8 in
Phase 3). A small parallelism-sized pool of reusable buffers, returned after
each `compare()`, keeps peak RSS flat under load with zero semantic change.

### Changes

1. **`SnapshotTestingByteBufferPool`** in
   `Sources/SnapshotTesting/Snapshotting/Internal/ImageComparisonResources.swift`.
   - Pool of `(buffer: UnsafeMutableRawPointer, capacity: Int)` slots.
   - `acquire(byteCount:) -> Slot` — returns a slot with `capacity >= byteCount`,
     either reused from the pool or freshly allocated; resizes if the smallest
     pooled slot is too small.
   - `release(_ slot: Slot)` — returns the slot for reuse (LIFO so hot buffers
     stay hot in cache).
   - Bounded size from `SNAPSHOT_TESTING_BUFFER_POOL_SIZE` (default = clamp of
     `ProcessInfo.activeProcessorCount * 2` to `[2, 32]`); set to `0` to
     disable (always fresh allocation).
   - `@unchecked Sendable`, lock-protected.
2. **`compare()` rewrites** in both `UIImage.swift` and `NSImage.swift`:
   - Replace `var oldBytes = [UInt8](repeating: 0, count: byteCount)` with
     `let oldSlot = pool.acquire(byteCount: byteCount); defer { pool.release(oldSlot) }`.
   - Pass `oldSlot.buffer` to `context(for:data:)` (already accepts
     `UnsafeMutableRawPointer?`).
   - Same for `newBytes`. The precision loop indexes through
     `oldSlot.buffer.assumingMemoryBound(to: UInt8.self)` (an
     `UnsafeMutableBufferPointer<UInt8>` of length `byteCount`).
3. **`normalizedComponentDiff`** also acquires its two normalization buffers
   from the pool; the `[UInt8]` for `diffBytes` stays Swift-allocated since
   `vImage_Buffer` and `createCGImage` need a live Swift backing for the
   produced `CGImage`. (Or: also pool diffBytes if vImage `Buffer_Init` from
   raw pointer is used. Decide during implementation.)
4. Document env var in `README.md`.

### Verification

- Bench `--parallel 8` shows flatter / lower peak RSS than Phase 4 across all
  scenarios; `total_alloc` (if we add the counter) should drop sharply.
- Wall time should be ≤ Phase 4 (maybe slightly better from cache reuse,
  certainly not worse).
- Existing snapshot suite + edge-case tests stay green.
- New unit tests: pool returns correct-size buffers; pool reuses (same pointer
  returned after release/acquire); pool grows on contention; `release` is
  idempotent against double-call; env override works; setting to `0` disables.

### Risks

- Pointer aliasing: a buffer must not be returned while still in use. The
  `defer { release }` discipline + Swift's strict-mode borrow checking makes
  this safe in practice, but the unit tests should include a stress harness
  that fires `concurrentPerform` and verifies no two acquires share a slot.
- Buffer-size growth: an outlier 16K×16K image followed by 100 small images
  would keep a 1GB slot pinned. Mitigation: bound `slot.capacity` to
  `SNAPSHOT_TESTING_BUFFER_POOL_MAX_BYTES` (default 256MB, i.e. 8K×8K RGBA);
  oversize requests bypass the pool and free immediately.

### Results

Code: `c6b7d9e` · Bench: tracked under `bench-results/c6b7d9e-*.csv`
(vs `bench-results/a3c01cd-*.csv`).

| Metric | Phase 4 | Phase 5 | Δ vs Phase 4 |
|---|---|---|---|
| `exact-match-large` p50, serial | 4.53 ms | 3.02 ms | **−33%** |
| `exact-match-large` wall, parallel-4 | 323 ms | 271 ms | −16% |
| `exact-match-mixed` p50, serial | 1.46 ms | 1.31 ms | −11% |
| `exact-match-mixed` wall, parallel-8 | 1277 ms | 1165 ms | −9% |
| `exact-match-small` p50, serial | 13.8 µs | 10.5 µs | −24% |
| `precision-1px-diff` p50, serial | 1.75 ms | 1.25 ms | **−29%** |
| `precision-1px-diff` wall, parallel-4 | 173 ms | 120 ms | **−31%** |
| `precision-50pct-diff` p50, serial | 1.96 ms | 1.27 ms | **−35%** |
| `precision-50pct-diff` wall, parallel-4 | 166 ms | 136 ms | −18% |
| `precision-early-fail` p50, serial | 23.58 ms | 24.28 ms | +3% (noise) |
| `perceptual-pass` p50, serial | 6.07 ms | 6.16 ms | +1% (noise) |
| `perceptual-fail` p50, serial | 6.03 ms | 6.23 ms | +3% (noise) |
| Peak RSS, parallel-4 (exact-match-mixed) | 4.75 GB | 6.37 GB | +34% |
| Peak RSS, parallel-8 (exact-match-mixed) | 4.65 GB | 6.21 GB | +33% |

Notes:
- Wall-time wins are dominated by skipping the `[UInt8](repeating: 0, count:)`
  zero-fill on every call. The pool both avoids the allocation *and* avoids
  the memset; the latter is the bigger cut for the precision scenarios.
- `precision-50pct-diff` matched `precision-1px-diff` post-Phase-3 (both run
  the full byte loop, dominated by allocation + zero-fill). With those gone,
  the remaining work is the comparison itself.
- Pre-existing CGContext quirk surfaced by uninitialized pool memory: the
  default `.normal` blend mode mixes translucent source pixels with whatever
  bytes already live in the destination buffer. Fixed by setting `.copy`
  blend mode in `context(for:)`. Byte-equivalent on the pre-existing
  zero-initialized legacy path.
- Peak RSS regression on `exact-match-mixed` is the explicit trade-off:
  default pool size of `clamp(activeProcessorCount * 2, 2, 32)` retains up
  to ~16 buffers process-wide, each grown to fit the largest image seen.
  Still ~27% below the original (pre-Phase-1) baseline of 8.54 GB at
  parallel-8. Projects with tight RSS budgets can lower
  `SNAPSHOT_TESTING_BUFFER_POOL_SIZE` or set it to `0` to disable.
- `ImageNormalizationEdgeCasesTests` (12 tests covering Display P3,
  grayscale, non-premultiplied alpha) and the full XCTest suite (99 tests)
  pass under both the new path and `SNAPSHOT_TESTING_LEGACY_NORMALIZATION=1`.

---

## Phase 6 — Fast-path `context(for:)` for already-normalized images (highest impact)

The hot path always does `CGContext.draw(cgImage, …)` to produce the
sRGB+RGBA8+premultipliedLast normalized buffer. But reference PNGs (decoded
via `UIImage(data:)`) and snapshots produced through `UIGraphicsImageRenderer`
typically arrive in *exactly* that layout already. For those, rasterization
is wasted work — we could copy bytes straight from the source's
`dataProvider`. This is the clearest remaining swing on the same hot path
Phase 3 cracked open.

### Prerequisites

- Phase 5 (buffer pool) should land first. The fast-path still needs a
  destination buffer for the `memcpy`; the pool keeps it allocation-free.
- A diverse fixture suite that exercises the layouts we *don't* fast-path
  (P3, grayscale, non-premultiplied, padded `bytesPerRow`) — already largely
  present in `ImageNormalizationEdgeCasesTests.swift`; extend with padded-row
  + 16bpc + indexed-colorspace fixtures so the layout check is provably
  correct against a comprehensive matrix.

### Changes

1. **`isCanonicalNormalizedLayout(_ cgImage:) -> Bool`** in
   `Sources/SnapshotTesting/Snapshotting/Internal/ImageComparisonResources.swift`.
   Returns true iff *all* the following hold:
   - `cgImage.colorSpace?.name == CGColorSpace.sRGB` (exact match — not
     `displayP3`, not `extendedSRGB`).
   - `cgImage.bitsPerComponent == 8`.
   - `cgImage.bitsPerPixel == 32`.
   - `cgImage.alphaInfo == .premultipliedLast` (exactly).
   - `cgImage.byteOrderInfo == .orderDefault` or `.order32Big`.
   - `cgImage.bytesPerRow == cgImage.width * 4` (no row padding).
   - `cgImage.bitmapInfo` does *not* contain `.floatComponents`.
2. **`context(for:data:)` rewrite**: when `data` is non-nil and
   `isCanonicalNormalizedLayout(cgImage)` returns true, copy bytes directly:
   ```swift
   if let provider = cgImage.dataProvider, let cf = provider.data {
     let src = CFDataGetBytePtr(cf)!
     memcpy(data, src, byteCount)
     return nil  // signal: bytes were copied, no CGContext needed
   }
   ```
   Adjust `compare()` callers to handle the "no context needed" return path
   (they only use the context for its `data` pointer, which was already
   populated).
3. Behind a kill-switch env var
   (`SNAPSHOT_TESTING_DISABLE_NORMALIZED_FASTPATH=1`) for one release in case
   a project hits a layout the check misclassifies.

### Verification

- Bench: `exact-match-mixed` p50 serial should drop further (current 1.46ms;
  expect <1ms — most fixtures are sRGB+RGBA8 PNGs); `precision-*` p50
  similarly. Other scenarios unchanged.
- Edge-case suite (Phase 3 follow-up) must stay green: P3, grayscale,
  non-premultiplied images all take the slow path and produce identical
  output.
- New parity test: for each canonical-layout fixture, assert
  `fastPathBytes == drawBasedBytes` (run both paths, byte-compare).
- Run with `SNAPSHOT_TESTING_DISABLE_NORMALIZED_FASTPATH=1`: bench numbers
  should match Phase 5 exactly.

### Risks

- Layout-check completeness: missing a subtle bit in `CGImage.bitmapInfo` or
  misjudging `byteOrderInfo` would silently produce wrong bytes for
  fast-pathed images. Mitigation: parity test above + start with the strictest
  possible check (only the *exact* layout `context(for:)` produces today),
  loosen later if measurement justifies it.
- Performance regression for borderline-non-canonical images: the layout check
  is cheap (~10 property reads) but called per `compare()`. Should be
  unmeasurable, but verify in bench.

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
| 7 | Phase 6 (fast-path normalized layout) | medium | further drop on `exact-match-mixed` & `precision-*`; full edge-case suite green |

Each PR description includes the bench CSV diff vs. the baseline committed in `bench-baseline/`.

---

## Open questions to resolve before Phase 0 lands

1. Is `swift run snapshot-bench` acceptable as the run interface, or do you want a separate Xcode scheme too? yes
2. Where should `bench-baseline/` live — repo root, or `bench-results/baseline/`? best way you can think off
3. iOS-simulator bench runs in CI later, or macOS-host only? iOS-simulator bench runs too.
4. Does the project want the bench files to be excluded from the published `SnapshotTesting` library? (Yes — separate executable target keeps them out automatically.)
