#if os(iOS) || os(tvOS) || os(macOS)
  import Accelerate.vImage
  import CoreGraphics
  import Foundation

  // Canonical destination layout for image comparison. Must match the
  // CGContext that the legacy `context(for:)` callers used so the byte
  // semantics of memcmp / per-byte precision walks are unchanged.
  private let canonicalCompareColorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  private let canonicalCompareBitsPerComponent: Int = 8
  private let canonicalCompareBytesPerPixel: Int = 4
  private let canonicalCompareBitmapInfo: CGBitmapInfo =
    CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

  /// Process-wide cache of `vImageConverter` instances keyed by the source
  /// CGImage's pixel format. Converter creation involves picking optimal
  /// SIMD kernels and is amortizable across calls; in a typical suite the
  /// same one or two source formats recur for every comparison.
  private final class CompareConverterCache: @unchecked Sendable {
    struct Key: Hashable {
      let bitsPerComponent: UInt32
      let bitsPerPixel: UInt32
      let bitmapInfo: UInt32
      let colorSpaceName: String
      let renderingIntent: Int32
    }

    private let lock = NSLock()
    private var cache: [Key: vImageConverter] = [:]

    static let shared = CompareConverterCache()

    func converter(forSourceFormat srcFormat: inout vImage_CGImageFormat,
                   destFormat: inout vImage_CGImageFormat,
                   key: Key?) -> vImageConverter? {
      if let key {
        lock.lock()
        let cached = cache[key]
        lock.unlock()
        if let cached { return cached }
      }
      var error: vImage_Error = kvImageNoError
      guard let unmanaged = vImageConverter_CreateWithCGImageFormat(
        &srcFormat, &destFormat, nil, vImage_Flags(kvImageNoFlags), &error
      ) else { return nil }
      let converter = unmanaged.takeRetainedValue()
      if let key {
        lock.lock()
        cache[key] = converter
        lock.unlock()
      }
      return converter
    }
  }

  /// Fill `buffer` (size = `width * height * 4`) with the pixels of `cgImage`
  /// converted to the canonical compare layout (sRGB / RGBA8 /
  /// premultipliedLast / tight stride). Returns `true` on success.
  ///
  /// Tries vImage first — its SIMD converters are typically 2–3× faster than
  /// `CGContext.draw` on the format pairs the snapshot pipeline produces.
  /// Falls back to `CGContext.draw` for source formats vImage rejects (rare:
  /// indexed color, planar layouts, exotic float formats).
  @discardableResult
  func loadNormalizedCompareBuffer(
    from cgImage: CGImage,
    into buffer: UnsafeMutableRawPointer
  ) -> Bool {
    let width = cgImage.width
    let height = cgImage.height
    let bytesPerRow = width * canonicalCompareBytesPerPixel

    if loadCompareBufferViaVImage(
      cgImage: cgImage, buffer: buffer,
      width: width, height: height, bytesPerRow: bytesPerRow
    ) {
      return true
    }

    // CGContext.draw fallback. Identical to the historic `context(for:)` path.
    guard let context = CGContext(
      data: buffer,
      width: width,
      height: height,
      bitsPerComponent: canonicalCompareBitsPerComponent,
      bytesPerRow: bytesPerRow,
      space: canonicalCompareColorSpace,
      bitmapInfo: canonicalCompareBitmapInfo.rawValue
    ) else { return false }
    context.setBlendMode(.copy)
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
  }

  private func loadCompareBufferViaVImage(
    cgImage: CGImage,
    buffer: UnsafeMutableRawPointer,
    width: Int,
    height: Int,
    bytesPerRow: Int
  ) -> Bool {
    guard let sourceColorSpace = cgImage.colorSpace else { return false }

    var srcFormat = vImage_CGImageFormat(
      bitsPerComponent: UInt32(cgImage.bitsPerComponent),
      bitsPerPixel: UInt32(cgImage.bitsPerPixel),
      colorSpace: Unmanaged.passUnretained(sourceColorSpace),
      bitmapInfo: cgImage.bitmapInfo,
      version: 0,
      decode: nil,
      renderingIntent: cgImage.renderingIntent
    )
    var destFormat = vImage_CGImageFormat(
      bitsPerComponent: UInt32(canonicalCompareBitsPerComponent),
      bitsPerPixel: UInt32(canonicalCompareBytesPerPixel * 8),
      colorSpace: Unmanaged.passUnretained(canonicalCompareColorSpace),
      bitmapInfo: canonicalCompareBitmapInfo,
      version: 0,
      decode: nil,
      renderingIntent: .defaultIntent
    )

    let cacheKey: CompareConverterCache.Key? = {
      guard let name = sourceColorSpace.name as String? else { return nil }
      return CompareConverterCache.Key(
        bitsPerComponent: srcFormat.bitsPerComponent,
        bitsPerPixel: srcFormat.bitsPerPixel,
        bitmapInfo: srcFormat.bitmapInfo.rawValue,
        colorSpaceName: name,
        renderingIntent: cgImage.renderingIntent.rawValue
      )
    }()

    guard let converter = CompareConverterCache.shared.converter(
      forSourceFormat: &srcFormat,
      destFormat: &destFormat,
      key: cacheKey
    ) else { return false }

    // Materialize the source bytes into a vImage_Buffer. For CGImages backed
    // by an in-memory CGDataProvider this is a copy; for callback providers
    // it triggers the synchronous decode that CGContext.draw would also have
    // forced.
    var srcBuffer = vImage_Buffer()
    let initError = vImageBuffer_InitWithCGImage(
      &srcBuffer, &srcFormat, nil, cgImage, vImage_Flags(kvImageNoFlags)
    )
    guard initError == kvImageNoError else { return false }
    defer { free(srcBuffer.data) }

    var dstBuffer = vImage_Buffer(
      data: buffer,
      height: vImagePixelCount(height),
      width: vImagePixelCount(width),
      rowBytes: bytesPerRow
    )

    let convertError = vImageConvert_AnyToAny(
      converter, &srcBuffer, &dstBuffer, nil, vImage_Flags(kvImageNoFlags)
    )
    return convertError == kvImageNoError
  }
#endif
