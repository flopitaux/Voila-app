import SwiftUI

/// Today's meetings in time order, shown above the task list in the Today view.
struct TodayAgenda: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let calendar = model.calendar
        let meetings = calendar.todayMeetings(at: now)
        VStack(spacing: 6) {
            header(now: now, count: meetings.filter { !$0.isDeclined }.count)

            if !model.showsCalendar {
                ConnectCalendarCard()
            } else if let error = calendar.errorMessage {
                note(error, symbol: "exclamationmark.triangle", tint: Theme.overdue)
            } else if !calendar.hasLoaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 12)
            } else if meetings.isEmpty {
                note("No meetings today", symbol: "sparkles", tint: .secondary)
            } else {
                // The "now" line sits before the first meeting still to come (or after the last one),
                // unless a meeting is on: its own row is highlighted instead.
                let showsNow = calendar.current(at: now) == nil
                let nextIndex = meetings.firstIndex { $0.start > now }
                ForEach(Array(meetings.enumerated()), id: \.element.occurrenceKey) { index, meeting in
                    if showsNow && index == nextIndex { NowLine(now: now, next: calendar.next(after: now)) }
                    MeetingRow(meeting: meeting, now: now)
                }
                if showsNow && nextIndex == nil { NowLine(now: now, next: nil) }
            }
        }
        .padding(.bottom, 8)
    }

    private func header(now: Date, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar").font(.system(size: 10, weight: .semibold))
            Text(now.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
            if model.showsCalendar, model.calendar.hasLoaded {
                Text("\(count)").monospacedDigit().foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .font(.voila(12, .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.top, 2)
    }

    private func note(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.voila(12))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }
}

/// "● Now 14:05 · 45 min free": where the day stands between two meetings.
private struct NowLine: View {
    var now: Date
    var next: Meeting?

    private var hint: String {
        guard let next, Calendar.current.isDate(next.start, inSameDayAs: now) else { return "free for the rest of the day" }
        let gap = next.start.timeIntervalSince(now)
        return gap < 5 * 60 ? "next meeting in \(max(1, Int((gap / 60).rounded(.up)))) min"
                            : "\(DurationFormat.short(gap)) free"
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.accent).frame(width: 7, height: 7)
            Text(now.formatted(date: .omitted, time: .shortened))
                .font(.voila(11, .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.accent)
            Text(hint)
                .font(.voila(11))
                .foregroundStyle(.secondary)
            Rectangle().fill(Theme.tint.opacity(0.35)).frame(height: 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }
}

private struct MeetingRow: View {
    @Environment(AppModel.self) private var model
    var meeting: Meeting
    var now: Date
    @State private var hovering = false

    private var isOngoing: Bool { meeting.isOngoing(at: now) && !meeting.isDeclined }
    private var isPast: Bool { meeting.end <= now }
    /// Join shows from 10 minutes before the start until the end.
    private var canJoin: Bool {
        meeting.link != nil && !meeting.isDeclined && !isPast && meeting.start.timeIntervalSince(now) <= 10 * 60
    }

    private var subtitle: String {
        if isOngoing {
            return "Now · \(max(1, Int((meeting.end.timeIntervalSince(now) / 60).rounded(.up)))) min left"
        }
        if meeting.isDeclined { return "Declined" }
        var parts: [String] = []
        if let link = meeting.link, link.service != .other { parts.append(link.service.rawValue) }
        else if let location = meeting.location { parts.append(location) }
        let others = meeting.attendees.filter { !$0.isSelf }.count
        if others > 0 { parts.append(others == 1 ? meeting.attendees.first { !$0.isSelf }!.name : "\(others) people") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(meeting.start.formatted(date: .omitted, time: .shortened))
                    .font(.voila(12, .semibold))
                    .monospacedDigit()
                Text(DurationFormat.short(meeting.duration))
                    .font(.voila(10))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 58, alignment: .trailing)

            Capsule()
                .fill(isOngoing ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.tint2.opacity(meeting.isDeclined ? 0.25 : 0.7)))
                .frame(width: 3)
                .padding(.vertical, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.voila(13, .medium))
                    .strikethrough(meeting.isDeclined)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.voila(11, isOngoing ? .semibold : .regular))
                        .foregroundStyle(isOngoing ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if canJoin, let link = meeting.link {
                Button { link.open() } label: {
                    Label("Join", systemImage: "video.fill")
                        .font(.voila(11, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help(link.joinTitle)
            } else if !isPast, meeting.myResponse == .needsAction || meeting.myResponse == .tentative {
                Image(systemName: meeting.myResponse.symbol)
                    .font(.voila(12))
                    .foregroundStyle(.tertiary)
                    .help(meeting.myResponse == .tentative ? "You replied Maybe" : "You haven't replied yet")
            }
        }
        .frame(minHeight: 30)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .opacity(isPast || meeting.isDeclined ? 0.5 : 1)
        .background {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            shape
                .fill(Theme.surface.opacity(isPast || meeting.isDeclined ? 0.6 : 1))
                .overlay(shape.fill(Theme.tint.opacity(isOngoing ? 0.14 : 0)))
                .overlay(shape.fill(.primary.opacity(hovering ? 0.04 : 0)))
                .overlay(shape.strokeBorder(isOngoing ? AnyShapeStyle(Theme.tint.opacity(0.45))
                                                      : AnyShapeStyle(.primary.opacity(0.07))))
                .shadow(color: .black.opacity(isPast || meeting.isDeclined ? 0 : 0.18), radius: 3, y: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.showMeeting(meeting) }
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        .help("Show people and topics")
    }
}

/// Shown when the Google connection predates the calendar permission.
private struct ConnectCalendarCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("See today's meetings here")
                .font(.voila(14, .semibold))
            Text("Voilà shows your day next to your tasks and brings up a card when a meeting starts. It only reads your calendar's events.")
                .font(.voila(12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.auth.isSigningIn {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Finish in your browser…").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { model.auth.cancelSignIn() }
                }
                .font(.voila(12))
            } else {
                Button { model.connectCalendar() } label: {
                    Label("Connect Google Calendar", systemImage: "calendar.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.tint)
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.07)))
    }
}
