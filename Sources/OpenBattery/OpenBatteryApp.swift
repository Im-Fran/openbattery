import AppKit
import SwiftUI

@main
struct OpenBatteryApp: App {
    @StateObject private var monitor = BatteryMonitor()
    @StateObject private var caffeine = CaffeineController()

    init() { DockPolicy.start() }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(monitor)
                .environmentObject(caffeine)
        } label: {
            MenuBarLabel(snapshot: monitor.snapshot, isCaffeinated: caffeine.isActive)
        }
        .menuBarExtraStyle(.window)

        Window("Battery Info", id: BatteryInfoView.windowID) {
            BatteryInfoView()
                .environmentObject(monitor)
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)

        Settings {
            SettingsView()
        }
    }
}

/// OpenBattery is an accessory app (`LSUIElement`): no Dock icon and no menu bar
/// of its own, which is what a menu bar popover wants. A real window wants the
/// opposite — without a Dock icon there is no way to bring it back once another
/// app covers it — so the policy follows whatever windows are on screen.
@MainActor
enum DockPolicy {
    /// Counts live windows instead of pairing open/close calls from the views:
    /// the Settings scene keeps its view alive between openings, so `onAppear`
    /// would count that window once and never again.
    static func start() {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                let closing = note.name == NSWindow.willCloseNotification
                MainActor.assumeIsolated { apply(ignoring: closing ? note.object as? NSWindow : nil) }
            }
        }
    }

    /// A closing window is still on screen when it says so, hence `ignoring`.
    private static func apply(ignoring closing: NSWindow?) {
        // Only app windows count: neither the status item nor the popover panel
        // behind the menu bar extra can ever become main.
        let hasWindow = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.canBecomeMain }
        let policy: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Gaining a Dock icon leaves the app behind whoever was frontmost, so it
        // has to be pulled forward after the switch, never before it.
        if hasWindow { NSApp.activate() }
    }
}
