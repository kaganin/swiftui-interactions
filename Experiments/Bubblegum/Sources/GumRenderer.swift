import MetalKit

/// MTKView calls its delegate on the main thread. The renderer owns GPU resources.
@MainActor
final class GumRenderer: NSObject, MTKViewDelegate {
    var targetInflation: Float = 0
    private var reduceMotion = false
    private var inflation: Float = 0
    private var velocity: Float = 0
    private var strain: Float = 0
    private var agitation: Float = 0
    private var sway = GumSway()
    #if os(iOS)
    private let motionInput = GumMotionInput()
    #endif
    private var phase: Float = 0
    private var rupture = GumRupture()
    private var resetID = 0
    private var burstVariation: UInt32 = 0
    private var shapeVariation: Float = .random(in: 0.05...0.95)
    private var onBurst: (@MainActor () -> Void)?
    private var lastFrame = CACurrentMediaTime()
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private let membranePipeline: any MTLRenderPipelineState
    private let burstLinePipeline: any MTLComputePipelineState
    private var burstLineProbes: [(command: any MTLCommandBuffer, buffer: any MTLBuffer)] = []
    private var fragments: GumFragments?

    enum SetupError: Error { case metalUnavailable, shadersUnavailable }

    init(view: MTKView) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { throw SetupError.metalUnavailable }
        guard let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "gumVertex"),
              let fragment = library.makeFunction(name: "gumFragment") else {
            throw SetupError.shadersUnavailable
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        guard let membraneVertex = library.makeFunction(name: "membraneVertex"),
              let membraneFragment = library.makeFunction(name: "membraneFragment") else {
            throw SetupError.shadersUnavailable
        }
        descriptor.vertexFunction = membraneVertex
        descriptor.fragmentFunction = membraneFragment
        let attachment = descriptor.colorAttachments[0]!
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        membranePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        guard let burstLineFunction = library.makeFunction(name: "gumVisibleBurstLine") else {
            throw SetupError.shadersUnavailable
        }
        burstLinePipeline = try device.makeComputePipelineState(function: burstLineFunction)
        self.queue = queue
        super.init()
        view.device = device
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.preferredFramesPerSecond = 60
        view.autoResizeDrawable = false
        view.delegate = self
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastFrame, 0), 1.0 / 20))
        lastFrame = now
        // Integrate in short steps, including after interruption or a slow frame.
        for _ in 0..<(rupture.time == nil ? 4 : 0) {
            let step = dt / 4
            velocity += ((targetInflation - inflation) * 65 - velocity * 15) * step
            inflation = min(max(inflation + velocity * step, 0), 1)
            // Expansion and recoil have different relaxation times, without idle wobble.
            let relaxation: Float = inflation > strain ? 4.5 : 3.0
            strain += (inflation - strain) * (1 - exp(-step * relaxation))
        }
        if rupture.time == nil {
            #if os(iOS)
            let gravityX = motionInput.gravityX
            let accelerationX = motionInput.recentAccelerationX
            #else
            let gravityX: Float = 0
            let accelerationX: Float = 0
            #endif
            sway.advance(dt: dt, inflation: inflation, inflationSpeed: velocity,
                         variation: shapeVariation, gravityX: gravityX,
                         accelerationX: accelerationX, reducedMotion: reduceMotion)
        }
        var touchingBurstLine = false
        burstLineProbes.removeAll { probe in
            switch probe.command.status {
            case .completed:
                touchingBurstLine = touchingBurstLine ||
                    probe.buffer.contents().load(as: UInt32.self) != 0
                return true
            case .error:
                return true
            default:
                return false
            }
        }
        let inputEnergy = reduceMotion ? 0 : min(abs(velocity) * 5, 1)
        agitation += (inputEnergy - agitation) * (1 - exp(-dt * 5))
        if !reduceMotion && agitation > 0.0005 && strain > 0.72 { phase += dt }
        let burstBegan = rupture.advance(touchingBurstLine: touchingBurstLine, dt: dt,
                                         reducedMotion: reduceMotion)
        if burstBegan {
            #if os(iOS)
            motionInput.stop()
            #endif
            let previous = burstVariation
            repeat { burstVariation = UInt32.random(in: 1...65535) } while burstVariation == previous
            fragments = GumFragments(variation: burstVariation, inflation: inflation, strain: strain,
                                     shapeVariation: shapeVariation, sway: sway.offset)
        }
        if let time = rupture.time { fragments?.advance(to: time) }
        let membraneVertices = fragments?.vertices ?? []
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            if burstBegan { onBurst?() }
            return
        }
        var parameters = SIMD8<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height),
                                      inflation, strain, agitation, phase, rupture.elapsedTime ?? 0, rupture.time == nil ? 0 : Float(burstVariation + 1))
        var motion = SIMD2(shapeVariation, sway.offset)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&parameters, length: MemoryLayout<SIMD8<Float>>.stride, index: 0)
        encoder.setFragmentBytes(&motion, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if !membraneVertices.isEmpty {
            // The command retains its immutable frame buffer until GPU completion;
            // CPU integration cannot overwrite vertices still being read by the GPU.
            let buffer = membraneVertices.withUnsafeBytes { bytes in
                queue.device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
            }
            if let buffer {
                encoder.setRenderPipelineState(membranePipeline)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.setVertexBytes(&parameters, length: MemoryLayout<SIMD8<Float>>.stride, index: 1)
                encoder.setVertexBytes(&motion, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
                encoder.setFragmentBytes(&parameters, length: MemoryLayout<SIMD8<Float>>.stride, index: 0)
                encoder.setFragmentBytes(&motion, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: membraneVertices.count)
            }
        }
        encoder.endEncoding()
        if rupture.time == nil && inflation > 0.70,
           let burstLineBuffer = queue.device.makeBuffer(length: MemoryLayout<UInt32>.stride,
                                                        options: .storageModeShared),
           let burstLineEncoder = command.makeComputeCommandEncoder() {
            burstLineBuffer.contents().storeBytes(of: UInt32(0), as: UInt32.self)
            burstLineEncoder.setComputePipelineState(burstLinePipeline)
            burstLineEncoder.setBuffer(burstLineBuffer, offset: 0, index: 0)
            burstLineEncoder.setBytes(&parameters, length: MemoryLayout<SIMD8<Float>>.stride, index: 1)
            burstLineEncoder.setBytes(&motion, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
            burstLineEncoder.dispatchThreads(MTLSize(width: 256, height: 1, depth: 1),
                                             threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            burstLineEncoder.endEncoding()
            burstLineProbes.append((command, burstLineBuffer))
        }
        command.present(drawable)
        command.commit()
        // Submit the first tear frame before changing SwiftUI's overlay. Audio
        // teardown is deferred by the view until the visible rupture settles.
        if burstBegan { onBurst?() }
        if rupture.isSettled { view.isPaused = true }
        if rupture.time == nil && strain < 0.975 && abs(targetInflation - inflation) < 0.0001 && abs(velocity) < 0.0001
            && abs(strain - inflation) < 0.0001 && agitation < 0.0005 && !sway.isMoving
            && burstLineProbes.isEmpty {
            view.isPaused = true
        }
    }

    func update(view: MTKView, inflation: Float, reducedMotion: Bool, active: Bool,
                resetID: Int, onBurst: @escaping @MainActor () -> Void) {
        if self.resetID != resetID {
            self.resetID = resetID
            let previous = SIMD2(sin(shapeVariation * 6.2831853), sin(shapeVariation * 11.938052))
            repeat { shapeVariation = .random(in: 0.05...0.95) }
            while simd_distance(previous, SIMD2(sin(shapeVariation * 6.2831853),
                                                sin(shapeVariation * 11.938052))) < 0.65
            rupture = GumRupture()
            fragments = nil
            burstLineProbes.removeAll()
            self.inflation = inflation; strain = inflation; velocity = 0; agitation = 0; sway = GumSway()
        }
        self.onBurst = onBurst
        targetInflation = inflation
        reduceMotion = reducedMotion
        #if os(iOS)
        motionInput.setActive(active && !reducedMotion && inflation > 0.05 && rupture.time == nil) {
            [weak view] in view?.isPaused = false
        }
        #endif
        if reducedMotion { agitation = 0; sway = GumSway() }
        if reducedMotion { self.inflation = inflation; strain = inflation; velocity = 0 }
        // SwiftUI may update on every microphone buffer. Resetting the clock on
        // each update made the integration step depend on callback/frame phase.
        if view.isPaused != !active {
            if active { lastFrame = CACurrentMediaTime() }
            view.isPaused = !active
        }
    }

    func stop() {
        #if os(iOS)
        motionInput.stop()
        #endif
    }
}
