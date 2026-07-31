//
//  SignInView.swift
//  GamesRoom
//
//  Track E1 — sign-in sheet.
//
//  Apple Sign-In button. On success the credential's identity
//  token is exchanged for a Supabase session via
//  `SupabaseClientProvider.shared.auth.signInWithIdToken(...)`,
//  then `AuthService.loadCurrentUser()` is called to join the
//  `public.users` row into the observable `currentUser`. Once
//  `currentUser` is non-nil the parent `ContentView`'s sheet
//  binding flips to `false` and the sheet dismisses; we also
//  call `dismiss()` explicitly so the close is immediate even if
//  the binding update lands a frame late.
//
//  ponytail: nonce intentionally omitted. GoTrue (Supabase auth
//  server) compares the id_token nonce claim to a SHA-256 of our
//  OpenIDConnectCredentials.nonce, but encodes the hash as hex
//  while Apple embeds it as base64url — they never match. Sending
//  no nonce bypasses the broken server-side verification. Track
//  https://github.com/supabase/auth/issues/2378 for the server-side
//  fix.
//
//  ponytail: Theme uses the V0.8 token shape (`Theme.Palette.X`
//  and `Theme.Typography.X`). The legacy `Theme.background` /
//  `Theme.displayFont` aliases from V0.7.1 are not present here;
//  the `Theme.swift` lock forbids adding them.
//
//

import AuthenticationServices
import Foundation
import Supabase
import SwiftUI

struct SignInView: View {
    @ObservedObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                VStack(spacing: 16) {
                    Text("A games room for people you actually know.")
                        .font(Theme.Typography.display)
                        .foregroundStyle(Theme.Palette.primaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Text("Sign in to continue.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.hairline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 48)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(.red.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 48)
                            .padding(.top, 12)
                    }
                }

                Spacer()

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
                            guard let tokenData = credential.identityToken,
                                  let tokenString = String(data: tokenData, encoding: .utf8) else {
                                errorMessage = "Could not read Apple identity token."
                                return
                            }
                            do {
                                try await SupabaseClientProvider.shared.auth.signInWithIdToken(
                                    credentials: .init(
                                        provider: .apple,
                                        idToken: tokenString
                                    )
                                )
                                await authService.loadCurrentUser()
                                dismiss()
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
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
            }
        }
    }
}
