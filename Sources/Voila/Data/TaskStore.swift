import AppKit
import Foundation
import Observation

/// The two statuses a task can have. **Now** = what you're actively working on, chosen by you and
/// stored as a `now` flag in Voilà's notes line; **Later** = everything else. Due dates are independent.
enum Bucket: Hashable {
    case now, later
}

/// A task shown in the open list, with its indentation depth (subtasks are depth 1).
struct TaskRowItem: Identifiable {
    let task: GTask
    let depth: Int
    var id: String { task.id }
}

@MainActor
@Observable
final class TaskStore {
    private let api: TasksAPI

    private(set) var lists: [TaskList] = []
    private(set) var selectedListID: String?
    private(set) var tasks: [GTask] = []
    private(set) var isLoading = false
    var errorMessage: String?

    /// The task shown in the focus card: running, or the last one paused (until completed or dismissed).
    private(set) var focusTask: GTask?
    private(set) var focusListID: String?

    /// Set briefly after completing a task, to drive the celebration.
    private(set) var celebration = 0

    init(auth: GoogleAuth) {
        api = TasksAPI(auth: auth)
        selectedListID = UserDefaults.standard.string(forKey: "selectedListID")
        if let ref = UserDefaults.standard.dictionary(forKey: "focusRef") as? [String: String] {
            focusListID = ref["list"]
            if let id = ref["task"] {
                focusTask = GTask(id: id, title: ref["title"], notes: nil, status: "needsAction")
            }
        }
    }

    // MARK: - Derived

    var selectedList: TaskList? { lists.first { $0.id == selectedListID } }

    func bucket(of task: GTask) -> Bucket {
        // Subtasks follow their parent.
        if let parentID = task.parent, let parent = tasks.first(where: { $0.id == parentID }), !parent.isCompleted {
            return bucket(of: parent)
        }
        let track = task.track
        return track.isNow || track.isRunning ? .now : .later   // a running task is always active
    }

    /// Whether a task is due today or overdue (shown as a hint; it doesn't move the task).
    func isDue(_ task: GTask) -> Bool {
        guard let due = task.dueDate else { return false }
        return due <= Calendar.current.startOfDay(for: .now)
    }

    /// Later tasks that are due today or overdue.
    var dueInLaterCount: Int {
        tasks.lazy.filter { !$0.isCompleted && $0.parent == nil && self.bucket(of: $0) == .later && self.isDue($0) }.count
    }

    /// Now's open tasks (the main list).
    var openItems: [TaskRowItem] { items(in: .now) }

    func items(in bucket: Bucket) -> [TaskRowItem] {
        let open = tasks.filter { !$0.isCompleted }
        let openIDs = Set(open.map(\.id))
        let byPosition: (GTask, GTask) -> Bool = { ($0.position ?? "") < ($1.position ?? "") }
        let roots = open.filter { ($0.parent == nil || !openIDs.contains($0.parent!)) && self.bucket(of: $0) == bucket }
            .sorted(by: byPosition)
        let children = Dictionary(grouping: open.filter { $0.parent != nil && openIDs.contains($0.parent!) },
                                  by: { $0.parent! })
        return roots.flatMap { root in
            [TaskRowItem(task: root, depth: 0)]
                + (children[root.id] ?? []).sorted(by: byPosition).map { TaskRowItem(task: $0, depth: 1) }
        }
    }

    var completedTasks: [GTask] {
        tasks.filter(\.isCompleted)
            .sorted { ($0.completedDate ?? .distantPast) > ($1.completedDate ?? .distantPast) }
            .prefix(30).map { $0 }
    }

    func count(in bucket: Bucket) -> Int {
        tasks.lazy.filter { !$0.isCompleted && self.bucket(of: $0) == bucket }.count
    }

    /// Open tasks in Now (drives the header stats and the pill).
    var openCount: Int { count(in: .now) }

    var doneTodayCount: Int {
        tasks.lazy.filter { $0.isCompleted && ($0.completedDate.map(Calendar.current.isDateInToday) ?? false) }.count
    }

    var nextTask: GTask? { items(in: .now).first?.task }

