import Darwin
import Foundation
import MachO

struct PerformanceSample: Equatable {
    let cpuPercent: Double
    let residentMemoryBytes: UInt64
}

final class PerformanceSampler {
    private var previousCPUSeconds: Double?
    private var previousDate: Date?

    func sample(at date: Date = Date()) -> PerformanceSample? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        let cpuSeconds = timevalSeconds(usage.ru_utime) + timevalSeconds(usage.ru_stime)

        let cpuPercent: Double
        if let previousCPUSeconds, let previousDate {
            let elapsed = date.timeIntervalSince(previousDate)
            cpuPercent = elapsed > 0 ? max(0, (cpuSeconds - previousCPUSeconds) / elapsed * 100) : 0
        } else {
            cpuPercent = 0
        }
        self.previousCPUSeconds = cpuSeconds
        self.previousDate = date

        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return PerformanceSample(cpuPercent: cpuPercent, residentMemoryBytes: info.resident_size)
    }

    private func timevalSeconds(_ value: timeval) -> Double {
        Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }
}
