#if canImport(CoreImage) && (os(iOS) || os(tvOS) || os(macOS))
  import CoreImage
  import Foundation

  /// Round-robin pool of reusable `CIContext` instances used by the perceptual
  /// image-diff path.
  ///
  /// `CIContext` allocation is expensive and tied to process-wide GPU/CPU
  /// resources. Allocating a fresh context per `compare()` call (the previous
  /// behavior) produced "Context leak detected" warnings and elevated peak RSS
  /// in highly parallel test runs. The pool fixes a small number of contexts at
  /// process start and hands them out round-robin.
  ///
  /// Pool size is read once from `SNAPSHOT_TESTING_CI_CONTEXT_POOL_SIZE`,
  /// clamped to `[1, 4]`. Default is `2`.
  @available(iOS 10.0, tvOS 10.0, macOS 10.13, *)
  final class SnapshotTestingCIContextPool: @unchecked Sendable {
    private let lock = NSLock()
    private var nextIndex = 0
    let contexts: [CIContext]

    init(size: Int) {
      let clamped = min(max(size, 1), 4)
      self.contexts = (0..<clamped).map { _ in
        CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
      }
    }

    func next() -> CIContext {
      lock.lock()
      defer { lock.unlock() }
      let context = contexts[nextIndex]
      nextIndex = (nextIndex + 1) % contexts.count
      return context
    }

    static let shared = SnapshotTestingCIContextPool(
      size: parsePoolSize(
        ProcessInfo.processInfo.environment["SNAPSHOT_TESTING_CI_CONTEXT_POOL_SIZE"]
      )
    )
  }

  func parsePoolSize(_ raw: String?) -> Int {
    guard let raw, let parsed = Int(raw) else { return 2 }
    return min(max(parsed, 1), 4)
  }

  /// Bounds the number of perceptual image comparisons that can run
  /// concurrently.
  ///
  /// The perceptual diff path (`CILabDeltaE` + Metal kernels, or the CPU vImage
  /// fallback) contends for a single GPU on most hardware. Letting every test
  /// thread enter it simultaneously produces queue pressure and elevated RSS
  /// without throughput gains.
  ///
  /// Concurrency is read once from `SNAPSHOT_TESTING_PERCEPTUAL_DIFF_CONCURRENCY`,
  /// clamped to `[1, 16]`. Default is `2`. Set to `0` to disable the limiter.
  final class SnapshotTestingImageDiffLimiter: @unchecked Sendable {
    private let semaphore: DispatchSemaphore?

    init(concurrency: Int) {
      if concurrency <= 0 {
        self.semaphore = nil
      } else {
        self.semaphore = DispatchSemaphore(value: min(concurrency, 16))
      }
    }

    func run<T>(_ body: () -> T) -> T {
      guard let semaphore else { return body() }
      semaphore.wait()
      defer { semaphore.signal() }
      return body()
    }

    static let shared = SnapshotTestingImageDiffLimiter(
      concurrency: parseConcurrency(
        ProcessInfo.processInfo.environment["SNAPSHOT_TESTING_PERCEPTUAL_DIFF_CONCURRENCY"]
      )
    )
  }

  func parseConcurrency(_ raw: String?) -> Int {
    guard let raw, let parsed = Int(raw) else { return 2 }
    return parsed
  }
#endif
