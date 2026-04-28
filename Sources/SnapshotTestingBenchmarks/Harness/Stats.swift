import Foundation

struct Stats {
  let count: Int
  let totalNs: UInt64
  let p50Ns: UInt64
  let p95Ns: UInt64
  let p99Ns: UInt64
  let minNs: UInt64
  let maxNs: UInt64

  init(samples: [UInt64]) {
    let sorted = samples.sorted()
    count = sorted.count
    totalNs = sorted.reduce(0, &+)
    p50Ns = sorted.percentile(0.50)
    p95Ns = sorted.percentile(0.95)
    p99Ns = sorted.percentile(0.99)
    minNs = sorted.first ?? 0
    maxNs = sorted.last ?? 0
  }
}

extension Array where Element == UInt64 {
  fileprivate func percentile(_ p: Double) -> UInt64 {
    guard !isEmpty else { return 0 }
    let idx = Swift.max(0, Swift.min(count - 1, Int((Double(count - 1) * p).rounded())))
    return self[idx]
  }
}
