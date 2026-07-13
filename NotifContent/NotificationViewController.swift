import UIKit
import SwiftUI
import UserNotifications
import UserNotificationsUI

/// Custom expanded notification view — shown when the user long-presses or
/// pulls down a Tap. reminder notification.
final class NotificationViewController: UIViewController, UNNotificationContentExtension {

    private var hosting: UIHostingController<NotificationCard>?

    func didReceive(_ notification: UNNotification) {
        let content = notification.request.content

        var mapImage: UIImage?
        if let attachment = content.attachments.first,
           attachment.url.startAccessingSecurityScopedResource() {
            mapImage = UIImage(contentsOfFile: attachment.url.path)
            attachment.url.stopAccessingSecurityScopedResource()
        }

        let urgent = (content.userInfo["isUrgent"] as? Bool) ?? content.title.contains("🔥")
        let card = NotificationCard(
            title: content.title
                .replacingOccurrences(of: "🔥 ", with: "")
                .replacingOccurrences(of: "🔥", with: ""),
            subtitle: content.subtitle,
            bodyText: content.body,
            urgent: urgent,
            mapImage: mapImage
        )

        hosting?.view.removeFromSuperview()
        hosting?.removeFromParent()

        let host = UIHostingController(rootView: card)
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
        hosting = host

        let target = host.view.systemLayoutSizeFitting(
            CGSize(width: view.bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        preferredContentSize = CGSize(width: view.bounds.width, height: target.height)
    }
}

/// The branded card: gradient, big rounded type, optional map.
struct NotificationCard: View {
    let title: String
    let subtitle: String
    let bodyText: String
    let urgent: Bool
    let mapImage: UIImage?

    private let gradient = LinearGradient(
        colors: [
            Color(red: 0.13, green: 0.10, blue: 0.36),
            Color(red: 0.15, green: 0.35, blue: 0.95),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tap.")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                if urgent {
                    Label("Urgent", systemImage: "flame.fill")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.orange.opacity(0.9), in: Capsule())
                }
            }

            Text(title)
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            if !subtitle.isEmpty {
                Label(subtitle, systemImage: "mappin.circle.fill")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
            }

            if !bodyText.isEmpty && bodyText != title {
                Text(bodyText)
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let mapImage {
                Image(uiImage: mapImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(gradient)
    }
}
