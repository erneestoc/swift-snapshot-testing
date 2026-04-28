import Foundation
import SnapshotTesting

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit) || canImport(UIKit)
struct Precision1pxDiff: Scenario {
  let name = "precision-1px-diff"
  let iterations = 1_000
  private let diffing: Diffing<BenchImage>
  private let old: BenchImage
  private let new: BenchImage

  init() {
    diffing = .image(precision: 0.999)
    let base = ImageFactory.gradient(width: 1024, height: 1024)
    old = base
    new = ImageFactory.singlePixelDiff(base)
  }

  func runOnce() {
    _ = diffing.diffV2(old, new)
  }
}

// 50% pixels mutated, threshold loose enough to pass: drives full byte loop on `newer`.
struct Precision50pctDiff: Scenario {
  let name = "precision-50pct-diff"
  let iterations = 1_000
  private let diffing: Diffing<BenchImage>
  private let old: BenchImage
  private let new: BenchImage

  init() {
    // Setting `precision` to 0 forces the precision branch but never fails on byte threshold,
    // exercising the full byte-by-byte loop on the post-PNG-roundtrip buffer.
    diffing = .image(precision: 0)
    let base = ImageFactory.gradient(width: 1024, height: 1024)
    old = base
    new = ImageFactory.percentDiff(base, fraction: 0.5)
  }

  func runOnce() {
    _ = diffing.diffV2(old, new)
  }
}

// Large diff with tight precision: should fail almost immediately under Phase 1 early-exit.
struct PrecisionEarlyFail: Scenario {
  let name = "precision-early-fail"
  let iterations = 1_000
  private let diffing: Diffing<BenchImage>
  private let old: BenchImage
  private let new: BenchImage

  init() {
    diffing = .image(precision: 0.99)
    let base = ImageFactory.gradient(width: 1024, height: 1024)
    old = base
    new = ImageFactory.percentDiff(base, fraction: 0.5)
  }

  func runOnce() {
    _ = diffing.diffV2(old, new)
  }
}
#endif
