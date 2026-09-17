import Combine
import Foundation
import IOKit.pwr_mgt

/// Holds an IOKit power assertion so the display does not sleep on its own.
///
/// `kIOPMAssertPreventUserIdleDisplaySleep` is the assertion `caffeinate -d`
/// takes: it only stops the *idle* timer, so closing the lid or locking the
/// screen still turns the display off. The older
/// `kIOPMAssertionTypeNoDisplaySleep` is its deprecated spelling and outranks
/// the user, which is not ours to decide.
@MainActor
final class CaffeineController: ObservableObject {

    @Published private(set) var isActive = false

    /// Non-nil exactly while an assertion is held.
    private var assertionID: IOPMAssertionID?

    deinit {
        if let assertionID {
            IOPMAssertionRelease(assertionID)
        }
    }

    func setActive(_ active: Bool) {
        // Releasing first means a second activation can never orphan the
        // assertion we are about to overwrite.
        release()
        guard active else { return }

        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            // Shown verbatim by `pmset -g assertions`, so it names the app.
            "OpenBattery is keeping the display awake" as CFString,
            &id
        )
        // Nothing to report but the switch itself: staying off says the display
        // will sleep, which is the truth.
        guard result == kIOReturnSuccess else { return }

        assertionID = id
        isActive = true
    }

    // ponytail: deliberately not persisted across launches. The app starts at
    // login, and waking up to a display pinned on by last week's toggle is a
    // surprise nobody asked for.
    private func release() {
        if let assertionID {
            IOPMAssertionRelease(assertionID)
        }
        assertionID = nil
        isActive = false
    }
}
