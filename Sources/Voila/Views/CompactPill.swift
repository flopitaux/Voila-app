import SwiftUI

/// Minimal always-on-top pill: the focus task with its live timer, or what's next.
/// Layout: [traffic lights] │ [ring] [title / time] … [✓] [▶] [⤢]
struct CompactPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.store
        HStack(spacing: 10) {
            // Divider after the standard window buttons, vertically centered with them.
            Capsule()
                .fill(.primary.opacity(0.12))
                .frame(width: 1, height: 22)
                .padding(.trailing, 2)

            if let task = store.focusTask {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let track = task.track
                    let progress = track.progress(at: ctx.date)
                    HStack(spacing: 10) {
                        RingPlayButton(progress: progress, isRunning: track.isRunning, lineWidth: 3, gap: 2.5) {
                            Task { await store.toggleRunning(task) }
                        }
                        .frame(width: 34, height: 34)

                        VStack(alignment: .leading, spacing: 0) {
                            Text(task.displayTitle)
                                .font(.voila(12.5, .semibold))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            HStack(spacing: 3) {
                                Text(DurationFormat.clock(track.elapsed(at: ctx.date)))
                                    .monospacedDigit()
                                    .foregroundStyle((progress ?? 0) > 1 ? AnyShapeStyle(Theme.overtime)
                                                                         : AnyShapeStyle(.secondary))
                                if let estimate = track.estimate {
                                    Text("of \(DurationFormat.short(estimate))").foregroundStyle(.tertiary)
                                }
                            }
                            .font(.voila(11, .medium))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        smallButton("checkmark", help: "Mark as done") { Task { await store.complete(task) } }
                    }
                }
            } else {
                if let next = store.nextTask {
                    RingPlayButton(progress: nil, isRunning: false, lineWidth: 3, gap: 2.5, idleSymbol: "play.fill") {
                        Task { await store.start(next) }
                    }
                    .frame(width: 34, height: 34)
                } else {
                    Image(systemName: "checkmark.circle")
                        .font(.voila(20, .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 34, height: 34)
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text(store.nextTask?.displayTitle ?? "All clear for now")
                        .font(.voila(12.5, .semibold))
                        .lineLimit(1)
                    Text(store.nextTask == nil ? "Nothing left for now"
                                               : "Up next · \(store.openCount) to do")
                        .font(.voila(11, .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            }

            smallButton("arrow.up.left.and.arrow.down.right", help: "Expand") { model.setCompact(false) }
        }
        .padding(.leading, model.trafficLightsInset - 6)
        .padding(.trailing, 12)
        .frame(maxHeight: .infinity)
        .overlay { CelebrationBurst(trigger: store.celebration).allowsHitTesting(false) }
    }

    private func smallButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.voila(9.5, .bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(.primary.opacity(0.07), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
