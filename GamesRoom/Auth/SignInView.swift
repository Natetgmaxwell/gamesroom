import AuthenticationServices
import SwiftUI

struct SignInView: View {
    @ObservedObject var authService: AuthService
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var errorMessage: String?

    private var gutter: CGFloat { Theme.Layout.gutter(for: hSize) }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                VStack(spacing: 16) {
                    Text("A games room for people you actually know.")
                        .font(Theme.displayFont)
                        .foregroundStyle(Theme.primaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, gutter)

                    Text("Sign in to continue.")
                        .font(Theme.bodyFont)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, gutter)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.red.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, gutter)
                            .padding(.top, 12)
                    }
                }

                Spacer()

                // ponytail: nonce intentionally omitted. GoTrue (Supabase auth server)
                // compares the id_token nonce claim to a SHA-256 of our OpenIDConnectCredentials.nonce,
                // but encodes the hash as hex while Apple embeds it as base64url — they never
                // match. Sending no nonce bypasses the broken server-side verification.
                // Track https://github.com/supabase/auth/issues/2378 for the server-side fix.
                SignInWithAppleButton { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    Task {
                        switch result {
                        case .success(let authorization):
                            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                                errorMessage = "Authorization credential was not an Apple ID credential."
                                return
                            }
                            do {
                                try await authService.signInWithApple(credential: credential)
                            } catch {
                                let detail = (error as NSError).localizedDescription
                                print("[GamesRoom] Sign-in failed: \(detail)")
                                errorMessage = "Sign-in failed: \(detail)"
                            }
                        case .failure(let error):
                            let detail = (error as NSError).localizedDescription
                            print("[GamesRoom] Apple auth failed: \(detail)")
                            errorMessage = "Apple sign-in failed: \(detail)"
                        }
                    }
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 50)
                .padding(.horizontal, gutter)

                // DEV-ONLY: simulator bypass for Apple Sign-In.
                // Hidden in production via DEBUG guard.
                #if DEBUG
                Button {
                    Task {
                        do {
                            try await authService.devSignIn()
                        } catch {
                            let detail = (error as NSError).localizedDescription
                            print("[GamesRoom] Dev sign-in failed: \(detail)")
                            errorMessage = "Dev sign-in failed: \(detail)"
                        }
                    }
                } label: {
                    Text("Dev sign-in (simulator)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.vertical, 8)
                }
                #endif
            }
            .padding(.horizontal, gutter)
            .padding(.bottom, 48)
        }
    }
}