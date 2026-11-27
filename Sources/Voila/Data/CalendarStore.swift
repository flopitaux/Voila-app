import Foundation
import Observation

/// What the menu bar says about meetings.
enum MeetingStatus: Equatable {
    /// A meeting is on: minutes until it ends.
    case ongoing(minutesLeft: Int)
    /// The next meeting starts within the hour: minutes until then.
    case upcoming(minutes: Int)
}

/// Today's (and tomorrow's) meetings from the primary Google Calendar.
@MainActor
@Observable
final class CalendarStore {
    private let api: CalendarAPI
    private let auth: GoogleAuth

    /// Timed meetings from the start of today to the end of tomorrow, by start time.
    private(set) var meetings: [Meeting] = []
    private(set) var hasLoaded = false
    /// Shown inline in the Today view (background refreshes never raise a banner).
    private(set) var errorMessage: String?

    // MARK: Settings (Meetings menu)

    /// How long before the start the card appears: 0 = at start time, nil = never.
    private(set) var reminderLead: TimeInterval? = {
        let stored = UserDefaults.standard.object(forKey: "meetingReminderLead") as? Double ?? 0
        return stored < 0 ? nil : stored
    }()
    /// Which replies of yours keep a meeting on screen. Hidden meetings are ignored everywhere.
    private(set) var showDeclined = UserDefaults.standard.bool(forKey: "showDeclinedMeetings")
    private(set) var showUnanswered = UserDefaults.standard.object(forKey: "showUnansweredMeetings") as? Bool ?? true
    private(set) var showTentative = UserDefaults.standard.object(forKey: "showTentativeMeetings") as? Bool ?? true

    static let reminderChoices: [(title: String, lead: TimeInterval?)] = [
        ("At Start Time", 0), ("1 Minute Before", 60), ("2 Minutes Before", 120), ("5 Minutes Before", 300),
        ("10 Minutes Before", 600), ("Never", nil),
    ]

    func setReminderLead(_ lead: TimeInterval?) {
        reminderLead = lead
        UserDefaults.standard.set(lead ?? -1, forKey: "meetingReminderLead")
        onChange?()   // re-arm the next card
    }

    func setShow(_ response: Meeting.Response, _ show: Bool) {
        switch response {
        case .declined: showDeclined = show; UserDefaults.standard.set(show, forKey: "showDeclinedMeetings")
        case .needsAction: showUnanswered = show; UserDefaults.standard.set(show, forKey: "showUnansweredMeetings")
        case .tentative: showTentative = show; UserDefaults.standard.set(show, forKey: "showTentativeMeetings")
        case .accepted: break
        }
        onChange?()
    }

    func shows(_ response: Meeting.Response) -> Bool {
        switch response {
        case .accepted: true
        case .declined: showDeclined
        case .needsAction: showUnanswered
        case .tentative: showTentative
        }
    }

    /// Meetings already announced with a card, so each start is shown once.
    @ObservationIgnored private var announced: Set<String> = []
    /// Called after every successful load, so the app can re-arm the next card.
    @ObservationIgnored var onChange: (() -> Void)?

    /// How long after its start a meeting is still announced (app launched or Mac woken late).
    static let announceWindow: TimeInterval = 5 * 60

    init(auth: GoogleAuth) {
        self.auth = auth
        api = CalendarAPI(auth: auth)
    }

    // MARK: - Derived

    /// Meetings of one day, as filtered by the Meetings settings.
    func meetings(on day: Date) -> [Meeting] {
        meetings.filter { shows($0.myResponse) && Calendar.current.isDate($0.start, inSameDayAs: day) }
    }

    /// Meetings the user is expected at: shown by the settings and not declined. Declined ones,
    /// even when shown in the list, never get a card or a countdown.
    private var attending: [Meeting] { meetings.filter { shows($0.myResponse) && !$0.isDeclined } }

    func current(at date: Date) -> Meeting? {
        attending.filter { $0.isOngoing(at: date) }.max { $0.start < $1.start }
    }

    func next(after date: Date) -> Meeting? { attending.first { $0.start > date } }

    func status(at date: Date) -> MeetingStatus? {
        if let current = current(at: date) {
            return .ongoing(minutesLeft: max(1, Int((current.end.timeIntervalSince(date) / 60).rounded(.up))))
        }
        if let next = next(after: date), next.start.timeIntervalSince(date) <= 3600 {
            return .upcoming(minutes: max(1, Int((next.start.timeIntervalSince(date) / 60).rounded(.up))))
        }
        return nil
    }

