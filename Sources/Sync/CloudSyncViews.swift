import SwiftData
import SwiftUI

/// The iCloud status rows and the Sync Now button, for either app's settings.
/// `publish` records a fresh reading of this device, skipping the spacing.
struct CloudSyncSection: View {
    let publish: () -> Void
    private var sync = CloudSync.shared

    init(publish: @escaping () -> Void) {
        self.publish = publish
    }

    var body: some View {
        Section {
            LabeledContent {
                Text(sync.account.title)
            } label: {
                Label("iCloud", systemImage: sync.account.symbol)
            }
            if sync.account == .available {
                LabeledContent("Status") {
                    if sync.isSyncing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Syncing…")
                        }
                    } else if sync.lastError != nil {
                        Text("Failed")
                    } else {
                        Text("Up to Date")
                    }
                }
                // Once a minute keeps "5 minutes ago" honest with nothing syncing.
                TimelineView(.everyMinute) { context in
                    LabeledContent("Last Synced",
                                   value: sync.lastSync.map { Fmt.relative($0, now: context.date) } ?? "Not since launch")
                }
                Button("Sync Now") {
                    Task { await sync.syncNow(publish: publish) }
                }
                .disabled(sync.isSyncing)
            }
        } header: {
            Text("iCloud Sync")
        } footer: {
            if let error = sync.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            } else if let explanation = sync.account.explanation {
                Text(explanation)
            } else {
                Text("Readings sync through your private iCloud database. Sync Now saves a fresh reading of this device and sends it, picking up what your other devices sent.")
            }
        }
        .task { await sync.refreshAccount() }
    }
}

/// What iCloud holds, one row per device, each history removable.
struct SyncedDataSection: View {
    @Query(sort: \BatteryRecord.date, order: .reverse) private var records: [BatteryRecord]
    @State private var error: String?

    var body: some View {
        let histories = SyncedHistory.summaries(from: records)
        let currentID = SyncDevice.current.id
        Section {
            if histories.isEmpty {
                Text("Nothing synced yet.").foregroundStyle(.subdued)
            }
            ForEach(histories) { history in
                SyncedHistoryRow(history: history, isCurrent: history.id == currentID, error: $error)
            }
        } header: {
            Text("Synced Data")
        } footer: {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            } else {
                Text("Readings older than 30 days are removed automatically. Deleting a device removes its history from every device on this iCloud account; if it is still running OpenBattery, it starts a new one.")
            }
        }
    }
}

/// Owns its own confirmation: a dialog on the Section would be copied onto
/// every row of the List, and the copies fight over one shared state.
private struct SyncedHistoryRow: View {
    let history: SyncedHistory
    let isCurrent: Bool
    @Binding var error: String?
    @State private var confirming = false

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(history.count) readings")
                Text(Fmt.relative(history.newest))
                    .font(.caption)
                    .foregroundStyle(.subdued)
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isCurrent ? "\(history.device.name) (This Device)" : history.device.name)
                    if let mac = history.device.relayedBy {
                        Text("Read by \(mac)").font(.caption).foregroundStyle(.subdued)
                    }
                }
            } icon: {
                Image(systemName: history.device.symbol)
            }
        }
        .accessibilityElement(children: .combine)
        .contextMenu { deleteButton }
        #if os(iOS)
        // Not `role: .destructive`: that slides the row away before the
        // person has confirmed anything.
        .swipeActions { deleteButton.tint(.red) }
        #endif
        .accessibilityActions { deleteButton }
        .confirmationDialog("Delete the history of “\(history.device.name)”?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("Delete \(history.count) Readings", role: .destructive, action: delete)
        } message: {
            Text("This removes it from iCloud on all your devices.")
        }
    }

    private var deleteButton: some View {
        Button("Delete History…", systemImage: "trash") { confirming = true }
    }

    private func delete() {
        do {
            error = nil
            try CloudStore.shared.deleteHistory(of: history.id)
        } catch {
            self.error = "Couldn't delete. \(error.localizedDescription)"
        }
    }
}
