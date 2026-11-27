import Foundation
import Observation

/// Colleagues' job titles, from the organization's Google directory (People API, read-only).
/// Titles are looked up once per person and remembered; a failed or empty lookup just means
/// the card shows the name alone.
@MainActor
@Observable
final class DirectoryStore {
    private let auth: GoogleAuth

    /// Lowercased email → "Job title • Department" ("" = looked up, none found).
    private(set) var titles: [String: String]
    /// Lowercased email → profile picture URL.
    private(set) var photos: [String: String]
    @ObservationIgnored private var inFlight: Set<String> = []

    init(auth: GoogleAuth) {
        self.auth = auth
        titles = UserDefaults.standard.dictionary(forKey: "directoryTitles") as? [String: String] ?? [:]
        photos = UserDefaults.standard.dictionary(forKey: "directoryPhotos") as? [String: String] ?? [:]
    }

    func photo(for email: String?) -> URL? {
        guard let email, let string = photos[email.lowercased()] else { return nil }
        return URL(string: string)
    }

    func title(for email: String?) -> String? {
        guard let email, let title = titles[email.lowercased()], !title.isEmpty else { return nil }
        return title
    }

    /// Looks up the internal guests of these meetings that aren't known yet, a few at a time.
    func load(for meetings: [Meeting]) async {
        guard auth.isSignedIn, auth.hasDirectoryAccess else { return }
        var seen = Set<String>()
        let emails = meetings.flatMap(\.attendees)
            .filter { !$0.isExternal && !$0.isSelf }
            .compactMap { $0.email?.lowercased() }
            .filter { titles[$0] == nil && !inFlight.contains($0) && seen.insert($0).inserted }
        guard !emails.isEmpty else { return }
        inFlight.formUnion(emails)
        defer { inFlight.subtract(emails) }

        for email in emails.prefix(60) {
            do {
                let person = try await lookUp(email)
                if let photo = person.photo { photos[email] = photo }
                titles[email] = person.title ?? ""
            } catch let error as CalendarError where error.isMissingScope {
                // The directory permission isn't on this sign-in: stop asking until the user reconnects.
                auth.setDirectoryAccess(false)
                break
            } catch {
                // Offline, throttled, the People API not enabled yet, or blocked by the organization:
                // keep the permission and try again on a later refresh.
                break
            }
        }
        UserDefaults.standard.set(titles, forKey: "directoryTitles")
        UserDefaults.standard.set(photos, forKey: "directoryPhotos")
    }

    func reset() {
        titles = [:]
        photos = [:]
        UserDefaults.standard.removeObject(forKey: "directoryTitles")
        UserDefaults.standard.removeObject(forKey: "directoryPhotos")
    }

    private struct SearchResponse: Decodable {
        struct Person: Decodable {
            struct Email: Decodable { var value: String? }
            struct Organization: Decodable {
                var title: String?
                var department: String?
                var current: Bool?
            }
            struct Photo: Decodable {
                var url: String?
                var `default`: Bool?    // Google's generated placeholder, not a real picture
            }
            var emailAddresses: [Email]?
            var organizations: [Organization]?
            var photos: [Photo]?
        }
        var people: [Person]?
    }

    private func lookUp(_ email: String, retry: Bool = true) async throws -> (title: String?, photo: String?) {
        var comps = URLComponents(string: "https://people.googleapis.com/v1/people:searchDirectoryPeople")!
        comps.queryItems = [
            .init(name: "query", value: email),
            .init(name: "readMask", value: "emailAddresses,organizations,photos"),
            .init(name: "sources", value: "DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE"),
            .init(name: "pageSize", value: "5"),
        ]
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: comps.url!)
        request.setValue("Bearer \(try await auth.validAccessToken(forceRefresh: !retry))",
                         forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 && retry { return try await lookUp(email, retry: false) }
        guard (200..<300).contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
                ?? HTTPURLResponse.localizedString(forStatusCode: status)
            throw CalendarError(status: status, message: message)
        }
        let people = try JSONDecoder().decode(SearchResponse.self, from: data).people ?? []
        let match = people.first { person in
            person.emailAddresses?.contains { $0.value?.lowercased() == email } ?? false
        }
        let organizations = match?.organizations ?? []
        // As Google Calendar shows it: "Senior AI Outcomes Manager • 725 Customer COE".
        let organization = organizations.first { $0.current == true } ?? organizations.first
        let parts = [organization?.title, organization?.department]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let photo = match?.photos?.first { $0.default != true }?.url
            .flatMap { $0.lowercased().hasPrefix("https://") ? $0 : nil }
        return (parts.isEmpty ? nil : parts.joined(separator: " • "), photo)
    }

    #if DEBUG
    func loadDemo() {
        titles = [
            "sarah.lin@acme.com": "VP Product • 300 Product", "arjun.patel@acme.com": "Staff Engineer • 410 Platform",
            "chloe.martin@acme.com": "Head of Design • 320 Design", "diego.alvarez@acme.com": "Product Designer • 320 Design",
            "emma.wilson@acme.com": "Finance Director • 110 Finance", "noah.kim@acme.com": "Data Scientist • 430 Analytics",
            "priya.shah@acme.com": "Engineering Manager • 410 Platform", "maya.cohen@acme.com": "Product Manager • 300 Product",
            "tom.reed@acme.com": "Solutions Engineer • 725 Customer COE",
        ]
    }
    #endif
}
