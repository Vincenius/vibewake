import AppKit
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// Holds / releases everything that keeps the Mac awake.
///
/// - An IOPM assertion prevents idle sleep (lid open).
/// - `pmset -a disablesleep 1` (via a narrow sudoers rule) prevents lid-close sleep.
final class SleepController {
    private(set) var isHolding = false
    private var assertionID: IOPMAssertionID = 0

    static let pmset = "/usr/bin/pmset"
    static let sudo = "/usr/bin/sudo"

    /// Whether the sudoers rule for `pmset disablesleep` is installed.
    var lidSupportAvailable: Bool {
        run(Self.sudo, ["-n", "-l", Self.pmset, "-a", "disablesleep", "1"]) == 0
    }

    /// Undo a `disablesleep 1` left behind by a previous run (crash, kill -9).
    func recoverFromPreviousRun() {
        if FileManager.default.fileExists(atPath: Paths.disableSleepOwned.path) {
            Log.write("sleep", "Found lid-close sleep still disabled from a previous run — restoring")
            setDisableSleep(false)
        }
    }

    func hold(reason: String) {
        if assertionID == 0 {
            var id: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "VibeWake: \(reason)" as CFString, &id)
            if r == kIOReturnSuccess {
                assertionID = id
                Log.write("sleep", "Idle sleep PREVENTED (power assertion on)")
            } else {
                Log.write("sleep", "Failed to create power assertion (IOReturn \(r))")
            }
        }
        if !FileManager.default.fileExists(atPath: Paths.disableSleepOwned.path) {
            setDisableSleep(true)
        }
        isHolding = true
    }

    /// Release all sleep prevention. If the lid is closed (and no external display
    /// is driving clamshell mode), put the Mac to sleep right away, as it would have.
    func release(sleepIfLidClosed: Bool) {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
            Log.write("sleep", "Idle sleep ALLOWED again (power assertion released)")
        }
        let wasDisabled = FileManager.default.fileExists(atPath: Paths.disableSleepOwned.path)
        if wasDisabled { setDisableSleep(false) }
        isHolding = false

        if sleepIfLidClosed && wasDisabled && Self.isLidClosed && !Self.hasExternalDisplay {
            Log.write("sleep", "Lid is closed and work is done → putting the Mac to sleep now")
            _ = run(Self.pmset, ["sleepnow"])
        }
    }

    private func setDisableSleep(_ on: Bool) {
        let status = run(Self.sudo, ["-n", Self.pmset, "-a", "disablesleep", on ? "1" : "0"])
        if on {
            if status == 0 {
                Paths.ensure()
                FileManager.default.createFile(atPath: Paths.disableSleepOwned.path, contents: nil)
                Log.write("sleep", "Lid-close sleep DISABLED (pmset disablesleep 1)")
            } else {
                Log.write("sleep", "Could not disable lid-close sleep (sudoers rule missing?) — closing the lid will still sleep")
            }
        } else if status == 0 {
            try? FileManager.default.removeItem(at: Paths.disableSleepOwned)
            Log.write("sleep", "Lid-close sleep RESTORED (pmset disablesleep 0)")
        } else {
            Log.write("sleep", "FAILED to restore lid-close sleep (pmset exit \(status)) — run: sudo pmset -a disablesleep 0")
        }
    }

    // MARK: - System state

    static var isLidClosed: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    /// Lid closed + external display = intentional clamshell mode; don't force sleep then.
    static var hasExternalDisplay: Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    /// (on battery, percent) — nil if the Mac has no battery.
    static var battery: (onBattery: Bool, percent: Int)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let onBattery = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            return (onBattery, cur * 100 / max)
        }
        return nil
    }

    @discardableResult
    private func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
