import Foundation

#if canImport(AppKit)
import AppKit

typealias BenchImage = NSImage
#elseif canImport(UIKit)
import UIKit

typealias BenchImage = UIImage
#endif

#if canImport(AppKit) || canImport(UIKit)
import CoreGraphics

enum ImageFactory {
  private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  private static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

  static func cgImage(width: Int, height: Int, bytes: [UInt8]) -> CGImage {
    precondition(bytes.count == width * height * 4)
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )!
  }

  static func image(from cg: CGImage) -> BenchImage {
    #if canImport(AppKit)
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    #else
    return UIImage(cgImage: cg)
    #endif
  }

  static func solid(width: Int, height: Int, rgba: (UInt8, UInt8, UInt8, UInt8)) -> BenchImage {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    var i = 0
    while i < bytes.count {
      bytes[i] = rgba.0
      bytes[i + 1] = rgba.1
      bytes[i + 2] = rgba.2
      bytes[i + 3] = rgba.3
      i += 4
    }
    return image(from: cgImage(width: width, height: height, bytes: bytes))
  }

  static func gradient(width: Int, height: Int) -> BenchImage {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    var y = 0
    while y < height {
      let v = UInt8((y * 255) / max(1, height - 1))
      var x = 0
      while x < width {
        let offset = (y * width + x) * 4
        bytes[offset] = v
        bytes[offset + 1] = v
        bytes[offset + 2] = v
        bytes[offset + 3] = 255
        x += 1
      }
      y += 1
    }
    return image(from: cgImage(width: width, height: height, bytes: bytes))
  }

  static func noise(width: Int, height: Int, seed: UInt64) -> BenchImage {
    var state = seed == 0 ? 0xDEAD_BEEF_CAFE_BABE : seed
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    var i = 0
    while i < bytes.count {
      state ^= state << 13
      state ^= state >> 7
      state ^= state << 17
      bytes[i] = UInt8(truncatingIfNeeded: state)
      bytes[i + 1] = UInt8(truncatingIfNeeded: state >> 8)
      bytes[i + 2] = UInt8(truncatingIfNeeded: state >> 16)
      bytes[i + 3] = 255
      i += 4
    }
    return image(from: cgImage(width: width, height: height, bytes: bytes))
  }

  static func bytes(of image: BenchImage) -> [UInt8]? {
    guard let cg = cgImage(of: image) else { return nil }
    let width = cg.width
    let height = cg.height
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
      data: &buffer,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: bitmapInfo
    )
    context?.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
  }

  static func cgImage(of image: BenchImage) -> CGImage? {
    #if canImport(AppKit)
    return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    #else
    return image.cgImage
    #endif
  }

  static func mutating(_ image: BenchImage, _ transform: (inout [UInt8]) -> Void) -> BenchImage {
    guard let cg = cgImage(of: image), var buffer = bytes(of: image) else { return image }
    transform(&buffer)
    return self.image(from: cgImage(width: cg.width, height: cg.height, bytes: buffer))
  }

  static func singlePixelDiff(_ base: BenchImage) -> BenchImage {
    return mutating(base) { bytes in
      // Toggle the red component of pixel 0 (idempotent across runs).
      bytes[0] = bytes[0] &+ 1
    }
  }

  static func percentDiff(_ base: BenchImage, fraction: Double) -> BenchImage {
    return mutating(base) { bytes in
      let pixelCount = bytes.count / 4
      let toChange = max(1, Int(Double(pixelCount) * fraction))
      var changed = 0
      var i = 0
      while changed < toChange && i < bytes.count {
        bytes[i] = bytes[i] &+ 64
        bytes[i + 1] = bytes[i + 1] &+ 64
        bytes[i + 2] = bytes[i + 2] &+ 64
        i += 4
        changed += 1
      }
    }
  }

  static func nearlyIdentical(_ base: BenchImage, delta: UInt8 = 1) -> BenchImage {
    return mutating(base) { bytes in
      var i = 0
      while i < bytes.count {
        bytes[i] = bytes[i] &+ delta
        bytes[i + 1] = bytes[i + 1] &+ delta
        bytes[i + 2] = bytes[i + 2] &+ delta
        i += 4
      }
    }
  }

  // Resolve repo root from this file's path so the bench can find Tests/__Snapshots__ at runtime.
  private static let repoRoot: URL = {
    let here = URL(fileURLWithPath: #filePath)
    return here
      .deletingLastPathComponent()  // Fixtures
      .deletingLastPathComponent()  // SnapshotTestingBenchmarks
      .deletingLastPathComponent()  // Sources
      .deletingLastPathComponent()  // repo root
  }()

  static func realFixtureURLs(limit: Int? = nil) -> [URL] {
    let snapshotsDir = repoRoot
      .appendingPathComponent("Tests")
      .appendingPathComponent("SnapshotTestingTests")
      .appendingPathComponent("__Snapshots__")
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: snapshotsDir, includingPropertiesForKeys: nil) else {
      return []
    }
    var urls = [URL]()
    for case let url as URL in enumerator where url.pathExtension.lowercased() == "png" {
      urls.append(url)
      if let limit, urls.count >= limit { break }
    }
    return urls.sorted { $0.path < $1.path }
  }

  static func loadImage(at url: URL) -> BenchImage? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    #if canImport(AppKit)
    return NSImage(data: data)
    #else
    return UIImage(data: data)
    #endif
  }
}
#endif
