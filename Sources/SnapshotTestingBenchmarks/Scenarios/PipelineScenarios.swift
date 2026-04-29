#if os(macOS)
import AppKit
import Foundation
import SnapshotTesting

// Per-stage timings for one pipeline iteration. Stage order matches
// `PipelineScenario.stageNames`.
//
// `attachments_ns` for the success path is always 0 — diffV2 returns nil
// before building any attachments. For the failure path it's approximated
// as `(diffV2 against differing reference) - (diffV2 against same image)`,
// since the library doesn't expose a hook to time attachment generation in
// isolation. Negative deltas are clamped to 0.
private struct StageTimings {
  var renderNs: UInt64 = 0
  var readNs: UInt64 = 0
  var decodeNs: UInt64 = 0
  var compareNs: UInt64 = 0
  var attachmentsNs: UInt64 = 0

  var asArray: [UInt64] { [renderNs, readNs, decodeNs, compareNs, attachmentsNs] }
}

private let pipelineStageNames = ["render", "read", "decode", "compare", "attachments"]

private final class PipelineState {
  let view: NSView
  let referenceURL: URL
  let snapshotting: Snapshotting<NSView, NSImage>
  let diffing: Diffing<NSImage>
  let isFailureScenario: Bool
  /// AppKit rendering on a single shared NSView is not safe to invoke
  /// concurrently from multiple workers. Serialize the render block so the
  /// `--parallel N` modes don't crash; per-iter timings still reflect the
  /// real cost, contention will inflate p95/wall.
  let renderLock = NSLock()

  init(
    view: NSView,
    referenceURL: URL,
    snapshotting: Snapshotting<NSView, NSImage>,
    diffing: Diffing<NSImage>,
    isFailureScenario: Bool
  ) {
    self.view = view
    self.referenceURL = referenceURL
    self.snapshotting = snapshotting
    self.diffing = diffing
    self.isFailureScenario = isFailureScenario
  }
}

