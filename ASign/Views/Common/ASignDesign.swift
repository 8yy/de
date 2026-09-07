//
//  ASignDesign.swift
//  ASign
//
//  The visual system for ASign: glass surfaces, motion presets and press
//  states. Everything here is SwiftUI-native so it renders identically from
//  iOS 16 through 26 — the Liquid Glass path simply upgrades the material
//  where the OS provides it.
//

import SwiftUI

// MARK: - Tokens

enum AS {
    /// Corner radius for cards and floating surfaces.
    static let radiusL: CGFloat = 22
    static let radiusM: CGFloat = 16
    static let radiusS: CGFloat = 11

    /// Standard content padding.
    static let padding: CGFloat = 16

    /// The signature spring: quick settle, no bounce overshoot.
    static var spring: Animation {
        .spring(response: 0.35, dampingFraction: 0.85)
    }

    /// A softer spring for full-screen transitions.
    static var springSoft: Animation {
        .spring(response: 0.5, dampingFraction: 0.9)
    }
}

// MARK: - Glass card

private struct ASGlassCard: ViewModifier {
    var cornerRadius: CGFloat
    var interactive: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    interactive ? .regular.interactive() : .regular,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
        }
    }
}

extension View {
    /// A translucent, elevated card — the base surface of the ASign design.
    @ViewBuilder
    func asGlassCard(cornerRadius: CGFloat = AS.radiusL, interactive: Bool = false) -> some View {
        modifier(ASGlassCard(cornerRadius: cornerRadius, interactive: interactive))
    }
}

// MARK: - Pressable button style

/// Uniform press feedback across the app: scale down + soften, spring back.
struct ASPressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(AS.spring, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == ASPressableButtonStyle {
    static var asPressable: ASPressableButtonStyle {
        ASPressableButtonStyle()
    }
}

// MARK: - Prominent action button

/// The primary call-to-action: a full-width glass capsule with the accent
/// gradient — used for "Start Signing", "Install", "Check Updates".
struct ASActionButton: View {
    let title: String
    var symbol: String = "signature"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                Text(title)
                    .font(.body.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: AS.radiusM, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.accentColor.opacity(0.85), .accentColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .foregroundStyle(.white)
        }
        .buttonStyle(.asPressable)
    }
}

// MARK: - Section header tile

/// Settings-style icon tile: a rounded gradient square behind an SF Symbol.
struct ASIconTile: View {
    let symbol: String
    var tint: Color = .accentColor

    var body: some View {
        Image(systemName: symbol)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: AS.radiusS - 3, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.9), tint],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
    }
}

// MARK: - Haptics

enum ASHaptic {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
