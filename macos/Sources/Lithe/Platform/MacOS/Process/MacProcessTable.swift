import Darwin
import Foundation

// Note: 统一子进程生命周期见 .agents/notes/proposed/architecture/2026-10-16-unified-child-process-lifecycle.md

/// Identity of one live process. The start time distinguishes a reused PID
/// from the process that was originally observed.
struct MacProcessIdentity: Hashable, Sendable, Codable {
    let processID: pid_t
    /// Start time in microseconds since 1970, as reported by the kernel.
    let startTime: UInt64
}

/// One row of a process-table snapshot owned by the current user.
struct MacProcessInfo: Hashable, Sendable {
    let identity: MacProcessIdentity
    let parentProcessID: pid_t
    let processGroupID: pid_t
    let sessionID: pid_t
    /// Whether the process still has a controlling terminal, such as a
    /// terminal tab's PTY. Daemons detach from theirs.
    let hasControllingTerminal: Bool
    /// Kernel short name (at most 16 bytes); use `MacProcessTable.arguments`
    /// for the full command line.
    let name: String

    var processID: pid_t { identity.processID }
}

/// Executable arguments and environment of a process, read through
/// `KERN_PROCARGS2`. Only processes of the same user are readable.
struct MacProcessArguments: Sendable {
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]

    var commandLine: String {
        arguments.isEmpty ? executablePath : arguments.joined(separator: " ")
    }
}

/// Read-only queries over the kernel process table.
///
/// Process groups and sessions are not containment boundaries on macOS: a
/// child can call `setsid` or double-fork and be re-parented to `launchd`.
/// The table therefore exposes the inherited environment as well, which is how
/// `MacProcessLedger` recognizes descendants that escaped their group.
enum MacProcessTable {
    /// Every live process owned by `userID`, ordered by PID.
    static func snapshot(userID: uid_t = getuid()) -> [MacProcessInfo] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: userID)]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // The table can grow between the size query and the read.
        size += size / 8 + MemoryLayout<kinfo_proc>.stride * 16
        let capacity = size / MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        let result = processes.withUnsafeMutableBufferPointer { buffer in
            sysctl(&mib, UInt32(mib.count), buffer.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        return processes.prefix(count).compactMap(info(from:)).sorted { $0.processID < $1.processID }
    }

    /// The current state of one process, or `nil` when it has exited.
    static func info(processID: pid_t) -> MacProcessInfo? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processID]
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &process, &size, nil, 0) == 0, size > 0 else { return nil }
        return info(from: process)
    }

    /// Whether the exact process (PID and start time) is still alive.
    static func isAlive(_ identity: MacProcessIdentity) -> Bool {
        info(processID: identity.processID)?.identity == identity
    }

    /// Reads argv and the environment. Returns `nil` for exited processes and
    /// for processes of another user or with a hardened runtime that denies it.
    static func arguments(processID: pid_t) -> MacProcessArguments? {
        var argumentMaximumMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argumentMaximum: Int32 = 0
        var argumentMaximumSize = MemoryLayout<Int32>.size
        guard sysctl(&argumentMaximumMIB, 2, &argumentMaximum, &argumentMaximumSize, nil, 0) == 0,
              argumentMaximum > 0 else { return nil }

        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, processID]
        var size = Int(argumentMaximum)
        var buffer = [UInt8](repeating: 0, count: size)
        let result = buffer.withUnsafeMutableBytes { bytes in
            sysctl(&mib, 3, bytes.baseAddress, &size, nil, 0)
        }
        guard result == 0, size > MemoryLayout<Int32>.size else { return nil }
        return parseArguments(Array(buffer.prefix(size)))
    }

    /// Parses the `KERN_PROCARGS2` layout: `argc`, the executable path, NUL
    /// padding, `argc` argument strings, then environment strings.
    static func parseArguments(_ bytes: [UInt8]) -> MacProcessArguments? {
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }
        let argumentCount = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argumentCount >= 0 else { return nil }
        var index = MemoryLayout<Int32>.size

        func nextString() -> String? {
            guard index < bytes.count else { return nil }
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            let value = String(decoding: bytes[start..<index], as: UTF8.self)
            index += 1
            return value
        }

        guard let executablePath = nextString() else { return nil }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        for _ in 0..<argumentCount {
            guard let argument = nextString() else { break }
            arguments.append(argument)
        }
        var environment: [String: String] = [:]
        while let entry = nextString(), !entry.isEmpty {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            let name = String(entry[..<separator])
            if environment[name] == nil {
                environment[name] = String(entry[entry.index(after: separator)...])
            }
        }
        return MacProcessArguments(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment
        )
    }

    /// Current working directory, if the process is readable.
    static func workingDirectory(processID: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(processID, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    /// TCP ports on which the process is listening, sorted and de-duplicated.
    static func listeningTCPPorts(processID: pid_t) -> [Int] {
        let descriptorSize = Int32(MemoryLayout<proc_fdinfo>.stride)
        let bufferSize = proc_pidinfo(processID, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        let capacity = Int(bufferSize / descriptorSize) + 8
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let used = descriptors.withUnsafeMutableBytes { bytes in
            proc_pidinfo(processID, PROC_PIDLISTFDS, 0, bytes.baseAddress, Int32(bytes.count))
        }
        guard used > 0 else { return [] }
        var ports = Set<Int>()
        for descriptor in descriptors.prefix(Int(used / descriptorSize))
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socket = socket_fdinfo()
            let read = proc_pidfdinfo(
                processID,
                descriptor.proc_fd,
                PROC_PIDFDSOCKETINFO,
                &socket,
                Int32(MemoryLayout<socket_fdinfo>.stride)
            )
            guard read == Int32(MemoryLayout<socket_fdinfo>.stride),
                  socket.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = socket.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            if port > 0 { ports.insert(port) }
        }
        return ports.sorted()
    }

    /// Every process whose ancestry reaches `rootProcessID`, excluding the root.
    static func descendants(of rootProcessID: pid_t, in snapshot: [MacProcessInfo]) -> [MacProcessInfo] {
        let children = Dictionary(grouping: snapshot, by: \.parentProcessID)
        var result: [MacProcessInfo] = []
        var pending = [rootProcessID]
        var visited: Set<pid_t> = [rootProcessID]
        while let parent = pending.popLast() {
            for child in children[parent] ?? [] where visited.insert(child.processID).inserted {
                result.append(child)
                pending.append(child.processID)
            }
        }
        return result.sorted { $0.processID < $1.processID }
    }

    private static func info(from process: kinfo_proc) -> MacProcessInfo? {
        let processID = process.kp_proc.p_pid
        // A zombie has already exited and only waits for its parent to reap it.
        guard processID > 0, process.kp_proc.p_stat != CChar(SZOMB) else { return nil }
        let start = process.kp_proc.p_un.__p_starttime
        let startTime = UInt64(max(0, start.tv_sec)) * 1_000_000 + UInt64(max(0, start.tv_usec))
        let sessionID = getsid(processID)
        let name = withUnsafeBytes(of: process.kp_proc.p_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return MacProcessInfo(
            identity: MacProcessIdentity(processID: processID, startTime: startTime),
            parentProcessID: process.kp_eproc.e_ppid,
            processGroupID: process.kp_eproc.e_pgid,
            sessionID: sessionID,
            hasControllingTerminal: process.kp_eproc.e_tdev != -1,
            name: name
        )
    }
}