private enum PipelineHelpers {
  static let scratchRoot: URL = {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("snapshot-bench-pipeline-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }()

  static func referenceURL(named name: String) -> URL {
    scratchRoot.appendingPathComponent("\(name).png")
  }

  /// Render the view once to seed `referenceURL`. For the failure scenario,
  /// we additionally tweak one pixel of the rendered image so the in-test
  /// render mismatches the on-disk reference.
  static func writeReference(
    view: NSView,
    snapshotting: Snapshotting<NSView, NSImage>,
    diffing: Diffing<NSImage>,
    referenceURL: URL,
    failureMode: Bool
  ) {
    var captured: NSImage?
    snapshotting.snapshot(view).run { captured = $0 }
    guard var image = captured else {
      fatalError("pipeline scenario failed to render reference for \(referenceURL.lastPathComponent)")
    }
    if failureMode {
      image = perturbedReference(image)
    }
    let data = diffing.toData(image)
    try? FileManager.default.createDirectory(
      at: referenceURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try? data.write(to: referenceURL)
  }

  /// Decode → flip one pixel → re-encode through the diffing strategy. Used
  /// only by failure-path scenarios so the on-disk reference deliberately
  /// differs from what each render produces.
  private static func perturbedReference(_ image: NSImage) -> NSImage {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return image
    }
    let width = cg.width
    let height = cg.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    bytes.withUnsafeMutableBytes { buf in
      let context = CGContext(
        data: buf.baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
      context?.setBlendMode(.copy)
      context?.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    bytes[0] = bytes[0] &+ 1
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let mutated = CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )!
    return NSImage(cgImage: mutated, size: NSSize(width: width, height: height))
  }
}

// MARK: - Stage runner

private func runStaged(_ state: PipelineState) -> [UInt64] {
  var t = StageTimings()

  // Render. Held under a per-state lock because AppKit views are not safe
  // to render concurrently from multiple workers.
  state.renderLock.lock()
  var produced: NSImage?
  let r0 = BenchClock.now()
  state.snapshotting.snapshot(state.view).run { produced = $0 }
  let r1 = BenchClock.now()
  state.renderLock.unlock()
  t.renderNs = BenchClock.nanoseconds(from: r0, to: r1)
  guard let newImage = produced else {
    fatalError("pipeline scenario render produced no image")
  }

  // Read reference PNG from disk.
  let read0 = BenchClock.now()
  let data: Data
  do {
    data = try Data(contentsOf: state.referenceURL)
  } catch {
    fatalError("pipeline scenario could not read \(state.referenceURL.path): \(error)")
  }
  let read1 = BenchClock.now()
  t.readNs = BenchClock.nanoseconds(from: read0, to: read1)

  // Decode reference NSImage from PNG bytes.
  let d0 = BenchClock.now()
  let referenceImage = state.diffing.fromData(data)
  let d1 = BenchClock.now()
  t.decodeNs = BenchClock.nanoseconds(from: d0, to: d1)

  if state.isFailureScenario {
    // Pure compare baseline: newImage vs newImage exits via memcmp without
    // any attachment work.
    let c0 = BenchClock.now()
    _ = state.diffing.diffV2(newImage, newImage)
    let c1 = BenchClock.now()
    t.compareNs = BenchClock.nanoseconds(from: c0, to: c1)

    // Full failure-path call: compare + attachment generation.
    let a0 = BenchClock.now()
    _ = state.diffing.diffV2(referenceImage, newImage)
    let a1 = BenchClock.now()
    let combined = BenchClock.nanoseconds(from: a0, to: a1)
    t.attachmentsNs = combined > t.compareNs ? combined - t.compareNs : 0
  } else {
    let c0 = BenchClock.now()
    _ = state.diffing.diffV2(referenceImage, newImage)
    let c1 = BenchClock.now()
    t.compareNs = BenchClock.nanoseconds(from: c0, to: c1)
    t.attachmentsNs = 0
  }

  return t.asArray
}

// MARK: - Scenarios

private func makeSmallFlatView() -> NSView {
  let label = NSTextField(labelWithString: "Hello, snapshot.")
  label.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
  let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
  host.addSubview(label)
  return host
}

private func makeMediumStackView() -> NSView {
  let stack = NSStackView()
  stack.orientation = .vertical
  stack.alignment = .leading
  stack.spacing = 8
  for i in 0..<5 {
    let field = NSTextField(labelWithString: "Row \(i): the quick brown fox jumps over.")
    stack.addArrangedSubview(field)
  }
  let imageView = NSImageView()
  imageView.image = ImageFactory.solid(width: 200, height: 60, rgba: (40, 90, 200, 255))
  imageView.frame = NSRect(x: 0, y: 0, width: 200, height: 60)
  stack.addArrangedSubview(imageView)
  stack.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
  stack.layoutSubtreeIfNeeded()
  return stack
}

private func makeLargeIPhoneView() -> NSView {
  let imageView = NSImageView()
  imageView.image = ImageFactory.iphoneScreenshot()
  imageView.imageScaling = .scaleAxesIndependently
  imageView.frame = NSRect(x: 0, y: 0, width: 1179, height: 2556)
  return imageView
}

struct PipelineSmallFlat: StagedScenario {
  let name = "pipeline-small-flat"
  let iterations = 1_000
  let stageNames = pipelineStageNames
  private let state: PipelineState

  init() {
    let view = makeSmallFlatView()
    let snap: Snapshotting<NSView, NSImage> = .image
    let diff = snap.diffing
    let url = PipelineHelpers.referenceURL(named: name)
    PipelineHelpers.writeReference(
      view: view, snapshotting: snap, diffing: diff,
      referenceURL: url, failureMode: false
    )
    self.state = PipelineState(
      view: view, referenceURL: url, snapshotting: snap, diffing: diff,
      isFailureScenario: false
    )
  }

  func runOnceStaged() -> [UInt64] { runStaged(state) }
}

struct PipelineMediumStack: StagedScenario {
  let name = "pipeline-medium-stack"
  let iterations = 500
  let stageNames = pipelineStageNames
  private let state: PipelineState

  init() {
    let view = makeMediumStackView()
    let snap: Snapshotting<NSView, NSImage> = .image
    let diff = snap.diffing
    let url = PipelineHelpers.referenceURL(named: name)
    PipelineHelpers.writeReference(
      view: view, snapshotting: snap, diffing: diff,
      referenceURL: url, failureMode: false
    )
    self.state = PipelineState(
      view: view, referenceURL: url, snapshotting: snap, diffing: diff,
      isFailureScenario: false
    )
  }

  func runOnceStaged() -> [UInt64] { runStaged(state) }
}

struct PipelineLargeIPhone: StagedScenario {
  let name = "pipeline-large-iphone"
  let iterations = 250
  let stageNames = pipelineStageNames
  private let state: PipelineState

  init() {
    let view = makeLargeIPhoneView()
    let snap: Snapshotting<NSView, NSImage> = .image
    let diff = snap.diffing
    let url = PipelineHelpers.referenceURL(named: name)
    PipelineHelpers.writeReference(
      view: view, snapshotting: snap, diffing: diff,
      referenceURL: url, failureMode: false
    )
    self.state = PipelineState(
      view: view, referenceURL: url, snapshotting: snap, diffing: diff,
      isFailureScenario: false
    )
  }

  func runOnceStaged() -> [UInt64] { runStaged(state) }
}

struct PipelineLargeIPhoneFail: StagedScenario {
  let name = "pipeline-large-iphone-fail"
  let iterations = 250
  let stageNames = pipelineStageNames
  private let state: PipelineState

  init() {
    let view = makeLargeIPhoneView()
    let snap: Snapshotting<NSView, NSImage> = .image
    let diff = snap.diffing
    let url = PipelineHelpers.referenceURL(named: name)
    PipelineHelpers.writeReference(
      view: view, snapshotting: snap, diffing: diff,
      referenceURL: url, failureMode: true
    )
    self.state = PipelineState(
      view: view, referenceURL: url, snapshotting: snap, diffing: diff,
      isFailureScenario: true
    )
  }

  func runOnceStaged() -> [UInt64] { runStaged(state) }
}
#endif