    /// Meetings whose card is due (start time minus the reminder setting) and hasn't been shown
    /// yet; marks them announced. Events with nobody but the user never get a card.
    func takeDue(at date: Date) -> [Meeting] {
        guard let lead = reminderLead else { return [] }
        let due = attending.filter {
            $0.hasGuests && $0.start.addingTimeInterval(-lead) <= date && date < min($0.end, $0.start.addingTimeInterval(Self.announceWindow))
                && !announced.contains($0.occurrenceKey)
        }
        announced.formUnion(due.map(\.occurrenceKey))
        return due
    }

    /// When the next card is due.
    func nextAnnouncement(after date: Date) -> Date? {
        guard let lead = reminderLead else { return nil }
        return attending.lazy.filter { $0.hasGuests && !self.announced.contains($0.occurrenceKey) }
            .map { $0.start.addingTimeInterval(-lead) }
            .first { $0 > date }
    }

    // MARK: - Loading

    func refresh() async {
        guard auth.isSignedIn, auth.hasCalendarAccess else { return }
        let cal = Calendar.current
        let from = cal.startOfDay(for: .now)
        guard let to = cal.date(byAdding: .day, value: 2, to: from) else { return }
        do {
            meetings = Self.mergingPrep(try await api.events(from: from, to: to).compactMap(Meeting.init))
            hasLoaded = true
            errorMessage = nil
            onChange?()
        } catch let error as CalendarError where error.isMissingScope {
            auth.setCalendarAccess(false)
            reset()
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            // Offline blips keep the last known day on screen.
            if error is URLError, hasLoaded { return }
            errorMessage = error.localizedDescription
        }
    }

    /// A "Prep…" event starting at the same time as a meeting is your own preparation for it:
    /// its description becomes the meeting's topics (ahead of the invite's own text) and the
    /// Prep event itself disappears. With several meetings at that time, the one named in the
    /// Prep title wins; a Prep event with no clear match is left as a normal event.
    static func mergingPrep(_ meetings: [Meeting]) -> [Meeting] {
        var result = meetings
        for prep in meetings where prep.isPrep {
            let subject = prep.prepSubject
            let companions = result.indices.filter {
                !result[$0].isPrep && abs(result[$0].start.timeIntervalSince(prep.start)) < 60
            }
            let named = companions.first {
                let title = result[$0].title.lowercased()
                return !subject.isEmpty && (title.contains(subject) || subject.contains(title))
            }
            guard let target = named ?? (companions.count == 1 ? companions.first : nil) else { continue }
            if !prep.topics.isEmpty {
                result[target].topics = [prep.topics, result[target].topics].filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
            }
            result[target].attachments = prep.attachments + result[target].attachments
            let key = prep.occurrenceKey
            result.removeAll { $0.occurrenceKey == key }
        }
        return result
    }

    func reset() {
        meetings = []
        hasLoaded = false
        errorMessage = nil
        announced = []
    }

