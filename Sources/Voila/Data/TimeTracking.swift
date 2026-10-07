import Foundation

/// Voilà's per-task state (time tracking + Now). Persisted as a single line in the Google Task notes:
///
///     ⏱ 42m10s / 1h ▶ 2026-10-03T16:02:11Z · now
///     ⏱ now
///
/// `42m10s` = time already spent, `1h` = estimate, `▶ <date>` = running since,
/// `now` = the task is in Now (actively worked on), independent of its due date.
struct TrackInfo: Equatable {
    var spent: TimeInterval = 0
    var estimate: TimeInterval?
    var runningSince: Date?
    var isNow = false

    var isRunning: Bool { runningSince != nil }
    var hasTime: Bool { spent >= 1 || estimate != nil || runningSince != nil }
    var isEmpty: Bool { !hasTime && !isNow }

    func elapsed(at now: Date = .now) -> TimeInterval {
        spent + (runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    func progress(at now: Date = .now) -> Double? {
        guard let estimate, estimate > 0 else { return nil }
        return elapsed(at: now) / estimate
    }

    /// Folds the running segment into `spent` and stops the clock.
    func paused(at now: Date = .now) -> TrackInfo {
        TrackInfo(spent: elapsed(at: now).rounded(), estimate: estimate, runningSince: nil, isNow: isNow)
    }
}

enum NotesCodec {
    static let marker = "⏱"
    static let nowFlag = "now"

    static func parse(_ notes: String?) -> (body: String, track: TrackInfo) {
        guard let notes, !notes.isEmpty else { return ("", TrackInfo()) }
        var lines = notes.components(separatedBy: "\n")
        var track = TrackInfo()
        if let idx = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(marker) }) {
            track = parseLine(lines[idx])
            lines.remove(at: idx)
        }
        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), track)
    }

    static func compose(body: String, track: TrackInfo) -> String {
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !track.isEmpty else { return body }
        var parts: [String] = []
        if track.hasTime {
            var time = DurationFormat.compact(track.spent)
            if let estimate = track.estimate { time += " / \(DurationFormat.compact(estimate))" }
            if let since = track.runningSince { time += " ▶ \(ISO8601.format(since))" }
            parts.append(time)
        }
        if track.isNow { parts.append(nowFlag) }
        let line = "\(marker) " + parts.joined(separator: " · ")
        return body.isEmpty ? line : "\(body)\n\n\(line)"
    }

    private static func parseLine(_ line: String) -> TrackInfo {
        var rest = line.trimmingCharacters(in: .whitespaces).dropFirst(marker.count)
            .trimmingCharacters(in: .whitespaces)
        var track = TrackInfo()
        // Trailing flags: "… · now" (or just "now" when there's no time yet).
        var segments = rest.components(separatedBy: "·").map { $0.trimmingCharacters(in: .whitespaces) }
        if segments.last?.lowercased() == nowFlag {
            track.isNow = true
            segments.removeLast()
        }
        rest = segments.joined(separator: "·").trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return track }
        if let r = rest.range(of: "▶") {
            track.runningSince = ISO8601.parse(rest[r.upperBound...].trimmingCharacters(in: .whitespaces))
            rest = rest[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
        }
        let parts = rest.components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        track.spent = parts.first.flatMap(DurationFormat.parse) ?? 0
        if parts.count > 1 { track.estimate = DurationFormat.parse(parts[1]) }
        return track
    }
}

enum DurationFormat {
    /// "1h05m", "42m10s", "0m" — machine-friendly but readable.
    static func compact(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        var out = ""
        if h > 0 { out += "\(h)h" }
        if m > 0 { out += h > 0 ? String(format: "%02dm", m) : "\(m)m" }
        if s > 0 { out += String(format: "%02ds", s) }
        return out.isEmpty ? "0m" : out
    }

    /// Parses "1h30m", "45m", "90s", "1h05m10s", or a bare number of minutes.
    static func parse(_ text: String) -> TimeInterval? {
        let t = text.lowercased().replacingOccurrences(of: " ", with: "")
        if let minutes = Double(t) { return minutes * 60 }
        guard let match = t.wholeMatch(of: #/(?:(\d+)h)?(?:(\d+)m(?:in)?)?(?:(\d+)s)?/#),
              match.1 != nil || match.2 != nil || match.3 != nil else { return nil }
        let h = match.1.flatMap { Double($0) } ?? 0
        let m = match.2.flatMap { Double($0) } ?? 0
        let s = match.3.flatMap { Double($0) } ?? 0
        return h * 3600 + m * 60 + s
    }

    /// Stopwatch style: "4:07", "42:10", "1:05:30".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Human style: "42m", "1h 5m", "<1m".
    static func short(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total < 60 { return total == 0 ? "0m" : "<1m" }
        let h = total / 3600, m = (total % 3600) / 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}

enum ISO8601 {
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parse(_ string: String) -> Date? { fractional.date(from: string) ?? plain.date(from: string) }
    static func format(_ date: Date) -> String { plain.string(from: date) }
}

/// Google Tasks stores due as a date at midnight UTC; only the date part is meaningful.
enum DueDate {
    static func date(from due: String?) -> Date? {
        guard let due, due.count >= 10 else { return nil }
        let parts = due.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func string(from date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02dT00:00:00.000Z", c.year!, c.month!, c.day!)
    }

    enum Urgency { case overdue, today, soon, later }

    static func label(for date: Date) -> (text: String, urgency: Urgency) {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: .now), to: cal.startOfDay(for: date)).day ?? 0
        switch days {
        case ..<(-1): return ("\(-days)d overdue", .overdue)
        case -1: return ("Yesterday", .overdue)
        case 0: return ("Today", .today)
        case 1: return ("Tomorrow", .soon)
        case 2..<7: return (date.formatted(.dateTime.weekday(.abbreviated)), .later)
        default: return (date.formatted(.dateTime.month(.abbreviated).day()), .later)
        }
    }
}
