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

/// Process and main-thread CPU time (s), for the heartbeat's cpu=/main= utilisation (renderer A/B: SpriteKit renders
/// inside SKView after our update(), so its cost only shows up here, not in the draw= section timer).
enum CPUTime {
    /// User + system time of the whole process (all threads).
    static func process() -> Double {
        #if canImport(Darwin)
        var u = rusage()
        if getrusage(RUSAGE_SELF, &u) != 0 { return 0 }
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
        #else
        return 0
        #endif
    }

    /// User + system time of the calling thread (call on the main thread).
    static func thread() -> Double {
        #if canImport(Darwin)
        var info = thread_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let port = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, port) }
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), raw, &count)
            }
        }
        if kr != KERN_SUCCESS { return 0 }
        return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
            + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
        #else
        return 0
        #endif
    }
}
