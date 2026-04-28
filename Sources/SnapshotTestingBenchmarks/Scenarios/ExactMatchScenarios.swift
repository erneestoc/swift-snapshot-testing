import Foundation
import SnapshotTesting

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit) || canImport(UIKit)
struct ExactMatchSmall: Scenario {
  let name = "exact-match-small"
  let iterations = 5_000
  private let diffing: Diffing<BenchImage>
  private let old: BenchImage
  private let new: BenchImage

  init() {
    diffing = .image()
    let img = ImageFactory.solid(width: 100, height: 100, rgba: (32, 64, 128, 255))
    old = img
    new = img
  }

  func runOnce() {
    _ = diffing.diffV2(old, new)
  }
}

struct ExactMatchLarge: Scenario {
  let name = "exact-match-large"
  let iterations = 200
  private let diffing: Diffing<BenchImage>
  private let old: BenchImage
  private let new: BenchImage

  init() {
    diffing = .image()
    let img = ImageFactory.gradient(width: 4096, height: 4096)
    old = img
    new = img
  }

  func runOnce() {
    _ = diffing.diffV2(old, new)
  }
}

struct ExactMatchMixed: Scenario {
  let name = "exact-match-mixed"
  let iterations = 2_000
  private let diffing: Diffing<BenchImage>
  private let images: [BenchImage]

  init() {
    diffing = .image()
    let urls = ImageFactory.realFixtureURLs(limit: 64)
    images = urls.compactMap { ImageFactory.loadImage(at: $0) }
  }

  func setUp() {
    if images.isEmpty {
      FileHandle.standardError.write(
        Data("warning: exact-match-mixed found no real fixtures\n".utf8)
      )
    }
  }

  func runOnce() {
    guard !images.isEmpty else { return }
    let i = Int.random(in: 0..<images.count)
    let img = images[i]
    _ = diffing.diffV2(img, img)
  }
}
#endif
