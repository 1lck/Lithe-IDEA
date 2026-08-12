import Darwin
import Foundation

/// macOS process-tree RSS sampler. The registry contains only roots owned by
/// Lithe, so terminal and updater processes are never folded into the total.
struct MacProcessMemorySampler: ManagedProcessMemorySampling {
    func currentProcessResidentMemoryBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : nil
    }

    func residentMemoryBytes(for processIDs: Set<Int32>) -> UInt64 {
        guard !processIDs.isEmpty else { return 0 }
        let estimatedCount = max(1024, Int(proc_listallpids(nil, 0)) + 64)
        var all = [pid_t](repeating: 0, count: estimatedCount)
        let count = Int(proc_listallpids(&all, Int32(all.count * MemoryLayout<pid_t>.stride)))
        guard count > 0 else { return direct(processIDs) }
        var parents: [pid_t: pid_t] = [:]
        for pid in all.prefix(count) where pid > 0 {
            var info = proc_bsdinfo()
            let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
            if size > 0 { parents[pid] = pid_t(info.pbi_ppid) }
        }
        let roots = Set(processIDs.map { pid_t($0) })
        var total: UInt64 = 0
        for pid in all.prefix(count) where pid > 0 {
            var current = pid
            var belongs = roots.contains(current)
            var seen = Set<pid_t>()
            while !belongs, let parent = parents[current], parent > 0, seen.insert(current).inserted {
                current = parent
                belongs = roots.contains(current)
            }
            guard belongs else { continue }
            var task = proc_taskinfo()
            let size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout.size(ofValue: task)))
            if size > 0 { total += UInt64(task.pti_resident_size) }
        }
        return total
    }

    private func direct(_ processIDs: Set<Int32>) -> UInt64 {
        processIDs.reduce(0) { total, id in
            var task = proc_taskinfo()
            let size = proc_pidinfo(pid_t(id), PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout.size(ofValue: task)))
            return total + (size > 0 ? UInt64(task.pti_resident_size) : 0)
        }
    }
}
