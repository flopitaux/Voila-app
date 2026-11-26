import AppKit
import SwiftUI

/// Borderless floating window for the meeting card. It never activates Voilà, so a card that
/// appears while you type elsewhere can't swallow a keystroke; Return / Esc work once you click it.
private final class MeetingPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar                       // above the Voilà panel and other floating windows
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        animationBehavior = .alertPanel
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
    }

    override var canBecomeKey: Bool { true }
}

/// Buttons respond to the very first click, although the card isn't the key window.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Shows one meeting card at a time; meetings starting together queue up behind each other.
@MainActor
final class MeetingCardController {
    private var panel: MeetingPanel?
    private var queue: [Meeting] = []
    private var autoClose: Task<Void, Never>?

    /// `activate`: the user asked for the card (give it keyboard focus) rather than it popping up.
    func present(_ meetings: [Meeting], activate: Bool) {
        guard let first = meetings.first else { return }
        if activate {
            queue = []
            show(first, activate: true)
        } else if panel?.isVisible == true {
            queue += meetings
        } else {
            queue = Array(meetings.dropFirst())
            show(first, activate: false)
        }
    }

    func close() {
        autoClose?.cancel()
        panel?.orderOut(nil)
        // Next meeting that started at the same time, if it is still on.
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if next.end > .now { show(next, activate: false); break }
        }
    }

    private func show(_ meeting: Meeting, activate: Bool) {
        let panel = self.panel ?? MeetingPanel()
        self.panel = panel
        let card = MeetingCardView(meeting: meeting,
                                   onJoin: { [weak self] in meeting.link?.open(); self?.close() },
                                   onOpenCalendar: { [weak self] in
                                       if let url = meeting.calendarURL { NSWorkspace.shared.open(url) }
                                       self?.close()
                                   },
                                   onClose: { [weak self] in self?.close() })
        let hosting = FirstClickHostingView(rootView: card)
        hosting.safeAreaRegions = []
        panel.contentView = hosting

        // The monitor you're looking at: the one with the mouse pointer.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var size = hosting.fittingSize
        size.height = min(size.height, visible.height - 80)
        // Centered, a little above the middle.
        let origin = NSPoint(x: visible.midX - size.width / 2,
                             y: visible.minY + (visible.height - size.height) * 0.6)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.invalidateShadow()
        if activate { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }

        // A card for a meeting still to end goes away by itself when the meeting is over.
        autoClose?.cancel()
        if meeting.end > .now {
            autoClose = Task { [weak self] in
                try? await Task.sleep(for: .seconds(meeting.end.timeIntervalSinceNow))
                if !Task.isCancelled { self?.close() }
            }
        }
    }
}

