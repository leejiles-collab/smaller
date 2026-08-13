import Foundation
import Darwin

/// Peak resident memory for this process.
///
/// The share extension gets roughly 120 MB before the system kills it, and a
/// single deck image is 3999x2250 — 27 MB decoded, plus its mask. We need a real
/// number before phase 3, not a guess.
enum Memory {

    /// High-water mark since launch, in bytes. The kernel tracks this for us, so
    /// there is no sampling and nothing to miss between samples.
    static func peakResidentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size_max)
    }

    /// Runs `work` while sampling the process footprint, and reports the highest
    /// value seen alongside the result.
    ///
    /// `resident_size_max` is monotonic for the life of the process, so it
    /// cannot answer "how much did *this* file cost" once several have run.
    /// Sampling can in principle miss a spike between polls, but at this
    /// interval it catches anything that lives long enough to matter.
    static func peak<T>(sampling interval: TimeInterval = 0.002, while work: () async throws -> T) async rethrows -> (value: T, peak: Int) {
        let tracker = PeakTracker(baseline: currentResidentBytes())
        let sampler = Thread {
            while !tracker.isFinished {
                tracker.observe(currentResidentBytes())
                Thread.sleep(forTimeInterval: interval)
            }
        }
        sampler.stackSize = 64 * 1024
        sampler.start()
        defer { tracker.finish() }

        let value = try await work()
        tracker.observe(currentResidentBytes())
        return (value, tracker.highest)
    }

    private final class PeakTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var _highest: Int
        private var _finished = false

        init(baseline: Int) { _highest = baseline }

        func observe(_ value: Int) {
            lock.lock(); defer { lock.unlock() }
            _highest = max(_highest, value)
        }

        var highest: Int {
            lock.lock(); defer { lock.unlock() }
            return _highest
        }

        var isFinished: Bool {
            lock.lock(); defer { lock.unlock() }
            return _finished
        }

        func finish() {
            lock.lock(); defer { lock.unlock() }
            _finished = true
        }
    }

    /// Current footprint, for measuring a single operation in isolation.
    static func currentResidentBytes() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint)
    }
}
