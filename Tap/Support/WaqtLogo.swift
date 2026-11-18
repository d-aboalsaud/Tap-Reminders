import SwiftUI

/// The Waqt wordmark: "wa", then a location pin standing in for the q, then "t".
/// The pin's head sits on the x-height and its point drops below the baseline
/// like the q's tail. Shared by the app and the notification extension.
struct WaqtLogo: View {
    var size: CGFloat = 40
    var textColor: Color
    var pinColor: Color

    /// Pin head radius, tuned to the rounded heavy x-height.
    private var radius: CGFloat { size * 0.32 }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.03) {
            Text("wa")
                .foregroundStyle(textColor)
            WaqtPin()
                // Even-odd so the hole shows whatever is behind the logo.
                .fill(pinColor, style: FillStyle(eoFill: true))
                .overlay(WaqtPinDot(radius: radius))
                // Tilted so the point swings right, like the tail of a q.
                .rotationEffect(.degrees(-WaqtPin.tilt), anchor: UnitPoint(x: 0.5, y: 1 / WaqtPin.heightRatio))
                .frame(width: radius * 2, height: radius * WaqtPin.heightRatio)
                // Head bottom sits just on the baseline; the point hangs below it.
                .alignmentGuide(.firstTextBaseline) { _ in radius * 2.07 }
            Text("t")
                .foregroundStyle(textColor)
        }
        .font(.system(size: size, weight: .heavy, design: .rounded))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Waqt")
    }
}

/// A map pin: round head plus a point, with the classic hole punched through.
struct WaqtPin: Shape {
    /// Total height as a multiple of the head radius.
    static let heightRatio: CGFloat = 3.14
    /// Degrees the pin leans in the logo and app icon.
    static let tilt: Double = 15

    func path(in rect: CGRect) -> Path {
        let r = rect.width / 2
        let center = CGPoint(x: rect.midX, y: rect.minY + r)
        let tip = CGPoint(x: rect.midX, y: rect.minY + r * Self.heightRatio)
        let k = r / 14
        let kappa: CGFloat = 0.5523 // cubic approximation of a quarter circle
        let left = CGPoint(x: center.x - r, y: center.y)
        let top = CGPoint(x: center.x, y: center.y - r)
        let right = CGPoint(x: center.x + r, y: center.y)
        // One outline: over the head, down to the point, back up.
        var path = Path()
        path.move(to: left)
        path.addCurve(to: top,
                      control1: CGPoint(x: left.x, y: center.y - kappa * r),
                      control2: CGPoint(x: center.x - kappa * r, y: top.y))
        path.addCurve(to: right,
                      control1: CGPoint(x: center.x + kappa * r, y: top.y),
                      control2: CGPoint(x: right.x, y: center.y - kappa * r))
        path.addQuadCurve(to: tip, control: CGPoint(x: right.x, y: center.y + 12 * k))
        path.addQuadCurve(to: left, control: CGPoint(x: left.x, y: center.y + 12 * k))
        path.closeSubpath()
        // The hole: its own subpath, removed by the even-odd fill.
        let hole = r * 6 / 14
        path.addEllipse(in: CGRect(x: center.x - hole, y: center.y - hole, width: hole * 2, height: hole * 2))
        return path
    }
}

/// The amber dot in the middle of the pin's hole.
private struct WaqtPinDot: View {
    let radius: CGFloat

    var body: some View {
        GeometryReader { proxy in
            Circle()
                .fill(Color(red: 1.0, green: 0.79, blue: 0.30))
                .frame(width: radius * 2.5 / 14 * 2, height: radius * 2.5 / 14 * 2)
                .position(x: proxy.size.width / 2, y: radius)
        }
    }
}