    /// Forgets everything cached for the current account (sign-out, or a different account signing in).
    func reset() {
        lists = []
        tasks = []
        selectedListID = nil
        focusTask = nil
        focusListID = nil
        errorMessage = nil
        for key in ["selectedListID", "focusRef"] { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: - Loading

    func bootstrap() async {
        await loadLists()
        await refresh()
    }

    func loadLists() async {
        do {
            lists = try await api.lists()
            if selectedListID == nil || !lists.contains(where: { $0.id == selectedListID }) {
                selectList(lists.first?.id, reload: false)
            }
        } catch {
            report(error)
        }
    }

    func selectList(_ id: String?, reload: Bool = true) {
        guard id != selectedListID || !reload else { return }
        selectedListID = id
        UserDefaults.standard.set(id, forKey: "selectedListID")
        tasks = []
        if reload { Task { await refresh() } }
    }

    func refresh() async {
        guard let listID = selectedListID else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await api.tasks(in: listID)
            guard listID == selectedListID else { return }
            tasks = fetched
            await syncFocus()
        } catch {
            report(error)
        }
    }

    /// Keeps the focus card in sync with the server, adopting a task started elsewhere.
    private func syncFocus() async {
        if let focusTask, let focusListID {
            if focusListID == selectedListID {
                if let fresh = tasks.first(where: { $0.id == focusTask.id }), !fresh.isCompleted {
                    self.focusTask = fresh
                } else {
                    setFocus(nil, listID: nil)
                }
            } else if let fresh = try? await api.task(focusTask.id, in: focusListID), !fresh.isCompleted {
                self.focusTask = fresh
            } else {
                setFocus(nil, listID: nil)
            }
        }
        if focusTask?.track.isRunning != true,
           let running = tasks.filter({ !$0.isCompleted && $0.track.isRunning })
               .max(by: { ($0.track.runningSince ?? .distantPast) < ($1.track.runningSince ?? .distantPast) }) {
            setFocus(running, listID: selectedListID)
        }
    }

    private func setFocus(_ task: GTask?, listID: String?) {
        focusTask = task
        focusListID = task == nil ? nil : listID
        if let task, let listID {
            UserDefaults.standard.set(["list": listID, "task": task.id, "title": task.displayTitle], forKey: "focusRef")
        } else {
            UserDefaults.standard.removeObject(forKey: "focusRef")
        }
    }

    func dismissFocus() {
        guard let task = focusTask, !task.track.isRunning else { return }
        setFocus(nil, listID: nil)
    }

    // MARK: - Mutations

    func addTask(title: String, estimate: TimeInterval?, due: Date?) async {
        guard let listID = selectedListID else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        var fields: [String: Any] = ["title": title]
        if let estimate { fields["notes"] = NotesCodec.compose(body: "", track: TrackInfo(estimate: estimate)) }
        if let due { fields["due"] = DueDate.string(from: due) }
        do {
            let created = try await api.insert(in: listID, fields: fields)
            if listID == selectedListID { tasks.append(created) }
        } catch {
            report(error)
        }
    }

    func start(_ task: GTask) async {
        let listID = listID(for: task)
        if let current = focusTask, current.id != task.id, current.track.isRunning, let currentList = focusListID {
            await setTrack(current.track.paused(), on: current, listID: currentList)
        }
        var track = task.track
        guard !track.isRunning else { return }
        track.runningSince = .now
        track.isNow = true      // starting work makes the task active
        setFocus(task, listID: listID)
        await setTrack(track, on: task, listID: listID)
    }

    func pause(_ task: GTask) async {
        guard task.track.isRunning else { return }
        await setTrack(task.track.paused(), on: task, listID: listID(for: task))
    }

    func toggleRunning(_ task: GTask) async {
        if task.track.isRunning { await pause(task) } else { await start(task) }
    }

    func complete(_ task: GTask) async {
        let listID = listID(for: task)
        var track = task.track.paused()
        track.isNow = false     // done: no longer active
        var fields: [String: Any] = ["status": "completed"]
        if task.track.isRunning || task.track.isNow {
            fields["notes"] = NotesCodec.compose(body: task.noteBody, track: track)
        }
        if focusTask?.id == task.id { setFocus(nil, listID: nil) }
        celebration += 1
        NSSound(named: "Glass")?.play()
        let wasNow = bucket(of: task) == .now
        await mutate(task, listID: listID, fields: fields) {
            $0.status = "completed"
            $0.completed = ISO8601.format(.now)
            if let notes = fields["notes"] as? String { $0.notes = notes }
        }
        // Open subtasks of a Now task were active through their parent: keep them in Now.
        if wasNow {
            for child in tasks where child.parent == task.id && !child.isCompleted && !child.track.isNow {
                await setNow(true, for: child)
            }
        }
    }

    func reopen(_ task: GTask) async {
        await mutate(task, listID: listID(for: task), fields: ["status": "needsAction", "completed": NSNull()]) {
            $0.status = "needsAction"
            $0.completed = nil
        }
    }

    func setEstimate(_ estimate: TimeInterval?, for task: GTask) async {
        var track = task.track
        track.estimate = estimate
        await setTrack(track, on: task, listID: listID(for: task))
    }

    func resetTime(for task: GTask) async {
        var track = task.track
        track.spent = 0
        if track.isRunning { track.runningSince = .now }
        await setTrack(track, on: task, listID: listID(for: task))
    }

    func setDue(_ date: Date?, for task: GTask) async {
        let value: Any = date.map(DueDate.string(from:)) ?? NSNull()
        await mutate(task, listID: listID(for: task), fields: ["due": value]) {
            $0.due = date.map(DueDate.string(from:))
        }
    }

    /// One-click switch between Now and Later (the due date is left alone).
    func toggleBucket(_ task: GTask) async {
        await setNow(bucket(of: task) != .now, for: task)
    }

    func setNow(_ isNow: Bool, for task: GTask) async {
        var track = (tasks.first { $0.id == task.id } ?? task).track
        guard track.isNow != isNow else { return }
        track.isNow = isNow
        await setTrack(track, on: tasks.first { $0.id == task.id } ?? task, listID: listID(for: task))
    }

    func rename(_ task: GTask, to title: String) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != task.title else { return }
        await mutate(task, listID: listID(for: task), fields: ["title": title]) { $0.title = title }
    }

