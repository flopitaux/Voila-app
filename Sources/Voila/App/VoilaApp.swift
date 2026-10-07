import AppKit
import Observation
import ServiceManagement
import SwiftUI

/// Light/dark appearance: follow the Mac setting, or force one.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Match System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil   // follows System Settings → Appearance, live
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let auth = GoogleAuth()
    let updater = Updater()
    let store: TaskStore
    private(set) var isCompact = UserDefaults.standard.bool(forKey: "compact")
    /// Whether the add-task field is expanded (otherwise only the + button shows).
    var isAddingTask = false
    private(set) var isPanelVisible = true
    /// Leading space reserved for the standard close/minimize/zoom buttons.
    private(set) var trafficLightsInset: CGFloat = 78
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Off = no Dock icon / ⌘-Tab entry; Voilà stays reachable from the menu bar icon.
    private(set) var showInDock = !UserDefaults.standard.bool(forKey: "hideDockIcon")
    private(set) var appearance = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system
    #if DEBUG
    let isDemo = ProcessInfo.processInfo.environment["VOILA_DEMO"] == "1"
    #else
    let isDemo = false
    #endif

    var showsTasks: Bool { auth.isSignedIn || isDemo }

    @ObservationIgnored private var panel: PanelController?
    @ObservationIgnored private var refreshLoop: Task<Void, Never>?
    @ObservationIgnored private var clockTimer: Timer?

    /// Ticks every 15 s so the menu bar can show the running task's minutes.
    private(set) var clock = Date()

    /// Minutes worked so far on the running task, for the menu bar (nil when nothing runs).
    var runningMinutes: Int? {
        guard let track = store.focusTask?.track, track.isRunning else { return nil }
        return Int(track.elapsed(at: clock) / 60)
    }

    private init() {
        store = TaskStore(auth: auth)
    }

    func launch() {
        if !isDemo { updater.start() }
        NSApp.appearance = appearance.nsAppearance
        clockTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.clock = Date() }
        }
        let controller = PanelController(rootView: RootView().environment(self), compact: isCompact)
        panel = controller
        controller.onVisibilityChange = { [weak self] visible in self?.isPanelVisible = visible }
        trafficLightsInset = controller.trafficLightsInset
        controller.show()
        #if DEBUG
        if isDemo { store.loadDemo() }
        #endif
        if auth.isSignedIn && !isDemo { startSync() }

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }
    }

    func startSync() {
        refreshLoop?.cancel()
        refreshLoop = Task { [weak self] in
            await self?.store.bootstrap()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, self.auth.isSignedIn else { continue }
                await self.store.refresh()
            }
        }
    }

    func refreshNow() {
        guard auth.isSignedIn else { return }
        Task {
            if store.lists.isEmpty { await store.loadLists() }
            await store.refresh()
        }
    }

    func signOut() {
        refreshLoop?.cancel()
        auth.signOut()
        store.reset()
    }

    /// After a successful sign-in: start fresh (it may be a different account) and sync.
    func didSignIn() {
        store.reset()
        startSync()
    }

    func startAddingTask() {
        showPanel()
        if isCompact { setCompact(false) }
        isAddingTask = true
    }

    func setCompact(_ compact: Bool) {
        withAnimation(.smooth(duration: 0.3)) { isCompact = compact }
        UserDefaults.standard.set(compact, forKey: "compact")
        panel?.setCompact(compact)
    }

    func togglePanel() {
        if panel?.isVisible == true { closePanel() } else { showPanel() }
    }

    func showPanel() {
        panel?.show()
        refreshNow()
    }

    /// Hides the panel; the app keeps running in the menu bar and timers keep counting.
    func closePanel() { panel?.hide() }

    /// Sends the panel to the Dock.
    func minimizePanel() { panel?.minimize() }

    func setAppearance(_ mode: AppearanceMode) {
        appearance = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "appearance")
        NSApp.appearance = mode.nsAppearance
    }

    func setShowInDock(_ show: Bool) {
        showInDock = show
        UserDefaults.standard.set(!show, forKey: "hideDockIcon")
        NSApp.setActivationPolicy(show ? .regular : .accessory)
        // Changing the activation policy can deactivate the app; keep the panel in front.
        DispatchQueue.main.async { self.panel?.show() }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            store.errorMessage = "Couldn't change Launch at Login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Apply "Show in Dock" before the Dock icon would appear.
    func applicationWillFinishLaunching(_ notification: Notification) {
        if UserDefaults.standard.bool(forKey: "hideDockIcon") { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.launch() }
    }

    /// Clicking the Dock icon brings the panel back after it was closed or minimized.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { AppModel.shared.showPanel() }
        return false
    }

    /// Closing the panel keeps Voilà running (Dock + menu bar); timers live in Google Tasks anyway.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct VoilaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent().environment(model)
        } label: {
            if let minutes = model.runningMinutes {
                Image(nsImage: MenuBarLabel.image(minutes: minutes))
            } else {
                Image(systemName: "checklist")
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Task") { model.startAddingTask() }
                    .keyboardShortcut("n")
            }
            CommandGroup(before: .windowSize) {
                Button("Close") { model.closePanel() }
                    .keyboardShortcut("w")
                Divider()
            }
            CommandGroup(after: .windowArrangement) {
                Button("Show Voilà") { model.showPanel() }
                    .keyboardShortcut("0")
                Button(model.isCompact ? "Expand Panel" : "Compact Panel") { model.setCompact(!model.isCompact) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {}
        }
    }
}

/// Draws "⏱ 42m" as one template image: menu bar items reliably show a single image,
/// and a template image follows the menu bar's light/dark appearance.
enum MenuBarLabel {
    static func image(minutes: Int) -> NSImage {
        let text = "\(minutes)m" as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textSize = text.size(withAttributes: attributes)
        let symbol = NSImage(systemSymbolName: "timer", accessibilityDescription: "Running")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) ?? NSImage()
        let height: CGFloat = 18, gap: CGFloat = 4
        let size = NSSize(width: ceil(symbol.size.width + gap + textSize.width), height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            symbol.draw(in: NSRect(x: 0, y: (height - symbol.size.height) / 2,
                                   width: symbol.size.width, height: symbol.size.height))
            text.draw(at: NSPoint(x: symbol.size.width + gap, y: (height - textSize.height) / 2),
                      withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
    }
}

private struct MenuBarContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button(model.isPanelVisible ? "Close Panel" : "Show Panel") { model.togglePanel() }
            .keyboardShortcut("t")
        Button(model.isCompact ? "Expand Panel" : "Compact Panel") { model.setCompact(!model.isCompact) }
        if model.auth.isSignedIn {
            Button("Refresh") { model.refreshNow() }
                .keyboardShortcut("r")
        }
        Divider()
        Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLogin },
                                               set: { model.setLaunchAtLogin($0) }))
        Toggle("Show in Dock", isOn: Binding(get: { model.showInDock },
                                            set: { model.setShowInDock($0) }))
        AppearancePicker()
        if model.auth.isSignedIn {
            Button("Sign Out of Google") { model.signOut() }
        }
        Divider()
        if model.updater.isAvailable {
            Button("Check for Updates…") { model.updater.checkForUpdates() }
                .disabled(!model.updater.canCheckForUpdates)
        }
        Button("Quit Voilà") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// "Appearance ▸ Match System / Light / Dark" submenu, used in the menu bar and ⋯ menus.
struct AppearancePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker("Appearance", selection: Binding(get: { model.appearance }, set: { model.setAppearance($0) })) {
            ForEach(AppearanceMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
    }
}
