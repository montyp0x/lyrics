import AuthenticationServices
import SwiftUI

struct SettingsView: View {
    @Environment(LyricsEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var appleMusicAuthorized = false
    @State private var errorMessage: String?

    var body: some View {
        @Bindable var engine = engine
        @Bindable var spotifyAuth = engine.spotifyAuth

        NavigationStack {
            Form {
                Section("Apple Music") {
                    if appleMusicAuthorized {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                    } else {
                        Button("Allow Apple Music access") {
                            Task { appleMusicAuthorized = await engine.appleMusic.requestAuthorization() }
                        }
                    }
                }

                Section {
                    TextField("Client ID", text: $spotifyAuth.clientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    if spotifyAuth.isConnected {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                        Button("Disconnect", role: .destructive) { spotifyAuth.disconnect() }
                    } else {
                        Button("Connect Spotify") { connectSpotify() }
                            .disabled(spotifyAuth.clientID.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let error = engine.spotifyError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Spotify")
                } footer: {
                    Text("Create an app at developer.spotify.com, select Web API, and add this redirect URI:\n\(SpotifyAuth.redirectURI)")
                        .textSelection(.enabled)
                }

                Section {
                    Toggle("Lock Screen & Dynamic Island", isOn: $engine.liveActivityEnabled)
                    Toggle("Keep running in background", isOn: $engine.keepAliveEnabled)
                } header: {
                    Text("Live Activity")
                } footer: {
                    Text("Background mode plays silent audio so lyrics keep updating while the phone is locked. It uses a little extra battery.")
                }

                Section {
                    Stepper(value: $engine.lyricsOffset, in: -5...5, step: 0.25) {
                        LabeledContent("Timing offset", value: String(format: "%+.2f s", engine.lyricsOffset))
                    }
                } footer: {
                    Text("Positive values show lines earlier. Spotify sometimes lags behind by a moment.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") { dismiss() }
            }
            .alert("Something went wrong", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear { appleMusicAuthorized = engine.appleMusic.isAuthorized }
        }
    }

    private func connectSpotify() {
        Task {
            do {
                let url = try engine.spotifyAuth.authorizationURL()
                let callback = try await webAuthenticationSession.authenticate(
                    using: url,
                    callbackURLScheme: SpotifyAuth.callbackScheme
                )
                try await engine.spotifyAuth.completeAuthorization(callbackURL: callback)
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
