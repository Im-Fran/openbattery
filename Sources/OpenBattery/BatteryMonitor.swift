import Combine
import Foundation
import IOKit.ps

/// Publishes battery state to the UI.
///
/// Nothing polls while the menu bar only shows charge and status: IOKit wakes
/// us on every power source change. A timer is only started when someone needs
/// the detailed read — an open popover or window, or a menu bar configured to
/// show watts, mAh or temperature — and it stops as soon as they stop.
@MainActor
final class BatteryMonitor: ObservableObject {

    @Published private(set) var snapshot: BatterySnapshot

    static let windowInterval: TimeInterval = 5
    /// Slower than an open window: this one may run all day.
    static let menuBarInterval: TimeInterval = 10

    private var runLoopSource: CFRunLoopSource?
    private var defaultsObserver: NSObjectProtocol?
    private var timer: Timer?
    private var timerInterval: TimeInterval?
    private var detailClients = 0

    init() {
        snapshot = BatteryReader.read(.quick)

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refresh() }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }

        // The menu bar configuration decides how deep we have to read, so react
        // when it changes instead of asking on a schedule.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePolicy() }
        }

        updatePolicy()
    }

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    /// Called when a detail view appears. Balanced by `endDetailUpdates()`.
    func beginDetailUpdates() {
        detailClients += 1
        updatePolicy()
    }

    func endDetailUpdates() {
        detailClients = max(0, detailClients - 1)
        updatePolicy()
    }

    func refresh() {
        let fresh = BatteryReader.read(needsDetailedRead ? .detailed : .quick)
        // Equatable guard: no SwiftUI invalidation when nothing actually moved.
        if fresh != snapshot { snapshot = fresh }
    }

    // MARK: - Refresh policy

    private var needsDetailedRead: Bool {
        detailClients > 0 || MenuBarConfig.load().needsDetailedRead
    }

    private func updatePolicy() {
        let wanted: TimeInterval?
        if detailClients > 0 {
            wanted = Self.windowInterval
        } else if MenuBarConfig.load().needsDetailedRead {
            wanted = Self.menuBarInterval
        } else {
            wanted = nil
        }

        guard wanted != timerInterval else { return }
        timer?.invalidate()
        timer = nil
        timerInterval = wanted

        if let wanted {
            let timer = Timer(timeInterval: wanted, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        refresh()
    }
}
