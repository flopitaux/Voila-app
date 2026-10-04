import Foundation

struct TaskList: Codable, Identifiable, Hashable {
    let id: String
    var title: String
}

struct GTask: Codable, Identifiable, Hashable {
    let id: String
    var title: String?
    var notes: String?
    var status: String
    var due: String?
    var completed: String?
    var parent: String?
    var position: String?
    var deleted: Bool?

    var isCompleted: Bool { status == "completed" }
    var displayTitle: String {
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Untitled" : t
    }
    var track: TrackInfo { NotesCodec.parse(notes).track }
    var noteBody: String { NotesCodec.parse(notes).body }
    var dueDate: Date? { DueDate.date(from: due) }
    var completedDate: Date? { completed.flatMap { ISO8601.parse($0) } }
}

private struct Page<T: Decodable>: Decodable {
    var items: [T]?
    var nextPageToken: String?
}

struct APIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { "Google Tasks error \(status): \(message)" }
}

/// Thin async client for the Google Tasks REST API v1.
@MainActor
final class TasksAPI {
    private let auth: GoogleAuth
    private let base = URL(string: "https://tasks.googleapis.com/tasks/v1/")!

    init(auth: GoogleAuth) { self.auth = auth }

    func lists() async throws -> [TaskList] {
        try await paginate(path: "users/@me/lists", query: ["maxResults": "100"])
    }

    func tasks(in listID: String) async throws -> [GTask] {
        try await paginate(path: "lists/\(listID)/tasks",
                           query: ["maxResults": "100", "showCompleted": "true", "showHidden": "true"])
            .filter { $0.deleted != true }
    }

    func task(_ taskID: String, in listID: String) async throws -> GTask {
        try decode(await send("GET", path: "lists/\(listID)/tasks/\(taskID)"))
    }

    func insert(in listID: String, fields: [String: Any]) async throws -> GTask {
        try decode(await send("POST", path: "lists/\(listID)/tasks", body: fields))
    }

    /// `fields` may contain `NSNull()` to clear a value.
    func patch(_ taskID: String, in listID: String, fields: [String: Any]) async throws -> GTask {
        try decode(await send("PATCH", path: "lists/\(listID)/tasks/\(taskID)", body: fields))
    }

    /// Moves a task after `previous` (nil = first) under `parent` (nil = top level).
    func move(_ taskID: String, in listID: String, parent: String?, previous: String?) async throws -> GTask {
        var query: [String: String] = [:]
        if let parent { query["parent"] = parent }
        if let previous { query["previous"] = previous }
        return try decode(await send("POST", path: "lists/\(listID)/tasks/\(taskID)/move", query: query))
    }

    func delete(_ taskID: String, in listID: String) async throws {
        _ = try await send("DELETE", path: "lists/\(listID)/tasks/\(taskID)")
    }

    // MARK: - Plumbing

    private func paginate<T: Decodable>(path: String, query: [String: String]) async throws -> [T] {
        var all: [T] = []
        var pageToken: String?
        repeat {
            var q = query
            if let pageToken { q["pageToken"] = pageToken }
            let page: Page<T> = try decode(await send("GET", path: path, query: q))
            all += page.items ?? []
            pageToken = page.nextPageToken
        } while pageToken != nil
        return all
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }

    private func send(_ method: String, path: String, query: [String: String] = [:],
                      body: [String: Any]? = nil, retry: Bool = true) async throws -> Data {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: comps.url!)
        request.httpMethod = method
        request.setValue("Bearer \(try await auth.validAccessToken(forceRefresh: !retry))",
                         forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 && retry {
            return try await send(method, path: path, query: query, body: body, retry: false)
        }
        guard (200..<300).contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
                ?? HTTPURLResponse.localizedString(forStatusCode: status)
            throw APIError(status: status, message: message)
        }
        return data
    }
}
