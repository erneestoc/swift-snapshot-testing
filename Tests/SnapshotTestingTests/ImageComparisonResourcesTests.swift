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
