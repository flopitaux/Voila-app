import SwiftUI

struct TaskRow: View {
    @Environment(AppModel.self) private var model
    var task: GTask
    var depth: Int

    @State private var hovering = false
    @State private var checking = false
    @State private var burst = 0
    @State private var editing = false
    @State private var draft = ""
    @State private var dropTargeted = false
    @State private var circleHovering = false
    @State private var showQuickEdit = false
    @State private var titleHovering = false
    @FocusState private var editorFocused: Bool

    private var store: TaskStore { model.store }

    var body: some View {
        let track = task.track
        HStack(alignment: .center, spacing: 10) {
            startButton(track)

            VStack(alignment: .leading, spacing: 4) {
                if editing {
                    TextField("Task", text: $draft)
                        .textFieldStyle(.plain)
                        .focused($editorFocused)
                        .onSubmit(commitEdit)
                        .onExitCommand { editing = false }
                        .onChange(of: editorFocused) { if !editorFocused { commitEdit() } }
                } else {
                    // Click the title to set the estimate (and rename) in a popover.
                    Text(task.displayTitle)
                        .lineLimit(2)
                        .strikethrough(checking, color: .secondary)
                        .foregroundStyle(checking ? .secondary : .primary)
                        .underline(titleHovering && !checking, color: .secondary.opacity(0.5))
                        .contentShape(Rectangle())
                        .onTapGesture { showQuickEdit = true }
                        .onHover { titleHovering = $0 }
                        .pointerStyle(.link)
                        .help("Set estimate or rename")
                        .popover(isPresented: $showQuickEdit, arrowEdge: .bottom) {
                            TaskQuickEdit(task: task) { showQuickEdit = false }
                                .environment(model)
                        }
                }
                meta(track)
            }
            .font(.voila(13.5, .medium))

            Spacer(minLength: 0)
        }
        .frame(minHeight: 26)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .padding(.leading, CGFloat(depth) * 22)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(track.isRunning ? AnyShapeStyle(Theme.tint.opacity(0.10))
                                      : AnyShapeStyle(.primary.opacity(hovering ? 0.06 : 0)))
        }
        .contentShape(Rectangle())
        // Hover actions float over the end of the row, so titles keep the full width
        // and nothing reflows when the mouse moves.
        .overlay(alignment: .trailing) {
            if hovering && !editing { hoverActions(track).padding(.trailing, 8).transition(.opacity) }
        }
        .overlay(alignment: .top) {
            if dropTargeted {
                Capsule().fill(Theme.accent).frame(height: 2.5).offset(y: -2).padding(.horizontal, 6)
            }
        }
        .draggable(task.id) {
            Text(task.displayTitle)
                .font(.voila(13, .medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
        }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, id != task.id, let dragged = store.task(withID: id) else { return false }
            Task { await store.move(dragged, before: task) }
            return true
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.12)) { dropTargeted = targeted }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .contextMenu { menu(track) }
    }

    // MARK: - Pieces

    private func hoverActions(_ track: TrackInfo) -> some View {
        HStack(spacing: 4) {
            // One-click Today ⇄ Later (top-level tasks; subtasks follow their parent).
            if depth == 0 {
                let isToday = store.bucket(of: task) == .today
                Button {
                    Task { await store.toggleBucket(task) }
                } label: {
                    Image(systemName: isToday ? "moon" : "sun.max")
                        .font(.voila(11, .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(.primary.opacity(0.08), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help(isToday ? "Move to Later" : "Move to Today")
            }
            Button(action: complete) {
                Image(systemName: "checkmark")
                    .font(.voila(11, .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Theme.done, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Mark as done")
        }
        .padding(3)
        .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
        .background(Capsule().strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }

    /// Leading circle: ▶ to start (⚡ / ⏸ for the running task). Its outline is the progress ring
    /// (time vs. estimate, amber past 100%). Turns into a green ✓ while completing.
    private func startButton(_ track: TrackInfo) -> some View {
        let running = track.isRunning
        let active = circleHovering && !checking
        return Button {
            guard !checking else { return }
            Task { await store.toggleRunning(task) }
        } label: {
            TimelineView(.periodic(from: .now, by: running ? 1 : 3600)) { ctx in
                let progress = track.progress(at: ctx.date)
                let showRing = running || (progress ?? 0) > 0
                ZStack {
                    // Outline = progress ring once work has started (or a spinner while running).
                    if !showRing {
                        Circle().strokeBorder(active ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary.opacity(0.55)),
                                              lineWidth: 1.5)
                    } else {
                        ProgressRing(progress: progress, isRunning: running, lineWidth: 2.2)
                            .padding(1.1)
                    }
                    // Hover: filled button inside the ring.
                    Circle()
                        .fill(Theme.accent)
                        .padding(showRing ? 3.5 : 0)
                        .opacity(active ? 1 : 0)
                    Image(systemName: active ? (running ? "pause.fill" : "play.fill") : (running ? "bolt.fill" : "play.fill"))
                        .font(.system(size: 7.5, weight: .heavy))
                        .foregroundStyle(active ? AnyShapeStyle(.white)
                                                : running ? AnyShapeStyle(Theme.tint) : AnyShapeStyle(.secondary))
                        .offset(x: running && !active ? 0 : 0.5)   // optical centering of ▶
                        .opacity(checking ? 0 : 1)
                    // Completion state: green fill + check.
                    Circle()
                        .fill(Theme.done)
                        .scaleEffect(checking ? 1 : 0.001)
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                        .scaleEffect(checking ? 1.05 : 0.3)
                        .opacity(checking ? 1 : 0)
                }
            }
            .frame(width: 22, height: 22)
            .scaleEffect(active ? 1.08 : 1)
            .overlay { CelebrationBurst(trigger: burst) }
            .padding(4)               // larger, forgiving hit area
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { h in withAnimation(.spring(duration: 0.2, bounce: 0.3)) { circleHovering = h } }
        .padding(-4)
        .help(running ? "Pause" : "Start")
    }

    private func complete() {
        guard !checking else { return }
        withAnimation(.spring(duration: 0.3, bounce: 0.5)) { checking = true }
        burst += 1
        Task {
            try? await Task.sleep(for: .milliseconds(420))
            await store.complete(task)
            checking = false
        }
    }

    @ViewBuilder
    private func meta(_ track: TrackInfo) -> some View {
        let showTime = track.spent > 0 || track.estimate != nil || track.isRunning
        let due = task.dueDate.map(DueDate.label(for:))
        let hasNotes = !task.noteBody.isEmpty
        if showTime || due != nil || hasNotes {
            HStack(spacing: 6) {
                if showTime {
                    TimelineView(.periodic(from: .now, by: track.isRunning ? 1 : 3600)) { ctx in
                        let label = timeLabel(elapsed: track.elapsed(at: ctx.date), estimate: track.estimate,
                                              running: track.isRunning)
                        Text(label.text)
                            .monospacedDigit()
                            .foregroundStyle(label.over ? AnyShapeStyle(Theme.overtime) : AnyShapeStyle(.secondary))
                            .font(.voila(10.5, .semibold))
                    }
                }
                if let due, due.urgency != .today {   // "Today" is implied by the Today view
                    Chip(text: due.text, systemImage: "calendar", tint: due.urgency.tint,
                         filled: due.urgency == .overdue)
                }
                if hasNotes {
                    Image(systemName: "text.alignleft")
                        .font(.voila(9.5, .semibold))
                        .foregroundStyle(.tertiary)
                        .help(task.noteBody)
                }
            }
        }
    }

    /// Remaining time is what matters for planning; the ring on the left shows the proportion.
    private func timeLabel(elapsed: TimeInterval, estimate: TimeInterval?, running: Bool) -> (text: String, over: Bool) {
        guard let estimate else {
            return (running ? DurationFormat.clock(elapsed) : DurationFormat.short(elapsed), false)
        }
        if elapsed < 1 && !running { return (DurationFormat.short(estimate), false) }   // not started yet
        let remaining = estimate - elapsed
        return remaining >= 0 ? ("\(DurationFormat.short(remaining)) left", false)
                              : ("\(DurationFormat.short(-remaining)) over", true)
    }

    @ViewBuilder
    private func menu(_ track: TrackInfo) -> some View {
        Button(track.isRunning ? "Pause" : "Start Focus") { Task { await store.toggleRunning(task) } }
        Button("Mark as Done") { Task { await store.complete(task) } }
        Divider()
        if depth == 0 {
            Button(store.bucket(of: task) == .today ? "Move to Later" : "Move to Today") {
                Task { await store.toggleBucket(task) }
            }
            Divider()
        }
        Button("Move to Top") { Task { await store.moveToTop(task) } }
            .disabled(!store.canMove(task, up: true))
        Button("Move Up") { Task { await store.moveUp(task) } }
            .disabled(!store.canMove(task, up: true))
        Button("Move Down") { Task { await store.moveDown(task) } }
            .disabled(!store.canMove(task, up: false))
        Divider()
        Menu("Estimate") {
            ForEach(EstimateOption.all, id: \.self) { seconds in
                Button(DurationFormat.short(seconds)) { Task { await store.setEstimate(seconds, for: task) } }
            }
            if track.estimate != nil {
                Divider()
                Button("No Estimate") { Task { await store.setEstimate(nil, for: task) } }
            }
        }
        Menu("Due Date") {
            Button("Today") { Task { await store.setDue(QuickDate.parse("today"), for: task) } }
            Button("Tomorrow") { Task { await store.setDue(QuickDate.parse("tomorrow"), for: task) } }
            Button("Next Week") { Task { await store.setDue(QuickDate.parse("week"), for: task) } }
            if task.due != nil {
                Divider()
                Button("No Due Date") { Task { await store.setDue(nil, for: task) } }
            }
        }
        if track.spent > 0 {
            Button("Reset Tracked Time") { Task { await store.resetTime(for: task) } }
        }
        Divider()
        Button("Rename") { beginEdit() }
        Button("Delete", role: .destructive) { Task { await store.delete(task) } }
    }

    private func beginEdit() {
        draft = task.title ?? ""
        editing = true
        editorFocused = true
    }

    private func commitEdit() {
        guard editing else { return }
        editing = false
        let newTitle = draft
        Task { await store.rename(task, to: newTitle) }
    }
}
