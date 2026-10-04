import SwiftUI

extension Font {
    /// Voilà's typeface: Avenir Next, slightly enlarged because it draws smaller than SF Pro.
    /// Falls back to the system font automatically if Avenir Next is unavailable.
    static func voila(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Avenir Next", size: size * 1.05).weight(weight)
    }
}

enum Theme {
    // Calm palette: dusty blue → muted sage, with soft amber/coral for alerts.
    static let tint = Color(red: 0.47, green: 0.60, blue: 0.74)
    static let tint2 = Color(red: 0.50, green: 0.69, blue: 0.66)
    static let overtime = Color(red: 0.89, green: 0.66, blue: 0.38)
    static let overdue = Color(red: 0.86, green: 0.44, blue: 0.42)
    static let done = Color(red: 0.36, green: 0.74, blue: 0.50)

    static let accent = LinearGradient(colors: [tint, tint2], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let ring = AngularGradient(colors: [tint, tint2, tint], center: .center,
                                      startAngle: .degrees(-90), endAngle: .degrees(270))

    static let panelRadius: CGFloat = 26
}

/// Circular progress: gradient arc for time vs. estimate, amber arc on top once over time,
/// a spinning arc when running without an estimate.
struct ProgressRing: View {
    var progress: Double?
    var isRunning: Bool
    var lineWidth: CGFloat = 6

    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.10), lineWidth: lineWidth)

            if let progress {
                Circle()
                    .trim(from: 0, to: min(max(progress, 0.001), 1))
                    .stroke(Theme.ring, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if progress > 1 {
                    Circle()
                        .trim(from: 0, to: min(progress - 1, 1))
                        .stroke(Theme.overtime, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: Theme.overtime.opacity(0.25), radius: 3)
                }
            } else if isRunning {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(Theme.ring, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 270 : -90))
                    .animation(.linear(duration: 1.6).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
            }
        }
        .animation(.smooth, value: progress)
    }
}

/// Progress ring that shows completion % (or a status icon when there's no estimate),
/// and turns into a play/pause button on mouse over.
struct RingPlayButton: View {
    var progress: Double?
    var isRunning: Bool
    var lineWidth: CGFloat = 6
    var gap: CGFloat = 4
    /// Icon shown at rest when there's no estimate (defaults to the running/paused state).
    var idleSymbol: String?
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        ZStack {
            ProgressRing(progress: progress, isRunning: isRunning, lineWidth: lineWidth)
            Button(action: action) {
                GeometryReader { geo in
                    let size = geo.size.width
                    ZStack {
                        // At rest: completion % or a status icon.
                        Group {
                            if let progress {
                                Text("\(Int((progress * 100).rounded()))%")
                                    .font(.voila(size * (progress >= 1 ? 0.26 : 0.3), .bold))
                                    .monospacedDigit()
                                    .minimumScaleFactor(0.6)
                                    .foregroundStyle(progress > 1 ? AnyShapeStyle(Theme.overtime) : AnyShapeStyle(.primary))
                            } else {
                                Image(systemName: idleSymbol ?? (isRunning ? "bolt.fill" : "pause.fill"))
                                    .font(.voila(size * 0.32, .bold))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .opacity(hovering ? 0 : 1)
                        .scaleEffect(hovering ? 0.7 : 1)

                        // On hover: the play/pause button.
                        Image(systemName: isRunning ? "pause.fill" : "play.fill")
                            .font(.voila(size * 0.36, .bold))
                            .foregroundStyle(.white)
                            .offset(x: isRunning ? 0 : size * 0.03)   // optical centering of ▶
                            .frame(width: size, height: size)
                            .background(Theme.accent, in: Circle())
                            .opacity(hovering ? 1 : 0)
                            .scaleEffect(hovering ? 1 : 0.6)
                    }
                    .frame(width: size, height: geo.size.height)
                    .contentShape(Circle())
                }
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .padding(lineWidth + gap)
            .help(isRunning ? "Pause" : "Start")
        }
        .contentShape(Circle())
        .onHover { h in withAnimation(.spring(duration: 0.22, bounce: 0.2)) { hovering = h } }
    }
}

/// Burst of colored dots, fired whenever `trigger` changes.
struct CelebrationBurst: View {
    var trigger: Int
    @State private var fired = false

    private let colors: [Color] = [Theme.tint, Theme.tint2, Theme.overtime, .white.opacity(0.8), Theme.tint2.opacity(0.7), Theme.tint.opacity(0.7)]

    var body: some View {
        ZStack {
            ForEach(0..<14, id: \.self) { i in
                let angle = Double(i) / 14 * 2 * .pi
                Circle()
                    .fill(colors[i % colors.count])
                    .frame(width: i.isMultiple(of: 3) ? 7 : 5)
                    .offset(x: fired ? cos(angle) * 46 : 0, y: fired ? sin(angle) * 46 : 0)
                    .opacity(fired ? 0 : 1)
                    .scaleEffect(fired ? 0.4 : 1)
            }
        }
        .allowsHitTesting(false)
        .opacity(trigger == 0 ? 0 : 1)
        .onChange(of: trigger) {
            fired = false
            withAnimation(.easeOut(duration: 0.8)) { fired = true }
        }
    }
}

/// Small capsule tag used for due dates and time.
struct Chip: View {
    var text: String
    var systemImage: String?
    var tint: Color = .secondary
    var filled = false

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.voila(10.5, .semibold))
        .foregroundStyle(filled ? .white : tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(filled ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.14)), in: Capsule())
    }
}

extension DueDate.Urgency {
    var tint: Color {
        switch self {
        case .overdue: Theme.overdue
        case .today: Theme.tint2
        case .soon: Theme.tint
        case .later: .secondary
        }
    }
}
