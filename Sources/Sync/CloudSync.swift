import CloudKit
import CoreData
import Foundation
import Observation
#if os(macOS)
import Security
#endif

/// What the iCloud mirror is doing, for a settings screen to show.
///
/// SwiftData mirrors through `NSPersistentCloudKitContainer`, which announces
/// every setup, import and export it runs; listening is all this does. There is
/// no public call that makes the mirror sync, so "Sync Now" records a fresh
/// reading: a change to save is what starts an export, and the export's
/// round trip to CloudKit picks up whatever other devices sent meanwhile.
@MainActor
@Observable
final class CloudSync {
    static let shared = CloudSync()

    enum Account: Equatable {
        /// Signed without the iCloud entitlement (a Debug Mac build): the store
        /// is local and asking CloudKit anything would crash.
        case unsupported
        case checking
        case available
        case noAccount
        case restricted
        case temporarilyUnavailable
        case unknown
    }

    private(set) var account: Account = .checking
    private(set) var lastImport: Date?
    private(set) var lastExport: Date?
    /// True while the mirror is running an import or export.
    private(set) var isSyncing = false
    private(set) var lastError: String?

    /// The newest moment anything went in either direction.
    var lastSync: Date? { [lastImport, lastExport].compactMap { $0 }.max() }

    private var running: Set<UUID> = []

    private init() {
        // ponytail: never removed, the shared instance lives as long as the app.
        NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main
        ) { note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else { return }
            MainActor.assumeIsolated { CloudSync.shared.handle(event) }
        }
        NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in await CloudSync.shared.refreshAccount() }
        }
        Task { await refreshAccount() }
    }

    func refreshAccount() async {
        guard Self.hasCloudKitEntitlement else { account = .unsupported; return }
        #if os(iOS)
        // nil when signed out, and also in a build signed without iCloud (an
        // unsigned simulator run), where touching CKContainer would crash.
        guard FileManager.default.ubiquityIdentityToken != nil else { account = .noAccount; return }
        #endif
        do {
            account = switch try await CKContainer(identifier: CloudStore.containerID).accountStatus() {
            case .available: .available
            case .noAccount: .noAccount
            case .restricted: .restricted
            case .temporarilyUnavailable: .temporarilyUnavailable
            default: .unknown
            }
        } catch {
            account = .unknown
            lastError = error.localizedDescription
        }
    }

    /// Records `publish`'s fresh reading and re-checks the account. The mirror
    /// takes it from there; `isSyncing` follows what it actually does.
    func syncNow(publish: () -> Void) async {
        lastError = nil
        await refreshAccount()
        guard account == .available else { return }
        publish()
    }

    private func handle(_ event: NSPersistentCloudKitContainer.Event) {
        guard let end = event.endDate else {
            running.insert(event.identifier)
            isSyncing = true
            return
        }
        running.remove(event.identifier)
        isSyncing = !running.isEmpty
        guard event.succeeded else {
            lastError = event.error?.localizedDescription
            return
        }
        lastError = nil
        switch event.type {
        case .import:
            lastImport = end
            // Another device's reading just landed: the widgets show it too.
            WidgetFeed.update()
        case .export: lastExport = end
        default: break
        }
    }

    private static let hasCloudKitEntitlement: Bool = {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let services = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil)
        return (services as? [String])?.contains("CloudKit") == true
        #else
        // iOS has no SecTask; `refreshAccount` checks the identity token instead.
        return true
        #endif
    }()
}

extension CloudSync.Account {
    var title: String {
        switch self {
        case .unsupported: "Not Available in This Build"
        case .checking: "Checking…"
        case .available: "On"
        case .noAccount: "Signed Out"
        case .restricted: "Restricted"
        case .temporarilyUnavailable: "Temporarily Unavailable"
        case .unknown: "Unknown"
        }
    }

    var symbol: String {
        switch self {
        case .available: "checkmark.icloud"
        case .checking: "icloud"
        case .temporarilyUnavailable, .unknown: "exclamationmark.icloud"
        case .unsupported, .noAccount, .restricted: "icloud.slash"
        }
    }

    /// Why sync is off and what to do about it; nil when it is on.
    var explanation: String? {
        switch self {
        case .available, .checking: nil
        case .unsupported: "This build isn't signed for iCloud, so readings stay on this device."
        #if os(macOS)
        case .noAccount: "Sign in to iCloud in System Settings to sync your devices."
        #else
        case .noAccount: "Sign in to iCloud in Settings to sync your devices."
        #endif
        case .restricted: "iCloud is restricted on this device, by Screen Time or a profile."
        case .temporarilyUnavailable: "iCloud is temporarily unavailable. Try again in a moment."
        case .unknown: "Couldn't reach iCloud. Check your connection and try again."
        }
    }
}
