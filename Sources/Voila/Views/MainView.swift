import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var showCompleted = false
    @State private var showLater = false

    private var store: TaskStore { model.store }

    var body: some View {
        VStack(spacing: 0) {
            Header()
                .padding(.horizontal, 16)
                .padding(.top, 13)
                .padding(.bottom, 10)

            if let focus = store.focusTask {
                FocusCard(task: focus)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.asymmetric(insertion: .scale(scale: 0.92).combined(with: .opacity),
                                            removal: .opacity))
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.openItems) { item in
                        TaskRow(task: item.task, depth: item.depth)
                            .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)),
                                                    removal: .opacity.combined(with: .scale(scale: 0.9))))
                    }

                    if store.openItems.isEmpty && !store.isLoading {
                        EmptyState(hasDone: store.doneTodayCount > 0, laterCount: store.count(in: .later))
                    }
                    EndDropZone(section: .today)

                    // Later: inline and collapsed, so the default view is just Today.
                    let later = store.items(in: .later)
                    if !later.isEmpty {
                        SectionHeader(title: "Later", icon: "moon", count: store.count(in: .later),
                                      expanded: $showLater)
                            .padding(.top, 6)
                        if showLater {
                            ForEach(later) { item in
                                TaskRow(task: item.task, depth: item.depth)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                            EndDropZone(section: .later)
                        }
                    }

                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .animation(.smooth(duration: 0.35), value: store.openItems.map(\.id))
                .animation(.smooth(duration: 0.35), value: store.items(in: .later).map(\.id))
            }
            .scrollIndicators(.never)
            .scrollContentBackground(.hidden)

            // Completed is pinned to the bottom of the window, on the same line as the + button.
            CompletedFooter(tasks: store.completedTasks, expanded: $showCompleted)
        }
        .overlay(alignment: .bottomTrailing) {
            AddTaskBar()
                .padding(12)
        }
        .animation(.spring(duration: 0.45, bounce: 0.25), value: store.focusTask?.id)
    }
}

// MARK: - Header

private struct Header: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.store
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Color.clear.frame(width: model.trafficLightsInset - 16, height: 1)

                Text("Voilà")
                    .font(.voila(20, .bold))
                    .lineLimit(1)

                // List picker (only when there's more than one Google Tasks list).
                if store.lists.count > 1 {
                    Menu {
                        Picker("Google Tasks list", selection: Binding(
                            get: { store.selectedListID ?? "" },
                            set: { store.selectList($0) })) {
                            ForEach(store.lists) { list in
                                Text(list.title).tag(list.id)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.voila(11, .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .help("Switch list: \(store.selectedList?.title ?? "")")
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                Spacer()

                IconButton(systemImage: "arrow.clockwise", help: "Refresh") { model.refreshNow() }
                    .rotationEffect(.degrees(store.isLoading ? 360 : 0))
                    .animation(store.isLoading ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                                               : .default, value: store.isLoading)
                IconButton(systemImage: "rectangle.compress.vertical", help: "Compact mode") {
                    model.setCompact(true)
                }
                Menu {
                    Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLogin },
                                                           set: { model.setLaunchAtLogin($0) }))
                    Toggle("Show in Dock", isOn: Binding(get: { model.showInDock },
                                                        set: { model.setShowInDock($0) }))
                    Divider()
                    Button("Minimize") { model.minimizePanel() }
                        .keyboardShortcut("m")
                    Button("Close Panel") { model.closePanel() }
                        .keyboardShortcut("w")
                    Divider()
                    Button("Sign Out of Google") { model.signOut() }
                    Button("Quit Voilà") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.voila(13, .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            TodayProgress(done: store.doneTodayCount, open: store.openCount)
        }
    }
}

private struct TodayProgress: View {
    var done: Int
    var open: Int

    var body: some View {
        let total = done + open
        let fraction = total == 0 ? 0 : Double(done) / Double(total)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(done == 0 ? "\(open) to do" : "\(done) done today · \(open) left")
                Spacer()
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }
            .font(.voila(11, .medium))
            .foregroundStyle(.secondary)
        }
    }
}

struct IconButton: View {
    var systemImage: String
    var help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.voila(12, .semibold))
                .frame(width: 26, height: 26)
                .background(.primary.opacity(hovering ? 0.08 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .onHover { hovering = $0 }
    }
}

// MARK: - Focus card

struct FocusCard: View {
    @Environment(AppModel.self) private var model
    var task: GTask