    // MARK: - Reordering

    func task(withID id: String) -> GTask? { tasks.first { $0.id == id } }

    /// Open siblings in display order; top-level ones are limited to one section (Today or Later).
    private func openSiblings(parent: String?, in section: Bucket) -> [GTask] {
        tasks.filter { !$0.isCompleted && $0.parent == parent && (parent != nil || bucket(of: $0) == section) }
            .sorted { ($0.position ?? "") < ($1.position ?? "") }
    }

    /// Drag & drop: place `task` just before `target` (taking the target's parent). Dropping into the
    /// other section also moves it between Now and Later.
    func move(_ task: GTask, before target: GTask) async {
        guard task.id != target.id else { return }
        let section = bucket(of: target)
        if target.parent == nil, bucket(of: task) != section {
            await setNow(section == .now, for: task)
        }
        await move(task, parent: target.parent, beforeID: target.id, section: section)
    }

    /// Drop below the last task of a section: move to its end (switching Now/Later if needed).
    func move(_ task: GTask, toEndOf section: Bucket) async {
        if bucket(of: task) != section || task.parent != nil {
            await setNow(section == .now, for: task)
        }
        await move(task, parent: nil, beforeID: nil, section: section)
    }

    func moveUp(_ task: GTask) async {
        let siblings = openSiblings(parent: task.parent, in: bucket(of: task))
        guard let i = siblings.firstIndex(where: { $0.id == task.id }), i > 0 else { return }
        await move(task, parent: task.parent, beforeID: siblings[i - 1].id, section: bucket(of: task))
    }

    func moveDown(_ task: GTask) async {
        let siblings = openSiblings(parent: task.parent, in: bucket(of: task))
        guard let i = siblings.firstIndex(where: { $0.id == task.id }), i < siblings.count - 1 else { return }
        await move(task, parent: task.parent, beforeID: i + 2 < siblings.count ? siblings[i + 2].id : nil,
                   section: bucket(of: task))
    }

    func moveToTop(_ task: GTask) async {
        await move(task, parent: task.parent,
                   beforeID: openSiblings(parent: task.parent, in: bucket(of: task)).first?.id, section: bucket(of: task))
    }

    func canMove(_ task: GTask, up: Bool) -> Bool {
        let siblings = openSiblings(parent: task.parent, in: bucket(of: task))
        guard let i = siblings.firstIndex(where: { $0.id == task.id }) else { return false }
        return up ? i > 0 : i < siblings.count - 1
    }

