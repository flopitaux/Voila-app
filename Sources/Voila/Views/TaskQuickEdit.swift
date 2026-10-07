import SwiftUI

/// Popover opened by clicking a task title: one-click estimate chips, a custom estimate,
/// and the title itself for quick renaming.
struct TaskQuickEdit: View {
    @Environment(AppModel.self) private var model
    var task: GTask
    var dismiss: () -> Void

    @State private var title = ""
    @State private var custom = ""
    @State private var customInvalid = false
    @State private var showCalendar = false
    @State private var pickedDate = Date()

    private var store: TaskStore { model.store }
    private var current: TimeInterval? { liveTask.track.estimate }
    /// The freshest copy of the task (it may have changed since the popover opened).
    private var liveTask: GTask { store.task(withID: task.id) ?? task }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Task title", text: $title)
                .textFieldStyle(.plain)
                .font(.voila(14, .semibold))
                .padding(8)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onSubmit { saveTitle(); dismiss() }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Estimate", systemImage: "timer")
                        .font(.voila(11, .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if current != nil {
                        Button("Clear") { setEstimate(nil) }
                            .buttonStyle(.plain)
                            .font(.voila(11, .medium))
                            .foregroundStyle(.secondary)
                            .pointerStyle(.link)
                    }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                    ForEach(EstimateOption.all, id: \.self) { seconds in
                        let selected = current.map { abs($0 - seconds) < 1 } ?? false
                        Button { setEstimate(seconds) } label: {
                            Text(DurationFormat.short(seconds).replacingOccurrences(of: " ", with: ""))
                                .font(.voila(12, .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                                .background(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary.opacity(0.07)),
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .pointerStyle(.link)
                    }
                }

                TextField("Custom: 1h20, 50…", text: $custom)
                    .textFieldStyle(.plain)
                    .font(.voila(12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Theme.overdue.opacity(customInvalid ? 0.8 : 0), lineWidth: 1))
                    .onSubmit {
                        if let seconds = DurationFormat.parse(custom), seconds > 0 { setEstimate(seconds) }
                        else { customInvalid = true }
                    }
                    .onChange(of: custom) { customInvalid = false }
            }

            if task.parent == nil { daySection }   // subtasks follow their parent's day

            let spent = liveTask.track.elapsed()
            if spent >= 1 {
                HStack {
                    Text("Tracked \(DurationFormat.short(spent))")
                        .font(.voila(11, .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") { Task { await store.resetTime(for: liveTask) } }
                        .buttonStyle(.plain)
                        .font(.voila(11, .medium))
                        .foregroundStyle(.secondary)
                        .pointerStyle(.link)
                }
            }
        }
        .padding(14)
        .frame(width: 290)
        .onAppear { title = task.title ?? "" }
        .onDisappear(perform: saveTitle)
    }

    private func setEstimate(_ seconds: TimeInterval?) {
        saveTitle()
        let target = liveTask
        Task { await store.setEstimate(seconds, for: target) }
        dismiss()
    }

    // MARK: - Day

    private struct DayOption: Identifiable {
        let id: String
        let label: String
        let date: Date?   // nil = no due date
    }

    private var dayOptions: [DayOption] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: today)! }
        var options = [DayOption(id: "today", label: "Today", date: today),
                       DayOption(id: "tomorrow", label: "Tomorrow", date: day(1))]
        for n in 2...5 {
            options.append(DayOption(id: "d\(n)", label: day(n).formatted(.dateTime.weekday(.abbreviated)), date: day(n)))
        }
        options.append(DayOption(id: "week", label: "Next wk", date: day(7)))
        options.append(DayOption(id: "2weeks", label: "In 2 wks", date: day(14)))
        return options
    }

    private var daySection: some View {
        let due = liveTask.dueDate
        let cal = Calendar.current
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Due date", systemImage: "calendar")
                    .font(.voila(11, .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(due.map { DueDate.label(for: $0).text } ?? "None")
                    .font(.voila(11, .medium))
                    .foregroundStyle(due.map { DueDate.label(for: $0).urgency.tint } ?? .secondary)
                if due != nil {
                    Button("Remove") { setDay(nil) }
                        .buttonStyle(.plain)
                        .font(.voila(11, .medium))
                        .foregroundStyle(.secondary)
                        .pointerStyle(.link)
                        .help("Remove the due date")
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(dayOptions) { option in
                    let selected: Bool = {
                        switch (option.date, due) {
                        case (nil, nil): return true
                        case let (d?, current?): return cal.isDate(d, inSameDayAs: current)
                        default: return false
                        }
                    }()
                    Button { setDay(option.date) } label: {
                        Text(option.label)
                            .font(.voila(11.5, .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                            .background(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary.opacity(0.07)),
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                }
            }

            Button {
                pickedDate = due ?? .now
                withAnimation(.smooth(duration: 0.2)) { showCalendar.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showCalendar ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Text("Pick a date…")
                }
                .font(.voila(11, .medium))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)

            if showCalendar {
                DatePicker("", selection: $pickedDate, in: Calendar.current.startOfDay(for: .now)...,
                           displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .onChange(of: pickedDate) { setDay(Calendar.current.startOfDay(for: pickedDate)) }
            }
        }
    }

    /// Sets the deadline only; Now / Later is chosen separately.
    private func setDay(_ date: Date?) {
        saveTitle()
        let target = liveTask
        Task { await store.setDue(date, for: target) }
        dismiss()
    }

    private func saveTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != (liveTask.title ?? "") else { return }
        let target = liveTask
        Task { await store.rename(target, to: trimmed) }
    }
}
