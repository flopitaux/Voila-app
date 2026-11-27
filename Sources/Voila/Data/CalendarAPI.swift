import Foundation

/// One event of the user's primary Google Calendar, as returned by the Calendar API v3.
struct GEvent: Decodable {
    struct When: Decodable {
        var dateTime: String?
        var date: String?      // all-day events
    }
    struct Person: Decodable {
        var email: String?
        var displayName: String?
        var responseStatus: String?
        var isSelf: Bool?
        var resource: Bool?    // meeting rooms

        enum CodingKeys: String, CodingKey {
            case email, displayName, responseStatus, resource
            case isSelf = "self"
        }
    }
    struct Conference: Decodable {
        struct EntryPoint: Decodable {
            var entryPointType: String?
            var uri: String?
        }
        struct Solution: Decodable { var name: String? }
        var entryPoints: [EntryPoint]?
        var conferenceSolution: Solution?
    }
    struct Attachment: Decodable {
        var title: String?
        var fileUrl: String?
    }

    let id: String
    var summary: String?
    var description: String?
    var location: String?
    var status: String?
    var eventType: String?
    var colorId: String?   // "1"…"11" when the event has its own colour
    var htmlLink: String?
    var hangoutLink: String?
    var start: When?
    var end: When?
    var organizer: Person?
    var attendees: [Person]?
    var conferenceData: Conference?
    var attachments: [Attachment]?
}

struct CalendarError: LocalizedError {
    let status: Int
    let message: String
    /// The token doesn't carry the calendar permission (connected before it existed, or unticked).
    var isMissingScope: Bool {
        status == 403 && (message.localizedCaseInsensitiveContains("insufficient")
                          || message.localizedCaseInsensitiveContains("scope"))
    }
    var errorDescription: String? { "Google Calendar error \(status): \(message)" }
}

/// Read-only client for the Google Calendar REST API v3 (primary calendar only).
@MainActor
final class CalendarAPI {
    private let auth: GoogleAuth
    private let base = URL(string: "https://www.googleapis.com/calendar/v3/")!

    init(auth: GoogleAuth) { self.auth = auth }

    /// Events overlapping `from ..< to`, recurring ones expanded, ordered by start time.
    func events(from: Date, to: Date) async throws -> [GEvent] {
        struct Page: Decodable {
            var items: [GEvent]?
            var nextPageToken: String?
        }
        var all: [GEvent] = []
        var pageToken: String?
        repeat {
            var query = [
                "timeMin": ISO8601.format(from), "timeMax": ISO8601.format(to),
                "singleEvents": "true", "orderBy": "startTime", "maxResults": "250",
            ]
            if let pageToken { query["pageToken"] = pageToken }
            let page = try JSONDecoder().decode(Page.self, from: await get("calendars/primary/events", query: query))
            all += page.items ?? []
            pageToken = page.nextPageToken
        } while pageToken != nil
        return all
    }

    private func get(_ path: String, query: [String: String], retry: Bool = true) async throws -> Data {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        // "+" in a time zone offset must not be read as a space.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: comps.url!)
        request.setValue("Bearer \(try await auth.validAccessToken(forceRefresh: !retry))",
                         forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 && retry { return try await get(path, query: query, retry: false) }
        guard (200..<300).contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
                ?? HTTPURLResponse.localizedString(forStatusCode: status)
            throw CalendarError(status: status, message: message)
        }
        return data
    }
}
