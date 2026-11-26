import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// `-LaunchTiming`: how long after the process started the app reached its init and its first
/// screen (`[LaunchTiming]` lines on the console). For comparing builds, e.g. with and without the
/// embedded Python (tools/reticulum/launch-timing.sh). Costs nothing without the flag.
enum LaunchTiming {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-LaunchTiming")
    private nonisolated(unsafe) static var marked: Set<String> = []

    /// Milliseconds since the kernel started this process.
    static func sinceProcessStart() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return (Date().timeIntervalSince1970 - started) * 1000
    }

    /// Logs `what` once per launch.
    static func mark(_ what: String) {
        guard enabled, !marked.contains(what), let ms = sinceProcessStart() else { return }
        marked.insert(what)
        print("[LaunchTiming] \(what) +\(Int(ms.rounded())) ms")
    }
}
