import SwiftUI
import SwiftData

struct ReminderListView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var geofence: GeofenceManager
    @EnvironmentObject private var router: AppRouter
    @Query(sort: \Reminder.createdAt, order: .reverse) private var reminders: [Reminder]
    @State private var path = NavigationPath()

    private var upcoming: [Reminder] { reminders.filter { !$0.isResolved } }
    private var done: [Reminder] { reminders.filter(\.isResolved) }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if upcoming.isEmpty && done.isEmpty {
                    RippleEmptyState(
                        icon: "bell.badge",
                        title: "No reminders yet",
                        message: "Capture one with your voice or a quick line of text."
                    )
                    .listRowSeparator(.hidden)
                }
                if !upcoming.isEmpty {
                    Section("Upcoming") {
                        ForEach(upcoming) { reminder in
                            NavigationLink(value: reminder.id) {
                                ReminderRow(reminder: reminder)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    complete(reminder)
                                } label: {
                                    Label("Done", systemImage: "checkmark.circle.fill")
                                }
                                .tint(.green)
                            }
                        }
                        .onDelete { deleteReminders(at: $0, from: upcoming) }
                    }
                }
                if !done.isEmpty {
                    Section("Done") {
                        ForEach(done) { reminder in
                            ReminderRow(reminder: reminder)
                                .foregroundStyle(.secondary)
                        }
                        .onDelete { deleteReminders(at: $0, from: done) }
                    }
                }
            }
            .navigationTitle("Reminders")
            .navigationDestination(for: UUID.self) { id in
                if let reminder = reminders.first(where: { $0.id == id }) {
                    ReminderDetailView(reminder: reminder)
                }
            }
            .onReceive(router.$pendingReminderID) { id in
                // Notification tap → open that reminder's page.
                guard let id else { return }
                path.append(id)
                router.pendingReminderID = nil
            }
        }
    }

    private func complete(_ reminder: Reminder) {
        reminder.isCompleted = true
        RaceCoordinator.deactivate(reminder, geofence: geofence)
        try? context.save()
        Haptics.success()
    }

    private func deleteReminders(at offsets: IndexSet, from source: [Reminder]) {
        for index in offsets {
            let reminder = source[index]
            RaceCoordinator.deactivate(reminder, geofence: geofence)
            context.delete(reminder)
        }
        try? context.save()
    }
}

struct ReminderRow: View {
    let reminder: Reminder

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                if reminder.isUrgent {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                }
                Text(reminder.content)
                    .strikethrough(reminder.isResolved)
            }

            HStack(spacing: 6) {
                if let date = reminder.fireDate {
                    ConditionChip(
                        icon: "clock.fill",
                        text: relativeText(for: date),
                        fired: reminder.timeFired
                    )
                }
                if reminder.hasLocationCondition {
                    ConditionChip(
                        icon: "mappin.circle.fill",
                        text: "\(reminder.triggerType == .leave ? "Leaving" : "At") \(reminder.locationName ?? "Pinned spot")",
                        tint: .tapIndigo,
                        fired: reminder.locationFired
                    )
                }
            }

            if reminder.isRace && !reminder.isResolved {
                Text(raceStatus)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }

    /// "in 3 hours" for upcoming today, otherwise a short absolute date.
    private func relativeText(for date: Date) -> String {
        if reminder.timeFired || date <= .now {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        if date.timeIntervalSinceNow < 20 * 3600 {
            return date.formatted(.relative(presentation: .named))
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var raceStatus: String {
        if reminder.timeFired { return "Time pinged — full reminder fires at the place" }
        if reminder.locationFired { return "Place pinged — full reminder fires at the time" }
        return "First to happen pings you, the second is the real one"
    }
}
