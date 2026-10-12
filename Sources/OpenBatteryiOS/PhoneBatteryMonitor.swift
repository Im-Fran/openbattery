import BackgroundTasks
import Foundation
import Observation
import OSLog
import UIKit

/// This iPhone's or iPad's own battery, as far as iOS lets an app see it:
/// level, charge state, Low Power Mode and thermal pressure. Health, cycles
/// and capacity are not among them; those arrive from a Mac over iCloud.
///
/// One instance for the whole app, because the background refresh has no view
/// to hang a monitor on and two monitors would publish twice.
@MainActor
@Observable
final class PhoneBatteryMonitor {
    static let shared = PhoneBatteryMonitor()

    /// Listed under BGTaskSchedulerPermittedIdentifiers in Info.plist.
    static let refreshTaskID = "cl.franciscosolis.openbattery.refresh"

    private(set) var snapshot = BatterySnapshot()
    /// Not part of `BatterySnapshot`, which models what a Mac's gas gauge
    /// reports; shown on this screen only.
    private(set) var thermalState = ProcessInfo.ThermalState.nominal

    private static let log = Logger(subsystem: "cl.franciscosolis.openbattery", category: "battery")

    private init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let names: [Notification.Name] = [
            UIDevice.batteryLevelDidChangeNotification,
            UIDevice.batteryStateDidChangeNotification,
            .NSProcessInfoPowerStateDidChange,
            ProcessInfo.thermalStateDidChangeNotification,
        ]
        // ponytail: never removed, the monitor lives as long as the app.
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { PhoneBatteryMonitor.shared.refresh() }
            }
        }
        refresh()
    }

    /// Reads the battery and hands it to iCloud. `CloudStore` spaces records
    /// out itself, so calling this on every notification costs nothing;
    /// `force` skips that spacing, for Sync Now.
    func refresh(force: Bool = false) {
        snapshot = Self.read()
        thermalState = ProcessInfo.processInfo.thermalState
        #if !targetEnvironment(simulator)
        // The simulator's reading is made up (see `read`), and a simulator
        // signed into iCloud would show it on the person's real Mac.
        CloudStore.shared.publish(snapshot, for: .current, force: force)
        #endif
    }

    private static func read() -> BatterySnapshot {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        #if targetEnvironment(simulator)
        // ponytail: the simulator reports level -1 and state .unknown, which
        // leaves nothing to design against. A plausible charging phone instead.
        return BatterySnapshot(percentage: 76, isCharging: true, isPluggedIn: true, isPresent: true, lowPowerMode: lowPower)
        #else
        let device = UIDevice.current
        guard device.batteryState != .unknown, device.batteryLevel >= 0 else {
            return BatterySnapshot(lowPowerMode: lowPower)
        }
        let state = device.batteryState
        return BatterySnapshot(
            percentage: Int((device.batteryLevel * 100).rounded()),
            isCharging: state == .charging,
            isPluggedIn: state == .charging || state == .full,
            isFullyCharged: state == .full,
            isPresent: true,
            lowPowerMode: lowPower)
        #endif
    }

    /// Asks iOS to wake the app in about a quarter of an hour, the spacing
    /// `CloudStore` keeps anyway. iOS decides when, or whether, it happens.
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = .now.addingTimeInterval(CloudStore.minimumSpacing)
        do { try BGTaskScheduler.shared.submit(request) } catch {
            // Always fails in the simulator, which has no background scheduler.
            log.error("refresh not scheduled: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension ProcessInfo.ThermalState {
    /// How hot the device runs, in words: iOS gives apps a pressure level,
    /// not degrees.
    var label: String {
        switch self {
        case .nominal: "Normal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
}
