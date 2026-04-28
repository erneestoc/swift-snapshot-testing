import Foundation
import SnapshotTesting

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit) || canImport(UIKit)
struct PerceptualPass: Scenario {
  let name = "perceptual-pass"
  let iterations = 500
  private let diffing: Diffing<BenchImage>
  private let old: BenchImage
  private let new: BenchImage

  init() {
    diffing = .image(precision: 1, perceptualPrecision: 0.98)
    let base = ImageFactory.gradient(width: 512, height: 512)
    old = base
    new = ImageFactory.nearlyIdentical(base, delta: 1)
  }

  func runOnce() {
    _ = diffing.diffV2(old, new)
  }
}

struct PerceptualFail: Scenario {
  let name = "perceptual-fail"
  let iterations = 500
  private let diffing: Diffing<BenchImage>
  private let old: BenchImage
  private let new: BenchImage

  init() {
    diffing = .image(precision: 1, perceptualPrecision: 0.98)
    let base = ImageFactory.gradient(width: 512, height: 512)
    old = base
    new = ImageFactory.percentDiff(base, fraction: 0.5)
  }

  func runOnce() {
    _ = diffing.diffV2(old, new)
  }
}
#endif
