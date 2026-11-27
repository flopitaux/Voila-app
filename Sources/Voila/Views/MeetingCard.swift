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

/// Shows the meeting card. Meetings that start together share one card.
@MainActor
final class MeetingCardController {
    private var panel: MeetingPanel?
    private var autoClose: Task<Void, Never>?
    private var trackGeneration = 0
    /// What Join does (the app opens the link and pauses the running task).
    var onJoin: ((Meeting) -> Void)?
    /// Colleagues' job titles, shown next to internal guests.
    var directory: DirectoryStore?

    /// `activate`: the user asked for the card (give it keyboard focus) rather than it popping up.
    func present(_ meetings: [Meeting], activate: Bool) {
        guard !meetings.isEmpty else { return }
        let panel = self.panel ?? MeetingPanel()
        self.panel = panel
        let card = MeetingCardView(meetings: meetings,
                                   onJoin: { [weak self] meeting in self?.onJoin?(meeting); self?.close() },
                                   onOpenCalendar: { [weak self] meeting in
                                       if let url = meeting.calendarURL { NSWorkspace.shared.open(url) }
                                       self?.close()
                                   },
                                   onClose: { [weak self] in self?.close() })
        let hosting = FirstClickHostingView(rootView: card.environment(\.directory, directory))
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

        trackTitles()

        // A card for meetings still to end goes away by itself when the last one is over.
        autoClose?.cancel()
        if let end = meetings.map(\.end).max(), end > .now {
            autoClose = Task { [weak self] in
                try? await Task.sleep(for: .seconds(end.timeIntervalSinceNow))
                if !Task.isCancelled { self?.close() }
            }
        }
    }

    func close() {
        autoClose?.cancel()
        panel?.orderOut(nil)
    }

    /// Job titles can arrive after the card is up and add lines: grow the window to fit,
    /// keeping its top edge and horizontal centre where they are.
    private func trackTitles() {
        guard let directory else { return }
        // One watcher per card: an older card's watcher stops when a newer card replaces it.
        trackGeneration += 1
        let generation = trackGeneration
        watchTitles(directory, generation: generation)
    }

    private func watchTitles(_ directory: DirectoryStore, generation: Int) {
        withObservationTracking { _ = directory.titles; _ = directory.photos } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.trackGeneration,
                      let panel = self.panel, panel.isVisible, let view = panel.contentView else { return }
                let size = view.fittingSize
                let frame = panel.frame
                panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height,
                                      width: size.width, height: size.height), display: true, animate: true)
                panel.invalidateShadow()
                self.watchTitles(directory, generation: generation)
            }
        }
    }
}

extension EnvironmentValues {
    /// Where the card finds colleagues' job titles (nil: names only).
    @Entry var directory: DirectoryStore? = nil
}

/// The card window's content: one meeting in full, or several meetings that start together,
/// side by side, each with its own Join button.
struct MeetingCardView: View {
    var meetings: [Meeting]
    var onJoin: (Meeting) -> Void
    var onOpenCalendar: (Meeting) -> Void
    var onClose: () -> Void

    private static let columnWidth: CGFloat = 460

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 34, style: .continuous)
        Group {
            if meetings.count == 1, let meeting = meetings.first {
                MeetingDetail(meeting: meeting, stacked: false, onJoin: { onJoin(meeting) },
                              onOpenCalendar: { onOpenCalendar(meeting) }, onClose: onClose)
                    .padding(44)
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    Label("\(meetings.count) meetings at the same time", systemImage: "rectangle.stack")
                        .font(.voila(13, .semibold))
                        .foregroundStyle(Theme.accent)
                    // Side by side, so both are readable at a glance; a fourth one scrolls sideways.
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(meetings, id: \.occurrenceKey) { meeting in
                                MeetingDetail(meeting: meeting, stacked: true, onJoin: { onJoin(meeting) },
                                              onOpenCalendar: { onOpenCalendar(meeting) }, onClose: onClose)
                                    .padding(24)
                                    .frame(width: Self.columnWidth)
                                    .frame(maxHeight: .infinity, alignment: .top)
                                    .background(Theme.surface.opacity(0.55),
                                                in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                                        .strokeBorder(Theme.cardStroke))
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)   // columns share the tallest one's height
                    }
                    .scrollIndicators(meetings.count > 3 ? .automatic : .never)
                    .frame(width: CGFloat(min(meetings.count, 3)) * (Self.columnWidth + 14) - 14)
                    HStack {
                        MeetingDetail.closeButton(onClose)
                        Spacer()
                    }
                }
                .padding(32)
            }
        }
        .font(.voila(14))
        .background(WindowDragArea())   // drag the card anywhere by its empty areas
        .background(Theme.background, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.panelStroke, lineWidth: 1))
    }
}