    var body: some View {
        let store = model.store
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let track = task.track
            let progress = track.progress(at: context.date)
            let elapsed = track.elapsed(at: context.date)
            HStack(spacing: 14) {
                RingPlayButton(progress: progress, isRunning: track.isRunning, lineWidth: 6) {
                    Task { await store.toggleRunning(task) }
                }
                .frame(width: 64, height: 64)

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.isRunning ? "FOCUSING" : "PAUSED")
                        .font(.voila(10, .heavy))
                        .tracking(1.2)
                        .foregroundStyle(track.isRunning ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                    Text(task.displayTitle)
                        .font(.voila(15, .semibold))
                        .lineLimit(2)
                    HStack(spacing: 4) {
                        Text(DurationFormat.clock(elapsed))
                            .font(.voila(20, .semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(.smooth, value: Int(elapsed))
                        if let estimate = track.estimate {
                            Text("/ \(DurationFormat.short(estimate))")
                                .font(.voila(12, .medium))
                                .foregroundStyle(.secondary)
                        }
                        if let progress, progress > 1, let estimate = track.estimate {
                            Chip(text: "+\(DurationFormat.short(elapsed - estimate))", tint: Theme.overtime)
                        }
                    }
                }
                Spacer(minLength: 0)

                VStack {
                    Button {
                        Task { await store.complete(task) }
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.voila(10, .bold))
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.small)
                    .pointerStyle(.link)
                    .help("Mark as done")
                }
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Theme.tint.opacity(track.isRunning ? 0.11 : 0.05))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Theme.tint.opacity(track.isRunning ? 0.28 : 0.12), lineWidth: 1))
            }
            .overlay(alignment: .topTrailing) {
                if !track.isRunning {
                    Button { withAnimation { store.dismissFocus() } } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 5, y: -5)
                    .help("Hide focus card")
                }
            }
        }
    }
}

/// Drop target below the last task of a section: moves the dragged task to its end
/// (and into that section if it came from the other one).
private struct EndDropZone: View {
    @Environment(AppModel.self) private var model
    var section: Bucket
    @State private var targeted = false

    var body: some View {
        Color.clear
            .frame(height: 14)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                if targeted { Capsule().fill(Theme.accent).frame(height: 2.5).padding(.horizontal, 14) }
            }
            .dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first, let task = model.store.task(withID: id) else { return false }
                Task { await model.store.move(task, toEndOf: section) }
                return true
            } isTargeted: { targeted = $0 }
    }
}

/// Collapsible section title ("› Later 12").
private struct SectionHeader: View {
    var title: String
    var icon: String
    var count: Int
    @Binding var expanded: Bool

    var body: some View {
        Button {
            withAnimation(.smooth) { expanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title)
                Text("\(count)").monospacedDigit().foregroundStyle(.tertiary)
                Spacer()
            }
            .font(.voila(12, .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
    }
}

// MARK: - Empty & completed

private struct EmptyState: View {
    var hasDone: Bool
    var laterCount: Int

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: hasDone ? "sparkles" : "sun.max")
                .font(.voila(30))
                .foregroundStyle(Theme.accent)
                .symbolEffect(.bounce, value: hasDone)
            Text(hasDone ? "Today is done!" : "Nothing for today")
                .font(.voila(15, .semibold))
            Text(hasDone ? "Enjoy it ✨" : laterCount > 0 ? "Pull a task in from Later below." : "Add a task with +.")
                .font(.voila(11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

/// Fixed footer: "› ✓ Completed N" at the bottom-left (the + sits at the bottom-right);
/// expanding reveals recently completed tasks in a short scrollable area above it.
private struct CompletedFooter: View {
    @Environment(AppModel.self) private var model
    var tasks: [GTask]
    @Binding var expanded: Bool

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.primary.opacity(0.07)).frame(height: 1)

            if expanded && !tasks.isEmpty {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(tasks) { task in row(task) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 190)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack {
                if !tasks.isEmpty {
                    SectionHeader(title: "Completed", icon: "checkmark.circle", count: tasks.count,
                                  expanded: $expanded)
                        .fixedSize()
                }
                Spacer()
            }
            .frame(height: 30)
            .padding(.leading, 8)
            .padding(.trailing, 54)      // keep clear of the + button
            .padding(.vertical, 12)
        }
        .animation(.smooth(duration: 0.3), value: expanded)
    }

    private func row(_ task: GTask) -> some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.store.reopen(task) }
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.voila(18))
                    .foregroundStyle(Theme.done)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Mark as not done")

            Text(task.displayTitle)
                .strikethrough()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if task.track.spent > 0 {
                Chip(text: DurationFormat.short(task.track.spent), systemImage: "timer")
            }
        }
        .font(.voila(13))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contextMenu {
            Button("Mark as Not Done") { Task { await model.store.reopen(task) } }
            Button("Delete", role: .destructive) { Task { await model.store.delete(task) } }
        }
    }
}

// MARK: - Add bar

