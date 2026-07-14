import SwiftUI
import SwiftData
import Combine

/// The capture screen. Sub-3-second philosophy: auto-commit, no confirm screen.
/// Live chips under the input show what the parser understood in real time;
/// the post-save detail sheet is the safety net for fixing mistakes.
struct CaptureView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var geofence: GeofenceManager
    @EnvironmentObject private var router: AppRouter
    @Query private var savedPlaces: [SavedPlace]

    @AppStorage("lastCaptureMode") private var lastModeRaw = CaptureMode.text.rawValue
    @AppStorage("appearanceMode") private var appearanceModeRaw = AppearanceMode.system.rawValue
    @StateObject private var voice = VoiceCaptureController()
    @State private var text = ""
    @State private var isUrgent = false
    @State private var justSaved: Reminder?
    @State private var hintIndex = 0
    @FocusState private var textFocused: Bool

    private static let hints = [
        "buy milk at 6pm",
        "call mom when I get to Home",
        "take the trash out when I leave Home",
        "pay the bill in 20 minutes",
        "gym tomorrow at 7pm !!",
    ]
    private let hintTimer = Timer.publish(every: 3.5, on: .main, in: .common).autoconnect()

    private var mode: CaptureMode {
        CaptureMode(rawValue: lastModeRaw) ?? .text
    }

    enum CaptureMode: String { case voice, text }

    private var currentInput: String {
        mode == .voice ? voice.transcript : text
    }

    private var livePreview: ParsedCapture? {
        let trimmed = currentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var parsed = CaptureParser.parse(trimmed, savedPlaces: savedPlaces)
        if isUrgent { parsed.isUrgent = true }
        return parsed
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                HStack {
                    Text("Tap.")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .foregroundStyle(LinearGradient(
                            colors: [.tapIndigo, .tapBlue],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                    Spacer()
                }
                .padding(.top, 8)

                Spacer()

                if mode == .voice {
                    voiceUI
                } else {
                    textUI
                }

                // Animation scoped to the chips only — animating the whole
                // stack on every keystroke breaks TextField text rendering.
                liveChips
                    .animation(.snappy(duration: 0.25), value: currentInput)
                    .animation(.snappy(duration: 0.25), value: isUrgent)

                Spacer()

                modeToggle
            }
            .padding()
            .contentShape(Rectangle())
            .onTapGesture { textFocused = false }
            .navigationTitle("Tap.")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Appearance", selection: $appearanceModeRaw) {
                            ForEach(AppearanceMode.allCases) { mode in
                                Label(mode.label, systemImage: mode.icon).tag(mode.rawValue)
                            }
                        }
                    } label: {
                        Image(systemName: "circle.lefthalf.filled")
                    }
                    .accessibilityLabel("Appearance")
                }
            }
            .onChange(of: router.captureFocusRequest) { _, _ in
                // Fast-capture reset: refocus after the tab switch settles.
                guard mode == .text else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    textFocused = true
                }
            }
            .sheet(item: $justSaved) { reminder in
                NavigationStack {
                    ReminderDetailView(reminder: reminder)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { justSaved = nil }
                            }
                        }
                }
                .presentationDetents([.large])
            }
        }
    }

    // MARK: - Live parse chips

    @ViewBuilder
    private var liveChips: some View {
        if let preview = livePreview {
            HStack(spacing: 8) {
                if preview.isUrgent {
                    ConditionChip(icon: "flame.fill", text: "Urgent", tint: .orange)
                        .transition(.scale.combined(with: .opacity))
                }
                if let date = preview.fireDate {
                    if preview.repeatRule != .none {
                        ConditionChip(icon: "repeat", text: preview.repeatRule.chipText(for: date))
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        ConditionChip(
                            icon: "clock.fill",
                            text: date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated,
                                                 time: .shortened)
                        )
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                if let place = preview.savedPlace {
                    ConditionChip(
                        icon: "mappin.circle.fill",
                        text: "\(preview.triggerType == .leave ? "Leaving" : "At") \(place.name)",
                        tint: .tapIndigo
                    )
                    .transition(.scale.combined(with: .opacity))
                }
                if !preview.hasCondition {
                    ConditionChip(icon: "questionmark.circle", text: "No time or place yet", tint: .secondary)
                        .transition(.opacity)
                }
            }
            .frame(minHeight: 30)
        } else {
            Color.clear.frame(height: 30)
        }
    }

    // MARK: - Voice

    private var voiceUI: some View {
        VStack(spacing: 24) {
            Text(voice.transcript.isEmpty ? "Say your reminder…" : voice.transcript)
                .font(.title3)
                .foregroundStyle(voice.transcript.isEmpty ? .secondary : .primary)
                .multilineTextAlignment(.center)
                .frame(minHeight: 80)

            if let error = voice.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }

            Button {
                if voice.isRecording {
                    let transcript = voice.stop()
                    commit(transcript, spoken: true)
                } else {
                    Haptics.tap()
                    voice.start()
                }
            } label: {
                VoiceOrb(isRecording: voice.isRecording, level: voice.audioLevel)
            }
            .buttonStyle(.plain)

            urgencyToggle
        }
        .onAppear {
            voice.onAutoStop = { transcript in
                commit(transcript, spoken: true)
            }
        }
    }

    // MARK: - Text

    private var textUI: some View {
        VStack(spacing: 16) {
            TextField(Self.hints[hintIndex], text: $text)
                .onReceive(hintTimer) { _ in
                    // Swapping the placeholder while the field is focused can
                    // drop keyboard focus — only cycle while idle.
                    guard text.isEmpty, !textFocused else { return }
                    hintIndex = (hintIndex + 1) % Self.hints.count
                }
                .font(.title3)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("captureField")
                .focused($textFocused)
                .submitLabel(.done)
                .onSubmit {
                    if text.trimmingCharacters(in: .whitespaces).isEmpty {
                        textFocused = false
                    } else {
                        commit(text, spoken: false)
                    }
                }
                .padding()
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button {
                            textFocused = false
                        } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                        }
                        .accessibilityLabel("Hide keyboard")
                    }
                }

            urgencyToggle

            Button {
                commit(text, spoken: false)
            } label: {
                Label("Tap.", systemImage: "arrow.up.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient.tapBrand
                            .opacity(text.trimmingCharacters(in: .whitespaces).isEmpty ? 0.35 : 1),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("captureSubmit")
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onAppear { textFocused = true }
    }

    private var urgencyToggle: some View {
        Button {
            isUrgent.toggle()
            Haptics.tap()
        } label: {
            Image(systemName: "flame.fill")
                .font(.title2)
                .foregroundStyle(isUrgent ? .orange : .secondary.opacity(0.5))
                .symbolEffect(.bounce, value: isUrgent)
                .padding(10)
                .background(
                    (isUrgent ? Color.orange.opacity(0.15) : Color.secondary.opacity(0.08)),
                    in: Circle()
                )
        }
        .accessibilityLabel(isUrgent ? "Urgent on" : "Urgent off")
    }

    private var modeToggle: some View {
        Picker("Input mode", selection: $lastModeRaw) {
            Label("Voice", systemImage: "mic").tag(CaptureMode.voice.rawValue)
            Label("Text", systemImage: "keyboard").tag(CaptureMode.text.rawValue)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 240)
    }

    // MARK: - Commit (auto-save, no confirm screen)

    private func commit(_ raw: String, spoken: Bool) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var parsed = CaptureParser.parse(trimmed, savedPlaces: savedPlaces)
        if isUrgent { parsed.isUrgent = true }

        let reminder = Reminder(
            content: parsed.content,
            isUrgent: parsed.isUrgent,
            fireDate: parsed.fireDate,
            savedPlace: parsed.savedPlace,
            triggerType: parsed.triggerType
        )
        reminder.repeatRule = parsed.repeatRule
        context.insert(reminder)
        try? context.save()
        RaceCoordinator.activate(reminder, geofence: geofence)

        if spoken {
            voice.speak(parsed.spokenConfirmation)
        }
        Haptics.success()

        text = ""
        isUrgent = false
        // Land on the reminder's page so the parse can be checked and fixed.
        justSaved = reminder
    }
}