/// The card: what the meeting is, who is coming, what it is about, and a Join button.
struct MeetingCardView: View {
    var meeting: Meeting
    var onJoin: () -> Void
    var onOpenCalendar: () -> Void
    var onClose: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 18) {
            header
            people
            if !meeting.topics.isEmpty || !meeting.attachments.isEmpty { topics }
            buttons
        }
        .padding(26)
        .frame(width: 520, alignment: .leading)
        .font(.voila(13))
        .background(Theme.background, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.primary.opacity(0.12), lineWidth: 1))
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 10)) { context in
                let state = Self.state(of: meeting, at: context.date)
                HStack(spacing: 7) {
                    if state.live { LiveDot(isRunning: true, size: 8).frame(width: 14, height: 14) }
                    Text(state.text)
                        .font(.voila(12, .semibold))
                        .foregroundStyle(state.live ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                }
            }
            Text(meeting.title)
                .font(.voila(24, .bold))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Label("\(meeting.timeRange) · \(DurationFormat.short(meeting.duration))", systemImage: "clock")
                if let link = meeting.link, link.service != .other {
                    Label(link.service.rawValue, systemImage: "video")
                }
                if let location = meeting.location, URL(string: location)?.scheme == nil {
                    Label(location, systemImage: "mappin.and.ellipse").lineLimit(1)
                }
            }
            .font(.voila(12, .medium))
            .foregroundStyle(.secondary)
        }
    }

    private static func state(of meeting: Meeting, at now: Date) -> (text: String, live: Bool) {
        func minutes(_ interval: TimeInterval) -> String { DurationFormat.short(max(60, interval)) }
        if now >= meeting.end { return ("Ended", false) }
        if now < meeting.start {
            let wait = meeting.start.timeIntervalSince(now)
            return (wait < 60 ? "Starting now" : "Starts in \(minutes(wait))", wait < 10 * 60)
        }
        let since = now.timeIntervalSince(meeting.start)
        let left = "\(minutes(meeting.end.timeIntervalSince(now))) left"
        return (since < 60 ? "Starting now · \(left)" : "Started \(minutes(since)) ago · \(left)", true)
    }

    // MARK: People

    private var people: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                sectionTitle("People", count: meeting.attendees.isEmpty ? nil : meeting.attendees.count)
                Spacer()
                if let organizer = meeting.organizer {
                    Text("Organized by \(organizer)")
                        .font(.voila(11))
                        .foregroundStyle(.secondary)
                }
            }
            if meeting.attendees.isEmpty {
                Text("No guests on this event.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    group(.accepted, tint: Theme.done)
                    group(.tentative, tint: Theme.tint)
                    group(.declined, tint: Theme.overdue)
                    group(.needsAction, tint: .secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.07)))
            }
        }
    }

    @ViewBuilder
    private func group(_ response: Meeting.Response, tint: Color) -> some View {
        let members = meeting.attendees(response)
        if !members.isEmpty {
            let shown = members.prefix(12).map(\.name).joined(separator: ", ")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: response.symbol).foregroundStyle(tint)
                    Text(response.title)
                    Text("\(members.count)").monospacedDigit().foregroundStyle(.tertiary)
                }
                .font(.voila(12, .semibold))
                .frame(width: 112, alignment: .leading)
                Text(members.count > 12 ? "\(shown) and \(members.count - 12) more" : shown)
                    .font(.voila(12.5))
                    .foregroundStyle(response == .declined ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Topics

    private var topics: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Topics", count: nil)
            if !meeting.topics.isEmpty {
                ScrollView {
                    Text(meeting.topics)
                        .font(.voila(13))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: 170)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !meeting.attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(meeting.attachments.prefix(3), id: \.self) { title in
                        Chip(text: title, systemImage: "paperclip", tint: Theme.tint2)
                            .lineLimit(1)
                    }
                    if meeting.attachments.count > 3 {
                        Chip(text: "+\(meeting.attachments.count - 3)")
                    }
                }
            }
        }
    }

    private func sectionTitle(_ title: String, count: Int?) -> some View {
        HStack(spacing: 6) {
            Text(title)
            if let count { Text("\(count)").monospacedDigit().foregroundStyle(.tertiary) }
        }
        .font(.voila(12, .semibold))
        .foregroundStyle(.secondary)
    }

    // MARK: Buttons

    /// Drawn by hand rather than with system button styles: those look disabled while the
    /// card isn't the key window, which is exactly when it pops up.
    private var buttons: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Text("Close")
                    .font(.voila(14, .semibold))
                    .frame(width: 110, height: 40)
                    .background(.primary.opacity(0.08), in: Capsule())
                    .contentShape(Capsule())
            }
            .keyboardShortcut(.cancelAction)

            if let link = meeting.link {
                Button(action: onJoin) {
                    Label(link.joinTitle, systemImage: "video.fill")
                        .font(.voila(14, .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(Theme.accent, in: Capsule())
                        .shadow(color: Theme.tint2.opacity(0.35), radius: 8, y: 3)
                        .contentShape(Capsule())
                }
                .keyboardShortcut(.defaultAction)
            } else if meeting.calendarURL != nil {
                Button(action: onOpenCalendar) {
                    Label("Open in Google Calendar", systemImage: "calendar")
                        .font(.voila(14, .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(.primary.opacity(0.08), in: Capsule())
                        .contentShape(Capsule())
                }
            } else {
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .padding(.top, 2)
    }
}
