import Foundation

/// Result of parsing a raw capture utterance/text.
struct ParsedCapture {
    var content: String
    var isUrgent: Bool
    var fireDate: Date?
    var savedPlace: SavedPlace?
    var triggerType: LocationTriggerType?
    var repeatRule: RepeatRule = .none

    var hasCondition: Bool { fireDate != nil || savedPlace != nil }

    /// Short sentence spoken back after voice capture.
    var spokenConfirmation: String {
        let placePhrase = savedPlace.map { place in
            (triggerType == .leave ? "when you leave " : "when you arrive at ") + place.name
        }
        let timePhrase = fireDate.map { date in
            let formatter = DateFormatter()
            formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .medium
            formatter.timeStyle = .short
            return "at " + formatter.string(from: date)
        }
        switch (timePhrase, placePhrase) {
        case let (time?, place?):
            return "I'll ping you for whichever comes first: \(time), or \(place)."
        case let (time?, nil):
            if repeatRule != .none, let date = fireDate {
                return "I'll remind you \(repeatRule.chipText(for: date).lowercased())."
            }
            return "I'll remind you \(time)."
        case let (nil, place?):
            return "I'll remind you \(place)."
        default:
            return "Saved, but no time or place was set."
        }
    }
}

/// Rule-based parser. Captures a time, a location, or BOTH from one utterance —
/// when both are present the reminder is created directly in race mode.
enum CaptureParser {

    static func parse(_ rawText: String, savedPlaces: [SavedPlace], now: Date = .now) -> ParsedCapture {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        var urgent = false

        // Urgency: "!!" anywhere, or the word "urgent".
        if text.contains("!!") {
            urgent = true
            text = text.replacingOccurrences(of: "!!", with: "")
        }
        if let range = text.range(of: #"\burgent\b"#, options: [.regularExpression, .caseInsensitive]) {
            urgent = true
            text.removeSubrange(range)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // "remind me to buy milk" → content should be "buy milk".
        if let range = text.range(
            of: #"^\s*remind me( to| that)?\s+"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            text.removeSubrange(range)
        }

        // Recurrence ("every day", "every monday", "daily") — detected before
        // the date so its phrase can be stripped and its weekday anchors the date.
        let repeatMatch = matchRepeat(in: text, now: now)

        let locationMatch = matchLocation(in: text, savedPlaces: savedPlaces)
        let dateMatch = matchRelativeDuration(in: text, now: now, excluding: locationMatch?.2)
            ?? matchDate(in: text, now: now, excluding: locationMatch?.2)

        // Anchor the fire date: explicit time wins; a weekly rule shifts it to
        // its weekday; a rule with no time at all defaults to 9 AM.
        var fireDate = dateMatch?.0
        var repeatRule = RepeatRule.none
        if let repeatMatch {
            repeatRule = repeatMatch.rule
            fireDate = anchorDate(
                rule: repeatMatch.rule,
                weekday: repeatMatch.weekday,
                time: fireDate,
                now: now
            )
        }

        // Strip condition phrases from the content. Ranges can overlap (the
        // date detector may swallow part of the repeat phrase), so merge them
        // as offsets first, then remove back-to-front.
        var content = text
        let offsets = [locationMatch?.2, dateMatch?.1, repeatMatch?.range]
            .compactMap { $0 }
            .map { (text.distance(from: text.startIndex, to: $0.lowerBound),
                    text.distance(from: text.startIndex, to: $0.upperBound)) }
            .sorted { $0.0 < $1.0 }
        var merged: [(Int, Int)] = []
        for range in offsets {
            if let last = merged.last, range.0 <= last.1 {
                merged[merged.count - 1].1 = max(last.1, range.1)
            } else {
                merged.append(range)
            }
        }
        for (start, end) in merged.reversed() {
            let si = content.index(content.startIndex, offsetBy: start)
            let ei = content.index(content.startIndex, offsetBy: end)
            content.removeSubrange(si..<ei)
        }
        content = cleanContent(content)

        return ParsedCapture(
            content: content.isEmpty ? text : content,
            isUrgent: urgent,
            fireDate: fireDate,
            savedPlace: repeatRule == .none ? locationMatch?.0 : nil,
            triggerType: repeatRule == .none ? locationMatch?.1 : nil,
            repeatRule: repeatRule
        )
    }

    // MARK: - Recurrence matching

    private static let weekdayNames = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
        "thursday": 5, "friday": 6, "saturday": 7,
    ]

