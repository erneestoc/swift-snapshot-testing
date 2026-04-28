import Foundation

#if canImport(Darwin)
import Darwin.Mach

enum RSS {
  private static func sample() -> mach_task_basic_info? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size
    )
    let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
      ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
      }
    }
    guard kr == KERN_SUCCESS else { return nil }
    return info
  }

  static func currentBytes() -> UInt64 {
    sample()?.resident_size ?? 0
  }

  static func peakBytes() -> UInt64 {
    sample()?.resident_size_max ?? 0
  }
}
#endif
