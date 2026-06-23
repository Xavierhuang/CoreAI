import Foundation
import Darwin

// Quick wrappers over Mach VM statistics. Used by the chat panel to surface
// "free RAM" so the user can predict whether their next Ollama turn will go
// to Metal (fast) or fall back to CPU (very slow) on this small-RAM Mac.
//
// "Effectively free" = free pages + inactive pages. Inactive pages are
// reclaimable on demand by the kernel, so for the purposes of "can I load a
// 1 GB model into unified memory" they count as available.
enum SystemStats {

    struct MemoryReport {
        let freeBytes: UInt64       // free + inactive
        let totalBytes: UInt64      // total physical RAM

        var freeGB: Double { Double(freeBytes) / 1_073_741_824.0 }
        var totalGB: Double { Double(totalBytes) / 1_073_741_824.0 }
    }

    static func memoryReport() -> MemoryReport {
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &size)
            }
        }
        let pageSize = UInt64(vm_kernel_page_size)
        let freeBytes: UInt64 = (kr == KERN_SUCCESS)
            ? (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * pageSize
            : 0
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        return MemoryReport(freeBytes: freeBytes, totalBytes: totalBytes)
    }
}
