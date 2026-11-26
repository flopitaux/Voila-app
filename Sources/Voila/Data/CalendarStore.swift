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

    func todayMeetings(at date: Date = .now) -> [Meeting] {
        meetings.filter { Calendar.current.isDate($0.start, inSameDayAs: date) }
    }

    /// Meetings the user is expected at (declined ones are shown, never announced).
    private var attending: [Meeting] { meetings.filter { !$0.isDeclined } }

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

    /// Meetings that just started and haven't been announced yet; marks them announced.
    func takeDue(at date: Date) -> [Meeting] {
        let due = attending.filter {
            $0.start <= date && date < min($0.end, $0.start.addingTimeInterval(Self.announceWindow))
                && !announced.contains($0.occurrenceKey)
        }
        announced.formUnion(due.map(\.occurrenceKey))
        return due
    }

    /// When the next card is due.
    func nextAnnouncement(after date: Date) -> Date? {
        attending.first { $0.start > date && !announced.contains($0.occurrenceKey) }?.start
    }

    // MARK: - Loading

    func refresh() async {
        guard auth.isSignedIn, auth.hasCalendarAccess else { return }
        let cal = Calendar.current
        let from = cal.startOfDay(for: .now)
        guard let to = cal.date(byAdding: .day, value: 2, to: from) else { return }
        do {
            meetings = try await api.events(from: from, to: to).compactMap(Meeting.init)
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
                    attachments: [], calendarURL: nil),
            Meeting(id: "m2", title: "Q4 roadmap review", start: at(-12), end: at(33),
                    topics: "• Where we landed on the Q4 priorities\n• Open risks on the analytics launch\n• Hiring plan for the design team\n\nPlease read the memo before the call.",
                    location: "Paris – Salle Monet", organizer: "Sarah Lin",
                    attendees: people([("Sarah Lin", .accepted), ("Arjun Patel", .accepted), ("Chloé Martin", .accepted),
                                       ("Diego Alvarez", .tentative), ("Emma Wilson", .declined), ("Noah Kim", .needsAction),
                                       ("Priya Shah", .needsAction)]),
                    myResponse: .accepted,
                    link: MeetingLink(url: URL(string: "https://acme.zoom.us/j/93812345678?pwd=demo")!, service: .zoom),
                    attachments: ["Q4 strategy memo", "Roadmap – draft v3"], calendarURL: nil),
            Meeting(id: "m3", title: "Customer demo: Northwind", start: at(58), end: at(118),
                    topics: "Walk through the retail dashboard, then questions.", location: nil, organizer: "You",
                    attendees: people([("Lena Fischer", .accepted), ("Omar Haddad", .needsAction)]),
                    myResponse: .accepted,
                    link: MeetingLink(url: URL(string: "https://teams.microsoft.com/l/meetup-join/demo")!, service: .teams),
                    attachments: [], calendarURL: nil),
            Meeting(id: "m4", title: "Vendor pitch", start: at(150), end: at(180), topics: "", location: nil,
                    organizer: "Jules Bernard", attendees: people([("Jules Bernard", .accepted)]),
                    myResponse: .declined, link: nil, attachments: [], calendarURL: nil),
            Meeting(id: "m5", title: "1:1 with Sarah", start: at(200), end: at(230), topics: "", location: nil,
                    organizer: "Sarah Lin", attendees: people([("Sarah Lin", .accepted)]),
                    myResponse: .needsAction,
                    link: MeetingLink(url: URL(string: "https://meet.google.com/xyz-abcd-efg")!, service: .meet),
                    attachments: [], calendarURL: nil),
        ]
        .filter { Calendar.current.isDate($0.start, inSameDayAs: now) || $0.isOngoing(at: now) }
        hasLoaded = true
    }
    #endif
}