    private static func matchRepeat(
        in text: String,
        now: Date
    ) -> (rule: RepeatRule, weekday: Int?, range: Range<String.Index>)? {
        let lowered = text.lowercased()

        // "every monday", "every friday"…
        for (name, weekday) in weekdayNames {
            if let r = lowered.range(of: "every \(name)") {
                return (.weekly, weekday, mapRange(r, from: lowered, to: text))
            }
        }
        for (phrase, rule) in [
            ("every day", RepeatRule.daily), ("everyday", .daily), ("daily", .daily),
            ("every week", .weekly), ("weekly", .weekly),
            ("every month", .monthly), ("monthly", .monthly),
        ] {
            if let r = lowered.range(of: phrase) {
                return (rule, nil, mapRange(r, from: lowered, to: text))
            }
        }
        return nil
    }

    /// Next occurrence matching the rule: keeps the parsed time-of-day (or 9 AM),
    /// and for weekly rules moves to the requested weekday.
    private static func anchorDate(rule: RepeatRule, weekday: Int?, time: Date?, now: Date) -> Date {
        let calendar = Calendar.current
        var hour = 9, minute = 0
        if let time {
            hour = calendar.component(.hour, from: time)
            minute = calendar.component(.minute, from: time)
        }
        var components = DateComponents(hour: hour, minute: minute)
        if rule == .weekly {
            components.weekday = weekday ?? calendar.component(.weekday, from: time ?? now)
        }
        return calendar.nextDate(
            after: now, matching: components, matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(3600)
    }

    private static func mapRange(
        _ range: Range<String.Index>,
        from lowered: String,
        to original: String
    ) -> Range<String.Index> {
        let start = original.index(original.startIndex, offsetBy: lowered.distance(from: lowered.startIndex, to: range.lowerBound))
        let end = original.index(original.startIndex, offsetBy: lowered.distance(from: lowered.startIndex, to: range.upperBound))
        return start..<end
    }

    // MARK: - Location matching

    private static func matchLocation(
        in text: String,
        savedPlaces: [SavedPlace]
    ) -> (SavedPlace, LocationTriggerType, Range<String.Index>)? {
        let lowered = text.lowercased()

        // If several saved-place names appear ("…my work at balsam"), take the one
        // mentioned last — the destination sits at the end of the condition clause.
        // Names only count as whole words ("gym" must not match "gymnastics").
        var bestMatch: (SavedPlace, Range<String.Index>)?
        for place in savedPlaces {
            let name = place.name.lowercased()
            var searchEnd = lowered.endIndex
            while let r = lowered.range(of: name, options: .backwards, range: lowered.startIndex..<searchEnd) {
                if isWordBounded(r, in: lowered) {
                    if bestMatch == nil || r.lowerBound > bestMatch!.1.lowerBound {
                        bestMatch = (place, r)
                    }
                    break
                }
                searchEnd = r.lowerBound
            }
        }
        guard let (place, nameRange) = bestMatch else { return nil }

        // A place mention only becomes a condition when a trigger phrase sits
        // close before it — otherwise "gym session at 7" would hijack the whole
        // sentence into a Gym reminder. Leave verbs win even when a generic
        // "at/in" sits between them and the name ("go out from my work at
        // Balsam" → leave), because arrive words like "at" are weak signals.
        let windowStart = lowered.index(
            nameRange.lowerBound, offsetBy: -60, limitedBy: lowered.startIndex
        ) ?? lowered.startIndex
        let window = windowStart..<nameRange.lowerBound
        let maxGap = 16 // chars allowed between phrase end and name ("my work at ")

        let trigger: LocationTriggerType
        let start: String.Index
        if let leaveRange = lastRange(ofAny: leavePhrases, in: lowered, within: window),
           lowered.distance(from: leaveRange.upperBound, to: nameRange.lowerBound) <= maxGap {
            trigger = .leave
            start = leaveRange.lowerBound
        } else if let arriveRange = lastRange(ofAny: arrivePhrases, in: lowered, within: window),
                  lowered.distance(from: arriveRange.upperBound, to: nameRange.lowerBound) <= maxGap {
            trigger = .arrive
            start = arriveRange.lowerBound
        } else {
            return nil
        }

        // Map lowered-string indices back onto the original text (same length/positions).
        let origStart = text.index(text.startIndex, offsetBy: lowered.distance(from: lowered.startIndex, to: start))
        let origEnd = text.index(text.startIndex, offsetBy: lowered.distance(from: lowered.startIndex, to: nameRange.upperBound))
        return (place, trigger, origStart..<origEnd)
    }

    private static func isWordBounded(_ range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex {
            let before = text[text.index(before: range.lowerBound)]
            if before.isLetter || before.isNumber { return false }
        }
        if range.upperBound < text.endIndex {
            let after = text[range.upperBound]
            if after.isLetter || after.isNumber { return false }
        }
        return true
    }

    /// Latest occurrence of any of the phrases inside the window (closest to the place name).
    private static func lastRange(
        ofAny phrases: [String],
        in text: String,
        within window: Range<String.Index>
    ) -> Range<String.Index>? {
        var best: Range<String.Index>?
        for phrase in phrases {
            if let r = text.range(of: phrase, options: .backwards, range: window) {
                // Latest match wins; on a tie at the same end, the longer phrase wins
                // ("when i go out from " over "out from ").
                if best == nil
                    || r.upperBound > best!.upperBound
                    || (r.upperBound == best!.upperBound && r.lowerBound < best!.lowerBound) {
                    best = r
                }
            }
        }
        return best
    }

    private static let leavePhrases = [
        "when i leave ", "when leaving ", "after i leave ", "before i leave ",
        "leaving ", "leave ",
        "when i go out from ", "when i go out of ", "go out from ", "go out of ",
        "when i get out of ", "get out of ", "when i exit ", "exit ", "out from ",
        "lama atla3 men ", "lamma atla3 men "
    ]
    private static let arrivePhrases = [
        "when i arrive at ", "when i get to ", "when i reach ", "when i get ",
        "arrive at ", "arriving at ", "get to ", "go to ", "get ", "reach ",
        "at ", "in ", "to ", "lama awsal ", "lamma awsal "
    ]

    // MARK: - Time matching

    /// "in 20 minutes", "after 2 hours", "in an hour", "in half an hour" —
    /// relative durations NSDataDetector can't handle.
    private static func matchRelativeDuration(
        in text: String,
        now: Date,
        excluding excludedRange: Range<String.Index>?
    ) -> (Date, Range<String.Index>)? {
        let pattern = #"(?:\b(?:in|after)\s+)(a|an|half an|(\d+)(?:\s+and\s+a\s+half)?)\s*(minutes?|mins?|m\b|hours?|hrs?|h\b)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              let range = Range(match.range, in: text)
        else { return nil }
        if let excluded = excludedRange, range.overlaps(excluded) { return nil }

        let quantityText = Range(match.range(at: 1), in: text).map { text[$0].lowercased() } ?? "a"
        let unitText = Range(match.range(at: 3), in: text).map { text[$0].lowercased() } ?? "minutes"
        let isHours = unitText.hasPrefix("h")

        var amount: Double
        if quantityText == "a" || quantityText == "an" {
            amount = 1
        } else if quantityText == "half an" {
            amount = 0.5
        } else if let digits = Range(match.range(at: 2), in: text), let n = Double(text[digits]) {
            amount = quantityText.contains("and a half") ? n + 0.5 : n
        } else {
            return nil
        }

        let seconds = amount * (isHours ? 3600 : 60)
        return (now.addingTimeInterval(seconds), range)
    }

    private static func matchDate(
        in text: String,
        now: Date,
        excluding excludedRange: Range<String.Index>? = nil
    ) -> (Date, Range<String.Index>)? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, options: [], range: nsRange)

