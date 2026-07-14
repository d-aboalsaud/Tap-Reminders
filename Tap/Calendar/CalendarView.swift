import SwiftUI
import SwiftData
import EventKit

/// Month grid of reminders, with the iPhone calendar's events (read-only)
/// shown for the selected day.
struct CalendarView: View {
    @Environment(\.modelContext) private var context
    @Query private var reminders: [Reminder]
    @StateObject private var eventKit = EventKitProvider()

    @State private var monthAnchor = Date.now
    @State private var selectedDay = Date.now

    private var calendar: Calendar { .current }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    monthHeader
                    weekdayRow
                    monthGrid
                    Divider()
                    daySection
                }
                .padding()
            }
            .navigationTitle("Calendar")
            .navigationDestination(for: UUID.self) { id in
                if let reminder = reminders.first(where: { $0.id == id }) {
                    ReminderDetailView(reminder: reminder)
                }
            }
            .onAppear { eventKit.requestAccess() }
        }
    }

    // MARK: - Month navigation

    private var monthHeader: some View {
        HStack {
            Button {
                shiftMonth(-1)
            } label: {
                Image(systemName: "chevron.left").font(.headline)
            }
            Spacer()
            Text(monthAnchor.formatted(.dateTime.month(.wide).year()))
                .font(.title3.weight(.bold))
            Spacer()
            Button {
                shiftMonth(1)
            } label: {
                Image(systemName: "chevron.right").font(.headline)
            }
        }
        .padding(.horizontal, 4)
    }

    private func shiftMonth(_ delta: Int) {
        if let shifted = calendar.date(byAdding: .month, value: delta, to: monthAnchor) {
            monthAnchor = shifted
        }
    }

    private var weekdayRow: some View {
        let symbols = calendar.veryShortWeekdaySymbols
        let ordered = Array(symbols[(calendar.firstWeekday - 1)...] + symbols[..<(calendar.firstWeekday - 1)])
        return HStack {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, s in
                Text(s)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Grid

    private var monthDays: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: monthAnchor) else { return [] }
        let firstWeekdayOfMonth = calendar.component(.weekday, from: interval.start)
        let leadingBlanks = (firstWeekdayOfMonth - calendar.firstWeekday + 7) % 7
        let dayCount = calendar.range(of: .day, in: .month, for: monthAnchor)?.count ?? 30
        var cells: [Date?] = Array(repeating: nil, count: leadingBlanks)
        for day in 0..<dayCount {
            cells.append(calendar.date(byAdding: .day, value: day, to: interval.start))
        }
        return cells
    }

    private var monthGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 6) {
            ForEach(Array(monthDays.enumerated()), id: \.offset) { _, day in
                if let day {
                    dayCell(day)
                } else {
                    Color.clear.frame(height: 44)
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        let isToday = calendar.isDateInToday(day)
        let hasReminders = reminders.contains { $0.occursOn(day) }
        let hasEvents = eventKit.authorized && !eventKit.events(on: day).isEmpty

        return Button {
            selectedDay = day
        } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.callout.weight(isToday ? .heavy : .medium))
                    .foregroundStyle(isSelected ? .white : (isToday ? Color.tapBlue : .primary))
                HStack(spacing: 3) {
                    if hasReminders {
                        Circle().fill(isSelected ? .white : Color.tapBlue).frame(width: 5, height: 5)
                    }
                    if hasEvents {
                        Circle().fill(isSelected ? .white.opacity(0.6) : Color.secondary.opacity(0.6))
                            .frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                isSelected
                    ? AnyShapeStyle(LinearGradient.tapBrand)
                    : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Selected day

    private var dayReminders: [Reminder] {
        reminders
            .filter { $0.occursOn(selectedDay) }
            .sorted { ($0.fireDate ?? .distantPast) < ($1.fireDate ?? .distantPast) }
    }

    private var daySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(selectedDay.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.headline)

            if dayReminders.isEmpty && eventKit.events(on: selectedDay).isEmpty {
                Text("Nothing on this day.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }

            if !dayReminders.isEmpty {
                Text("Reminders")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(dayReminders) { reminder in
                    NavigationLink(value: reminder.id) {
                        HStack {
                            ReminderRow(reminder: reminder, onComplete: nil)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if eventKit.authorized {
                let events = eventKit.events(on: selectedDay)
                if !events.isEmpty {
                    Text("From your calendar")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(events, id: \.eventIdentifier) { event in
                        eventRow(event)
                    }
                }
            } else if eventKit.denied {
                Label(
                    "Allow calendar access in Settings to see your events here.",
                    systemImage: "calendar.badge.exclamationmark"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func eventRow(_ event: EKEvent) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(cgColor: event.calendar.cgColor))
                .frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title ?? "Event")
                    .font(.subheadline.weight(.medium))
                Text(event.isAllDay
                     ? "All day"
                     : "\(event.startDate.formatted(date: .omitted, time: .shortened)) – \(event.endDate.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
