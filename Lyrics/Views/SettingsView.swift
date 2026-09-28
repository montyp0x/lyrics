import AuthenticationServices
import SwiftUI

struct SettingsView: View {
    @Environment(LyricsEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var appleMusicAuthorized = false
    @State private var errorMessage: String?
    @State private var tokenCheck: String?

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
                    SecureField("media-user-token", text: $engine.appleMusicUserToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    Button("Check token") { checkAppleMusicToken() }
                        .disabled(engine.appleMusicUserToken.isEmpty)
                    if let tokenCheck {
                        Text(tokenCheck).font(.footnote)
                    }
                    if let status = engine.appleLyricsStatus {
                        Text(status).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Apple Music lyrics")
                } footer: {
                    Text("Uses Apple Music's own synced lyrics. Sign in at music.apple.com in a desktop browser, open the developer tools, and copy the media-user-token cookie. It lasts for months; paste a new one if lyrics stop loading.")
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
                    Text("Background mode plays silent audio and keeps a coarse location session open, which iOS requires before it accepts Lock Screen updates from the background. It uses a little extra battery and shows the location indicator.")
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

    private func checkAppleMusicToken() {
        tokenCheck = "Checking…"
        Task {
            do {
                let storefront = try await engine.appleLyrics.verify()
                tokenCheck = "✓ Works (storefront \(storefront.uppercased()))"
            } catch {
                tokenCheck = "✗ \(error.localizedDescription)"
            }
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
