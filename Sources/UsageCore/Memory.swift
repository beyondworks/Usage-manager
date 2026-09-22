import Foundation

/// What the app costs, measured the way macOS charges it.
public enum Memory {
    /// `phys_footprint` — what Activity Monitor shows and what the system counts against
    /// the app. Resident size is lower and misses compressed pages the process still
    /// owns, which is most of what a scan leaves behind.
    public static var footprint: Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return ok == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    public static func mb(_ bytes: Int) -> String { "\(bytes / 1_048_576)MB" }
}
