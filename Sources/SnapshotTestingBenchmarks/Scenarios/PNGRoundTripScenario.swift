import Foundation

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit) || canImport(UIKit)
// Isolates the PNG encode/decode normalization that lives inside the current `compare()`
// implementations. After Phase 3 lands, the `compare()` paths skip this work entirely; this
// scenario quantifies how much we save by removing it.
struct PNGRoundTrip: Scenario {
  let name = "png-roundtrip"
  let iterations = 1_000
  private let image: BenchImage

  init() {
    image = ImageFactory.gradient(width: 1024, height: 1024)
  }

  func runOnce() {
    #if canImport(AppKit)
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
    let rep = NSBitmapImageRep(cgImage: cg)
    rep.size = image.size
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    _ = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    #else
    guard let data = image.pngData() else { return }
    _ = UIImage(data: data)?.cgImage
    #endif
  }
}
#endif
