import SwiftUI
import MetalKit

@main
struct BubblegumApp: App {
    var body: some Scene {
        WindowGroup {
            GumStudy()
                .preferredColorScheme(.light)
                #if os(macOS)
                .frame(minWidth: 390, idealWidth: 440, minHeight: 640, idealHeight: 760)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 440, height: 760)
        #endif
    }
}

private struct GumStudy: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var inflation = 0.0
    @State private var renderError: String?
    @State private var hasBurst = false
    @State private var resetID = 0
    @State private var showDebug = false
    @State private var showMicrophoneAlert = false
    @State private var microphoneAlertMessage = ""
    @GestureState private var isInflating = false
    #if os(iOS)
    @StateObject private var blowInput = GumBlowInput()
    @State private var burstAudio = GumBurstAudio()
    @State private var burstAudioStatus = "Not played yet"
    #endif

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Neutral gray sampled from the supplied on.design screenshot (#F2F2F2).
                Color(.sRGB, red: 242 / 255, green: 242 / 255, blue: 242 / 255)
                    .ignoresSafeArea()
                GumSurface(inflation: Float(inflation), reduceMotion: reduceMotion,
                           active: scenePhase == .active, resetID: resetID,
                           onBurst: {
                               #if os(iOS)
                               burstAudioStatus = burstAudio.play() ? "Started" : "Failed to start"
                               #endif
                               hasBurst = true
                           }, size: geometry.size,
                           error: $renderError)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Three-dimensional pink bubblegum")
                    .accessibilityValue(hasBurst ? "Burst" : "\(Int(inflation * 100)) percent inflated")

                if hasBurst {
                    Button(action: reset) {
                        Image("Retry")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 40, height: 40)
                            .foregroundStyle(Color.blue)
                            .frame(width: 72, height: 72)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Inflate again")
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                } else {
                    #if os(iOS)
                    if inflation == 0 && blowInput.status != .listening {
                        microphoneEmptyState
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    } else if inflation == 0 {
                        breathGuidance
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .transition(.asymmetric(
                                insertion: .identity,
                                removal: reduceMotion ? .opacity : .scale(scale: 0.9, anchor: .bottom)
                                    .combined(with: .opacity)
                            ).animation(.snappy(duration: 0.22)))
                    } else {
                        Button(action: toggleMicrophone) {
                            Image(systemName: blowInput.isActive ? "mic.fill" : "mic")
                                .font(.system(size: blowInput.isActive ? 23 : 32, weight: .regular))
                                .foregroundStyle(blowInput.isBlowing ? Color.pink : Color.primary)
                                .frame(width: 72, height: 72)
                        }
                        .disabled(blowInput.status == .requesting)
                        .accessibilityLabel(blowInput.isActive ? "Turn microphone off" : "Inflate with microphone")
                        .accessibilityHint("Requests microphone permission on first use; audio is never recorded")
                        .position(x: geometry.size.width / 2,
                                  y: blowInput.isActive ? 82 : geometry.size.height / 2)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: blowInput.isActive)
                    }
                    #else
                    manualInflationControl
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    #endif
                }
                if let renderError {
                    Text(renderError).font(.caption).foregroundStyle(.red)
                        .position(x: geometry.size.width / 2, y: 110)
                }
                #if DEBUG
                // Intentionally invisible on the study canvas. Hold the top-right
                // corner to open manual controls and microphone diagnostics.
                Color.clear.frame(width: 68, height: 68).contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 1) { showDebug = true }
                    .accessibilityLabel("Debug menu")
                    .position(x: geometry.size.width - 34, y: 68)
                #endif
            }
        }
        .ignoresSafeArea()
        .sheet(isPresented: $showDebug) { debugControls }
        .alert("Microphone", isPresented: $showMicrophoneAlert) {
            #if os(iOS)
            if blowInput.status == .denied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
            #endif
            Button("OK", role: .cancel) {}
        } message: { Text(microphoneAlertMessage) }
        .task(id: isInflating && scenePhase == .active && !hasBurst) {
            guard isInflating && scenePhase == .active && !hasBurst else { return }
            let clock = ContinuousClock()
            var previous = clock.now
            while !Task.isCancelled && !hasBurst && inflation < 1 {
                do { try await Task.sleep(for: .milliseconds(33)) }
                catch { return }
                guard !Task.isCancelled else { return }
                let now = clock.now
                let elapsed = previous.duration(to: now).components
                let seconds = min(0.1, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
                previous = now
                // The stretched film offers increasing resistance near its limit.
                let resistance = 1 - 0.78 * pow(inflation, 3)
                inflation = min(1, inflation + seconds * 0.22 * resistance)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            #if os(iOS)
            if phase != .active && blowInput.status == .listening { blowInput.stop() }
            #endif
        }
        .task(id: hasBurst) {
            #if os(iOS)
            guard hasBurst else { return }
            // AVAudioEngine teardown can block the main actor. Keep it outside
            // the visible tear, then release the microphone once film settles.
            do { try await Task.sleep(for: .milliseconds(800)) }
            catch { return }
            guard !Task.isCancelled && hasBurst else { return }
            blowInput.stop()
            #endif
        }
        .onDisappear {
            #if os(iOS)
            blowInput.stop()
            #endif
        }
    }

    private func reset() {
        inflation = 0
        hasBurst = false
        #if os(iOS)
        burstAudioStatus = "Not played yet"
        #endif
        resetID += 1
    }

    #if os(iOS)
    private var microphoneEmptyState: some View {
        VStack(spacing: 0) {
            Image("MicrophonePermission")
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
                .padding(.bottom, 32)
            Text("enable microphone access")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(.black)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 6)
            Text("microphone is used to detect your breath.\nyour audio is never recorded.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(Color(red: 124 / 255, green: 124 / 255, blue: 130 / 255))
                .lineSpacing(4)
            Button(action: toggleMicrophone) {
                if #available(iOS 26.0, *) {
                    microphoneButtonLabel
                        .glassEffect(.regular.tint(Color(red: 1, green: 96 / 255, blue: 154 / 255)).interactive(),
                                     in: .capsule)
                } else {
                    microphoneButtonLabel
                        .background(Color(red: 1, green: 96 / 255, blue: 154 / 255), in: Capsule())
                }
            }
            .buttonStyle(.plain)
            .disabled(blowInput.status == .requesting)
            .accessibilityHint("Allow microphone access to detect your breath")
            .padding(.top, 40)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 340)
        .padding(.horizontal, 24)
    }

    private var microphoneButtonLabel: some View {
        Text(blowInput.status == .requesting ? "opening…" : "continue")
            .font(.system(.body, design: .rounded, weight: .semibold))
            .foregroundStyle(.white)
            .frame(minWidth: 150, minHeight: 54)
    }

    private var breathGuidance: some View {
        VStack(spacing: 40) {
            Text("blow into your microphone to inflate a bubble!")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(.black)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
                .padding(.horizontal, 24)
            Image("BreathArrow")
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .phaseAnimator(reduceMotion || scenePhase != .active ? [false] : [false, true]) { arrow, down in
                    arrow.offset(y: down ? 8 : 0)
                } animation: { _ in
                    .timingCurve(0.37, 0, 0.63, 1, duration: 0.5)
                }
                .accessibilityHidden(true)
        }
        .padding(.bottom, 32)
        .allowsHitTesting(false)
    }

    private func toggleMicrophone() {
        if blowInput.isActive { blowInput.stop(); return }
        Task {
            await blowInput.start { duration, strength in
                guard !hasBurst else { return }
                let resistance = 1 - 0.78 * pow(inflation, 3)
                inflation = min(1, inflation + duration * 0.24
                                * (0.5 + 0.5 * Double(strength)) * resistance)
            }
            if blowInput.status == .listening { burstAudio.prepare() }
            if blowInput.status == .denied {
                microphoneAlertMessage = "Enable microphone access in Settings > Bubblegum."
                showMicrophoneAlert = true
            } else if blowInput.status == .unavailable {
                #if DEBUG
                microphoneAlertMessage = "Microphone unavailable. Try the manual inflation control in the Debug menu."
                #else
                microphoneAlertMessage = "Microphone unavailable. Check your audio input and try again."
                #endif
                showMicrophoneAlert = true
            }
        }
    }
    #endif

    private var manualInflationControl: some View {
        Image(systemName: "hand.tap")
            .font(.system(size: 28))
            .frame(width: 72, height: 72)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).updating($isInflating) { _, pressed, _ in
                pressed = true
            })
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Inflate manually")
            .accessibilityHint("Press and hold")
            .accessibilityAction { inflation = min(1, inflation + 0.08) }
    }

    private var debugControls: some View {
        NavigationStack {
            Form {
                Section("Inflation") {
                    Slider(value: $inflation, in: 0...1)
                        .disabled(hasBurst)
                    Text("Target: \(Int(inflation * 100))%")
                    HStack { Text("Inflate manually"); Spacer(); manualInflationControl }
                    Button("Reset", action: reset)
                }
                #if os(iOS)
                Section("Microphone") {
                    Button(blowInput.isActive ? "Turn microphone off" : "Turn microphone on", action: toggleMicrophone)
                    Text(blowInput.status == .listening ? "Listening" : "Off")
                    Text(blowInput.isBlowing ? "Breath detected" : "Waiting for breath")
                    if let frame = blowInput.lastFrame {
                        Text(String(format: "MIC %.5f · HF %.2f · P %.2f",
                                    frame.rms, frame.highFrequencyShare, frame.periodicity))
                    }
                    if let peak = blowInput.peakFrame {
                        Text(String(format: "PEAK %.5f · HF %.2f · P %.2f",
                                    peak.rms, peak.highFrequencyShare, peak.periodicity))
                    }
                    Text("\(blowInput.lastBufferFrames) frames · \(blowInput.inputChannelCount) ch")
                    Text(blowInput.inputRoute)
                    Text("Audio output: \(blowInput.outputRoute)")
                    Text("Burst audio: \(burstAudioStatus)")
                }
                #endif
            }
            .navigationTitle("Bubblegum Debug")
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Done") { showDebug = false }
            } }
        }
    }

}

