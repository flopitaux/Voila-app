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
        var email: String? = nil
        /// From another organization than the user's (false when that can't be told).
        var isExternal = false

        /// A LinkedIn people search for this guest: their name plus their company, guessed from
        /// the email domain ("lena@northwind.com" → "Lena Fischer northwind").
        var linkedInSearchURL: URL? {
            var keywords = name
            if let domain, !Meeting.personalDomains.contains(domain),
               let company = domain.split(separator: ".").dropLast().last {
                keywords += " \(company)"
            }
            var comps = URLComponents(string: "https://www.linkedin.com/search/results/people/")
            comps?.queryItems = [URLQueryItem(name: "keywords", value: keywords)]
            return comps?.url
        }
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
    /// Your own notes for this meeting, taken from a "Prep…" event that starts at the same time.
    var prepNotes: String = ""
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
    /// Google Calendar's colour for this event ("1"…"11"); nil when it uses the calendar's own.
    var colorID: String? = nil

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
                     isSelf: $0.isSelf == true, domain: Self.domain(of: $0.email), email: $0.email)
        }
        myResponse = attendees.first(where: \.isSelf)?.response ?? .accepted
        link = MeetingLink.find(in: event)
        colorID = event.colorId
        attachments = (event.attachments ?? []).compactMap(\.title)
        calendarURL = event.htmlLink.flatMap(URL.init(string:)).flatMap { $0.isWebLink ? $0 : nil }

        // Internal or external: compare the guests' email domains with the user's own, and with
        // the other domains the user counts as internal (Meetings settings).
        let alsoInternal = Self.internalDomains
        let mine = attendees.first(where: \.isSelf)?.domain
            ?? (event.organizer?.isSelf == true ? Self.domain(of: event.organizer?.email) : nil)
        let others = attendees.filter { !$0.isSelf }.compactMap(\.domain)
        if let mine, !Self.personalDomains.contains(mine), !others.isEmpty {
            var seen = Set<String>()
            func isOutside(_ domain: String) -> Bool {
                domain != mine && !alsoInternal.contains { HostMatch.matches(domain, $0) }
            }
            externalDomains = others.filter { isOutside($0) && seen.insert($0).inserted }
            for index in attendees.indices {
                attendees[index].isExternal = attendees[index].domain.map(isOutside) ?? false
            }
            audience = externalDomains.isEmpty ? .inside : .outside
        }
    }

    /// Email domains counted as internal on top of the user's own (a sister company, a domain
    /// kept after a merger…), as typed in the Meetings settings. Subdomains are included.
    static var internalDomains: [String] {
        UserDefaults.standard.stringArray(forKey: "internalDomains") ?? []
    }

    /// "@Mode.com, modeanalytics.com" → ["mode.com", "modeanalytics.com"].
    static func parseDomains(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: ",; \n\t"))
            .map { String($0.split(separator: "@").last ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { $0.contains(".") && seen.insert($0).inserted }
    }

    /// With a personal address there is no "own organization" to compare with.
    fileprivate static let personalDomains: Set<String> = [
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
    /// and description, then any link in the location, then a link the description itself
    /// presents as the way in ("Click to join the meeting: https://…").
    static func find(in event: GEvent) -> MeetingLink? {
        // Only web links are ever opened: an invite can't make Join launch another kind of URL.
        let video = event.conferenceData?.entryPoints?.first { $0.entryPointType == "video" }?.uri
        if let url = (video ?? event.hangoutLink).flatMap(URL.init(string:)), url.isWebLink {
            return MeetingLink(url: url, service: service(for: url))
        }
        let urls = Self.urls(in: event.location) + Self.urls(in: event.description)
        if let known = urls.first(where: { service(for: $0) != .other }) {
            return MeetingLink(url: known, service: service(for: known))
        }
        return (Self.urls(in: event.location).first ?? MeetingText.joinURL(inHTML: event.description))
            .map { MeetingLink(url: $0, service: .other) }
    }

    static func service(for url: URL) -> Service {
        let host = url.host()?.lowercased() ?? ""
        func on(_ domains: String...) -> Bool { domains.contains { HostMatch.matches(host, $0) } }
        if host == "meet.google.com" { return .meet }
        if on("zoom.us", "zoom.com", "zoomgov.com") { return .zoom }
        if on("teams.microsoft.com", "teams.live.com") { return .teams }
        if on("webex.com") { return .webex }
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

enum HostMatch {
    /// True for the domain itself and its subdomains only: "acme.zoom.us" is on "zoom.us",
    /// "notzoom.us" is not. (A plain suffix test would let look-alike domains pass as the service.)
    static func matches(_ host: String, _ domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }
}

extension URL {
    var isWebLink: Bool { scheme?.lowercased() == "https" || scheme?.lowercased() == "http" }
}

enum MeetingText {
    /// Words that introduce the meeting's link in an invite written by hand or by a booking tool.
    private static let joinCues = ["join", "meeting link", "meeting url", "connect to the meeting", "attend the meeting",
                                   "enter the meeting", "access the meeting", "launch meeting", "start the meeting"]

    /// The link a description presents as the way into the meeting, for providers Voilà doesn't
    /// know by name: either a link labelled "Join…" or a URL that follows such words closely.
    /// Other links in a description (documents, agendas) are left alone.
    static func joinURL(inHTML html: String?) -> URL? {
        guard let html, !html.isEmpty else { return nil }
        func hasCue(_ text: String) -> Bool { joinCues.contains(where: text.lowercased().contains) }
        func web(_ string: String) -> URL? {
            guard let url = URL(string: string.replacingOccurrences(of: "&amp;", with: "&")),
                  url.scheme == "https" || url.scheme == "http" else { return nil }
            return url
        }
        // <a href="https://…">Join the meeting</a>
        if let anchor = try? NSRegularExpression(pattern: "<a\\b[^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>",
                                                 options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            for match in anchor.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let href = Range(match.range(at: 1), in: html), let label = Range(match.range(at: 2), in: html)
                else { continue }
                let text = html[label].replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                if hasCue(text), !text.lowercased().hasPrefix("http"), let url = web(String(html[href])) { return url }
            }
        }
        // "Click to join the meeting:\nhttps://…": the words come just before the URL.
        let text = html.replacingOccurrences(of: "(?i)<br\\s*/?>|</p>|</div>|</li>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&nbsp;", with: " ")
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let url = match.url, url.scheme?.hasPrefix("http") == true
            else { continue }
            let before = text[..<range.lowerBound].suffix(90)
            // Only the sentence leading up to the link counts, not an earlier paragraph.
            let lead = before.components(separatedBy: "\n\n").last ?? ""
            if hasCue(lead) { return url }
        }
        return nil
    }

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
