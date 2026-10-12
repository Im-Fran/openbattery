import AppKit
import Darwin

/// The apps drawing the most power right now, for the popover.
///
/// The kernel keeps a running energy total for every process
/// (`ri_energy_nj`); two samples a few seconds apart give each one's watts.
/// Helpers are charged to the app whose bundle they live in, so a browser's
/// renderers count as the browser. Only apps with a Dock icon are listed,
/// like the system's own "Apps Using Significant Energy".
///
/// ponytail: attribution is by bundle path, so work done for an app by a
/// shared system service (Safari's WebContent lives in WebKit.framework) is
/// not charged to it. Coalitions would fix that, but they are private API.
@MainActor
final class AppEnergyMonitor: ObservableObject {

    struct Usage: Identifiable, Equatable {
        let bundlePath: String
        let name: String
        let watts: Double

        var id: String { bundlePath }
    }

    /// Nil until two samples exist. Empty means nothing worth listing.
    @Published private(set) var top: [Usage]?

    static let count = 5
    /// Below this an app is idle, and listing it is noise.
    static let threshold = 0.01
    /// The popover's pace, as `BatteryMonitor.windowInterval`.
    static let interval: TimeInterval = 5

    /// Samples while the calling view is on screen; `.task` cancels it.
    func run() async {
        var last = AppEnergy.sample()
        // A quick first reading so the popover is not blank for long, then the
        // same pace as the rest of the popover.
        var interval: TimeInterval = 1
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            let now = AppEnergy.sample()
            let fresh = AppEnergy.rank(from: last, to: now, over: interval,
                                       apps: Self.runningApps(), threshold: Self.threshold)
            top = Array(fresh.prefix(Self.count))
            last = now
            interval = Self.interval
        }
    }

    /// Bundle path → name, for apps with a Dock icon. The bundle is taken from
    /// the same path the samples use, so firmlinked system apps still match.
    private static func runningApps() -> [String: String] {
        var apps: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let path = AppEnergy.executablePath(app.processIdentifier),
                  let bundle = AppEnergy.bundlePath(of: path) else { continue }
            apps[bundle] = app.localizedName ?? FileManager.default.displayName(atPath: bundle)
        }
        return apps
    }
}

enum AppEnergy {
    struct Reading: Equatable {
        let path: String
        let nanojoules: UInt64
    }

    /// Every process we are allowed to read, which excludes root's.
    static func sample() -> [pid_t: Reading] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var readings: [pid_t: Reading] = [:]
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            guard let energy = energy(pid), let path = executablePath(pid) else { continue }
            readings[pid] = Reading(path: path, nanojoules: energy)
        }
        return readings
    }

    /// Watts per app between two samples, highest first. A process only counts
    /// if it is the same executable in both, so a reused pid is not mistaken
    /// for a huge jump.
    static func rank(from old: [pid_t: Reading], to new: [pid_t: Reading], over seconds: TimeInterval,
                     apps: [String: String], threshold: Double) -> [AppEnergyMonitor.Usage] {
        guard seconds > 0 else { return [] }
        var joules: [String: Double] = [:]
        for (pid, now) in new {
            guard let then = old[pid], then.path == now.path, now.nanojoules >= then.nanojoules,
                  let bundle = bundlePath(of: now.path), apps[bundle] != nil else { continue }
            joules[bundle, default: 0] += Double(now.nanojoules - then.nanojoules) / 1e9
        }
        return joules
            .map { AppEnergyMonitor.Usage(bundlePath: $0.key, name: apps[$0.key]!, watts: $0.value / seconds) }
            .filter { $0.watts >= threshold }
            .sorted { $0.watts > $1.watts }
    }

    /// The outermost `.app` in a path: helpers nested in `Contents/Frameworks`
    /// belong to the app that ships them.
    static func bundlePath(of executable: String) -> String? {
        guard let range = executable.range(of: ".app/") else { return nil }
        return String(executable[..<executable.index(before: range.upperBound)])
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func energy(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        return result == 0 ? info.ri_energy_nj : nil
    }
}