    #if DEBUG
    /// Sample day for UI checks (`VOILA_DEMO=1`): one past, one ongoing, one soon, one declined.
    func loadDemo() {
        let now = Date()
        func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }
        func people(_ list: [(String, Meeting.Response)]) -> [Meeting.Attendee] {
            [Meeting.Attendee(name: "You", response: .accepted, isSelf: true)]
                + list.map { Meeting.Attendee(name: $0.0, response: $0.1, isSelf: false) }
        }
        meetings = [
            Meeting(id: "m1", title: "Team stand-up", start: at(-150), end: at(-135), topics: "", location: nil,
                    organizer: "Maya Cohen", attendees: people([("Maya Cohen", .accepted), ("Tom Reed", .accepted)]),
                    myResponse: .accepted,
                    link: MeetingLink(url: URL(string: "https://meet.google.com/abc-defg-hij")!, service: .meet),
                    attachments: [], calendarURL: nil, audience: .inside),
            Meeting(id: "m2", title: "Q4 roadmap review", start: at(-12), end: at(33),
                    topics: "• Where we landed on the Q4 priorities\n• Open risks on the analytics launch\n• Hiring plan for the design team\n\nPlease read the memo before the call.",
                    location: "Paris – Salle Monet", organizer: "Sarah Lin",
                    attendees: people([("Sarah Lin", .accepted), ("Arjun Patel", .accepted), ("Chloé Martin", .accepted),
                                       ("Diego Alvarez", .tentative), ("Emma Wilson", .declined), ("Noah Kim", .needsAction),
                                       ("Priya Shah", .needsAction)]),
                    myResponse: .accepted,
                    link: MeetingLink(url: URL(string: "https://acme.zoom.us/j/93812345678?pwd=demo")!, service: .zoom),
                    attachments: ["Q4 strategy memo", "Roadmap – draft v3"], calendarURL: nil, audience: .inside),
            Meeting(id: "m3", title: "Customer demo: Northwind", start: at(58), end: at(118),
                    topics: "Walk through the retail dashboard, then questions.", location: nil, organizer: "You",
                    attendees: people([("Arjun Patel", .accepted), ("Chloé Martin", .tentative), ("Lena Fischer", .accepted),
                                       ("Omar Haddad", .needsAction)]),
                    myResponse: .accepted,
                    link: MeetingLink(url: URL(string: "https://teams.microsoft.com/l/meetup-join/demo")!, service: .teams),
                    attachments: [], calendarURL: nil, audience: .outside, externalDomains: ["northwind.com"]),
            Meeting(id: "m4", title: "Vendor pitch", start: at(150), end: at(180), topics: "", location: nil,
                    organizer: "Jules Bernard", attendees: people([("Jules Bernard", .accepted)]),
                    myResponse: .declined, link: nil, attachments: [], calendarURL: nil, audience: .inside),
            Meeting(id: "m5", title: "1:1 with Sarah", start: at(200), end: at(230), topics: "", location: nil,
                    organizer: "Sarah Lin", attendees: people([("Sarah Lin", .accepted)]),
                    myResponse: .needsAction,
                    link: MeetingLink(url: URL(string: "https://meet.google.com/xyz-abcd-efg")!, service: .meet),
                    attachments: [], calendarURL: nil, audience: .inside),
        ]
        .filter { Calendar.current.isDate($0.start, inSameDayAs: now) || $0.isOngoing(at: now) }
        // A private prep block at the same time as the customer demo: its notes become the topics.
        if let demo = meetings.first(where: { $0.id == "m3" }) {
            meetings.append(Meeting(id: "p3", title: "Prep: Customer demo", start: demo.start, end: demo.end,
                                    topics: "My prep notes\n• Lead with the store-level drill-down\n• Lena asked about pricing last time: have the tiers ready\n• Ask Omar who signs off on the pilot",
                                    location: nil, organizer: "You", attendees: [], myResponse: .accepted, link: nil,
                                    attachments: [], calendarURL: nil))
        }
        // Tomorrow, at fixed times.
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        func next(_ hour: Double) -> Date { tomorrow.addingTimeInterval(hour * 3600) }
        meetings += [
            Meeting(id: "t1", title: "Weekly product sync", start: next(9.5), end: next(10.5), topics: "", location: nil,
                    organizer: "Maya Cohen", attendees: people([("Maya Cohen", .accepted), ("Tom Reed", .accepted), ("Arjun Patel", .tentative)]),
                    myResponse: .accepted,
                    link: MeetingLink(url: URL(string: "https://meet.google.com/abc-defg-hij")!, service: .meet),
                    attachments: [], calendarURL: nil, audience: .inside),
            Meeting(id: "t2", title: "Design review: onboarding", start: next(11), end: next(11.75), topics: "", location: "Paris – Salle Monet",
                    organizer: "Chloé Martin", attendees: people([("Chloé Martin", .accepted), ("Diego Alvarez", .accepted)]),
                    myResponse: .tentative, link: nil, attachments: [], calendarURL: nil, audience: .inside),
            Meeting(id: "t3", title: "Partner check-in: Contoso", start: next(15), end: next(15.5), topics: "", location: nil,
                    organizer: "You", attendees: people([("Hana Sato", .accepted)]),
                    myResponse: .accepted,
                    link: MeetingLink(url: URL(string: "https://acme.zoom.us/j/93812345678?pwd=demo")!, service: .zoom),
                    attachments: [], calendarURL: nil, audience: .outside, externalDomains: ["contoso.com"]),
        ]
        // Guests from the sample customers and partners are external.
        let outsiders: Set<String> = ["Lena Fischer", "Omar Haddad", "Hana Sato"]
        for m in meetings.indices {
            for a in meetings[m].attendees.indices where outsiders.contains(meetings[m].attendees[a].name) {
                meetings[m].attendees[a].isExternal = true
            }
        }
        meetings = Self.mergingPrep(meetings).sorted { $0.start < $1.start }
        hasLoaded = true
    }
    #endif
}
