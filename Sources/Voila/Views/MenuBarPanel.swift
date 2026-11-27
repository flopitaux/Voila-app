import SwiftUI

/// What opens from the menu bar icon: the day as a timeline, then the app's commands.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @State private var window: NSWindow?
    /// Days ahead of today on the timeline. Back to today every time the window closes.
    @State private var dayOffset = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 10) {
                    let day = Calendar.current.date(byAdding: .day, value: dayOffset, to: context.date) ?? context.date
                    header(now: context.date, day: day)
                    if model.showsCalendar {
                        DayTimeline(meetings: model.calendar.meetings(on: day), now: context.date, day: day,
                                    onOpen: { meeting in dismiss(); model.showMeeting(meeting) },
                                    onJoin: { meeting in dismiss(); model.join(meeting) })
                            .id(dayOffset)   // a fresh scroll position for each day
                    } else {
                        Text("Connect Google Calendar from the Today view in the panel to see your day here.")
                            .font(.voila(12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)
            }
            Rectangle().fill(Theme.cardStroke).frame(height: 1)
            footer
        }
        .frame(width: 340)
        .font(.voila(13))
        .background(Theme.background)
        .background(WindowReader { found in DispatchQueue.main.async { window = found } })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            if let window, note.object as? NSWindow === window { dayOffset = 0 }
        }
    }

    /// "Friday, Nov 27", what is next ("Next in 12 min"), and the arrows to the other days.
    private func header(now: Date, day: Date) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text(day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
                .font(.voila(15, .bold))
                .lineLimit(1)
            Spacer(minLength: 4)
            if model.showsCalendar {
                Text(dayOffset == 0 ? summary(now: now) : summary(of: day))
                    .font(.voila(11, .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 0) {
                    stepButton("chevron.left", by: -1, help: "Previous day")
                    if dayOffset != 0 {
                        Button { dayOffset = 0 } label: {
                            Text("Today")
                                .font(.voila(11, .semibold))
                                .foregroundStyle(Theme.tint2)
                                .padding(.horizontal, 4)
                                .frame(height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .pointerStyle(.link)
                        .help("Back to today")
                    }
                    stepButton("chevron.right", by: 1, help: "Next day")
                }
                .padding(.horizontal, 2)
                .background(.primary.opacity(0.07), in: Capsule())
            }
        }
    }

    private func stepButton(_ symbol: String, by step: Int, help: String) -> some View {
        let target = dayOffset + step
        let enabled = (0...CalendarStore.daysAhead).contains(target)
        return Button { dayOffset = target } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(enabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(enabled ? .link : .default)
        .disabled(!enabled)
        .help(help)
    }

    private func summary(now: Date) -> String {
        let calendar = model.calendar
        if let current = calendar.current(at: now) {
            return "\(max(1, Int((current.end.timeIntervalSince(now) / 60).rounded(.up)))) min left in meeting"
        }
        if let next = calendar.next(after: now), Calendar.current.isDate(next.start, inSameDayAs: now) {
            return "Next in \(DurationFormat.short(max(60, next.start.timeIntervalSince(now))))"
        }
        return calendar.meetings(on: now).isEmpty ? "No meetings today" : "No more meetings today"
    }

    /// Another day: how many meetings you are expected at.
    private func summary(of day: Date) -> String {
        let count = model.calendar.meetings(on: day).filter { !$0.isDeclined }.count
        return count == 0 ? "No meetings" : count == 1 ? "1 meeting" : "\(count) meetings"
    }

    private var footer: some View {
        HStack(spacing: 6) {
            footerButton(model.isPanelVisible ? "Close Panel" : "Show Panel",
                         symbol: model.isPanelVisible ? "rectangle.slash" : "rectangle.on.rectangle") {
                dismiss(); model.togglePanel()
            }
            if model.auth.isSignedIn {
                footerButton("Refresh", symbol: "arrow.clockwise") { model.refreshNow() }
            }
            Spacer()
            Menu {
                MenuBarSettingsItems()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.voila(13, .semibold))
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings, updates and Quit")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func footerButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.voila(12, .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.primary.opacity(0.07), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
    }

    /// Closes the menu bar window (it doesn't close by itself when a button inside is clicked).
    /// It is the window this view sits in, never "whichever window has the keyboard", which
    /// could be the task panel.
    private func dismiss() {
        window?.close()
    }
}

/// Reports the window a view ends up in.
private struct WindowReader: NSViewRepresentable {
    var onChange: (NSWindow?) -> Void

    final class Probe: NSView {
        var onChange: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onChange?(window)
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onChange = onChange
        return probe
    }

    func updateNSView(_ nsView: Probe, context: Context) { nsView.onChange = onChange }
}

/// The day drawn to scale: hours down the side, one block per meeting, a line for now.
struct DayTimeline: View {
    var meetings: [Meeting]
    var now: Date
    /// The day drawn (any moment of it); today unless the user stepped to another day.
    var day: Date
    var onOpen: (Meeting) -> Void
    var onJoin: (Meeting) -> Void

    private var isToday: Bool { Calendar.current.isDate(day, inSameDayAs: now) }

    private static let hourHeight: CGFloat = 50
    private static let gutter: CGFloat = 44

    /// A meeting with its column among the meetings it overlaps.
    private struct Slot: Identifiable {
        let meeting: Meeting
        let column: Int
        let columns: Int
        var id: String { meeting.occurrenceKey }
    }

    /// Working hours, stretched to include earlier or later meetings and the current time.
    private var hours: ClosedRange<Int> {
        let cal = Calendar.current
        var first = 8, last = 18
        for meeting in meetings {
            first = min(first, cal.component(.hour, from: meeting.start))
            let end = cal.dateComponents([.hour, .minute], from: meeting.end)
            let endHour = cal.isDate(meeting.end, inSameDayAs: meeting.start) ? (end.hour ?? 0) + ((end.minute ?? 0) > 0 ? 1 : 0) : 24
            last = max(last, endHour)
        }
        if isToday {
            let nowHour = cal.component(.hour, from: now)
            first = min(first, nowHour)
            last = max(last, nowHour + 1)
        }
        return max(0, first)...min(24, last)
    }

    /// Overlapping meetings share the width, side by side.
    private var slots: [Slot] {
        var result: [Slot] = []
        var cluster: [(meeting: Meeting, column: Int)] = []
        var clusterEnd = Date.distantPast
        func flush() {
            let columns = (cluster.map(\.column).max() ?? 0) + 1
            result += cluster.map { Slot(meeting: $0.meeting, column: $0.column, columns: columns) }
            cluster = []
        }
        for meeting in meetings.sorted(by: { $0.start < $1.start }) {
            if meeting.start >= clusterEnd { flush() }
            var column = 0
            while cluster.contains(where: { $0.column == column && $0.meeting.end > meeting.start }) { column += 1 }
            cluster.append((meeting, column))
            clusterEnd = max(clusterEnd, meeting.end)
        }
        flush()
        return result
    }

    private func y(_ date: Date, in hours: ClosedRange<Int>) -> CGFloat {
        let startOfDay = Calendar.current.startOfDay(for: day)
        let hour = date.timeIntervalSince(startOfDay) / 3600
        return CGFloat(min(max(hour, Double(hours.lowerBound)), Double(hours.upperBound)) - Double(hours.lowerBound))
            * Self.hourHeight
    }

    var body: some View {
        let hours = self.hours
        let height = CGFloat(hours.upperBound - hours.lowerBound) * Self.hourHeight
        ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    grid(hours)
                    if isToday { nowLine(hours) }   // under the blocks: the meeting that is on is highlighted itself
                    GeometryReader { geo in
                        let width = geo.size.width - Self.gutter
                        ForEach(slots) { slot in
                            let top = y(slot.meeting.start, in: hours)
                            let blockHeight = max(18, y(slot.meeting.end, in: hours) - top - 2)
                            let columnWidth = width / CGFloat(slot.columns)
                            MeetingBlock(meeting: slot.meeting, now: now, height: blockHeight,
                                         onOpen: onOpen, onJoin: onJoin)
                                .frame(width: columnWidth - 3, height: blockHeight)
                                .offset(x: Self.gutter + CGFloat(slot.column) * columnWidth, y: top + 1)
                        }
                    }
                }
                .frame(height: height + 8, alignment: .top)
                .padding(.top, 6)
            }
            .scrollIndicators(.never)
            .frame(height: min(height + 14, 520))
            .onAppear { if isToday { proxy.scrollTo("now", anchor: .center) } }
        }
    }

    /// Hour labels and hairlines.
    private func grid(_ hours: ClosedRange<Int>) -> some View {
        ForEach(Array(hours), id: \.self) { hour in
            HStack(spacing: 6) {
                Text(label(hour))
                    .font(.voila(10, .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: Self.gutter - 8, alignment: .trailing)
                Rectangle().fill(Theme.cardStroke).frame(height: 1)
            }
            .frame(height: 12)
            .offset(y: CGFloat(hour - hours.lowerBound) * Self.hourHeight - 6)
        }
    }

    private func label(_ hour: Int) -> String {
        let date = Calendar.current.startOfDay(for: day).addingTimeInterval(TimeInterval(hour) * 3600)
        return hour == 24 ? "" : date.formatted(date: .omitted, time: .shortened)
    }

    private func nowLine(_ hours: ClosedRange<Int>) -> some View {
        HStack(spacing: 0) {
            Spacer().frame(width: Self.gutter - 5)
            Circle().fill(Theme.overtime).frame(width: 8, height: 8)
            Rectangle().fill(Theme.overtime).frame(height: 1.5)
        }
        .frame(height: 8)
        .offset(y: y(now, in: hours) - 4)
        .id("now")
        .allowsHitTesting(false)
    }
}

/// One meeting on the timeline, in its Google Calendar colour; gradient when it is on.
private struct MeetingBlock: View {
    var meeting: Meeting
    var now: Date
    var height: CGFloat
    var onOpen: (Meeting) -> Void
    var onJoin: (Meeting) -> Void
    @State private var hovering = false

    private var isOngoing: Bool { meeting.isOngoing(at: now) && !meeting.isDeclined }
    private var isPast: Bool { meeting.end <= now }
    private var tint: Color { meeting.color }
    private var canJoin: Bool {
        meeting.link != nil && !meeting.isDeclined && !isPast && meeting.start.timeIntervalSince(now) <= 10 * 60
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title)
                    .font(.voila(11.5, .semibold))
                    .strikethrough(meeting.isDeclined)
                    .lineLimit(height >= 52 ? 2 : 1)
                if height >= 34 {
                    Text(isOngoing ? "Now · \(max(1, Int((meeting.end.timeIntervalSince(now) / 60).rounded(.up)))) min left"
                                   : meeting.timeRange)
                        .font(.voila(10, .medium))
                        .opacity(0.75)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if canJoin {
                Button { onJoin(meeting) } label: {
                    if let service = meeting.link?.service, service.appIcon != nil {
                        ServiceIcon(service: service, size: 20)   // the service's own icon
                    } else {
                        Image(systemName: "video.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(isOngoing ? AnyShapeStyle(Theme.tint2) : AnyShapeStyle(.white))
                            .frame(width: 22, height: 16)
                            .background(isOngoing ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.accent), in: Capsule())
                    }
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help(meeting.link?.joinTitle ?? "Join")
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .padding(.vertical, height >= 26 ? 4 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(isOngoing ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background {
            if isOngoing {
                shape.fill(Theme.accent)
            } else {
                shape.fill(Theme.surface)
                    .overlay(shape.fill(tint.opacity(hovering ? 0.30 : 0.20)))
                    .overlay(alignment: .leading) { Rectangle().fill(tint).frame(width: 3) }
                    .clipShape(shape)
            }
        }
        .overlay(shape.strokeBorder(Theme.background, lineWidth: 1))   // a gap between touching blocks
        .opacity(isPast || meeting.isDeclined ? 0.5 : 1)
        .contentShape(shape)
        .onTapGesture { onOpen(meeting) }
        .onHover { hovering = $0 }
        .help("\(meeting.title) · \(meeting.timeRange)")
    }
}
