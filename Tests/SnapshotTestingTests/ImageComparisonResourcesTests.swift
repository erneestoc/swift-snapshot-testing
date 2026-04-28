#if canImport(CoreImage) && (os(iOS) || os(tvOS) || os(macOS))
  import CoreImage
  import XCTest

  @testable import SnapshotTesting

  @available(iOS 10.0, tvOS 10.0, macOS 10.13, *)
  final class ImageComparisonResourcesTests: XCTestCase {

    // MARK: - parsePoolSize

    func testParsePoolSize_default() {
      XCTAssertEqual(parsePoolSize(nil), 2)
      XCTAssertEqual(parsePoolSize("not-a-number"), 2)
    }

    func testParsePoolSize_validValues() {
      XCTAssertEqual(parsePoolSize("1"), 1)
      XCTAssertEqual(parsePoolSize("3"), 3)
      XCTAssertEqual(parsePoolSize("4"), 4)
    }

    func testParsePoolSize_clamps() {
      XCTAssertEqual(parsePoolSize("0"), 1, "values below 1 clamp up to 1")
      XCTAssertEqual(parsePoolSize("-5"), 1, "negatives clamp up to 1")
      XCTAssertEqual(parsePoolSize("100"), 4, "values above 4 clamp down to 4")
    }

    // MARK: - SnapshotTestingCIContextPool

    func testPoolHoldsRequestedNumberOfDistinctContexts() {
      let pool = SnapshotTestingCIContextPool(size: 3)
      XCTAssertEqual(pool.contexts.count, 3)
      XCTAssertTrue(pool.contexts[0] !== pool.contexts[1])
      XCTAssertTrue(pool.contexts[1] !== pool.contexts[2])
      XCTAssertTrue(pool.contexts[0] !== pool.contexts[2])
    }

    func testPoolRoundRobins() {
      let pool = SnapshotTestingCIContextPool(size: 3)
      let first = pool.next()
      let second = pool.next()
      let third = pool.next()
      let fourth = pool.next()
      XCTAssertTrue(first !== second)
      XCTAssertTrue(second !== third)
      XCTAssertTrue(first === fourth, "round-robin should wrap to the first context")
    }

    func testPoolClampsConstructorInput() {
      XCTAssertEqual(SnapshotTestingCIContextPool(size: 0).contexts.count, 1)
      XCTAssertEqual(SnapshotTestingCIContextPool(size: 99).contexts.count, 4)
    }

    // MARK: - parseConcurrency

    func testParseConcurrency_default() {
      XCTAssertEqual(parseConcurrency(nil), 2)
      XCTAssertEqual(parseConcurrency("garbage"), 2)
    }

    func testParseConcurrency_validValues() {
      XCTAssertEqual(parseConcurrency("0"), 0, "0 disables limiter (passes through)")
      XCTAssertEqual(parseConcurrency("1"), 1)
      XCTAssertEqual(parseConcurrency("8"), 8)
    }

    // MARK: - SnapshotTestingImageDiffLimiter

    func testLimiterDisabledWhenConcurrencyZero() {
      let limiter = SnapshotTestingImageDiffLimiter(concurrency: 0)
      // No serialization expected: 8 concurrent calls all run their body once.
      let invocations = LockedCounter()
      DispatchQueue.concurrentPerform(iterations: 8) { _ in
        limiter.run { _ = invocations.increment() }
      }
      XCTAssertEqual(invocations.value, 8)
    }

    func testLimiterSerializesWhenConcurrencyOne() {
      let limiter = SnapshotTestingImageDiffLimiter(concurrency: 1)
      let inFlight = LockedCounter()
      let maxInFlight = LockedCounter()
      DispatchQueue.concurrentPerform(iterations: 16) { _ in
        limiter.run {
          let now = inFlight.increment()
          maxInFlight.bumpIfGreater(now)
          // Hold the slot briefly so contention is real.
          Thread.sleep(forTimeInterval: 0.005)
          inFlight.decrement()
        }
      }
      XCTAssertEqual(maxInFlight.value, 1, "capacity=1 should serialize")
    }

    func testLimiterCapsConcurrency() {
      let limiter = SnapshotTestingImageDiffLimiter(concurrency: 3)
      let inFlight = LockedCounter()
      let maxInFlight = LockedCounter()
      DispatchQueue.concurrentPerform(iterations: 32) { _ in
        limiter.run {
          let now = inFlight.increment()
          maxInFlight.bumpIfGreater(now)
          Thread.sleep(forTimeInterval: 0.002)
          inFlight.decrement()
        }
      }
      XCTAssertLessThanOrEqual(maxInFlight.value, 3)
      XCTAssertGreaterThan(maxInFlight.value, 1, "should achieve some parallelism with capacity > 1")
    }

    func testLimiterClampsAbove16() {
      // Indirectly: with capacity 1000, behavior should still be bounded — but more
      // importantly we just want to confirm it doesn't explode at construction.
      let limiter = SnapshotTestingImageDiffLimiter(concurrency: 1000)
      let counter = LockedCounter()
      DispatchQueue.concurrentPerform(iterations: 4) { _ in
        limiter.run { _ = counter.increment() }
      }
      XCTAssertEqual(counter.value, 4)
    }

    // MARK: - parseBufferPoolSize

    func testParseBufferPoolSize_default() {
      let cores = ProcessInfo.processInfo.activeProcessorCount
      let expected = min(max(cores * 2, 2), 32)
      XCTAssertEqual(parseBufferPoolSize(nil), expected)
      XCTAssertEqual(parseBufferPoolSize("not-a-number"), expected)
    }

    func testParseBufferPoolSize_validValues() {
      XCTAssertEqual(parseBufferPoolSize("0"), 0, "0 disables the pool")
      XCTAssertEqual(parseBufferPoolSize("1"), 1)
      XCTAssertEqual(parseBufferPoolSize("8"), 8)
      XCTAssertEqual(parseBufferPoolSize("32"), 32)
    }

    func testParseBufferPoolSize_clamps() {
      XCTAssertEqual(parseBufferPoolSize("-5"), 0, "negatives clamp up to 0")
      XCTAssertEqual(parseBufferPoolSize("100"), 32, "values above 32 clamp down to 32")
    }

    // MARK: - parseBufferPoolMaxBytes

    func testParseBufferPoolMaxBytes_default() {
      XCTAssertEqual(parseBufferPoolMaxBytes(nil), 256 * 1024 * 1024)
      XCTAssertEqual(parseBufferPoolMaxBytes("garbage"), 256 * 1024 * 1024)
      XCTAssertEqual(parseBufferPoolMaxBytes("0"), 256 * 1024 * 1024, "zero falls back to default")
      XCTAssertEqual(parseBufferPoolMaxBytes("-10"), 256 * 1024 * 1024)
    }

    func testParseBufferPoolMaxBytes_validValues() {
      XCTAssertEqual(parseBufferPoolMaxBytes("1024"), 1024)
      XCTAssertEqual(parseBufferPoolMaxBytes("1048576"), 1024 * 1024)
    }

    // MARK: - SnapshotTestingByteBufferPool

    func testBufferPoolReturnsCorrectCapacity() {
      let pool = SnapshotTestingByteBufferPool(maxSlots: 4, maxBytesPerSlot: 1 << 20)
      let slot = pool.acquire(byteCount: 4096)
      XCTAssertGreaterThanOrEqual(slot.capacity, 4096)
      pool.release(slot)
    }

    func testBufferPoolReusesReleasedBuffer() {
      let pool = SnapshotTestingByteBufferPool(maxSlots: 4, maxBytesPerSlot: 1 << 20)
      let first = pool.acquire(byteCount: 4096)
      let firstAddress = first.buffer
      pool.release(first)
      let second = pool.acquire(byteCount: 4096)
      XCTAssertEqual(second.buffer, firstAddress, "LIFO: same pointer should come back")
      pool.release(second)
    }

    func testBufferPoolLifoOrdering() {
      let pool = SnapshotTestingByteBufferPool(maxSlots: 4, maxBytesPerSlot: 1 << 20)
      let a = pool.acquire(byteCount: 4096)
      let b = pool.acquire(byteCount: 4096)
      let aAddress = a.buffer
      let bAddress = b.buffer
      pool.release(a)
      pool.release(b)
      let firstReturned = pool.acquire(byteCount: 4096)
      XCTAssertEqual(firstReturned.buffer, bAddress, "most-recently released should come back first")
      let secondReturned = pool.acquire(byteCount: 4096)
      XCTAssertEqual(secondReturned.buffer, aAddress)
      pool.release(firstReturned)
      pool.release(secondReturned)
    }

    func testBufferPoolFitsLargerRequestFromExistingSlot() {
      let pool = SnapshotTestingByteBufferPool(maxSlots: 4, maxBytesPerSlot: 1 << 20)
      // Seed pool with a 16K slot
      let big = pool.acquire(byteCount: 16 * 1024)
      pool.release(big)
      // A 4K request should reuse the 16K slot rather than allocating
      let small = pool.acquire(byteCount: 4 * 1024)
      XCTAssertEqual(small.capacity, 16 * 1024, "best-effort fit picks any slot of sufficient capacity")
      pool.release(small)
    }

    func testBufferPoolBoundedAtMaxSlots() {
      let pool = SnapshotTestingByteBufferPool(maxSlots: 2, maxBytesPerSlot: 1 << 20)
      let slots = (0..<5).map { _ in pool.acquire(byteCount: 4096) }
      slots.forEach { pool.release($0) }
      XCTAssertEqual(pool.slotCountForTesting, 2, "pool retains at most maxSlots buffers")
    }

    func testBufferPoolBypassesWhenSizeZero() {
      let pool = SnapshotTestingByteBufferPool(maxSlots: 0, maxBytesPerSlot: 1 << 20)
      let slot = pool.acquire(byteCount: 4096)
      pool.release(slot)
      XCTAssertEqual(pool.slotCountForTesting, 0, "size-0 pool retains nothing")
    }

    func testBufferPoolBypassesOversize() {
      let pool = SnapshotTestingByteBufferPool(maxSlots: 4, maxBytesPerSlot: 1024)
      let slot = pool.acquire(byteCount: 4096)
      XCTAssertEqual(slot.capacity, 4096)
      pool.release(slot)
      XCTAssertEqual(pool.slotCountForTesting, 0, "oversize allocations bypass the pool")
    }

    func testBufferPoolEvictsSmallerToFitLarger() {
      let pool = SnapshotTestingByteBufferPool(maxSlots: 2, maxBytesPerSlot: 1 << 20)
      // Fill pool with two 4K slots
      let a = pool.acquire(byteCount: 4096)
      let b = pool.acquire(byteCount: 4096)
      pool.release(a)
      pool.release(b)
      XCTAssertEqual(pool.slotCountForTesting, 2)
      // Release a 16K slot — should evict a 4K and pool the larger one
      let large = pool.acquire(byteCount: 16 * 1024)
      pool.release(large)
      XCTAssertEqual(pool.slotCountForTesting, 2)
      // Two acquires should reveal one 16K and one 4K capacity
      let first = pool.acquire(byteCount: 4096)
      let second = pool.acquire(byteCount: 4096)
      let capacities = [first.capacity, second.capacity].sorted()
      XCTAssertEqual(capacities, [4096, 16 * 1024])
      pool.release(first)
      pool.release(second)
    }

    func testBufferPoolHandlesConcurrentAcquireAndReleaseWithoutSharingSlots() {
      let pool = SnapshotTestingByteBufferPool(maxSlots: 4, maxBytesPerSlot: 1 << 20)
      let inUse = LockedAddressSet()
      let collisionCount = LockedCounter()
      DispatchQueue.concurrentPerform(iterations: 200) { _ in
        let slot = pool.acquire(byteCount: 4096)
        if !inUse.insert(slot.buffer) {
          collisionCount.increment()
        }
        // Brief work simulating buffer use
        memset(slot.buffer, 0, 4096)
        inUse.remove(slot.buffer)
        pool.release(slot)
      }
      XCTAssertEqual(collisionCount.value, 0, "no two concurrent acquires should share a slot pointer")
    }
  }

  /// Lock-protected address set used to detect any concurrent acquires that
  /// hand out the same buffer pointer.
  private final class LockedAddressSet: @unchecked Sendable {
    private let lock = NSLock()
    private var addresses = Set<UInt>()

    /// Returns `true` if the address was newly inserted.
    @discardableResult
    func insert(_ pointer: UnsafeMutableRawPointer) -> Bool {
      lock.lock(); defer { lock.unlock() }
      return addresses.insert(UInt(bitPattern: pointer)).inserted
    }

    func remove(_ pointer: UnsafeMutableRawPointer) {
      lock.lock(); defer { lock.unlock() }
      addresses.remove(UInt(bitPattern: pointer))
    }
  }

  /// Minimal lock-protected Int for the limiter tests.
  private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    @discardableResult
    func increment() -> Int {
      lock.lock()
      defer { lock.unlock() }
      _value += 1
      return _value
    }

    func decrement() {
      lock.lock()
      defer { lock.unlock() }
      _value -= 1
    }

    func bumpIfGreater(_ candidate: Int) {
      lock.lock()
      defer { lock.unlock() }
      if candidate > _value { _value = candidate }
    }

    var value: Int {
      lock.lock()
      defer { lock.unlock() }
      return _value
    }
  }
#endif
