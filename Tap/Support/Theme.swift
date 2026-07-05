import SwiftUI
import UIKit

extension Color {
    /// Brand colors — match the app icon's indigo→blue gradient.
    static let tapIndigo = Color(red: 0.13, green: 0.10, blue: 0.36)
    static let tapBlue = Color(red: 0.15, green: 0.35, blue: 0.95)
}

extension LinearGradient {
    static let tapBrand = LinearGradient(
        colors: [.tapIndigo, .tapBlue],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

enum Haptics {
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    static func tap() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}

/// Small capsule showing one parsed/stored condition (time, place, urgency).
struct ConditionChip: View {
    let icon: String
    let text: String
    var tint: Color = .tapBlue
    var fired: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: fired ? "checkmark.circle.fill" : icon)
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(fired ? Color.green : tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background((fired ? Color.green : tint).opacity(0.12), in: Capsule())
    }
}

/// Branded empty state — the icon's ripple rings behind a message.
struct RippleEmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(
                            LinearGradient.tapBrand.opacity(0.16 - Double(i) * 0.045),
                            lineWidth: CGFloat(7 - i * 2)
                        )
                        .frame(width: CGFloat(84 + i * 52), height: CGFloat(84 + i * 52))
                }
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(LinearGradient.tapBrand)
            }
            .frame(height: 200)

            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
