# UIImage / NSImage Snapshot Performance Plan

## Progress log (resumable)

- **Phase 0** ✅ committed `6e3461a`. `SnapshotTestingBenchmarks` executable target,
  `scripts/bench.sh`, baselines under `bench-baseline/pre-phase1-{serial,parallel-4,parallel-8}.csv`.
- **Phase 1** in progress. Edits applied in working tree, build green, awaiting commit + bench run.
- **Phase 2/3/4** pending.

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

---

## Phase 4 — Diff API modernization

### Changes

- Replace `UIGraphicsBeginImageContextWithOptions` / `UIGraphicsEndImageContext` in `blendModeDiff` (`UIImage.swift:185-195`) with `UIGraphicsImageRenderer`.

### Verification

- Bench delta expected to be small.
- Visual diff of generated `difference.png` against current implementation across 5 fixture pairs — pixels should match within rounding.

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

Each PR description includes the bench CSV diff vs. the baseline committed in `bench-baseline/`.

---

## Open questions to resolve before Phase 0 lands

1. Is `swift run snapshot-bench` acceptable as the run interface, or do you want a separate Xcode scheme too? yes
2. Where should `bench-baseline/` live — repo root, or `bench-results/baseline/`? best way you can think off
3. iOS-simulator bench runs in CI later, or macOS-host only? iOS-simulator bench runs too.
4. Does the project want the bench files to be excluded from the published `SnapshotTesting` library? (Yes — separate executable target keeps them out automatically.)
