import Foundation
import ServiceManagement

/// Opening at login, which macOS will only do for a real app bundle.
///
/// A supervisor you have to remember to start is not supervising. But this is
/// only offered when it can actually work: run from `swift build` there is no
/// bundle to register, so the panel does not show a switch that would fail.
enum LoginItem {
    /// True only for the bundled app, which is the only shape macOS can
    /// register. `make-app.sh` builds it.
    static var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    static var on: Bool {
        available && SMAppService.mainApp.status == .enabled
    }

    /// Returns nil on success, or what macOS said, so the panel can show its
    /// words rather than failing quietly.
    static func set(_ wanted: Bool) -> String? {
        guard available else {
            return "Build the app first, with app/mac/make-app.sh"
        }
        do {
            if wanted { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
