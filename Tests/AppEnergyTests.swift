import XCTest

final class AppEnergyTests: XCTestCase {

    private let chrome = "/Applications/Google Chrome.app"
    private let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"

    func testHelpersBelongToTheOutermostApp() {
        XCTAssertEqual(AppEnergy.bundlePath(of: helper), chrome)
        XCTAssertNil(AppEnergy.bundlePath(of: "/usr/libexec/trustd"))
    }

    func testSumsAnAppsProcessesAndSkipsTheRest() {
        let old: [pid_t: AppEnergy.Reading] = [
            1: .init(path: "\(chrome)/Contents/MacOS/Chrome", nanojoules: 0),
            2: .init(path: helper, nanojoules: 1_000_000_000),
            3: .init(path: "/usr/libexec/trustd", nanojoules: 0),
            4: .init(path: "/Applications/Old.app/Contents/MacOS/Old", nanojoules: 0),
        ]
        let new: [pid_t: AppEnergy.Reading] = [
            1: .init(path: "\(chrome)/Contents/MacOS/Chrome", nanojoules: 4_000_000_000),
            2: .init(path: helper, nanojoules: 7_000_000_000),
            3: .init(path: "/usr/libexec/trustd", nanojoules: 9_000_000_000),
            // Reused pid: a different executable, not a jump in energy.
            4: .init(path: "/Applications/New.app/Contents/MacOS/New", nanojoules: 9_000_000_000),
        ]
        let apps = [chrome: "Chrome", "/Applications/New.app": "New"]
        let ranked = AppEnergy.rank(from: old, to: new, over: 2, apps: apps, threshold: 0.01)
        XCTAssertEqual(ranked.map(\.name), ["Chrome"])
        XCTAssertEqual(ranked.first?.watts ?? 0, 5, accuracy: 1e-9)
    }
}