private struct AddTaskBar: View {
    @Environment(AppModel.self) private var model
    @State private var title = ""
    @State private var estimate: TimeInterval?
    @State private var due: Date?
    @State private var datePickerShown = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .trailing) {
            if model.isAddingTask {
                field
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.15, anchor: .trailing).combined(with: .opacity),
                        removal: .scale(scale: 0.15, anchor: .trailing).combined(with: .opacity)))
            } else {
                Button { model.isAddingTask = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Theme.accent, in: Circle())
                        .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help("Add a task (⌘N)")
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.18), value: model.isAddingTask)
        .onChange(of: model.isAddingTask) {
            if model.isAddingTask { DispatchQueue.main.async { focused = true } }
        }
        .onChange(of: focused) {
            // Clicking away from an untouched field folds it back into the + button.
            guard !focused else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if !focused && !datePickerShown && title.isEmpty && estimate == nil && due == nil { close() }
            }
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .font(.voila(18))
                .foregroundStyle(Theme.accent)

            TextField("Add a task…", text: $title)
                .textFieldStyle(.plain)
                .font(.voila(14))
                .focused($focused)
                .onSubmit(submit)
                .onExitCommand { close() }

            Menu {
                ForEach(EstimateOption.all, id: \.self) { seconds in
                    Button(DurationFormat.short(seconds)) { estimate = seconds }
                }
                Divider()
                Button("No estimate") { estimate = nil }
            } label: {
                Chip(text: estimate.map(DurationFormat.short) ?? "Est.", systemImage: "timer",
                     tint: estimate == nil ? .secondary : Theme.tint)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Time estimate")

            DueMenu(due: due, showPicker: $datePickerShown) { due = $0 } label: {
                Chip(text: due.map { DueDate.label(for: $0).text } ?? "Due",
                     systemImage: "calendar",
                     tint: due.map { DueDate.label(for: $0).urgency.tint } ?? .secondary)
            }
            .help("Due date")

            Button { close() } label: {
                Image(systemName: "xmark")
                    .font(.voila(9, .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(.primary.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.92),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Theme.tint.opacity(focused ? 0.45 : 0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        .animation(.smooth(duration: 0.2), value: focused)
    }

    private func close() {
        title = ""
        estimate = nil
        due = nil
        focused = false
        model.isAddingTask = false
    }

    /// Supports inline shortcuts: "Write report ~45m !tomorrow".
    private func submit() {
        var words: [Substring] = []
        var est = estimate
        var date = due
        for word in title.split(separator: " ") {
            if word.hasPrefix("~"), let parsed = DurationFormat.parse(String(word.dropFirst())) {
                est = parsed
            } else if word.hasPrefix("!"), let parsed = QuickDate.parse(String(word.dropFirst())) {
                date = parsed
            } else {
                words.append(word)
            }
        }
        let text = words.joined(separator: " ")
        guard !text.isEmpty else { return }
        title = ""
        estimate = nil
        due = nil
        // New tasks go to Today unless a date was chosen.
        if date == nil { date = Calendar.current.startOfDay(for: .now) }
        Task { await model.store.addTask(title: text, estimate: est, due: date) }
    }
}

enum EstimateOption {
    static let all: [TimeInterval] = [10, 15, 25, 30, 45, 60, 90, 120, 180, 240].map { $0 * 60 }
}

enum QuickDate {
    static func parse(_ word: String) -> Date? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        switch word.lowercased() {
        case "today", "tod": return today
        case "tomorrow", "tom", "tmr": return cal.date(byAdding: .day, value: 1, to: today)
        case "week", "nextweek": return cal.date(byAdding: .day, value: 7, to: today)
        default:
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.date(from: word)
        }
    }
}

/// Menu with common due-date choices plus a calendar picker.
struct DueMenu<Label: View>: View {
    var due: Date?
    @Binding var showPicker: Bool
    var onSelect: (Date?) -> Void
    @ViewBuilder var label: () -> Label
    @State private var picked = Date()

    var body: some View {
        Menu {
            Button("Today") { onSelect(QuickDate.parse("today")) }
            Button("Tomorrow") { onSelect(QuickDate.parse("tomorrow")) }
            Button("Next Week") { onSelect(QuickDate.parse("week")) }
            Button("Pick a Date…") { picked = due ?? .now; showPicker = true }
            if due != nil {
                Divider()
                Button("No Due Date") { onSelect(nil) }
            }
        } label: {
            label()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .popover(isPresented: $showPicker) {
            VStack(spacing: 10) {
                DatePicker("", selection: $picked, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                Button("Set Due Date") {
                    onSelect(Calendar.current.startOfDay(for: picked))
                    showPicker = false
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.tint)
            }
            .padding(12)
        }
    }
}
