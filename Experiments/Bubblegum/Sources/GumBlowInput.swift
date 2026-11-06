#if os(iOS)
import AVFAudio
import SwiftUI

@MainActor
final class GumBlowInput: ObservableObject {
    enum Status: Equatable { case off, requesting, listening, denied, unavailable }

    @Published private(set) var status: Status = .off
    @Published private(set) var isBlowing = false
    @Published private(set) var lastFrame: GumBlowFrame?
    @Published private(set) var peakFrame: GumBlowFrame?
    @Published private(set) var inputRoute = ""
    @Published private(set) var outputRoute = ""
    @Published private(set) var lastBufferFrames = 0
    @Published private(set) var inputChannelCount = 0
    @Published private(set) var isInputSilent = false
    private var engine: AVAudioEngine?
    private var generation = 0
    private var gate = GumBreathGate()
    private var onBlow: ((Double, Float) -> Void)?
    private var diagnosticTime: Double = 0
    private var silentTime: Double = 0

    var isActive: Bool { status == .requesting || status == .listening }

    func start(onBlow: @escaping (Double, Float) -> Void) async {
        guard !isActive else { return }
        generation += 1
        let startGeneration = generation
        status = .requesting
        guard await AVAudioApplication.requestRecordPermission() else {
            if generation == startGeneration { status = .denied }
            return
        }
        guard generation == startGeneration else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: .defaultToSpeaker)
            try session.setActive(true)
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate >= 8_000, format.channelCount > 0 else {
                throw InputError.noMicrophone
            }
            let sampleRate = format.sampleRate
            inputChannelCount = Int(format.channelCount)
            inputRoute = session.currentRoute.inputs.map(\.portName).joined(separator: ", ")
            outputRoute = session.currentRoute.outputs.map(\.portName).joined(separator: ", ")
            self.engine = engine
            // AVAudioEngine invokes the tap off the main actor. Explicitly
            // keep this closure nonisolated under Swift 6 actor checking.
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable [weak self] buffer, _ in
                guard let channels = buffer.floatChannelData else { return }
                let count = Int(buffer.frameLength)
                var frame = GumBlowDetector.analyze(channels[0], count: count,
                                                    sampleRate: sampleRate)
                if buffer.format.channelCount > 1 {
                    for channel in 1..<Int(buffer.format.channelCount) {
                        let candidate = GumBlowDetector.analyze(channels[channel], count: count,
                                                                sampleRate: sampleRate)
                        if candidate.rms > frame.rms { frame = candidate }
                    }
                }
                let duration = Double(count) / sampleRate
                Task { @MainActor [weak self] in
                    guard let self, self.generation == startGeneration else { return }
                    self.receive(frame, duration: duration, bufferFrames: count)
                }
            }
            try engine.start()
            self.engine = engine
            self.onBlow = onBlow
            status = .listening
        } catch {
            engine?.inputNode.removeTap(onBus: 0)
            engine?.stop()
            engine = nil
            try? AVAudioSession.sharedInstance().setActive(false)
            status = .unavailable
        }
    }

    func stop() {
        generation += 1
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        onBlow = nil
        gate = GumBreathGate()
        isBlowing = false
        lastFrame = nil
        peakFrame = nil
        inputRoute = ""
        outputRoute = ""
        lastBufferFrames = 0
        inputChannelCount = 0
        isInputSilent = false
        diagnosticTime = 0
        silentTime = 0
        status = .off
    }

    private func receive(_ frame: GumBlowFrame, duration: Double, bufferFrames: Int) {
        guard status == .listening else { return }
        if lastBufferFrames != bufferFrames { lastBufferFrames = bufferFrames }
        silentTime = frame.rms < 0.000001 ? silentTime + duration : 0
        let silent = silentTime >= 1
        if isInputSilent != silent { isInputSilent = silent }
        let blowing = gate.accept(frame, duration: duration)
        if isBlowing != blowing { isBlowing = blowing }
        if frame.rms > (peakFrame?.rms ?? 0) { peakFrame = frame }
        diagnosticTime += duration
        if diagnosticTime >= 0.1 {
            diagnosticTime = 0
            lastFrame = frame
        }
        if isBlowing { onBlow?(duration, frame.strength) }
    }

    private enum InputError: Error { case noMicrophone }
}
#endif
