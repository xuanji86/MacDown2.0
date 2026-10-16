import Foundation
import IOKit
import IOKit.ps

/// When it is fine to run the heavy `qmd embed` in the background (PLAN 4.12): nobody has touched the keyboard or mouse for a
/// while, and the Mac is on power or has more than half its battery. Both are read-only queries of the system.
enum QmdIdle {
    /// No input event for `seconds` (IOHIDSystem's `HIDIdleTime`; needs no permission). False when it cannot be read.
    static func isIdle(seconds: Double) -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let nanoseconds = (value as? NSNumber)?.uint64Value
        else { return false }
        return Double(nanoseconds) / 1e9 >= seconds
    }

    /// On AC power, or a battery above 50 %. A Mac without a battery is on power.
    static func hasPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return true }
        if let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?, source == kIOPMACPowerKey { return true }
        guard let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return true }
        for item in list {
            guard let description = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int, let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return Double(current) / Double(max) > 0.5
        }
        return true
    }
}
