import Foundation
import SnapshotTesting

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit) || canImport(UIKit)
// iPhone 15 Pro: 1179×2556 (≈12 MB per RGBA buffer).
struct IPhoneExactMatch: Scenario {
  let name = "iphone-exact-match"
  let iterations = 1_000
  private let diffing: Diffing<BenchImage>
  private let old: BenchImage
  private let new: BenchImage

  init() {
    diffing = .image()
    let img = ImageFactory.iphoneScreenshot()
    old = img
    new = img
  }

  func runOnce() {
    _ = diffing.diffV2(old, new)
  }
}

struct IPhone1pxDiff: Scenario {
  let name = "iphone-1px-diff"
  let iterations = 1_000
  private let diffing: Diffing<BenchImage>
  private let old: BenchImage
  private let new: BenchImage

  init() {
    // precision 0 forces the full byte-loop path on the 12 MB buffer.
    diffing = .image(precision: 0)
    let base = ImageFactory.iphoneScreenshot()
    old = base
    new = ImageFactory.iphoneScreenshotWithDiff(at: 0)
  }

  func runOnce() {
    _ = diffing.diffV2(old, new)
  }
}

struct IPhonePrecision99: Scenario {
  let name = "iphone-precision-99"
  let iterations = 500
  private let diffing: Diffing<BenchImage>
  private let old: BenchImage
  private let new: BenchImage

  init() {
    diffing = .image(precision: 0.99)
    let base = ImageFactory.iphoneScreenshot()
    old = base
    new = ImageFactory.percentDiff(base, fraction: 0.004)  // ~0.4% of pixels
  }

  func runOnce() {
    _ = diffing.diffV2(old, new)
  }
}

// iPad Pro 13": 2064×2752 (≈22 MB per RGBA buffer).
struct IPadExactMatch: Scenario {
  let name = "ipad-exact-match"
  let iterations = 500
  private let diffing: Diffing<BenchImage>
  private let old: BenchImage
  private let new: BenchImage

  init() {
    diffing = .image()
    let img = ImageFactory.ipadScreenshot()
    old = img
    new = img
  }

  func runOnce() {
    _ = diffing.diffV2(old, new)
  }
}

struct IPad1pxDiff: Scenario {
  let name = "ipad-1px-diff"
  let iterations = 500
  private let diffing: Diffing<BenchImage>
  private let old: BenchImage
  private let new: BenchImage

  init() {
    diffing = .image(precision: 0)
    let base = ImageFactory.ipadScreenshot()
    old = base
    new = ImageFactory.ipadScreenshotWithDiff(at: 0)
  }

  func runOnce() {
    _ = diffing.diffV2(old, new)
  }
}

struct IPadPrecision99: Scenario {
  let name = "ipad-precision-99"
  let iterations = 250
  private let diffing: Diffing<BenchImage>
  private let old: BenchImage
  private let new: BenchImage

  init() {
    diffing = .image(precision: 0.99)
    let base = ImageFactory.ipadScreenshot()
    old = base
    new = ImageFactory.percentDiff(base, fraction: 0.004)
  }

  func runOnce() {
    _ = diffing.diffV2(old, new)
  }
}

struct IPhonePerceptualPass: Scenario {
  let name = "iphone-perceptual-pass"
  let iterations = 250
  private let diffing: Diffing<BenchImage>
  private let old: BenchImage
  private let new: BenchImage

  init() {
    diffing = .image(precision: 1, perceptualPrecision: 0.99)
    let base = ImageFactory.iphoneScreenshot()
    old = base
    new = ImageFactory.nearlyIdentical(base, delta: 1)
  }

  func runOnce() {
    _ = diffing.diffV2(old, new)
  }
}
#endif
