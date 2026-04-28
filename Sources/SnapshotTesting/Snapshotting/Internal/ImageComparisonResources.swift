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

  /// When `true`, image comparison uses the historic PNG round-trip code path
  /// instead of the Phase 3 normalized-buffer path.
  ///
  /// This is an escape hatch in case a project hits a pixel-difference edge
  /// case the new code path doesn't handle. It's read once at process start
  /// from `SNAPSHOT_TESTING_LEGACY_NORMALIZATION`. Any of `1`, `true`, `yes`
  /// (case-insensitive) enables it.
  let snapshotTestingLegacyNormalization: Bool = parseLegacyNormalizationFlag(
    ProcessInfo.processInfo.environment["SNAPSHOT_TESTING_LEGACY_NORMALIZATION"]
  )

  func parseLegacyNormalizationFlag(_ raw: String?) -> Bool {
    guard let raw = raw?.lowercased(), !raw.isEmpty else { return false }
    return raw == "1" || raw == "true" || raw == "yes"
  }

  /// LIFO pool of reusable raw byte buffers used as destination storage for the
  /// normalized RGBA renderings in `compare()` / `normalizedComponentDiff()`.
  ///
  /// At parallel-8 on 4096×4096 images each `compare()` call allocates roughly
  /// 2 × 64 MB of transient `[UInt8]` storage; under load that's ~1 GB of
  /// churn per window and shows up as a steady peak-RSS climb. Pooling these
  /// buffers keeps peak RSS flat without changing observable behavior.
  ///
  /// Pool size is read once from `SNAPSHOT_TESTING_BUFFER_POOL_SIZE` (default
  /// `clamp(activeProcessorCount * 2, 2, 32)`; set to `0` to disable). Per-slot
  /// capacity is bounded by `SNAPSHOT_TESTING_BUFFER_POOL_MAX_BYTES` (default
  /// 256 MB, i.e. one 8K×8K RGBA buffer); larger requests bypass the pool and
  /// are freed immediately on `release`.
  final class SnapshotTestingByteBufferPool: @unchecked Sendable {
    struct Slot {
      let buffer: UnsafeMutableRawPointer
      let capacity: Int
      fileprivate let pooled: Bool
    }

    private struct Entry {
      let buffer: UnsafeMutableRawPointer
      let capacity: Int
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    let maxSlots: Int
    let maxBytesPerSlot: Int

    init(maxSlots: Int, maxBytesPerSlot: Int) {
      self.maxSlots = max(0, maxSlots)
      self.maxBytesPerSlot = max(0, maxBytesPerSlot)
    }

    deinit {
      for entry in entries { entry.buffer.deallocate() }
    }

    func acquire(byteCount: Int) -> Slot {
      precondition(byteCount > 0, "byteCount must be positive")
      if maxSlots == 0 || byteCount > maxBytesPerSlot {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        return Slot(buffer: buffer, capacity: byteCount, pooled: false)
      }
      lock.lock()
      // LIFO best-effort: scan from the top of the stack for any entry of
      // sufficient capacity. In typical usage all entries are the same size,
      // so this picks the most recently released (hottest in cache) buffer.
      var index = entries.count - 1
      while index >= 0 {
        if entries[index].capacity >= byteCount {
          let entry = entries.remove(at: index)
          lock.unlock()
          return Slot(buffer: entry.buffer, capacity: entry.capacity, pooled: true)
        }
        index -= 1
      }
      lock.unlock()
      let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
      return Slot(buffer: buffer, capacity: byteCount, pooled: true)
    }

    func release(_ slot: Slot) {
      if !slot.pooled {
        slot.buffer.deallocate()
        return
      }
      lock.lock()
      if entries.count < maxSlots {
        entries.append(Entry(buffer: slot.buffer, capacity: slot.capacity))
        lock.unlock()
        return
      }
      // Pool full. Evict the smallest entry only if the incoming slot is
      // larger, so over time the pool drifts toward the working-set size
      // without thrashing on equal-sized requests.
      var smallestIndex = 0
      for i in entries.indices where entries[i].capacity < entries[smallestIndex].capacity {
        smallestIndex = i
      }
      if entries[smallestIndex].capacity < slot.capacity {
        let evicted = entries.remove(at: smallestIndex)
        entries.append(Entry(buffer: slot.buffer, capacity: slot.capacity))
        lock.unlock()
        evicted.buffer.deallocate()
      } else {
        lock.unlock()
        slot.buffer.deallocate()
      }
    }

    var slotCountForTesting: Int {
      lock.lock(); defer { lock.unlock() }
      return entries.count
    }

    static let shared = SnapshotTestingByteBufferPool(
      maxSlots: parseBufferPoolSize(
        ProcessInfo.processInfo.environment["SNAPSHOT_TESTING_BUFFER_POOL_SIZE"]),
      maxBytesPerSlot: parseBufferPoolMaxBytes(
        ProcessInfo.processInfo.environment["SNAPSHOT_TESTING_BUFFER_POOL_MAX_BYTES"])
    )
  }

  func parseBufferPoolSize(_ raw: String?) -> Int {
    guard let raw, let parsed = Int(raw) else {
      let cores = ProcessInfo.processInfo.activeProcessorCount
      return min(max(cores * 2, 2), 32)
    }
    return max(0, min(parsed, 32))
  }

  func parseBufferPoolMaxBytes(_ raw: String?) -> Int {
    guard let raw, let parsed = Int(raw), parsed > 0 else {
      return 256 * 1024 * 1024
    }
    return parsed
  }
#endif
