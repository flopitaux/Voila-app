import SwiftUI

/// Minimal always-on-top pill: the focus task with its live timer, or what's next.
/// Layout: [traffic lights] │ [ring] [Focusing / title] … [time / estimate] [✓] [⤢]
/// A thin progress line runs along the bottom edge while a task with an estimate is running.
/// The pill takes the panel's width; when that's narrow, the estimate is dropped and the
/// buttons replace the timer only while the pointer is over the pill.
struct CompactPill: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false
    @State private var width: CGFloat = 420

    private var isNarrow: Bool { width < 360 }

    var body: some View {
        let store = model.store
        Group {
            if let task = store.focusTask {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    focusContent(task, at: ctx.date)
                }
            } else {
                nextContent
            }
        }
        .padding(.leading, model.trafficLightsInset - 6)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // A soft wash of the accent while focusing, matching the main panel's focus card.
            if store.focusTask?.track.isRunning == true {
                LinearGradient(colors: [Theme.tint.opacity(0.10), Theme.tint2.opacity(0.04)],
                               startPoint: .leading, endPoint: .trailing)
            }
        }
        .overlay { CelebrationBurst(trigger: store.celebration).allowsHitTesting(false) }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hovering = h } }
    }

    // MARK: - Focus

    private func focusContent(_ task: GTask, at date: Date) -> some View {
        let store = model.store
        let track = task.track
        let progress = track.progress(at: date)
        let isOver = (progress ?? 0) > 1
        return HStack(spacing: 10) {
            divider

            RingPlayButton(progress: progress, isRunning: track.isRunning, lineWidth: 2.5, gap: 3,
                           showsPercent: false) {
                Task { await store.toggleRunning(task) }
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(isOver ? "Over time" : "Focusing")
                    .font(.voila(9.5, .semibold))
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .lineLimit(1)
                    .foregroundStyle(isOver ? AnyShapeStyle(Theme.overtime) : AnyShapeStyle(Theme.accent))
                Text(task.displayTitle)
                    .font(.voila(13, .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            let timer = HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(DurationFormat.clock(track.elapsed(at: date)))
                    .font(.voila(17, .medium))
                    .monospacedDigit()
                    .foregroundStyle(isOver ? AnyShapeStyle(Theme.overtime) : AnyShapeStyle(.primary))
                    .contentTransition(.numericText())
                if let estimate = track.estimate, !isNarrow {
                    Text("/ \(DurationFormat.short(estimate))")
                        .font(.voila(11, .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .fixedSize()

            let buttons = HStack(spacing: 4) {
                PillButton(systemImage: "checkmark", help: "Mark as done", emphasized: hovering || isNarrow) {
                    Task { await store.complete(task) }
                }
                PillButton(systemImage: "arrow.up.left.and.arrow.down.right", help: "Expand",
                           emphasized: hovering || isNarrow) {
                    model.setCompact(false)
                }
            }

            if isNarrow {
                // Not enough room for both: the buttons take the timer's place on hover.
                ZStack(alignment: .trailing) {
                    timer.opacity(hovering ? 0 : 1)
                    buttons.opacity(hovering ? 1 : 0).allowsHitTesting(hovering)
                }
            } else {
                timer
                buttons
            }
        }
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if track.isRunning, let progress { progressLine(progress) }
        }
    }

    /// Hairline along the bottom edge: progress toward the estimate, raspberry once over time.
    private func progressLine(_ progress: Double) -> some View {
        GeometryReader { geo in
            Capsule()
                .fill(progress > 1 ? AnyShapeStyle(Theme.overtime) : AnyShapeStyle(Theme.accent))
                .frame(width: geo.size.width * min(max(progress, 0), 1), height: 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 2)
        .padding(.leading, -(model.trafficLightsInset - 6))   // span the whole pill, under the window buttons too
        .padding(.trailing, -12)
        .opacity(0.8)
        .animation(.smooth, value: progress)
    }

    // MARK: - Nothing running

    private var nextContent: some View {
        let store = model.store
        return HStack(spacing: 10) {
            divider

            if let next = store.nextTask {
                RingPlayButton(progress: nil, isRunning: false, lineWidth: 2.5, gap: 3, idleSymbol: "play.fill") {
                    Task { await store.start(next) }
                }
                .frame(width: 30, height: 30)
            } else {
                Image(systemName: "checkmark.circle")
                    .font(.voila(20, .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 30, height: 30)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(store.nextTask == nil ? "All clear" : "Up next · \(store.openCount) to do")
                    .font(.voila(9.5, .semibold))
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                Text(store.nextTask?.displayTitle ?? "Nothing left for now")
                    .font(.voila(13, .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            PillButton(systemImage: "arrow.up.left.and.arrow.down.right", help: "Expand", emphasized: hovering) {
                model.setCompact(false)
            }
        }
    }

    // Divider after the standard window buttons, vertically centered with them.
    private var divider: some View {
        Capsule()
            .fill(.primary.opacity(0.12))
            .frame(width: 1, height: 22)
            .padding(.trailing, 2)
    }
}

/// Quiet circular icon button: faint at rest, fuller while the pointer is over the pill,
/// filled when the pointer is on the button itself.
private struct PillButton: View {
    var systemImage: String
    var help: String
    var emphasized: Bool
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.voila(10, .bold))
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 26, height: 26)
                .background(.primary.opacity(hovering ? 0.12 : 0.06), in: Circle())
                .contentShape(Circle())
                .opacity(emphasized || hovering ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(help)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}
