// probe: interrupt wakeups/s, package idle wakeups/s (top's IDLEW), cpu % and phys_footprint of a running process
// top's IDLEW only counts package idle wakeups so it shows ~0 even for a 10 Hz timer, ri_interrupt_wkups is the real rate
// run: swiftc -O tools/bench/probes/wakeups.swift -o "$TMPDIR/wakeups" && "$TMPDIR/wakeups" $(pgrep -x DynamicIslandManager) 10

import Darwin
import Foundation

guard CommandLine.arguments.count == 3, let pid = Int32(CommandLine.arguments[1]), let secs = UInt32(CommandLine.arguments[2]) else {
    print("usage: wakeups <pid> <seconds>"); exit(2)
}
func read() -> rusage_info_v4? {
    var ri = rusage_info_v4()
    let r = withUnsafeMutablePointer(to: &ri) { p in
        p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    return r == 0 ? ri : nil
}
// ri_user_time / ri_system_time are mach absolute time units, convert with the timebase
var tb = mach_timebase_info_data_t()
mach_timebase_info(&tb)
guard let a = read() else { print("rusage failed (wrong pid?)"); exit(1) }
sleep(secs)
guard let b = read() else { print("rusage failed"); exit(1) }
let s = Double(secs)
let intr = Double(b.ri_interrupt_wkups - a.ri_interrupt_wkups) / s
let pkg = Double(b.ri_pkg_idle_wkups - a.ri_pkg_idle_wkups) / s
let cpuTicks = (b.ri_user_time + b.ri_system_time) - (a.ri_user_time + a.ri_system_time)
let cpuNs = Double(cpuTicks) * Double(tb.numer) / Double(tb.denom)
let cpu = cpuNs / 1e9 / s * 100
let fp = Double(b.ri_phys_footprint) / 1_048_576
print(String(format: "pid %d over %ds: interrupt wakeups %.1f/s, pkg-idle wakeups %.2f/s, cpu %.2f%%, footprint %.1f MB", pid, secs, intr, pkg, cpu, fp))
