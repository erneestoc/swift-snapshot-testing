#if os(macOS)
  import Cocoa
  import XCTest

  extension Diffing where Value == NSImage {
    /// A pixel-diffing strategy for NSImage's which requires a 100% match.
    public static let image = Diffing.image()

    /// A pixel-diffing strategy for NSImage that allows customizing how precise the matching must be.
    ///
    /// - Parameters:
    ///   - precision: The percentage of pixels that must match.
    ///   - perceptualPrecision: The percentage a pixel must match the source pixel to be considered a
    ///     match. 98-99% mimics
    ///     [the precision](http://zschuessler.github.io/DeltaE/learn/#toc-defining-delta-e) of the
    ///     human eye.
    /// - Returns: A new diffing strategy.
    public static func image(precision: Float = 1, perceptualPrecision: Float = 1) -> Diffing {
      return .diff(
        toData: { NSImagePNGRepresentation($0)! },
        fromData: { NSImage(data: $0)! }
      ) { old, new in
        autoreleasepool {
          guard
            let message = compare(
              old, new, precision: precision, perceptualPrecision: perceptualPrecision)
          else { return nil }
          let difference = SnapshotTesting.diff(old, new)
          let oldAttachment = DiffAttachment.data(NSImagePNGRepresentation(old)!, name: "reference.png")
          let newAttachment = DiffAttachment.data(NSImagePNGRepresentation(new)!, name: "failure.png")
          let differenceAttachment = DiffAttachment.data(NSImagePNGRepresentation(difference)!, name: "difference.png")
          return (
            message,
            [oldAttachment, newAttachment, differenceAttachment]
          )
        }
      }
    }
  }

  extension Snapshotting where Value == NSImage, Format == NSImage {
    /// A snapshot strategy for comparing images based on pixel equality.
    public static var image: Snapshotting {
      return .image()
    }

    /// A snapshot strategy for comparing images based on pixel equality.
    ///
    /// - Parameters:
    ///   - precision: The percentage of pixels that must match.
    ///   - perceptualPrecision: The percentage a pixel must match the source pixel to be considered a
    ///     match. 98-99% mimics
    ///     [the precision](http://zschuessler.github.io/DeltaE/learn/#toc-defining-delta-e) of the
    ///     human eye.
    public static func image(precision: Float = 1, perceptualPrecision: Float = 1) -> Snapshotting {
      return .init(
        pathExtension: "png",
        diffing: .image(precision: precision, perceptualPrecision: perceptualPrecision)
      )
    }
  }

  private func NSImagePNGRepresentation(_ image: NSImage) -> Data? {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return nil
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = image.size
    return rep.representation(using: .png, properties: [:])
  }

  private func compare(_ old: NSImage, _ new: NSImage, precision: Float, perceptualPrecision: Float)
    -> String?
  {
    guard let oldCgImage = old.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return "Reference image could not be loaded."
    }
    guard let newCgImage = new.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return "Newly-taken snapshot could not be loaded."
    }
    guard newCgImage.width != 0, newCgImage.height != 0 else {
      return "Newly-taken snapshot is empty."
    }
    guard oldCgImage.width == newCgImage.width, oldCgImage.height == newCgImage.height else {
      return "Newly-taken snapshot@\(new.size) does not match reference@\(old.size)."
    }
    let pixelCount = oldCgImage.width * oldCgImage.height
    let byteCount = imageContextBytesPerPixel * pixelCount
    var oldBytes = [UInt8](repeating: 0, count: byteCount)
    guard let oldData = context(for: oldCgImage, data: &oldBytes)?.data else {
      return "Reference image's data could not be loaded."
    }

    if snapshotTestingLegacyNormalization {
      return legacyCompareTail(
        oldCgImage: oldCgImage, newCgImage: newCgImage, new: new,
        oldBytes: oldBytes, oldData: oldData, byteCount: byteCount,
        precision: precision, perceptualPrecision: perceptualPrecision
      )
    }

    var newBytes = [UInt8](repeating: 0, count: byteCount)
    guard let newData = context(for: newCgImage, data: &newBytes)?.data else {
      return "Newly-taken snapshot's data could not be loaded."
    }
    if memcmp(oldData, newData, byteCount) == 0 { return nil }
    if precision >= 1, perceptualPrecision >= 1 {
      return "Newly-taken snapshot does not match reference."
    }
    if perceptualPrecision < 1, #available(macOS 10.13, *) {
      return SnapshotTestingImageDiffLimiter.shared.run {
        perceptuallyCompare(
          CIImage(cgImage: oldCgImage),
          CIImage(cgImage: newCgImage),
          pixelPrecision: precision,
          perceptualPrecision: perceptualPrecision
        )
      }
    } else {
      let byteCountThreshold = Int((1 - precision) * Float(byteCount))
      var differentByteCount = 0
      var index = 0
      while index < byteCount {
        if oldBytes[index] != newBytes[index] {
          differentByteCount += 1
          if differentByteCount > byteCountThreshold {
            return "Actual image precision is less than required \(precision)"
          }
        }
        index += 1
      }
    }
    return nil
  }

  // Original (pre-Phase-3) compare tail. Available behind
  // SNAPSHOT_TESTING_LEGACY_NORMALIZATION as a one-release escape hatch.
  private func legacyCompareTail(
    oldCgImage: CGImage, newCgImage: CGImage, new: NSImage,
    oldBytes: [UInt8], oldData: UnsafeMutableRawPointer, byteCount: Int,
    precision: Float, perceptualPrecision: Float
  ) -> String? {
    var newBytes = [UInt8](repeating: 0, count: byteCount)
    guard let newData = context(for: newCgImage, data: &newBytes)?.data else {
      return "Newly-taken snapshot's data could not be loaded."
    }
    if memcmp(oldData, newData, byteCount) == 0 { return nil }
    var newerBytes = [UInt8](repeating: 0, count: byteCount)
    guard
      let pngData = NSImagePNGRepresentation(new),
      let newerCgImage = NSImage(data: pngData)?.cgImage(
        forProposedRect: nil, context: nil, hints: nil),
      let newerData = context(for: newerCgImage, data: &newerBytes)?.data
    else {
      return "Newly-taken snapshot's data could not be loaded."
    }
    if memcmp(oldData, newerData, byteCount) == 0 { return nil }
    if precision >= 1, perceptualPrecision >= 1 {
      return "Newly-taken snapshot does not match reference."
    }
    if perceptualPrecision < 1, #available(macOS 10.13, *) {
      return SnapshotTestingImageDiffLimiter.shared.run {
        perceptuallyCompare(
          CIImage(cgImage: oldCgImage),
          CIImage(cgImage: newCgImage),
          pixelPrecision: precision,
          perceptualPrecision: perceptualPrecision
        )
      }
    } else {
      let byteCountThreshold = Int((1 - precision) * Float(byteCount))
      var differentByteCount = 0
      var index = 0
      while index < byteCount {
        if oldBytes[index] != newerBytes[index] {
          differentByteCount += 1
          if differentByteCount > byteCountThreshold {
            return "Actual image precision is less than required \(precision)"
          }
        }
        index += 1
      }
    }
    return nil
  }

  private let imageContextColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
  private let imageContextBitsPerComponent = 8
  private let imageContextBytesPerPixel = 4

  private func context(for cgImage: CGImage, data: UnsafeMutableRawPointer? = nil) -> CGContext? {
    let bytesPerRow = cgImage.width * imageContextBytesPerPixel
    guard
      let colorSpace = imageContextColorSpace,
      let context = CGContext(
        data: data,
        width: cgImage.width,
        height: cgImage.height,
        bitsPerComponent: imageContextBitsPerComponent,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }

    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
    return context
  }

  private func diff(_ old: NSImage, _ new: NSImage) -> NSImage {
    let oldCiImage = CIImage(cgImage: old.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
    let newCiImage = CIImage(cgImage: new.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
    let differenceFilter = CIFilter(name: "CIDifferenceBlendMode")!
    differenceFilter.setValue(oldCiImage, forKey: kCIInputImageKey)
    differenceFilter.setValue(newCiImage, forKey: kCIInputBackgroundImageKey)
    let maxSize = CGSize(
      width: max(old.size.width, new.size.width),
      height: max(old.size.height, new.size.height)
    )
    let rep = NSCIImageRep(ciImage: differenceFilter.outputImage!)
    let difference = NSImage(size: maxSize)
    difference.addRepresentation(rep)
    return difference
  }
#endif