/// One meeting: what it is, who is coming, what it is about, and a Join button.
/// Airy, with regular-size text: people on the left, topics on the right.
/// `stacked`: one of several in the same card, so a single narrow column, and Close is shared below.
private struct MeetingDetail: View {
    var meeting: Meeting
    var stacked: Bool
    var onJoin: () -> Void
    var onOpenCalendar: () -> Void
    var onClose: () -> Void

    @Environment(\.directory) private var directory
    /// Which text the right column shows when the meeting has both.
    @State private var showsPrep = false

    private var hasTopics: Bool {
        !meeting.topics.isEmpty || !meeting.prepNotes.isEmpty || !meeting.attachments.isEmpty
    }
    /// Long notes (a prep brief): the topics get most of a wider card.
    private var hasLongTopics: Bool { max(meeting.topics.count, meeting.prepNotes.count) > 500 }
    /// The invite's description and your prep notes both exist: show them as two tabs.
    private var hasTabs: Bool { !meeting.topics.isEmpty && !meeting.prepNotes.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: stacked ? 18 : 30) {
            header
            // On its own: people beside topics. Sharing the card: one narrow column each.
            let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
                                 : AnyLayout(HStackLayout(alignment: .top, spacing: 36))
            layout {
                people.frame(maxWidth: hasLongTopics && !stacked ? 300 : .infinity, alignment: .topLeading)
                if hasTopics { topics.frame(maxWidth: .infinity, alignment: .topLeading) }
            }
            .frame(minHeight: stacked ? 0 : 220, alignment: .top)
            if stacked { Spacer(minLength: 0) }   // Join buttons line up at the bottom
            buttons
        }
        .frame(width: stacked ? nil : (hasLongTopics ? 952 : hasTopics ? 792 : 552), alignment: .leading)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.periodic(from: .now, by: 10)) { context in
                let state = Self.state(of: meeting, at: context.date)
                HStack(spacing: 7) {
                    if state.live { LiveDot(isRunning: true, size: 8).frame(width: 14, height: 14) }
                    Text(state.text)
                        .font(.voila(13, .semibold))
                        .foregroundStyle(state.live ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                    Spacer()
                    audienceBadge
                }
            }
            Text(meeting.title)
                .font(.voila(stacked ? 21 : 28, .bold))
                .lineLimit(stacked ? 2 : 3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: stacked ? 12 : 18) {
                Label("\(meeting.timeRange) · \(DurationFormat.short(meeting.duration))", systemImage: "clock")
                if let link = meeting.link, link.service != .other {
                    HStack(spacing: 5) {
                        ServiceIcon(service: link.service, size: 18, fallback: "video")
                        Text(link.service.rawValue)
                    }
                }
                if let location = meeting.location, URL(string: location)?.scheme == nil {
                    Label(location, systemImage: "mappin.and.ellipse").lineLimit(1)
                }
            }
            .font(.voila(13, .medium))
            .foregroundStyle(.secondary)
        }
    }

    /// "Internal", or "External · northwind.com" in a warmer color so it stands out.
    @ViewBuilder
    private var audienceBadge: some View {
        if let audience = meeting.audience {
            let outside = audience == .outside
            let domains = meeting.externalDomains.prefix(2).joined(separator: ", ")
                + (meeting.externalDomains.count > 2 ? " +\(meeting.externalDomains.count - 2)" : "")
            Label(outside && !domains.isEmpty ? "External · \(domains)" : audience.rawValue,
                  systemImage: outside ? "globe" : "building.2")
                .font(.voila(12, .semibold))
                .foregroundStyle(outside ? Theme.tint : Color.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background((outside ? Theme.tint : Color.secondary).opacity(0.14), in: Capsule())
                .help(outside ? "Some guests are outside your organization" : "Everyone is in your organization")
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                sectionTitle("People", count: meeting.attendees.isEmpty ? nil : meeting.attendees.count)
                Spacer()
                if let organizer = meeting.organizer {
                    Text("Organized by \(organizer)")
                        .font(.voila(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            let outside = meeting.attendees.filter(\.isExternal)
            if meeting.attendees.isEmpty {
                Text("No guests on this event.").foregroundStyle(.secondary)
            } else if outside.isEmpty {
                peopleBox(meeting.attendees, title: nil, symbol: nil, tint: .secondary,
                          withTitles: meeting.audience == .inside)
            } else {
                // Mixed meeting: your colleagues first, then the guests from outside.
                peopleBox(meeting.attendees.filter { !$0.isExternal }, title: "Internal", symbol: "building.2",
                          tint: .secondary, withTitles: true)
                peopleBox(outside, title: "External · \(meeting.externalDomains.prefix(3).joined(separator: ", "))",
                          symbol: "globe", tint: Theme.tint, withLinkedIn: true)
            }
        }
    }

    /// One box of guests grouped by reply, optionally titled ("Internal 4").
    /// `withTitles`: colleagues, listed one per line with their job title from the directory.
    private func peopleBox(_ members: [Meeting.Attendee], title: String?, symbol: String?, tint: Color,
                           withTitles: Bool = false, withLinkedIn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title {
                HStack(spacing: 6) {
                    if let symbol { Image(systemName: symbol) }
                    Text(title).lineLimit(1)
                    Text("\(members.count)").monospacedDigit().opacity(0.6)
                }
                .font(.voila(12, .semibold))
                .foregroundStyle(tint)
            }
            group(.accepted, in: members, tint: Theme.done, withTitles: withTitles, withLinkedIn: withLinkedIn)
            group(.tentative, in: members, tint: Theme.tint, withTitles: withTitles, withLinkedIn: withLinkedIn)
            group(.declined, in: members, tint: Theme.overdue, withTitles: withTitles, withLinkedIn: withLinkedIn)
            group(.needsAction, in: members, tint: .secondary, withTitles: withTitles, withLinkedIn: withLinkedIn)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.cardStroke))
    }

    /// "✓ Accepted 4" with the names underneath: on one line, or, for colleagues, one per line
    /// with their job title ("Sarah Lin · VP Product").
    /// Outside guests, also one per line, get a link that searches LinkedIn for them.
    @ViewBuilder
    private func group(_ response: Meeting.Response, in all: [Meeting.Attendee], tint: Color,
                       withTitles: Bool, withLinkedIn: Bool) -> some View {
        let members = all.filter { $0.response == response }
        if !members.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: response.symbol).foregroundStyle(tint)
                    Text(response.title)
                    Text("\(members.count)").monospacedDigit().foregroundStyle(.tertiary)
                }
                .font(.voila(13, .semibold))
                Group {
                    if (withTitles && directory != nil) || withLinkedIn, !stacked || members.count <= 4 {
                        let limit = stacked ? 4 : 10
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(Array(members.prefix(limit).enumerated()), id: \.offset) { _, member in
                             HStack(spacing: 9) {
                              Avatar(name: member.isSelf ? "You" : member.name,
                                     photo: withTitles ? directory?.photo(for: member.email) : nil, size: 28)
                              VStack(alignment: .leading, spacing: 1) {
                                HStack(alignment: .center, spacing: 6) {
                                    Text(member.name).layoutPriority(1)
                                    if withLinkedIn, let url = member.linkedInSearchURL {
                                        Button { NSWorkspace.shared.open(url) } label: {
                                            LinkedInIcon(size: 22).contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .pointerStyle(.link)
                                        .help("Search LinkedIn for \(member.name)")
                                    }
                                }
                                .lineLimit(1)
                                // "Senior AI Outcomes Manager • 725 Customer COE", as in Google Calendar.
                                if withTitles, let title = directory?.title(for: member.email) {
                                    Text(title)
                                        .font(.voila(11.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .help(title)
                                }
                              }
                             }
                            }
                            if members.count > limit {
                                Text("and \(members.count - limit) more").foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        let shown = members.prefix(14).map(\.name).joined(separator: ", ")
                        Text(members.count > 14 ? "\(shown) and \(members.count - 14) more" : shown)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.voila(14))
                .foregroundStyle(response == .declined ? .secondary : .primary)
                .padding(.leading, 2)
            }
        }
    }

    // MARK: Topics

    private var topics: some View {
        VStack(alignment: .leading, spacing: 14) {
            if hasTabs {
                topicsPicker
                // Both texts are laid out, so the card keeps one size whichever tab is showing.
                ZStack(alignment: .topLeading) {
                    notes(meeting.topics).opacity(showsPrep ? 0 : 1).allowsHitTesting(!showsPrep)
                    notes(meeting.prepNotes).opacity(showsPrep ? 1 : 0).allowsHitTesting(showsPrep)
                }
            } else if !meeting.prepNotes.isEmpty {
                sectionTitle("Prep notes", count: nil)
                notes(meeting.prepNotes)
            } else {
                sectionTitle("Description", count: nil)
                if !meeting.topics.isEmpty { notes(meeting.topics) }
            }
            if !meeting.attachments.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(meeting.attachments.prefix(4), id: \.self) { title in
                        Chip(text: title, systemImage: "paperclip", tint: Theme.tint2).lineLimit(1)
                    }
                    if meeting.attachments.count > 4 {
                        Chip(text: "+\(meeting.attachments.count - 4)")
                    }
                }
            }
        }
    }

    private func notes(_ text: String) -> some View {
        ScrollView {
            TopicsText(text: text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 10)
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: stacked ? 120 : hasLongTopics ? 420 : 320)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "Description | Prep notes" pill: the invite's own text, or your notes from the Prep event.
    private var topicsPicker: some View {
        HStack(spacing: 2) {
            ForEach([false, true], id: \.self) { prep in
                let selected = showsPrep == prep
                Button { showsPrep = prep } label: {
                    Label(prep ? "Prep notes" : "Description", systemImage: prep ? "note.text" : "text.alignleft")
                        .font(.voila(12, .semibold))
                        .foregroundStyle(selected ? AnyShapeStyle(Theme.tint2) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Theme.tint2.opacity(selected ? 0.18 : 0), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
            }
        }
        .padding(2)
        .background(.primary.opacity(0.06), in: Capsule())
        .padding(.top, -5)   // sits on the same line as the "People" title
    }

    private func sectionTitle(_ title: String, count: Int?) -> some View {
        HStack(spacing: 6) {
            Text(title)
            if let count { Text("\(count)").monospacedDigit().foregroundStyle(.tertiary) }
        }
        .font(.voila(13, .semibold))
        .foregroundStyle(.secondary)
    }

    // MARK: Buttons

    /// Drawn by hand rather than with system button styles: those look disabled while the
    /// card isn't the key window, which is exactly when it pops up.
    private var buttons: some View {
        HStack(spacing: 12) {
            if !stacked { Self.closeButton(onClose) }

            if let link = meeting.link {
                Button(action: onJoin) {
                    HStack(spacing: 8) {
                        ServiceIcon(service: link.service, size: 26)
                        Text(link.joinTitle)
                    }
                        .font(.voila(15, .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Theme.accent, in: Capsule())
                        .shadow(color: Theme.tint2.opacity(0.35), radius: 8, y: 3)
                        .contentShape(Capsule())
                }
                .keyboardShortcut(stacked ? nil : .defaultAction)   // Return joins only when there is no choice
                .help("Opens \(link.url.host() ?? link.url.absoluteString)")
            } else if meeting.calendarURL != nil {
                Button(action: onOpenCalendar) {
                    Label("Open in Google Calendar", systemImage: "calendar")
                        .font(.voila(15, .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(.primary.opacity(0.08), in: Capsule())
                        .contentShape(Capsule())
                }
            } else {
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
    }

    static func closeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Close")
                .font(.voila(15, .semibold))
                .frame(width: 150, height: 48)
                .background(.primary.opacity(0.08), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .keyboardShortcut(.cancelAction)
    }
}

/// Topics laid out for reading at a glance: lines in capitals ("WHO IS IN THE ROOM") become
/// section headings, "- " lines become bullets, the rest is plain text.
private struct TopicsText: View {
    var text: String

    private enum Line {
        case heading(String), bullet(String), body(String), gap
    }

    private var lines: [Line] {
        text.components(separatedBy: .newlines).map { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return .gap }
            for marker in ["- ", "• ", "* ", "– "] where line.hasPrefix(marker) {
                return .bullet(String(line.dropFirst(marker.count)))
            }
            let letters = line.filter(\.isLetter)
            if letters.count >= 3, line.count <= 60, letters.allSatisfy(\.isUppercase) { return .heading(line) }
            return .body(line)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                switch line {
                case .heading(let title):
                    Text(title)
                        .font(.voila(11.5, .bold))
                        .kerning(0.6)
                        .foregroundStyle(Theme.tint2)
                        .padding(.top, index == 0 ? 0 : 8)
                case .bullet(let item):
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•").foregroundStyle(.secondary)
                        Text(item).fixedSize(horizontal: false, vertical: true)
                    }
                case .body(let content):
                    Text(content).fixedSize(horizontal: false, vertical: true)
                case .gap:
                    Color.clear.frame(height: 2)
                }
            }
        }
        .font(.voila(14))
        .lineSpacing(3)
        .textSelection(.enabled)
    }
}
