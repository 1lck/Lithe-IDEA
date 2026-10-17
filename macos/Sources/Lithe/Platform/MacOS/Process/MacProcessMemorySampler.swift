import Darwin
import Foundation

// Command Line Tools SDKs ship libproc.h without exposing its functions through
// Swift's Darwin module, so bind the stable libSystem symbols locally.
@_silgen_name("proc_listallpids")
private func litheProcListAllPIDs(
    _ buffer: UnsafeMutableRawPointer?,
    _ bufferSize: Int32
) -> Int32

@_silgen_name("proc_pidinfo")
private func litheProcPIDInfo(
    _ processID: pid_t,
    _ flavor: Int32,
    _ argument: UInt64,
    _ buffer: UnsafeMutableRawPointer?,
    _ bufferSize: Int32
) -> Int32

/// macOS process-tree RSS sampler. The registry contains only roots owned by
/// Lithe, so terminal and updater processes are never folded into the total.
struct MacProcessMemorySampler: ManagedProcessMemorySampling {
    private static let timebase: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t()
        mach_timebase_info(&value)
        return value
    }()

    static func nanoseconds(ticks: UInt64, numerator: UInt32, denominator: UInt32) -> UInt64 {
        let divisor = UInt64(max(1, denominator))
        let product = ticks.multipliedFullWidth(by: UInt64(numerator))
        guard product.high < divisor else { return UInt64.max }
        return divisor.dividingFullWidth(product).quotient
    }

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
        residentMemoryBytes(forExactProcessIDs: descendantProcessIDs(of: processIDs))
    }

    func descendantProcessIDs(of processIDs: Set<Int32>) -> Set<Int32> {
        guard !processIDs.isEmpty else { return [] }
        let estimatedCount = max(1024, Int(litheProcListAllPIDs(nil, 0)) + 64)
        var all = [pid_t](repeating: 0, count: estimatedCount)
        let count = Int(litheProcListAllPIDs(&all, Int32(all.count * MemoryLayout<pid_t>.stride)))
        guard count > 0 else { return processIDs }
        var parents: [pid_t: pid_t] = [:]
        for pid in all.prefix(min(count, all.count)) where pid > 0 {
            var info = proc_bsdinfo()
            let size = litheProcPIDInfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
            if size == MemoryLayout.size(ofValue: info) { parents[pid] = pid_t(info.pbi_ppid) }
        }
        var owned = processIDs
        for pid in parents.keys {
            var current = pid
            var seen = Set<pid_t>()
            while !owned.contains(current), let parent = parents[current], parent > 0, seen.insert(current).inserted {
                current = parent
            }
            if owned.contains(current) { owned.insert(pid) }
        }
        return owned
    }

    func cpuSnapshot(for processID: Int32) -> (nanoseconds: UInt64, startedSeconds: UInt64, startedMicroseconds: UInt64)? {
        var task = proc_taskinfo()
        var bsd = proc_bsdinfo()
        guard litheProcPIDInfo(processID, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout.size(ofValue: task))) == MemoryLayout.size(ofValue: task),
              litheProcPIDInfo(processID, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout.size(ofValue: bsd))) == MemoryLayout.size(ofValue: bsd) else { return nil }
        // XNU fill_taskprocinfo exposes recount_times_mach, not nanoseconds.
        // Convert here so all callers share the same units on Intel and Apple Silicon.
        let time = Self.nanoseconds(ticks: task.pti_total_user &+ task.pti_total_system,
            numerator: Self.timebase.numer, denominator: Self.timebase.denom)
        return (time, bsd.pbi_start_tvsec, bsd.pbi_start_tvusec)
    }

    func residentMemoryBytes(forExactProcessIDs processIDs: Set<Int32>) -> UInt64 {
        processIDs.reduce(0) { total, id in
            var task = proc_taskinfo()
            let size = litheProcPIDInfo(
                pid_t(id),
                PROC_PIDTASKINFO,
                0,
                &task,
                Int32(MemoryLayout.size(ofValue: task))
            )
            return total + (size > 0 ? UInt64(task.pti_resident_size) : 0)
        }
    }
}
