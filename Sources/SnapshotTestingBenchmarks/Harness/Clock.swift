import Foundation

#if canImport(Darwin)
import Darwin

enum BenchClock {
  static let timebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
  }()

  @inline(__always)
  static func now() -> UInt64 {
    mach_absolute_time()
  }

  @inline(__always)
  static func nanoseconds(from start: UInt64, to end: UInt64) -> UInt64 {
    let elapsed = end &- start
    return elapsed * UInt64(timebase.numer) / UInt64(timebase.denom)
  }
}
#endif
