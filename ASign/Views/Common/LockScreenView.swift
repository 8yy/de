//
//  LockScreenView.swift
//  ASign
//
//  Optional biometric gate: shown full-screen whenever the app is backgrounded
//  with the lock enabled, and dismissed with Face ID / Touch ID / passcode.
//

import SwiftUI
import LocalAuthentication

struct LockScreenView: View {
    @Binding var isUnlocked: Bool
    @State private var _isAuthenticating = false
    @State private var _failureCount = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(.secondary)

                Text(.localized("ASign is Locked"))
                    .font(.title3.weight(.semibold))

                Text(.localized("Authenticate with Face ID or your passcode to continue."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Button {
                    _authenticate()
                } label: {
                    Label(.localized("Unlock"), systemImage: "faceid")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.asPressable)
                .disabled(_isAuthenticating)

                if _failureCount > 0 {
                    Text(.localized("Authentication failed. Try again."))
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .transition(.opacity)
                }
            }
        }
        .onAppear(perform: _authenticate)
        .animation(AS.spring, value: _failureCount)
    }

    private func _authenticate() {
        guard !_isAuthenticating else { return }

        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No biometrics/passcode configured — nothing to gate on.
            isUnlocked = true
            return
        }

        _isAuthenticating = true
        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: String.localized("Unlock ASign")
        ) { success, _ in
            DispatchQueue.main.async {
                _isAuthenticating = false
                if success {
                    ASHaptic.success()
                    isUnlocked = true
                } else {
                    _failureCount += 1
                }
            }
        }
    }
}
