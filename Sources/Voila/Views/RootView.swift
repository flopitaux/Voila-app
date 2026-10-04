import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
        ZStack {
            if !model.showsTasks {
                OnboardingView()
                    .transition(.opacity)
            } else if model.isCompact {
                CompactPill()
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                MainView()
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .font(.voila(13))
        .background(WindowDragArea())
        // Fully opaque: whatever is behind the panel never shows through, in any window state.
        .background(Color(nsColor: .windowBackgroundColor), in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .overlay(alignment: .top) { ErrorBanner() }
        .overlay { VoilaToast(trigger: model.store.celebration) }
        .animation(.smooth(duration: 0.3), value: model.showsTasks)
        .ignoresSafeArea()   // draw under the transparent title bar; traffic lights sit on our glass
    }
}

private struct ErrorBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let message = model.store.errorMessage {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { model.store.errorMessage = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            .font(.voila(11))
            .foregroundStyle(.white)
            .padding(10)
            .background(Theme.overdue.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: message) {
                try? await Task.sleep(for: .seconds(6))
                withAnimation { model.store.errorMessage = nil }
            }
        }
    }
}

/// The signature moment: a "Voilà !" badge that pops in whenever a task is completed.
private struct VoilaToast: View {
    var trigger: Int
    @State private var visible = false

    var body: some View {
        Text("Voilà\u{202F}!")
            .font(.voila(22, .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(Theme.accent, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
            .rotationEffect(.degrees(visible ? -4 : 6))
            .scaleEffect(visible ? 1 : 0.4)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(false)
            .task(id: trigger) {
                guard trigger > 0 else { return }
                withAnimation(.spring(duration: 0.4, bounce: 0.55)) { visible = true }
                try? await Task.sleep(for: .milliseconds(1100))
                withAnimation(.easeIn(duration: 0.25)) { visible = false }
            }
    }
}
