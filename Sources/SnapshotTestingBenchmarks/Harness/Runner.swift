import Foundation

#if canImport(Darwin)
import Dispatch

protocol Scenario {
  var name: String { get }
  var iterations: Int { get }
  func setUp()
  func runOnce()
  func tearDown()
}

extension Scenario {
  func setUp() {}
  func tearDown() {}
}

struct ScenarioResult {
  let name: String
  let mode: String
  let parallelism: Int
  let iterations: Int
  let stats: Stats
  let wallNs: UInt64
  let peakRSSBytes: UInt64
  let rssDeltaBytes: Int64
}

struct BenchRunner {
  let parallelism: Int
  let warmupIterations: Int

  init(parallelism: Int, warmupIterations: Int = 5) {
    self.parallelism = max(1, parallelism)
    self.warmupIterations = warmupIterations
  }

  func run(_ scenario: Scenario) -> ScenarioResult {
    scenario.setUp()
    defer { scenario.tearDown() }

    for _ in 0..<warmupIterations {
      scenario.runOnce()
    }

    let rssBefore = RSS.currentBytes()
    let wallStart = BenchClock.now()

    let samples: [UInt64]
    if parallelism == 1 {
      var local = [UInt64]()
      local.reserveCapacity(scenario.iterations)
      for _ in 0..<scenario.iterations {
        let t0 = BenchClock.now()
        scenario.runOnce()
        let t1 = BenchClock.now()
        local.append(BenchClock.nanoseconds(from: t0, to: t1))
      }
      samples = local
    } else {
      // N long-running workers pull iterations from a shared counter so that
      // at most `parallelism` runOnce() calls are in flight at any moment.
      // DispatchQueue.concurrentPerform would farm work onto GCD's global pool
      // (sized to the full machine), defeating the --parallel N cap.
      let total = scenario.iterations
      let workerCount = min(parallelism, total)
      let counterLock = NSLock()
      var nextIteration = 0
      let samplesLock = NSLock()
      var collected = [UInt64]()
      collected.reserveCapacity(total)
      let queue = DispatchQueue.global(qos: .userInitiated)
      let group = DispatchGroup()
      for _ in 0..<workerCount {
        queue.async(group: group) {
          while true {
            counterLock.lock()
            let i = nextIteration
            if i >= total {
              counterLock.unlock()
              return
            }
            nextIteration = i + 1
            counterLock.unlock()

            let t0 = BenchClock.now()
            scenario.runOnce()
            let t1 = BenchClock.now()
            let ns = BenchClock.nanoseconds(from: t0, to: t1)
            samplesLock.lock()
            collected.append(ns)
            samplesLock.unlock()
          }
        }
      }
      group.wait()
      samples = collected
    }

    let wallEnd = BenchClock.now()
    let peak = RSS.peakBytes()
    let rssAfter = RSS.currentBytes()

    return ScenarioResult(
      name: scenario.name,
      mode: parallelism == 1 ? "serial" : "parallel-\(parallelism)",
      parallelism: parallelism,
      iterations: scenario.iterations,
      stats: Stats(samples: samples),
      wallNs: BenchClock.nanoseconds(from: wallStart, to: wallEnd),
      peakRSSBytes: peak,
      rssDeltaBytes: Int64(rssAfter) - Int64(rssBefore)
    )
  }
}
#endif