private struct GumSurface {
    var inflation: Float
    var reduceMotion: Bool
    var active: Bool
    var resetID: Int
    var onBurst: @MainActor () -> Void
    var size: CGSize
    @Binding var error: String?

    @MainActor final class Coordinator {
        var renderer: GumRenderer?
    }

    @MainActor func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor private func makeView(coordinator: Coordinator) -> MTKView {
        let view = MTKView(frame: .zero)
        do {
            coordinator.renderer = try GumRenderer(view: view)
        } catch {
            let message = "Unable to create Metal view: \(error.localizedDescription)"
            DispatchQueue.main.async { self.error = message }
        }
        return view
    }

    @MainActor private func update(_ view: MTKView, coordinator: Coordinator) {
        let scale = min(3, 1500 / max(size.width, size.height, 1))
        let drawableSize = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        if view.drawableSize != drawableSize { view.drawableSize = drawableSize }
        coordinator.renderer?.update(view: view, inflation: inflation,
                                     reducedMotion: reduceMotion, active: active,
                                     resetID: resetID, onBurst: onBurst)
    }
}

#if os(macOS)
extension GumSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> MTKView { makeView(coordinator: context.coordinator) }
    func updateNSView(_ view: MTKView, context: Context) { update(view, coordinator: context.coordinator) }
    static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
        coordinator.renderer?.stop()
        view.isPaused = true
    }
}
#else
extension GumSurface: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView { makeView(coordinator: context.coordinator) }
    func updateUIView(_ view: MTKView, context: Context) { update(view, coordinator: context.coordinator) }
    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        coordinator.renderer?.stop()
        view.isPaused = true
    }
}
#endif
