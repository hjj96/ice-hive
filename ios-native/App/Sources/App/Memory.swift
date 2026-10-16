import Foundation
import os
#if canImport(Darwin)
import Darwin
#endif

/// Process memory for the heartbeat log: the footprint jetsam uses, and what the OS still grants the app.
/// On the simulator the Metal textures live in the host's GPU process, so the footprint stops counting the sprite
/// sheets once they are uploaded; on a device (unified memory) they count. `avail` is 0 on the simulator.
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

    /// os_proc_available_memory() in MB (iOS 13+; 0 where the call does not apply).
    static func availableMB() -> Int {
        return Int(os_proc_available_memory() / 1_048_576)
    }

    static var summary: String { "mem=\(footprintMB())MB avail=\(availableMB())MB" }
}
