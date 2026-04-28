import Foundation

#if canImport(Darwin)
enum CSV {
  static let header = [
    "scenario",
    "mode",
    "parallelism",
    "iterations",
    "p50_ns",
    "p95_ns",
    "p99_ns",
    "min_ns",
    "max_ns",
    "total_ns",
    "wall_ns",
    "peak_rss_bytes",
    "rss_delta_bytes",
  ]

  static func row(_ result: ScenarioResult) -> String {
    [
      result.name,
      result.mode,
      String(result.parallelism),
      String(result.iterations),
      String(result.stats.p50Ns),
      String(result.stats.p95Ns),
      String(result.stats.p99Ns),
      String(result.stats.minNs),
      String(result.stats.maxNs),
      String(result.stats.totalNs),
      String(result.wallNs),
      String(result.peakRSSBytes),
      String(result.rssDeltaBytes),
    ].joined(separator: ",")
  }

  static func write(_ results: [ScenarioResult], to url: URL) throws {
    var lines = [header.joined(separator: ",")]
    let sorted = results.sorted { lhs, rhs in
      if lhs.name != rhs.name { return lhs.name < rhs.name }
      return lhs.parallelism < rhs.parallelism
    }
    for r in sorted {
      lines.append(row(r))
    }
    let body = lines.joined(separator: "\n") + "\n"
    try body.write(to: url, atomically: true, encoding: .utf8)
  }
}
#endif
