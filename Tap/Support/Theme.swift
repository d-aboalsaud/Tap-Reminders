import SwiftUI
import UIKit

extension Color {
    /// Brand colors — adaptive: deep on light backgrounds, lifted on dark so
    /// chips and tinted text stay readable.
    static let tapIndigo = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.64, green: 0.66, blue: 1.00, alpha: 1)
            : UIColor(red: 0.13, green: 0.10, blue: 0.36, alpha: 1)
    })
    static let tapBlue = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.42, green: 0.58, blue: 1.00, alpha: 1)
            : UIColor(red: 0.15, green: 0.35, blue: 0.95, alpha: 1)
    })
}

extension LinearGradient {
    /// The icon's gradient — fixed colors so the brand look is identical in
    /// both modes (always used with white foreground content).
    static let tapBrand = LinearGradient(
        colors: [
            Color(red: 0.13, green: 0.10, blue: 0.36),
            Color(red: 0.15, green: 0.35, blue: 0.95),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// User-selectable appearance, persisted via @AppStorage("appearanceMode").
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: return "iphone"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
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
