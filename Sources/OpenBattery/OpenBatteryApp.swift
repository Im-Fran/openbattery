import SwiftUI

@main
struct OpenBatteryApp: App {
    @StateObject private var monitor = BatteryMonitor()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(monitor)
        } label: {
            MenuBarLabel(snapshot: monitor.snapshot)
        }
        .menuBarExtraStyle(.window)

        Window("Battery Info", id: BatteryInfoView.windowID) {
            BatteryInfoView()
                .environmentObject(monitor)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
