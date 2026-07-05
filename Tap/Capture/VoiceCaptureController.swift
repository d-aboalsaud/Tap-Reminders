import Foundation
import AVFoundation
import Speech

/// Live speech-to-text via SFSpeechRecognizer, plus TTS confirmation playback.
@MainActor
final class VoiceCaptureController: NSObject, ObservableObject {
    @Published var transcript: String = ""
    @Published var isRecording = false
    @Published var errorMessage: String?
    /// 0…1 live microphone loudness, drives the waveform animation.
    @Published var audioLevel: Double = 0

    private let recognizer = SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let synthesizer = AVSpeechSynthesizer()

    /// Called with the final transcript when recording auto-stops after silence.
    var onAutoStop: ((String) -> Void)?
    private var silenceTimer: Timer?
    private var lastTranscriptChange: Date = .now
    private static let silenceWindow: TimeInterval = 1.5

    func start() {
        errorMessage = nil
        transcript = ""

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else {
                    self.errorMessage = "Speech recognition permission is required."
                    return
                }
                AVAudioApplication.requestRecordPermission { granted in
                    Task { @MainActor in
                        guard granted else {
                            self.errorMessage = "Microphone permission is required."
                            return
                        }
                        self.beginRecording()
                    }
                }
            }
        }
    }

    private func beginRecording() {
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognition is not available right now."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            // Never REQUIRE on-device recognition: the local model may be missing
            // (always the case on the Simulator) and the task dies instantly.
            self.request = request

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                request.append(buffer)
                if let data = buffer.floatChannelData?[0] {
                    let frames = Int(buffer.frameLength)
                    var sum: Float = 0
                    for i in 0..<frames { sum += data[i] * data[i] }
                    let rms = frames > 0 ? sqrt(sum / Float(frames)) : 0
                    let level = min(1.0, Double(rms) * 12)
                    Task { @MainActor in self?.audioLevel = level }
                }
            }

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        let updated = result.bestTranscription.formattedString
                        if updated != self.transcript {
                            self.transcript = updated
                            self.lastTranscriptChange = .now
                        }
                    }
                    if let error {
                        // Never die silently: if recognition failed before anything
                        // was transcribed, tell the user what's going on.
                        if self.transcript.isEmpty && self.isRecording {
                            self.errorMessage = "Speech recognition isn't responding. On the Simulator voice usually doesn't work — try a real iPhone, or use Text mode. (\((error as NSError).code))"
                        }
                        self.stopEngineOnly()
                    } else if result?.isFinal ?? false {
                        self.stopEngineOnly()
                    }
                }
            }

            // Auto-stop: once something was heard, commit after a silence gap.
            lastTranscriptChange = .now
            silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isRecording, !self.transcript.isEmpty else { return }
                    if Date.now.timeIntervalSince(self.lastTranscriptChange) >= Self.silenceWindow {
                        let final = self.stop()
                        self.onAutoStop?(final)
                    }
                }
            }
        } catch {
            errorMessage = "Could not start recording: \(error.localizedDescription)"
            stopEngineOnly()
        }
    }

    /// Stops capture and returns the final transcript.
    func stop() -> String {
        stopEngineOnly()
        return transcript
    }

    private func stopEngineOnly() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
        audioLevel = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Speaks the parsed-capture confirmation (voice mode only).
    func speak(_ text: String) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }
}
