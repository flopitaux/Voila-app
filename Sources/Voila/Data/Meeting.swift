import AppKit
import Foundation

/// A timed calendar event, reduced to what Voilà shows.
struct Meeting: Identifiable, Hashable {
    enum Response: String {
        case accepted, tentative, declined, needsAction

        var title: String {
            switch self {
            case .accepted: "Accepted"
            case .tentative: "Maybe"
            case .declined: "Declined"
            case .needsAction: "No reply"
            }
        }
        var symbol: String {
            switch self {
            case .accepted: "checkmark.circle.fill"
            case .tentative: "questionmark.circle.fill"
            case .declined: "xmark.circle.fill"
            case .needsAction: "circle.dashed"
            }
        }
    }

    struct Attendee: Hashable {
        var name: String
        var response: Response
        var isSelf: Bool
        /// Email domain, lowercased ("acme.com").
        var domain: String? = nil
    }

    /// Whether every guest is from the user's own organization.
    enum Audience: String {
        case inside = "Internal", outside = "External"
    }

    let id: String
    var title: String
    var start: Date
    var end: Date
    /// The invite's description as plain text, without the conferencing boilerplate.
    var topics: String
    var location: String?
    var organizer: String?
    var attendees: [Attendee]
    /// The user's own reply (accepted when they organize it or there are no guests).
    var myResponse: Response
    var link: MeetingLink?
    var attachments: [String]
    var calendarURL: URL?
    /// Nil when it can't be told: no other guests, or the user's own address is a personal one.
    var audience: Audience? = nil
    /// The other organizations in the meeting, for "External · northwind.com".
    var externalDomains: [String] = []

    /// Distinguishes a rescheduled meeting from its earlier slot.
    var occurrenceKey: String { "\(id)@\(Int(start.timeIntervalSince1970))" }
    var duration: TimeInterval { end.timeIntervalSince(start) }
    var isDeclined: Bool { myResponse == .declined }
    /// "Prep", "Prep: Roadmap review", "Prep – demo"… (but not "Prepare" or "Preparation").
    var isPrep: Bool {
        let lower = title.lowercased()
        guard lower.hasPrefix("prep") else { return false }
        return lower.dropFirst(4).first.map { !$0.isLetter } ?? true
    }
    /// What the prep is for: the title without "Prep" and punctuation, lowercased.
    var prepSubject: String {
        guard isPrep else { return "" }
        return title.dropFirst(4).lowercased()
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            .replacingOccurrences(of: "^for\\s+", with: "", options: .regularExpression)
    }
    /// False for a block on your own calendar with nobody else in it.
    var hasGuests: Bool { attendees.contains { !$0.isSelf } }

    func isOngoing(at date: Date) -> Bool { start <= date && date < end }
    func attendees(_ response: Response) -> [Attendee] { attendees.filter { $0.response == response } }

    var timeRange: String {
        "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }
}

extension Meeting {
    /// Nil for anything that isn't a real timed meeting: all-day events, cancelled events,
    /// working locations, out-of-office and focus-time blocks.
    init?(_ event: GEvent) {
        guard event.status != "cancelled",
              (event.eventType ?? "default") == "default",
              let start = event.start?.dateTime.flatMap(ISO8601.parse),
              let end = event.end?.dateTime.flatMap(ISO8601.parse), end > start else { return nil }

        let people = (event.attendees ?? []).filter { $0.resource != true }
        id = event.id
        let summary = (event.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        title = summary.isEmpty ? "(No title)" : summary
        self.start = start
        self.end = end
        topics = MeetingText.topics(fromHTML: event.description)
        let place = event.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        location = (place?.isEmpty ?? true) ? nil : place
        organizer = event.organizer.map { $0.isSelf == true ? "You" : Self.name(of: $0) }
        attendees = people.map {
            Attendee(name: $0.isSelf == true ? "You" : Self.name(of: $0),
                     response: Response(rawValue: $0.responseStatus ?? "") ?? .needsAction,
                     isSelf: $0.isSelf == true, domain: Self.domain(of: $0.email))
        }
        myResponse = attendees.first(where: \.isSelf)?.response ?? .accepted
        link = MeetingLink.find(in: event)
        attachments = (event.attachments ?? []).compactMap(\.title)
        calendarURL = event.htmlLink.flatMap(URL.init(string:))

        // Internal or external: compare the guests' email domains with the user's own.
        let mine = attendees.first(where: \.isSelf)?.domain
            ?? (event.organizer?.isSelf == true ? Self.domain(of: event.organizer?.email) : nil)
        let others = attendees.filter { !$0.isSelf }.compactMap(\.domain)
        if let mine, !Self.personalDomains.contains(mine), !others.isEmpty {
            var seen = Set<String>()
            externalDomains = others.filter { $0 != mine && seen.insert($0).inserted }
            audience = externalDomains.isEmpty ? .inside : .outside
        }
    }

    /// With a personal address there is no "own organization" to compare with.
    private static let personalDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "yahoo.com", "icloud.com", "me.com",
    ]

