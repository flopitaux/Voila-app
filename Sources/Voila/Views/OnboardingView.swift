import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.voila(40))
                        .foregroundStyle(Theme.accent)
                    Text("Voilà")
                        .font(.voila(26, .bold))
                    Text("Your Google Tasks, always on top. Start, focus, finish… voilà.")
                        .foregroundStyle(.secondary)
                }

                if !model.auth.isPreconfigured {
                    VStack(alignment: .leading, spacing: 8) {
                        step(1, "Create a project at console.cloud.google.com and enable the **Google Tasks API**.")
                        step(2, "Configure the OAuth consent screen (External, add yourself as a test user).")
                        step(3, "Create an **OAuth client ID** of type **Desktop app**, then paste it below.")
                        Link("Open Google Cloud Console →",
                             destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                            .font(.voila(13, .semibold))
                            .foregroundStyle(Theme.tint)
                    }

                    VStack(spacing: 8) {
                        TextField("Client ID", text: $clientID)
                        SecureField("Client secret", text: $clientSecret)
                    }
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if let error {
                    Text(error).font(.voila(11)).foregroundStyle(Theme.overdue)
                }

                if model.auth.isPreconfigured {
                    Label("Voilà only reads and updates your Google Tasks. Nothing else.", systemImage: "lock.fill")
                        .font(.voila(11))
                        .foregroundStyle(.secondary)
                }

                if model.auth.isSigningIn {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Finish signing in in your browser…").foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { model.auth.cancelSignIn() }
                    }
                } else {
                    Button {
                        connect()
                    } label: {
                        Label("Connect Google Account", systemImage: "person.crop.circle.badge.checkmark")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.tint)
                    .controlSize(.large)
                    .disabled(!model.auth.isPreconfigured && (clientID.isEmpty || clientSecret.isEmpty))
                }
            }
            .padding(22)
            .padding(.top, 26)
            .containerRelativeFrame(.vertical, alignment: model.auth.isPreconfigured ? .center : .top)
        }
        .scrollIndicators(.never)
        .onAppear {
            clientID = model.auth.clientID
            clientSecret = model.auth.clientSecret
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.voila(11, .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Theme.accent, in: Circle())
            Text(text).font(.voila(13)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func connect() {
        error = nil
        if !model.auth.isPreconfigured {
            model.auth.saveCredentials(clientID: clientID, clientSecret: clientSecret)
        }
        Task {
            do {
                try await model.auth.signIn()
                model.didSignIn()
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
