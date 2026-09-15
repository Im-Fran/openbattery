import Combine
import Foundation
import IOKit.ps

/// Publishes battery state to the UI.
///
/// Nothing polls while the menu bar is idle: IOKit wakes us on every power
/// source change. The expensive detailed read only runs while a popover or
/// window is on screen, and stops the moment the last one closes.
@MainActor
final class BatteryMonitor: ObservableObject {

    @Published private(set) var snapshot: BatterySnapshot

    private var runLoopSource: CFRunLoopSource?
    private var detailTimer: Timer?
    private var detailClients = 0

    static let detailInterval: TimeInterval = 5

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
    }

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
    }

    /// Called when a detail view appears. Balanced by `endDetailUpdates()`.
    func beginDetailUpdates() {
        detailClients += 1
        guard detailClients == 1 else { return }
        let timer = Timer(timeInterval: Self.detailInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        detailTimer = timer
        refresh()
    }

    func endDetailUpdates() {
        detailClients = max(0, detailClients - 1)
        guard detailClients == 0 else { return }
        detailTimer?.invalidate()
        detailTimer = nil
    }

    func refresh() {
        let fresh = BatteryReader.read(detailClients > 0 ? .detailed : .quick)
        // Equatable guard: no SwiftUI invalidation when nothing actually moved.
        if fresh != snapshot { snapshot = fresh }
    }
}
