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

/// What the expanded panel shows: the task lists alone, or today's meetings above them.
enum PanelTab: String {
    case tasks, today
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let auth = GoogleAuth()
    let updater = Updater()
    let store: TaskStore
    let calendar: CalendarStore
    let directory: DirectoryStore
    private(set) var tab = PanelTab(rawValue: UserDefaults.standard.string(forKey: "panelTab") ?? "") ?? .tasks
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
    @ObservationIgnored private let meetingCard = MeetingCardController()
    @ObservationIgnored private var meetingAlarm: Task<Void, Never>?

    /// Ticks every 15 s so the menu bar can show the running task's minutes.
    private(set) var clock = Date()

    /// Minutes worked so far on the running task, for the menu bar (nil when nothing runs).
    var runningMinutes: Int? {
        guard let track = store.focusTask?.track, track.isRunning else { return nil }
        return Int(track.elapsed(at: clock) / 60)
    }

    /// Whether meetings are available (calendar permission granted, or demo data).
    var showsCalendar: Bool { (auth.isSignedIn && auth.hasCalendarAccess) || isDemo }

    /// Next or ongoing meeting, for the menu bar (nil when nothing is within the hour).
    var meetingStatus: MeetingStatus? { showsCalendar ? calendar.status(at: clock) : nil }

    /// "⏱ 42m" for the running task and "📅 12m" / "📹 23m left" for meetings, side by side.
    var menuBarParts: [MenuBarLabel.Part] {
        var parts: [MenuBarLabel.Part] = []
        if let minutes = runningMinutes { parts.append(.init(symbol: "timer", text: "\(minutes)m")) }
        switch meetingStatus {
        case .upcoming(let minutes): parts.append(.init(symbol: "calendar", text: "\(minutes)m"))
        case .ongoing(let left): parts.append(.init(symbol: "video.fill", text: "\(left)m left"))
        case nil: break
        }
        return parts
    }

    private init() {
        store = TaskStore(auth: auth)
        calendar = CalendarStore(auth: auth)
        directory = DirectoryStore(auth: auth)
        calendar.onChange = { [weak self] in
            guard let self else { return }
            self.armMeetingAlarm()
            // Colleagues' job titles for the coming meetings, ready before their card appears.
            Task { await self.directory.load(for: self.calendar.meetings) }
        }
        meetingCard.onJoin = { [weak self] meeting in self?.join(meeting) }
        meetingCard.directory = directory
        // Starting a task means it's time to focus: collapse to the compact pill.
        store.onTaskStarted = { [weak self] in
            guard let self, !self.isCompact else { return }
            self.setCompact(true)
        }
        // Pausing ends the focus session: back to the full panel.
        store.onTaskPaused = { [weak self] in
            guard let self, self.isCompact else { return }
            self.setCompact(false)
        }
    }

