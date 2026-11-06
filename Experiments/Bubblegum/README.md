# Bubblegum

An interactive material study: inflate a bubble with your breath, sway it by tilting your phone, and watch it tear and stick to the glass.

## Run

- Open `Bubblegum.xcodeproj`, or the repository’s `SwiftUI-Interactions.xcworkspace`.
- Use Xcode 26+ and an iPhone running iOS 18+. This snapshot was build-checked with Xcode 27.
- Run the **Debug** configuration for the manual controls. iOS 26+ adds Liquid Glass; earlier systems use a solid pink button.
- For a physical phone, choose your own signing team and unique bundle identifier. No development team or provisioning profile is included.

## Try it

1. Tap **continue** and grant microphone permission.
2. Gently blow toward the bottom microphone. The arrow and instruction disappear when inflation starts.
3. Pause or tilt the phone to see the bubble settle and sway.
4. Keep blowing: the membrane tears around three-fifths of the screen height.
5. Tap the blue retry icon to start again.

While a bubble is visible, the microphone control lets you stop/restart listening. To reveal manual inflation and input readings, hold the top-right corner for one second in a Debug build. Manual inflation makes the simulator useful even without a usable microphone.

Audio is analyzed on the device and never written to a recording or uploaded. Microphone capture stops when the app goes into the background. Permission denial offers a link to Settings.

## Implementation

| Area | Main files |
| --- | --- |
| SwiftUI interface and input coordination | `Sources/BubblegumApp.swift` |
| Material, lighting, and membrane shading | `Sources/Gum.metal` |
| Metal rendering | `Sources/GumRenderer.swift` |
| Tear lifecycle and connected fragments | `Sources/GumRupture.swift`, `Sources/GumFragments.swift` |
| Shape and membrane geometry | `Sources/GumSurfaceGeometry.swift` |
| Breath classification and audio capture | `Sources/GumBlowDetector.swift`, `Sources/GumBlowInput.swift` |
| Motion input and damped sway | `Sources/GumMotionInput.swift`, `Sources/GumSway.swift` |
| Preloaded burst audio | `Sources/GumBurstAudio.swift` |

## Limits

This is an authored visual simulation, not a validated physical model. Breath classification is heuristic: wind, noise, microphone placement, and audio routing can affect it. Avoid phone screen mirroring while testing the microphone; it has caused silent input buffers in our device trials. Metal rendering, microphone behavior, and sound synchronization should be judged on a real phone.

Reduce Motion removes the arrow travel and secondary sway, and simplifies the rupture. The debug UI is for development. Interface text, accessibility labels, and diagnostics are in English. The Xcode target also contains a macOS study path, but this collection’s documented and build-checked target is iOS.

## Validate

From the repository root:

```sh
./scripts/check-bubblegum.sh
./scripts/build.sh Bubblegum
```

On a physical iPhone, check permission denial/recovery, breath versus speech, pause/resume, tilt, immediate rupture and sound, retry, background/foreground, and Reduce Motion.

## Credits

See [third-party notices](../../THIRD_PARTY_NOTICES.md) for the audio sources and licenses. The SwiftUI/Metal study and interface assets come from this collection’s Bubblegum experiment.

## Reuse

Commercial use is allowed under the [project license](../../LICENSE). Link to [kagan.in](https://kagan.in) in your app’s About/Credits screen, or obtain written permission to omit the credit. See [attribution examples](../../ATTRIBUTION.md). The separately licensed burst audio retains its own terms.
