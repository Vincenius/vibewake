import Darwin
import Foundation

struct ProcInfo {
    let pid: Int32
    let ppid: Int32
    let name: String      // p_comm (max 16 chars)
    let startTime: Double // seconds since epoch
}

enum ProcessTree {
    static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "nu"]

    /// Snapshot of all processes visible to this user via sysctl(KERN_PROC_ALL).
    static func snapshot() -> [Int32: ProcInfo] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        // Leave headroom in case processes appear between the two calls.
        size += size / 8
        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [:] }
        let n = size / MemoryLayout<kinfo_proc>.stride

        var result: [Int32: ProcInfo] = [:]
        result.reserveCapacity(n)
        for i in 0..<n {
            var p = procs[i]
            let pid = p.kp_proc.p_pid
            let name = withUnsafePointer(to: &p.kp_proc.p_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
            }
            let tv = p.kp_proc.p_un.__p_starttime
            let start = Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
            result[pid] = ProcInfo(pid: pid, ppid: p.kp_eproc.e_ppid, name: name, startTime: start)
        }
        return result
    }

    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Whether the process a marker was written for still runs (not just some process with a reused pid).
    static func isAlive(_ marker: Marker, in table: [Int32: ProcInfo]) -> Bool {
        guard let p = table[marker.pid] else { return isAlive(marker.pid) }
        guard let start = marker.pidStart else { return true }
        return abs(p.startTime - start) < 0.5
    }

    /// Start time of one process (seconds since epoch).
    static func startTime(of pid: Int32) -> Double? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
    }

    /// Shell processes that are direct children of `pid` and have been running
    /// for at least `minAge` seconds (filters out short-lived hook/statusline shells).
    static func longRunningShellChildren(of pid: Int32, in table: [Int32: ProcInfo], minAge: Double) -> [ProcInfo] {
        let now = Date().timeIntervalSince1970
        return table.values.filter {
            $0.ppid == pid && shells.contains($0.name) && now - $0.startTime >= minAge
        }
    }

    /// Total CPU time (user + system) consumed by `pid`, in seconds.
    static func cpuSeconds(_ pid: Int32) -> Double? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        let ticks = Double(info.pti_total_user + info.pti_total_system)
        return ticks * timebase / 1_000_000_000
    }

    /// Mach absolute time units → nanoseconds.
    private static let timebase: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()
}
