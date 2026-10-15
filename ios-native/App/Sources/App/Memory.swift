import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Process memory footprint (the figure jetsam uses), for the heartbeat log.
enum Memory {
    static func footprintMB() -> Int {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
            }
        }
        if kr != KERN_SUCCESS { return -1 }
        return Int(info.phys_footprint / 1_048_576)
        #else
        return -1
        #endif
    }
}