        for match in matches {
            guard var date = match.date, let range = Range(match.range, in: text) else { continue }
            // Skip anything inside the location phrase (e.g. a number in a place name).
            if let excluded = excludedRange, range.overlaps(excluded) { continue }
            // NSDataDetector can resolve bare times to earlier today; push to the next occurrence.
            if date <= now {
                if let bumped = Calendar.current.date(byAdding: .day, value: 1, to: date), bumped > now {
                    date = bumped
                } else {
                    continue
                }
            }
            // Include a leading "at/on/by/tomorrow" style connector in the removed range.
            var start = range.lowerBound
            let prefix = text[..<range.lowerBound].lowercased()
            for connector in ["at ", "on ", "by ", "around "] {
                if prefix.hasSuffixPhrase(connector) {
                    if let cRange = text.range(of: connector, options: [.backwards, .caseInsensitive], range: text.startIndex..<range.lowerBound) {
                        start = cRange.lowerBound
                    }
                    break
                }
            }
            return (date, start..<range.upperBound)
        }
        return nil
    }

    private static func cleanContent(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip dangling connectors left after removing the condition phrase.
        let danglers = ["at", "on", "by", "when", "when i", "to", "and", ",", "every"]
        var changed = true
        while changed {
            changed = false
            for d in danglers {
                if s.lowercased().hasSuffix(" " + d) || s.lowercased() == d {
                    s = String(s.dropLast(d.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                }
            }
        }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
    }
}

private extension String {
    /// True if the string's trailing text (ignoring trailing spaces beyond one) ends with the phrase.
    func hasSuffixPhrase(_ phrase: String) -> Bool {
        lowercased().hasSuffix(phrase)
    }
}
