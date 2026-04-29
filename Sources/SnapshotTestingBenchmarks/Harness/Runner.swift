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

/// A scenario that decomposes each iteration into named stages. The runner
/// records both the per-iteration total (sum of stage timings) and per-stage
/// percentiles, which CSV emits as additional columns.
protocol StagedScenario: Scenario {
  /// Stage names in the order returned by `runOnceStaged()`. Must be stable
  /// across iterations; same order is used for CSV column generation.
  var stageNames: [String] { get }
  /// Returns nanosecond timings for each stage of one iteration, in the same
  /// order as `stageNames`.
  func runOnceStaged() -> [UInt64]
}

extension StagedScenario {
  func runOnce() {
    _ = runOnceStaged()
  }
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
  /// `nil` for non-staged scenarios; otherwise one `(name, stats)` per stage,
  /// in the order declared by the scenario's `stageNames`.
  let stageStats: [(name: String, stats: Stats)]?
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
    let stageSamples: [[UInt64]]?

    if let staged = scenario as? StagedScenario {
      // Pipeline scenarios touch AppKit; AppKit autolayout is main-thread-only
      // and rejects calls from background workers once initialized on main.
      // Force serial execution regardless of `--parallel N`. The CSV still
      // records the requested mode/parallelism so suites can be diffed
      // against each other; the `wall_ns` column reflects actual serialized
      // execution.
      let stageCount = staged.stageNames.count
      let total = scenario.iterations
      var perIter = [UInt64]()
      perIter.reserveCapacity(total)
      var perStage = (0..<stageCount).map { _ -> [UInt64] in
        var a = [UInt64](); a.reserveCapacity(total); return a
      }
      for _ in 0..<total {
        let stages = staged.runOnceStaged()
        var sum: UInt64 = 0
        for i in 0..<stageCount {
          let v = stages[i]
          perStage[i].append(v)
          sum &+= v
        }
        perIter.append(sum)
      }
      samples = perIter
      stageSamples = perStage
    } else if parallelism == 1 {
      var local = [UInt64]()
      local.reserveCapacity(scenario.iterations)
      for _ in 0..<scenario.iterations {
        let t0 = BenchClock.now()
        scenario.runOnce()
        let t1 = BenchClock.now()
        local.append(BenchClock.nanoseconds(from: t0, to: t1))
      }
      samples = local
      stageSamples = nil
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
      stageSamples = nil
    }

    let wallEnd = BenchClock.now()
    let peak = RSS.peakBytes()
    let rssAfter = RSS.currentBytes()

    let stageStats: [(name: String, stats: Stats)]?
    if let stageSamples, let staged = scenario as? StagedScenario {
      stageStats = zip(staged.stageNames, stageSamples).map { ($0, Stats(samples: $1)) }
    } else {
      stageStats = nil
    }

    return ScenarioResult(
      name: scenario.name,
      mode: parallelism == 1 ? "serial" : "parallel-\(parallelism)",
      parallelism: parallelism,
      iterations: scenario.iterations,
      stats: Stats(samples: samples),
      wallNs: BenchClock.nanoseconds(from: wallStart, to: wallEnd),
      peakRSSBytes: peak,
      rssDeltaBytes: Int64(rssAfter) - Int64(rssBefore),
      stageStats: stageStats
    )
  }
}
#endif
