// Phase 3 follow-up: targeted regression coverage for the normalized-buffer
// compare path (UIImage.swift / NSImage.swift). Phase 3 dropped the historical
// PNG round-trip on the new image, betting that `context(for:)`'s sRGB +
// premultipliedLast normalization subsumed whatever alpha/colorspace surprises
// the round-trip was silently fixing. These tests construct CGImages with
// non-default bitmap layouts (non-premultiplied alpha, non-sRGB colorspace,
// grayscale) and verify the comparison still behaves correctly.

#if os(iOS) || os(tvOS) || os(macOS)
  import CoreGraphics
  import Foundation
  import XCTest

  @testable import SnapshotTesting

  #if os(iOS) || os(tvOS)
    import UIKit

    final class UIImageNormalizationEdgeCasesTests: XCTestCase {
      func testGrayscale_identicalImagesPass() {
        let cg = makeGrayscaleCGImage(value: 128)
        let diffing = Diffing<UIImage>.image()
        XCTAssertNil(diffing.diffV2(UIImage(cgImage: cg), UIImage(cgImage: cg)))
      }

      func testGrayscale_differentImagesFail() {
        let a = UIImage(cgImage: makeGrayscaleCGImage(value: 64))
        let b = UIImage(cgImage: makeGrayscaleCGImage(value: 200))
        let diffing = Diffing<UIImage>.image()
        let result = diffing.diffV2(a, b)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.1.count, 3, "expected reference + failure + difference attachments")
      }

      func testNonPremultipliedAlpha_identicalImagesPass() {
        let cg = makeNonPremultipliedRGBACGImage(red: 255, green: 0, blue: 0, alpha: 128)
        let diffing = Diffing<UIImage>.image()
        XCTAssertNil(diffing.diffV2(UIImage(cgImage: cg), UIImage(cgImage: cg)))
      }

      func testNonPremultipliedAlpha_differentImagesFail() {
        let a = UIImage(
          cgImage: makeNonPremultipliedRGBACGImage(red: 255, green: 0, blue: 0, alpha: 128))
        let b = UIImage(
          cgImage: makeNonPremultipliedRGBACGImage(red: 0, green: 255, blue: 0, alpha: 128))
        let diffing = Diffing<UIImage>.image()
        let result = diffing.diffV2(a, b)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.1.count, 3)
      }

      func testDisplayP3_identicalImagesPass() {
        let cg = makeDisplayP3CGImage(red: 1.0, green: 0.0, blue: 0.0)
        let diffing = Diffing<UIImage>.image()
        XCTAssertNil(diffing.diffV2(UIImage(cgImage: cg), UIImage(cgImage: cg)))
      }

      func testDisplayP3_differentImagesFail() {
        let a = UIImage(cgImage: makeDisplayP3CGImage(red: 1.0, green: 0.0, blue: 0.0))
        let b = UIImage(cgImage: makeDisplayP3CGImage(red: 0.0, green: 1.0, blue: 0.0))
        let diffing = Diffing<UIImage>.image()
        let result = diffing.diffV2(a, b)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.1.count, 3)
      }
    }
  #endif

  #if os(macOS)
    import AppKit

    final class NSImageNormalizationEdgeCasesTests: XCTestCase {
      func testGrayscale_identicalImagesPass() {
        let cg = makeGrayscaleCGImage(value: 128)
        let diffing = Diffing<NSImage>.image()
        XCTAssertNil(diffing.diffV2(nsImage(from: cg), nsImage(from: cg)))
      }

      func testGrayscale_differentImagesFail() {
        let a = nsImage(from: makeGrayscaleCGImage(value: 64))
        let b = nsImage(from: makeGrayscaleCGImage(value: 200))
        let diffing = Diffing<NSImage>.image()
        let result = diffing.diffV2(a, b)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.1.count, 3, "expected reference + failure + difference attachments")
      }

      func testNonPremultipliedAlpha_identicalImagesPass() {
        let cg = makeNonPremultipliedRGBACGImage(red: 255, green: 0, blue: 0, alpha: 128)
        let diffing = Diffing<NSImage>.image()
        XCTAssertNil(diffing.diffV2(nsImage(from: cg), nsImage(from: cg)))
      }

      func testNonPremultipliedAlpha_differentImagesFail() {
        let a = nsImage(
          from: makeNonPremultipliedRGBACGImage(red: 255, green: 0, blue: 0, alpha: 128))
        let b = nsImage(
          from: makeNonPremultipliedRGBACGImage(red: 0, green: 255, blue: 0, alpha: 128))
        let diffing = Diffing<NSImage>.image()
        let result = diffing.diffV2(a, b)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.1.count, 3)
      }

      func testDisplayP3_identicalImagesPass() {
        let cg = makeDisplayP3CGImage(red: 1.0, green: 0.0, blue: 0.0)
        let diffing = Diffing<NSImage>.image()
        XCTAssertNil(diffing.diffV2(nsImage(from: cg), nsImage(from: cg)))
      }

      func testDisplayP3_differentImagesFail() {
        let a = nsImage(from: makeDisplayP3CGImage(red: 1.0, green: 0.0, blue: 0.0))
        let b = nsImage(from: makeDisplayP3CGImage(red: 0.0, green: 1.0, blue: 0.0))
        let diffing = Diffing<NSImage>.image()
        let result = diffing.diffV2(a, b)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.1.count, 3)
      }

      private func nsImage(from cg: CGImage) -> NSImage {
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
      }
    }
  #endif

  // MARK: - Fixture builders

  private let edgeCaseSize = 32

  private func makeGrayscaleCGImage(value: UInt8) -> CGImage {
    let count = edgeCaseSize * edgeCaseSize
    let bytes = [UInt8](repeating: value, count: count)
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(
      width: edgeCaseSize,
      height: edgeCaseSize,
      bitsPerComponent: 8,
      bitsPerPixel: 8,
      bytesPerRow: edgeCaseSize,
      space: CGColorSpaceCreateDeviceGray(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )!
  }

  private func makeNonPremultipliedRGBACGImage(
    red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8
  ) -> CGImage {
    let pixel: [UInt8] = [red, green, blue, alpha]
    var bytes = [UInt8]()
    bytes.reserveCapacity(edgeCaseSize * edgeCaseSize * 4)
    for _ in 0..<(edgeCaseSize * edgeCaseSize) { bytes.append(contentsOf: pixel) }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(
      width: edgeCaseSize,
      height: edgeCaseSize,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: edgeCaseSize * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      // .last == non-premultiplied alpha last (RGBA, straight alpha)
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )!
  }

  private func makeDisplayP3CGImage(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
    let context = CGContext(
      data: nil,
      width: edgeCaseSize,
      height: edgeCaseSize,
      bitsPerComponent: 8,
      bytesPerRow: edgeCaseSize * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(
      CGColor(colorSpace: colorSpace, components: [red, green, blue, 1])!
    )
    context.fill(CGRect(x: 0, y: 0, width: edgeCaseSize, height: edgeCaseSize))
    return context.makeImage()!
  }
#endif