    func launch() {
        if !isDemo { updater.start() }
        NSApp.appearance = appearance.nsAppearance
        clockTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.clock = Date()
                self?.announceDueMeetings()   // safety net for the precise alarm below
            }
        }
        let controller = PanelController(rootView: RootView().environment(self), compact: isCompact)
        panel = controller
        controller.onVisibilityChange = { [weak self] visible in self?.isPanelVisible = visible }
        trafficLightsInset = controller.trafficLightsInset
        controller.show()
        #if DEBUG
        if isDemo {
            store.loadDemo()
            calendar.loadDemo()
            directory.loadDemo()
            // VOILA_DEMO_CARD=m2 (or m2,m3 for meetings starting together) opens the card at launch.
            let ids = (ProcessInfo.processInfo.environment["VOILA_DEMO_CARD"] ?? "").split(separator: ",").map(String.init)
            meetingCard.present(calendar.meetings.filter { ids.contains($0.id) }, activate: false)
            if ProcessInfo.processInfo.environment["VOILA_DEMO_MENUBAR"] == "1" {
                DemoSnapshot.showMenuBarPanel(model: self)
            }
            if let dir = ProcessInfo.processInfo.environment["VOILA_DEMO_SNAPSHOT"] {
                DemoSnapshot.write(to: dir, model: self)
            }
        }
        #endif
        if auth.isSignedIn && !isDemo { startSync() }

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAfterWake() }
        }
    }

    func startSync() {
        refreshLoop?.cancel()
        refreshLoop = Task { [weak self] in
            await self?.calendar.refresh()
            await self?.store.bootstrap()
            var minutes = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, self.auth.isSignedIn else { continue }
                await self.store.refresh(reportingOffline: false)   // background poll: don't nag while offline
                // Tasks sync every minute; the calendar changes less often: every 5 minutes.
                minutes += 1
                if minutes % 5 == 0 { await self.calendar.refresh() }
            }
        }
    }

    func refreshNow() {
        guard auth.isSignedIn else { return }
        Task {
            async let meetings: Void = calendar.refresh()
            if store.lists.isEmpty { await store.loadLists() }
            await store.refresh()
            await meetings
        }
    }

    private func refreshAfterWake() {
        guard auth.isSignedIn else { return }
        Task {
            await store.refreshAfterWake()
            clock = Date()
            await calendar.refresh()
            announceDueMeetings()
        }
    }

    func signOut() {
        refreshLoop?.cancel()
        meetingAlarm?.cancel()
        meetingCard.close()
        auth.signOut()
        store.reset()
        calendar.reset()
        directory.reset()
    }

    /// After a successful sign-in: start fresh (it may be a different account) and sync.
    func didSignIn() {
        store.reset()
        calendar.reset()
        directory.reset()
        startSync()
    }

    // MARK: - Meetings

    func setTab(_ tab: PanelTab) {
        withAnimation(.smooth(duration: 0.3)) { self.tab = tab }
        UserDefaults.standard.set(tab.rawValue, forKey: "panelTab")
        if tab == .today { Task { await calendar.refresh() } }
    }

    /// Accounts connected before the calendar existed: go through Google's consent once more.
    func connectCalendar() {
        Task {
            do {
                try await auth.signIn()
                didSignIn()
            } catch is CancellationError {
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }

    /// Opens the meeting card on request (a click in the Today view or the menu bar).
    func showMeeting(_ meeting: Meeting) {
        meetingCard.present([meeting], activate: true)
    }

    /// Opens the meeting in its app or the browser. Joining means the task at hand stops.
    func join(_ meeting: Meeting) {
        pauseRunningTask()
        meeting.link?.open()
    }

    /// A meeting takes over: stop the timer of the task in progress (it keeps its time).
    private func pauseRunningTask() {
        guard !isDemo, let task = store.focusTask, task.track.isRunning else { return }
        Task { await store.pause(task) }
    }

    /// Shows the card for meetings that are due, without taking keyboard focus, and pauses the
    /// running task when a meeting begins.
    private func announceDueMeetings() {
        guard showsCalendar, !isDemo else { return }
        if !calendar.takeStarted(at: .now).isEmpty { pauseRunningTask() }
        let due = calendar.takeDue(at: .now)
        if !due.isEmpty { meetingCard.present(due, activate: false) }
    }

    /// Sleeps until the next meeting's start so its card appears on time (the 15 s clock alone
    /// could be late). Re-armed after every calendar load.
    private func armMeetingAlarm() {
        meetingAlarm?.cancel()
        announceDueMeetings()
        guard let next = calendar.nextAnnouncement(after: .now) else { return }
        meetingAlarm = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            self.clock = Date()
            self.armMeetingAlarm()
        }
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
        // A window rather than a plain menu, so it can draw the day's timeline.
        MenuBarExtra {
            MenuBarPanel().environment(model)
        } label: {
            let parts = model.menuBarParts
            if parts.isEmpty {
                Image(systemName: "checklist")
            } else {
                Image(nsImage: MenuBarLabel.image(parts))
            }
        }
        .menuBarExtraStyle(.window)
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

/// Draws "⏱ 42m  📅 12m" as one template image: menu bar items reliably show a single image,
/// and a template image follows the menu bar's light/dark appearance.
enum MenuBarLabel {
    struct Part: Equatable {
        var symbol: String
        var text: String
    }

    static func image(_ parts: [Part]) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let height: CGFloat = 18, gap: CGFloat = 4, partGap: CGFloat = 9
        let items = parts.map { part in
            (symbol: NSImage(systemSymbolName: part.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) ?? NSImage(),
             text: part.text as NSString, textSize: (part.text as NSString).size(withAttributes: attributes))
        }
        let width = items.reduce(CGFloat(0)) { $0 + $1.symbol.size.width + gap + $1.textSize.width }
            + partGap * CGFloat(max(0, items.count - 1))
        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for item in items {
                item.symbol.draw(in: NSRect(x: x, y: (height - item.symbol.size.height) / 2,
                                            width: item.symbol.size.width, height: item.symbol.size.height))
                x += item.symbol.size.width + gap
                item.text.draw(at: NSPoint(x: x, y: (height - item.textSize.height) / 2), withAttributes: attributes)
                x += item.textSize.width + partGap
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The settings and app commands, shown under "⋯" in the menu bar window.
struct MenuBarSettingsItems: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button(model.isCompact ? "Expand Panel" : "Compact Panel") { model.setCompact(!model.isCompact) }
        Divider()
        Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLogin },
                                               set: { model.setLaunchAtLogin($0) }))
        Toggle("Show in Dock", isOn: Binding(get: { model.showInDock },
                                            set: { model.setShowInDock($0) }))
        AppearancePicker()
        if model.showsCalendar { MeetingSettingsMenu() }
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

/// "Meetings ▸" submenu: when the card appears, and which of your replies keep a meeting on screen.
struct MeetingSettingsMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let calendar = model.calendar
        Menu("Meetings") {
            Picker("Show Meeting Card", selection: Binding(get: { calendar.reminderLead ?? -1 },
                                                           set: { calendar.setReminderLead($0 < 0 ? nil : $0) })) {
                ForEach(CalendarStore.reminderChoices, id: \.title) { choice in
                    Text(choice.title).tag(choice.lead ?? -1)
                }
            }
            Divider()
            Toggle("Show Unanswered Meetings", isOn: Binding(get: { calendar.showUnanswered },
                                                             set: { calendar.setShow(.needsAction, $0) }))
            Toggle("Show Tentative Meetings", isOn: Binding(get: { calendar.showTentative },
                                                            set: { calendar.setShow(.tentative, $0) }))
            Toggle("Show Declined Meetings", isOn: Binding(get: { calendar.showDeclined },
                                                           set: { calendar.setShow(.declined, $0) }))
            if model.auth.isSignedIn, !model.auth.hasDirectoryAccess {
                Divider()
                // Connected before job titles existed (or the permission was unticked).
                Button("Show Colleagues' Job Titles…") { model.connectCalendar() }
            }
        }
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
