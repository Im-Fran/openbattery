import AppKit
import SwiftUI

@main
struct OpenBatteryApp: App {
    @StateObject private var monitor = BatteryMonitor()
    @StateObject private var caffeine = CaffeineController()
    @StateObject private var devices = DeviceMonitor()

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
                .environmentObject(devices)
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
        .commands { BatteryInfoCommands(snapshot: monitor.snapshot) }

        Settings {
            SettingsView()
        }
    }
}

/// The tabs of the Battery Info window, in the menu bar where a Mac user looks
/// to find out what a window can do — and where the key equivalents are shown
/// rather than having to be discovered.
private struct BatteryInfoCommands: Commands {
    let snapshot: BatterySnapshot

    @AppStorage(BatteryInfoView.Tab.key) private var tab = BatteryInfoView.Tab.charge
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Into the View menu SwiftUI already provides, not a second one
        // beside it: CommandMenu("View") appends a duplicate rather than
        // merging, which the menu bar shows as two View menus.
        CommandGroup(before: .toolbar) {
            ForEach(BatteryInfoView.Tab.allCases) { item in
                // A Toggle, so the menu marks the tab you are on: these are
                // four views of one window, not four unrelated commands. The
                // menu bar belongs to the app rather than to a scene, so it
                // is offered whenever any window is up — opening Battery Info
                // is what keeps choosing a tab from doing nothing visible.
                Toggle(item.title, isOn: Binding(get: {
                    // The same question the window asks, so a check can never
                    // sit on a tab the window is not showing.
                    BatteryInfoView.Tab.shown(tab, hasLifetime: snapshot.lifetime != nil) == item
                },
                                                 set: { isOn in
                    // A checked item sends false, and it still has to bring
                    // the window forward: picking a view command should focus
                    // its window, not do nothing because you were already on
                    // that tab. Only the tab change belongs behind the guard.
                    if isOn { tab = item }
                    openWindow(id: BatteryInfoView.windowID)
                }))
                    .keyboardShortcut(item.shortcut)
                    // Greyed rather than hidden: a gauge with no lifetime log
                    // has no Lifetime tab, and a missing menu item reads as a
                    // bug where a disabled one reads as "not on this Mac".
                    .disabled(item == .lifetime && snapshot.lifetime == nil)
            }
            Divider()
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
