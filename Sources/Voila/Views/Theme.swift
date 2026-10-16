import AppKit
import SwiftUI

extension Font {
    /// Voilà's typeface: Helvetica Neue. Weights are capped at bold so text stays refined
    /// (heavy weights look chunky). Falls back to the system font if Helvetica Neue is unavailable.
    static func voila(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let refined: Font.Weight = (weight == .heavy || weight == .black) ? .bold : weight
        return .custom("Helvetica Neue", size: size).weight(refined)
    }
}

enum Theme {
    // Apricot → lavender, matching the icon, with a raspberry red for alerts.
    static let tint = Color(red: 0.961, green: 0.620, blue: 0.424)     // #F59E6C apricot
    static let tint2 = Color(red: 0.608, green: 0.541, blue: 0.961)    // #9B8AF5 lavender
    static let overtime = Color(red: 0.898, green: 0.329, blue: 0.416) // #E5546A raspberry
    static let overdue = Color(red: 0.85, green: 0.30, blue: 0.33)
    static let done = Color(red: 0.36, green: 0.74, blue: 0.50)

    static let accent = LinearGradient(colors: [tint, tint2], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let ring = AngularGradient(colors: [tint, tint2, tint], center: .center,
                                      startAngle: .degrees(-90), endAngle: .degrees(270))

    static let panelRadius: CGFloat = 26

    /// Panel background: soft warm white in light mode, deep plum-charcoal in dark mode.
    static let background = Color(nsColor: NSColor(name: "VoilaBackground") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.106, green: 0.102, blue: 0.122, alpha: 1)    // #1B1A1F
            : NSColor(srgbRed: 0.984, green: 0.973, blue: 0.965, alpha: 1)    // #FBF8F6
    })

    /// Task cards: a surface a step lighter than the background.
    static let surface = Color(nsColor: NSColor(name: "VoilaSurface") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.153, green: 0.145, blue: 0.173, alpha: 1)    // #27252C
            : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)                // #FFFFFF
    })
}

/// Circular progress: gradient arc for time vs. estimate, raspberry arc on top once over time,
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
    /// Off: a small pulsing dot sits in the middle at rest instead of the % (for tight spaces).
    var showsPercent = true
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
                            if !showsPercent {
                                LiveDot(isRunning: isRunning, size: size * 0.32)
                            } else if let progress {
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

/// Accent dot that gently breathes while running (still and faint when paused).
struct LiveDot: View {
    var isRunning: Bool
    var size: CGFloat

    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Theme.accent)
            .frame(width: size, height: size)
            .background {
                Circle()
                    .fill(Theme.tint.opacity(0.35))
                    .scaleEffect(pulse ? 2.1 : 1)
                    .opacity(pulse ? 0 : 1)
            }
            .opacity(isRunning ? 1 : 0.5)
            .onAppear {
                guard isRunning else { return }
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
            }
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