/// Pulsing gradient orb with a live waveform while recording.
struct VoiceOrb: View {
    let isRecording: Bool
    let level: Double

    private static let barMultipliers: [Double] = [0.45, 0.8, 1.0, 0.7, 0.5]

    var body: some View {
        ZStack {
            // Outer glow ring reacts to loudness.
            Circle()
                .fill(LinearGradient.tapBrand)
                .opacity(isRecording ? 0.18 : 0)
                .frame(width: 132, height: 132)
                .scaleEffect(1 + level * 0.35)
                .animation(.easeOut(duration: 0.12), value: level)

            Circle()
                .fill(LinearGradient.tapBrand)
                .frame(width: 104, height: 104)
                .shadow(color: .tapBlue.opacity(isRecording ? 0.45 : 0.25), radius: isRecording ? 18 : 10)
                .scaleEffect(isRecording ? 1.04 : 1)
                .animation(.spring(duration: 0.4), value: isRecording)

            if isRecording {
                HStack(spacing: 5) {
                    ForEach(0..<Self.barMultipliers.count, id: \.self) { i in
                        Capsule()
                            .fill(.white)
                            .frame(
                                width: 5,
                                height: 10 + CGFloat(level * 38 * Self.barMultipliers[i])
                            )
                            .animation(.easeOut(duration: 0.1), value: level)
                    }
                }
                .frame(height: 52)
            } else {
                Image(systemName: "mic.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 140, height: 140)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}
