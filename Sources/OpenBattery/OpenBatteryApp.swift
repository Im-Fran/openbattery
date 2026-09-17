import SwiftUI

@main
struct OpenBatteryApp: App {
    @StateObject private var monitor = BatteryMonitor()
    @StateObject private var caffeine = CaffeineController()

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
