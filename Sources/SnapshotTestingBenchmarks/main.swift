import Foundation

#if canImport(AppKit) || canImport(UIKit)
struct CLIOptions {
  var parallelism: Int = 1
  var outputPath: String? = nil
  var only: Set<String> = []
  var iterationsScale: Double = 1.0
}

func parseArgs(_ args: [String]) -> CLIOptions {
  var opts = CLIOptions()
  var i = 1
  while i < args.count {
    let arg = args[i]
    switch arg {
    case "--parallel":
      i += 1
      if i < args.count, let n = Int(args[i]) { opts.parallelism = max(1, n) }
    case "--serial":
      opts.parallelism = 1
    case "--out":
      i += 1
      if i < args.count { opts.outputPath = args[i] }
    case "--only":
      i += 1
      if i < args.count {
        opts.only.formUnion(args[i].split(separator: ",").map(String.init))
      }
    case "--scale":
      i += 1
      if i < args.count, let s = Double(args[i]) { opts.iterationsScale = max(0.01, s) }
    case "--help", "-h":
      print("""
        snapshot-bench [--serial | --parallel N] [--out PATH] [--only NAME[,NAME...]] [--scale F]

        --serial          Run scenarios on a single thread (default).
        --parallel N      Run each scenario's iterations on N concurrent workers.
        --out PATH        Write results CSV to PATH. Defaults to stdout.
        --only NAMES      Run only scenarios whose names match one of NAMES (comma-separated).
        --scale F         Multiply iteration counts by F (e.g. 0.1 for a smoke run).
        """)
      exit(0)
    default:
      FileHandle.standardError.write(Data("unknown argument: \(arg)\n".utf8))
      exit(2)
    }
    i += 1
  }
  return opts
}

struct ScaledScenario: Scenario {
  let name: String
  let iterations: Int
  private let inner: Scenario
  init(_ inner: Scenario, scale: Double) {
    self.inner = inner
    self.name = inner.name
    self.iterations = max(1, Int(Double(inner.iterations) * scale))
  }
  func setUp() { inner.setUp() }
  func runOnce() { inner.runOnce() }
  func tearDown() { inner.tearDown() }
}

let opts = parseArgs(CommandLine.arguments)

let allScenarios: [Scenario] = [
  ExactMatchSmall(),
  ExactMatchLarge(),
  ExactMatchMixed(),
  Precision1pxDiff(),
  Precision50pctDiff(),
  PrecisionEarlyFail(),
  PerceptualPass(),
  PerceptualFail(),
  PNGRoundTrip(),
]

let filtered: [Scenario] = opts.only.isEmpty
  ? allScenarios
  : allScenarios.filter { opts.only.contains($0.name) }

let scenarios: [Scenario] = opts.iterationsScale == 1.0
  ? filtered
  : filtered.map { ScaledScenario($0, scale: opts.iterationsScale) }

if scenarios.isEmpty {
  FileHandle.standardError.write(Data("no scenarios selected\n".utf8))
  exit(2)
}

let runner = BenchRunner(parallelism: opts.parallelism)
var results: [ScenarioResult] = []
for scenario in scenarios {
  FileHandle.standardError.write(
    Data("running \(scenario.name) (iters=\(scenario.iterations), parallel=\(opts.parallelism))\n".utf8)
  )
  let start = BenchClock.now()
  let result = runner.run(scenario)
  let elapsedNs = BenchClock.nanoseconds(from: start, to: BenchClock.now())
  FileHandle.standardError.write(
    Data(String(format: "  done in %.2fs\n", Double(elapsedNs) / 1_000_000_000).utf8)
  )
  results.append(result)
}

if let path = opts.outputPath {
  let url = URL(fileURLWithPath: path)
  try CSV.write(results, to: url)
  FileHandle.standardError.write(Data("wrote \(results.count) rows to \(path)\n".utf8))
} else {
  print(CSV.header.joined(separator: ","))
  for r in results.sorted(by: { $0.name < $1.name }) {
    print(CSV.row(r))
  }
}
#else
print("SnapshotTestingBenchmarks requires AppKit or UIKit; this platform has neither.")
exit(1)
#endif
