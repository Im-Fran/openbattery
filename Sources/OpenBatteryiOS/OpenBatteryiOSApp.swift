import SwiftData
import SwiftUI
import UIKit

@main
struct OpenBatteryiOSApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(CloudStore.shared.container)
        // Coming forward is the one moment a reading is guaranteed; going
        // away is the last chance to ask for one later.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                LiveLink.shared.start()
                PhoneBatteryMonitor.shared.refresh()
            case .background:
                LiveLink.shared.stop()
                PhoneBatteryMonitor.scheduleRefresh()
            default: break
            }
        }
        // Each wake books the next one first, so a reading that fails to
        // save still leaves the chain intact.
        .backgroundTask(.appRefresh(PhoneBatteryMonitor.refreshTaskID)) {
            await MainActor.run {
                PhoneBatteryMonitor.scheduleRefresh()
                PhoneBatteryMonitor.shared.refresh()
            }
        }
    }
}

/// The device in your hand, every device on your iCloud account, and settings.
struct RootView: View {
    private let isPad = UIDevice.current.userInterfaceIdiom == .pad

    var body: some View {
        TabView {
            Tab(isPad ? "This iPad" : "This iPhone", systemImage: isPad ? "ipad" : "iphone") {
                ThisDeviceView()
            }
            Tab("Devices", systemImage: "macbook.and.iphone") {
                DevicesView()
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
        }
    }
}