    /// "Jane@Acme.com" → "acme.com"; nil for Google's group and room calendars.
    private static func domain(of email: String?) -> String? {
        guard let domain = email?.split(separator: "@").last?.lowercased(), email?.contains("@") == true,
              !domain.hasSuffix("calendar.google.com") else { return nil }
        return domain
    }

    /// "Display Name", or "jane.doe@x.com" → "Jane Doe" when Google gives no name.
    private static func name(of person: GEvent.Person) -> String {
        if let name = person.displayName?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        guard let local = person.email?.split(separator: "@").first else { return "Someone" }
        return local.split(whereSeparator: { ".-_".contains($0) }).map { $0.capitalized }.joined(separator: " ")
    }
}

/// Where the meeting happens online, and how to open it in the matching app.
struct MeetingLink: Hashable {
    enum Service: String {
        case meet = "Google Meet", zoom = "Zoom", teams = "Microsoft Teams", webex = "Webex", other = "Meeting"
    }

    var url: URL
    var service: Service

    var joinTitle: String { service == .other ? "Join Meeting" : "Join \(service.rawValue)" }

    /// Conference data first (Meet and calendar add-ons), then known providers in the location
    /// and description, then any link in the location.
    static func find(in event: GEvent) -> MeetingLink? {
        let video = event.conferenceData?.entryPoints?.first { $0.entryPointType == "video" }?.uri
        if let url = (video ?? event.hangoutLink).flatMap(URL.init(string:)) {
            return MeetingLink(url: url, service: service(for: url))
        }
        let urls = Self.urls(in: event.location) + Self.urls(in: event.description)
        if let known = urls.first(where: { service(for: $0) != .other }) {
            return MeetingLink(url: known, service: service(for: known))
        }
        return Self.urls(in: event.location).first.map { MeetingLink(url: $0, service: .other) }
    }

    static func service(for url: URL) -> Service {
        let host = url.host()?.lowercased() ?? ""
        if host == "meet.google.com" { return .meet }
        if host.hasSuffix("zoom.us") || host.hasSuffix("zoom.com") || host.hasSuffix("zoomgov.com") { return .zoom }
        if host.hasSuffix("teams.microsoft.com") || host.hasSuffix("teams.live.com") { return .teams }
        if host.hasSuffix("webex.com") { return .webex }
        return .other
    }

    private static func urls(in text: String?) -> [URL] {
        guard let text, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [] }
        // Descriptions are HTML: read hrefs and visible links alike.
        let plain = text.replacingOccurrences(of: "&amp;", with: "&")
        return detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain))
            .compactMap(\.url)
            .filter { $0.scheme == "https" || $0.scheme == "http" }
    }

    /// The URL that opens straight in the installed app (Zoom, Teams), else the web link.
    var launchURL: URL {
        let candidate: URL? = switch service {
        case .zoom: zoomAppURL
        case .teams: teamsAppURL
        default: nil
        }
        if let candidate, NSWorkspace.shared.urlForApplication(toOpen: candidate) != nil { return candidate }
        return url
    }

    func open() { NSWorkspace.shared.open(launchURL) }

    /// https://acme.zoom.us/j/123?pwd=abc → zoommtg://acme.zoom.us/join?action=join&confno=123&pwd=abc
    private var zoomAppURL: URL? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = comps.host else { return nil }
        let parts = comps.path.split(separator: "/")
        guard parts.count >= 2, ["j", "w", "s"].contains(parts[0]), parts[1].allSatisfy(\.isNumber) else { return nil }
        var app = URLComponents()
        app.scheme = "zoommtg"
        app.host = host
        app.path = "/join"
        app.queryItems = [.init(name: "action", value: "join"), .init(name: "confno", value: String(parts[1]))]
            + (comps.queryItems ?? []).filter { ["pwd", "tk", "zak"].contains($0.name) }
        return app.url
    }

    /// https://teams.microsoft.com/l/meetup-join/… → msteams:/l/meetup-join/…
    private var teamsAppURL: URL? {
        guard url.host()?.lowercased() == "teams.microsoft.com",
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              comps.path.hasPrefix("/l/") else { return nil }
        comps.scheme = "msteams"
        comps.host = nil
        return comps.url
    }
}

enum MeetingText {
    /// Lines from which an invite is only dial-in details added by the conferencing tool.
    private static let boilerplate = [
        "is inviting you to a scheduled zoom meeting", "join zoom meeting", "microsoft teams meeting",
        "microsoft teams need help", "join with google meet", "join the meeting now", "-::~:~::~",
        "──────────", "________________", "join webex meeting",
    ]

    /// Google returns descriptions as light HTML: keep the text and line breaks, drop the tags
    /// and whatever the conferencing tool appended.
    static func topics(fromHTML html: String?) -> String {
        guard var text = html, !text.isEmpty else { return "" }
        for (pattern, replacement) in [("(?i)<br\\s*/?>|</p>|</div>|</li>|</h[1-6]>|</tr>", "\n"), ("(?i)<li[^>]*>", "• "),
                                       ("<[^>]+>", "")] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        for (entity, char) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        var lines: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if boilerplate.contains(where: trimmed.lowercased().contains) { break }
            if trimmed.isEmpty && (lines.last?.isEmpty ?? true) { continue }   // collapse blank runs
            lines.append(trimmed)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
