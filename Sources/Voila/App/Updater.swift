import Foundation
import Observation
import Sparkle

/// Auto-updates via Sparkle. Checks the appcast daily (configured in Info.plist) and asks before
/// installing; "Check for Updates…" triggers a check on demand.
@MainActor
@Observable
final class Updater {
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    private(set) var canCheckForUpdates = false

    /// Only real, bundled builds with a feed URL update themselves (not debug/demo runs).
    var isAvailable: Bool { controller != nil }

    func start() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                      userDriverDelegate: nil)
        self.controller = controller
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let can = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = can }
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