    /// Reorders locally right away, then asks Google to move the task after the preceding sibling.
    private func move(_ task: GTask, parent: String?, beforeID: String?, section: Bucket) async {
        guard let listID = selectedListID, parent != task.id else { return }
        if parent != nil, tasks.contains(where: { $0.parent == task.id && !$0.isCompleted }) {
            errorMessage = "A task with subtasks can't become a subtask."
            return
        }
        var siblings = openSiblings(parent: parent, in: section).filter { $0.id != task.id }
        let index = beforeID.flatMap { id in siblings.firstIndex { $0.id == id } } ?? siblings.count
        let previous = index > 0 ? siblings[index - 1].id : nil

        var moved = tasks.first { $0.id == task.id } ?? task
        moved.parent = parent
        siblings.insert(moved, at: index)
        for (i, sibling) in siblings.enumerated() {
            var updated = sibling
            updated.position = String(format: "%020d", i)
            apply(updated)
        }

        do {
            apply(try await api.move(task.id, in: listID, parent: parent, previous: previous))
        } catch {
            report(error)
        }
        await refresh()
    }

    func delete(_ task: GTask) async {
        let listID = listID(for: task)
        if focusTask?.id == task.id { setFocus(nil, listID: nil) }
        let snapshot = tasks
        tasks.removeAll { $0.id == task.id }
        do {
            try await api.delete(task.id, in: listID)
        } catch {
            tasks = snapshot
            report(error)
        }
    }

    #if DEBUG
    /// Sample data for UI checks without a Google account (`VOILA_DEMO=1`, debug builds only).
    func loadDemo() {
        let now = Date()
        func notes(_ t: TrackInfo) -> String { NotesCodec.compose(body: "", track: t) }
        lists = [TaskList(id: "demo", title: "My Tasks"), TaskList(id: "work", title: "Work")]
        selectedListID = "demo"
        tasks = [
            GTask(id: "1", title: "Write Q4 product strategy memo",
                  notes: notes(TrackInfo(spent: 1500, estimate: 3600, runningSince: now.addingTimeInterval(-642), isNow: true)),
                  status: "needsAction", due: DueDate.string(from: now), position: "1"),
            GTask(id: "2", title: "Review design mocks for onboarding", notes: notes(TrackInfo(spent: 2400, estimate: 1800, isNow: true)),
                  status: "needsAction", due: DueDate.string(from: now.addingTimeInterval(86400 * 3)), position: "2"),
            GTask(id: "2a", title: "Leave feedback in Figma", notes: nil, status: "needsAction", parent: "2", position: "1"),
            GTask(id: "3", title: "Prep customer demo", notes: "Use the retail dataset\n\n" + notes(TrackInfo(estimate: 2700)),
                  status: "needsAction", due: DueDate.string(from: now.addingTimeInterval(86400)), position: "3"),
            GTask(id: "4", title: "Book flights to NYC", notes: nil, status: "needsAction",
                  due: DueDate.string(from: now.addingTimeInterval(-86400)), position: "4"),
            GTask(id: "5", title: "Reply to Sarah about roadmap", notes: notes(TrackInfo(spent: 600)), status: "completed",
                  completed: ISO8601.format(now.addingTimeInterval(-3600)), position: "5"),
            GTask(id: "6", title: "Expense report", notes: nil, status: "completed",
                  completed: ISO8601.format(now.addingTimeInterval(-7200)), position: "6"),
        ]
        focusTask = tasks[0]
        focusListID = "demo"
    }
    #endif

    // MARK: - Helpers

    private func listID(for task: GTask) -> String {
        if task.id == focusTask?.id, let focusListID { return focusListID }
        return selectedListID ?? ""
    }

    private func setTrack(_ track: TrackInfo, on task: GTask, listID: String) async {
        let notes = NotesCodec.compose(body: task.noteBody, track: track)
        await mutate(task, listID: listID, fields: ["notes": notes]) { $0.notes = notes }
    }

    /// Optimistically applies `change` locally, PATCHes the server, then adopts the server's copy.
    private func mutate(_ task: GTask, listID: String, fields: [String: Any], change: (inout GTask) -> Void) async {
        var local = tasks.first { $0.id == task.id } ?? task
        change(&local)
        apply(local)
        do {
            let server = try await api.patch(task.id, in: listID, fields: fields)
            apply(server)
        } catch {
            report(error)
            await refresh()
        }
    }

    private func apply(_ task: GTask) {
        if let i = tasks.firstIndex(where: { $0.id == task.id }) { tasks[i] = task }
        if focusTask?.id == task.id { focusTask = task }
    }

    private func report(_ error: Error) {
        if error is CancellationError { return }
        if (error as? URLError)?.code == .cancelled { return }
        errorMessage = error.localizedDescription
    }
}
