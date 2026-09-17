import ServiceManagement
import SwiftUI

/// The Settings window (⌘,): toolbar-tabbed panes, as on every Mac app.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }
            MenuBarSettingsPane()
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
        }
        .frame(width: 520)
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var error: String?

    private static let repository = URL(string: "https://github.com/Im-Fran/openbattery")!

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                appHeader
            }

            Section {
                Toggle("Launch at login", isOn: Binding(get: { launchesAtLogin },
                                                        set: setLaunchAtLogin(_:)))
            } header: {
                Text("Startup")
            } footer: {
                if let error {
                    // Colour lives on the icon; orange text fails contrast in light mode.
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
            }

            Section {
                LabeledContent("Version") {
                    Text(version).textSelection(.enabled)
                }
                LabeledContent("Data source", value: "IOKit, read-only")
                LabeledContent("License", value: "MIT")
                LabeledContent("Source code") {
                    Link("GitHub", destination: Self.repository)
                }
                LabeledContent("Found a bug?") {
                    Link("Report an Issue", destination: Self.repository.appending(path: "issues/new"))
                }
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
        .sizedToContent()
    }

    private var appHeader: some View {
        HStack(spacing: 12) {
            // No app icon ships yet; a symbol tile stands in for one.
            Image(systemName: "battery.100.bolt")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(.green.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("OpenBattery").font(.title2.weight(.semibold))
                Text("See what your battery is actually doing, straight from the menu bar.")
                    .foregroundStyle(.secondary)
                Text("© 2026 Francisco Solis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            error = nil
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            // Registration can "succeed" while still blocked on user approval.
            if SMAppService.mainApp.status == .requiresApproval {
                report("Allow OpenBattery in System Settings › General › Login Items.")
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            report("Couldn't change Launch at login. \(error.localizedDescription)")
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func report(_ message: String) {
        error = message
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}

// MARK: - Menu bar

/// The menu bar fields as tokens in a text-field-like well: drag to reorder,
/// drag in from the palette to add, drag back out to remove. Every drag has a
/// click, context-menu or VoiceOver equivalent.
private struct MenuBarSettingsPane: View {
    @AppStorage(MenuBarConfig.itemsKey) private var rawItems = MenuBarConfig.default.rawItems
    @AppStorage(MenuBarConfig.iconKey) private var showsIcon = MenuBarConfig.default.showsIcon

    /// The token a drag hovers, so the caret shows where the drop will land.
    @State private var dropTarget: MenuBarItem?
    @State private var isFieldTargeted = false
    @State private var isPaletteTargeted = false

    private var config: MenuBarConfig { MenuBarConfig(showsIcon: showsIcon, rawItems: rawItems) }
    private var available: [MenuBarItem] { MenuBarItem.allCases.filter { !config.contains($0) } }

    var body: some View {
        Form {
            Section {
                Toggle("Show battery icon", isOn: Binding(get: { config.effectiveShowsIcon },
                                                          set: { showsIcon = $0 }))
                    // Forced back on when nothing else is shown, so the toggle
                    // says what is really happening.
                    .disabled(config.items.isEmpty)
                tokenField
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("Drag items to reorder them. Drag an item out of the field to remove it.")
            }

            Section {
                palette
            } header: {
                Text("Available Items")
            } footer: {
                Text("Drag an item into the field above, or click it to add it at the end. Items marked with \(Image(systemName: "timer")) keep a more frequent battery reading running.")
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") { apply(.default) }
                        .disabled(config == .default)
                }
            }
        }
        .formStyle(.grouped)
        .sizedToContent()
    }

    // MARK: Field

    private var tokenField: some View {
        FlowLayout(spacing: 6) {
            ForEach(config.items, content: fieldToken)
            if config.items.isEmpty {
                Text("Drag items here")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            } else {
                // Where a drop onto the empty part of the field lands.
                caret(visible: isFieldTargeted && dropTarget == nil)
                    .frame(width: 2, height: Token.height)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: Token.height + 12, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            // The drop-target highlight, drawn like the keyboard focus ring.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isFieldTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                              lineWidth: isFieldTargeted ? 2 : 1)
        }
        .dropDestination(for: String.self) { strings, _ in
            drop(strings, before: nil)
        } isTargeted: { isFieldTargeted = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Menu bar items")
    }

    private func fieldToken(_ item: MenuBarItem) -> some View {
        Token(item: item)
            .overlay(alignment: .leading) { caret(visible: dropTarget == item) }
            .draggable(item.rawValue) { Token(item: item) }
            .dropDestination(for: String.self) { strings, _ in
                drop(strings, before: item)
            } isTargeted: { isTargeted in
                if isTargeted {
                    dropTarget = item
                } else if dropTarget == item {
                    dropTarget = nil
                }
            }
            .contextMenu { tokenActions(item) }
            .accessibilityActions { tokenActions(item) }
    }

    private func caret(visible: Bool) -> some View {
        Capsule()
            .fill(.tint)
            .frame(width: 2, height: Token.height)
            .offset(x: -4)
            .opacity(visible ? 1 : 0)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func tokenActions(_ item: MenuBarItem) -> some View {
        Button("Move Left") { apply(config.moving(item, by: -1)) }
            .disabled(config.items.first == item)
        Button("Move Right") { apply(config.moving(item, by: 1)) }
            .disabled(config.items.last == item)
        Divider()
        Button("Remove") { apply(config.removing(item)) }
    }

    // MARK: Palette

    private var palette: some View {
        FlowLayout(spacing: 6) {
            ForEach(available) { item in
                Button { apply(config.inserting(item, before: nil)) } label: { Token(item: item) }
                    .buttonStyle(.plain)
                    .draggable(item.rawValue) { Token(item: item) }
                    .accessibilityHint("Adds it to the menu bar")
            }
            if available.isEmpty {
                Text("All items are in the menu bar.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Token.height, alignment: .leading)
        .padding(.vertical, 2)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.tint, lineWidth: 2)
                .padding(-4)
                .opacity(isPaletteTargeted ? 1 : 0)
        }
        // Dropping a token back here takes it out of the menu bar.
        .dropDestination(for: String.self) { strings, _ in
            let dropped = strings.compactMap(MenuBarItem.init(rawValue:))
            apply(dropped.reduce(config) { $0.removing($1) })
            return !dropped.isEmpty
        } isTargeted: { isPaletteTargeted = $0 }
    }

    // MARK: Changes

    private func drop(_ strings: [String], before target: MenuBarItem?) -> Bool {
        let dropped = strings.compactMap(MenuBarItem.init(rawValue:))
        dropTarget = nil
        guard !dropped.isEmpty else { return false }
        withAnimation(.snappy) {
            apply(dropped.reduce(config) { $0.inserting($1, before: target) })
        }
        return true
    }

    private func apply(_ config: MenuBarConfig) {
        rawItems = config.rawItems
        showsIcon = config.effectiveShowsIcon
    }
}

/// One menu bar field, drawn like an `NSTokenField` token.
private struct Token: View {
    static let height: CGFloat = 22

    let item: MenuBarItem

    var body: some View {
        HStack(spacing: 4) {
            Text(item.title)
            if item.requiresDetailedRead {
                Image(systemName: "timer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Keeps a more frequent battery reading running")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background(Color.accentColor.opacity(0.15),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.4))
        }
        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
    }
}

/// Left-to-right rows that wrap, like words in a text field.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(for: subviews, width: proposal.width ?? .infinity)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(for: subviews, width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(for subviews: Subviews, width: CGFloat) -> [CGRect] {
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0
        return subviews.map { subview in
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > 0 && origin.x + size.width > width {
                origin = CGPoint(x: 0, y: origin.y + rowHeight + spacing)
                rowHeight = 0
            }
            defer { origin.x += size.width + spacing; rowHeight = max(rowHeight, size.height) }
            return CGRect(origin: origin, size: size)
        }
    }
}

private extension View {
    /// Settings panes size to their content instead of scrolling.
    func sizedToContent() -> some View {
        fixedSize(horizontal: false, vertical: true).scrollDisabled(true)
    }
}
