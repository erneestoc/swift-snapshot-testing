import Foundation

#if canImport(Darwin)
enum CSV {
  static let baseHeader = [
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

  // Backwards-compat: some callers still reference `header` as the static
  // base (no stage columns). Pipeline scenarios extend the header dynamically.
  static let header = baseHeader

  /// Stable union of stage names across results, in the order each stage
  /// first appears. Empty if no result has stage stats.
  static func stageColumns(from results: [ScenarioResult]) -> [String] {
    var seen = Set<String>()
    var ordered = [String]()
    for r in results {
      guard let stages = r.stageStats else { continue }
      for (name, _) in stages where !seen.contains(name) {
        seen.insert(name)
        ordered.append(name)
      }
    }
    return ordered
  }

  static func header(stageColumns: [String]) -> [String] {
    var h = baseHeader
    for stage in stageColumns {
      h.append("\(stage)_p50_ns")
      h.append("\(stage)_p95_ns")
    }
    return h
  }

  static func row(_ result: ScenarioResult, stageColumns: [String] = []) -> String {
    var fields: [String] = [
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
    ]
    if !stageColumns.isEmpty {
      let byName = Dictionary(uniqueKeysWithValues: result.stageStats ?? [])
      for stage in stageColumns {
        if let s = byName[stage] {
          fields.append(String(s.p50Ns))
          fields.append(String(s.p95Ns))
        } else {
          // Non-staged scenario in a mixed result set, or a stage missing on
          // this row: leave blank so the column stays diff-friendly.
          fields.append("")
          fields.append("")
        }
      }
    }
    return fields.joined(separator: ",")
  }

  static func write(_ results: [ScenarioResult], to url: URL) throws {
    let stages = stageColumns(from: results)
    var lines = [header(stageColumns: stages).joined(separator: ",")]
    let sorted = results.sorted { lhs, rhs in
      if lhs.name != rhs.name { return lhs.name < rhs.name }
      return lhs.parallelism < rhs.parallelism
    }
    for r in sorted {
      lines.append(row(r, stageColumns: stages))
    }
    let body = lines.joined(separator: "\n") + "\n"
    try body.write(to: url, atomically: true, encoding: .utf8)
  }
}
#endif
