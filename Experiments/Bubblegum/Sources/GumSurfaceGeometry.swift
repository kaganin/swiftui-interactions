import simd

/// CPU counterpart of Gum.metal's intact material surface. Rupture samples these
/// same world-space positions and film thicknesses instead of inventing sheets.
enum GumSurfaceGeometry {
    static let glassZ: Float = 1.20

    private static func shapeBias(_ variation: Float) -> SIMD2<Float> {
        SIMD2(sin(variation * 6.2831853), sin(variation * 11.938052))
    }

    private static func forwardShift(_ inflation: Float, variation: Float) -> Float {
        (0.31 + 0.018 * shapeBias(variation).y) * smoothstep(0.55, 0.90, inflation)
    }

    static func centre(inflation: Float, variation: Float = 0, sway: Float = 0) -> SIMD3<Float> {
        let radius = mix(0.29, 1.12, inflation)
        let opened = smoothstep(0, 0.45, inflation)
        let y = radius * (0.78 + 0.22 * opened) - 0.88
        return SIMD3(0.08 * radius + sway * smoothstep(-0.84, -0.16, y), y,
                     forwardShift(inflation, variation: variation) - 0.025 * radius)
    }

    static func point(direction: SIMD3<Float>, inflation: Float, strain: Float,
                      variation: Float = 0, sway: Float = 0) -> SIMD3<Float> {
        let origin = centre(inflation: inflation, variation: variation, sway: sway)
        let ray = simd_length_squared(direction) > 0.00000001
            ? simd_normalize(direction) : SIMD3<Float>(0, 0, 1)
        var lower: Float = 0
        var upper = mix(0.29, 1.12, inflation) * 2
        // The body plus retained root lies inside this initial bound for 0...1
        // inflation. Expansion keeps the bracket valid if its deformation grows.
        for _ in 0..<8 {
            if distance(origin + ray * upper, inflation: inflation, strain: strain,
                        variation: variation, sway: sway) >= 0 { break }
            upper *= 2
        }
        for _ in 0..<22 {
            let middle = (lower + upper) * 0.5
            if distance(origin + ray * middle, inflation: inflation, strain: strain,
                        variation: variation, sway: sway) < 0 {
                lower = middle
            } else {
                upper = middle
            }
        }
        return origin + ray * ((lower + upper) * 0.5)
    }

    static func distance(_ p: SIMD3<Float>, inflation: Float, strain: Float,
                         variation: Float = 0, sway: Float = 0) -> Float {
        let radius = mix(0.29, 1.12, inflation)
        let radii = gumRadii(inflation)
        let q = coordinates(p, inflation: inflation, strain: strain, variation: variation, sway: sway) * radii
        var body = ellipsoid(q, radii)
        let direction = simd_normalize(q + SIMD3(0, 0.0001, 0))
        let localExtension = strain * mix(0.72, 1.22, smoothstep(-0.8, 0.6, direction.y))
        let slack = (1 - smoothstep(0.02, 0.85, localExtension))
            * (1 - 0.55 * smoothstep(0.05, 0.25, inflation))
        let limitLoad = smoothstep(0.65, 1, strain)
        let foldRegion = 1 - 0.85 * smoothstep(-0.70, -0.20, direction.y)
        let folds = sin(direction.x * 13 + direction.y * 4)
            * sin(direction.z * 11 - direction.y * 5) * foldRegion
        let lower = 1 - smoothstep(-0.88, -0.57, direction.y)
        body += radius * (0.012 * slack * folds + 0.014 * lower * slack
            * sin(direction.x * 24 + direction.z * 8))
        body += radius * mix(0.018, 0.004, limitLoad) * sin(direction.x * 3.2 + 1.1)
            * sin(direction.y * 4 - direction.z * 2)
        let root = ellipsoid(p - SIMD3(-0.025, -0.88, 0), SIMD3(0.10, 0.075, 0.10))
        // The near side compresses against the display glass before fracture.
        return max(smoothUnion(body, root, 0.08), p.z - glassZ)
    }

    static func thickness(_ p: SIMD3<Float>, inflation: Float, strain: Float,
                          variation: Float = 0, sway: Float = 0) -> Float {
        let local = coordinates(p, inflation: inflation, strain: strain, variation: variation, sway: sway)
        let stretched = smoothstep(0.15, 0.95, strain)
        let patch = tissueNoise(local * 3.5 + SIMD3(4.1, 1.7, 0))
        var fibrePosition = local * SIMD3(14, 5, 6) + SIMD3(2, 8, 4)
        fibrePosition.x += sin(local.y * 4) * 0.65
        let ridges = pow(smoothstep(0.50, 0.82, tissueNoise(fibrePosition)), 3)
        let rootThickness = 1 - smoothstep(-0.94, -0.78, local.y)
        let rootXZ = (SIMD2(p.x, p.z) - SIMD2<Float>(-0.025, 0)) / SIMD2<Float>(0.14, 0.13)
        let rootExtra = rootThickness * 0.004 * exp(-simd_dot(rootXZ, rootXZ))
        let bias = shapeBias(variation)
        let shoulder = (SIMD2(local.x, local.y) - SIMD2<Float>(0.20 + 0.12 * bias.x,
                                                              0.30 + 0.07 * bias.y)) * SIMD2(1.5, 1.2)
        let thinShoulder = exp(-simd_dot(shoulder, shoulder))
        let material = (0.55 + patch * 1.15 + ridges * stretched * 0.12)
            * (1 - thinShoulder * stretched * 0.55)
        let limitLoad = smoothstep(0.65, 1, strain)
        let weak = weakShoulder(local, variation: variation)
        let dome = pow(saturate(abs(local.z)), 3) * smoothstep(-0.70, -0.15, local.y)
        let stretch = areaStretch(p, inflation: inflation, strain: strain, variation: variation, sway: sway)
        let thinCap = pow(saturate(abs(local.z)), 1.5) * smoothstep(-0.99, -0.72, local.y)
        let capThinning = mix(1, pow(stretch, -1.10), thinCap)
        let necking = mix(1, 0.62, limitLoad) * (1 - 0.60 * limitLoad * dome)
            * (1 - 0.48 * limitLoad * weak)
        let earlyOpening = smoothstep(0.16, 0.30, inflation)
            * (1 - smoothstep(0.38, 0.70, inflation))
        let startingThickness = mix(0.052, 0.023, smoothstep(0.01, 0.18, inflation))
            * (1 - 0.50 * earlyOpening)
        return 0.00004 + max(0.00003, startingThickness / stretch * material * necking * capThinning) + rootExtra
    }

    private static func gumRadii(_ inflation: Float) -> SIMD3<Float> {
        mix(0.29, 1.12, inflation) * SIMD3(1.03, mix(0.78, 1, smoothstep(0, 0.45, inflation)), 0.87)
    }

    private static func coordinates(_ p: SIMD3<Float>, inflation: Float, strain: Float,
                                    variation: Float, sway: Float) -> SIMD3<Float> {
        let radius = mix(0.29, 1.12, inflation)
        let opened = smoothstep(0, 0.45, inflation)
        let taut = smoothstep(0.45, 1, strain)
        let opening = smoothstep(0.18, 0.72, inflation)
        let bias = shapeBias(variation)
        var q = p - SIMD3(0, radius * (0.78 + 0.22 * opened) - 0.88, 0)
        let height = saturate((p.y + 0.90) / (2 * radius))
        q.x -= radius * (0.12 * height * height + 0.045 * sin(height * 3.7))
        q.x -= radius * 0.085 * bias.x * opening * height * height
        q.x -= sway * smoothstep(-0.84, -0.16, p.y)
        q.z += radius * 0.055 * height - forwardShift(inflation, variation: variation)
        q.x *= 1 - 0.045 * taut * smoothstep(0.2, 0.9, height)
        q.x *= 1 + 0.085 * bias.y * opening
        q.z *= 1 + 0.035 * taut * height
        q.y += radius * (0.045 + 0.024 * bias.y * opening)
            * sin(q.x / radius * 2.1 + 0.8 + 0.35 * bias.x * opening)
        let local = q / gumRadii(inflation)
        let limitLoad = smoothstep(0.65, 1, strain)
        let weakLoad = 0.06 * smoothstep(0.05, 0.42, inflation) + 0.09 * limitLoad
        return local * (1 - weakLoad * weakShoulder(local, variation: variation))
    }

    private static func areaStretch(_ p: SIMD3<Float>, inflation: Float, strain: Float,
                                    variation: Float, sway: Float) -> Float {
        let epsilon = mix(0.29, 1.12, inflation) * 0.002
        let q = coordinates(p, inflation: inflation, strain: strain, variation: variation, sway: sway)
        let dx = (coordinates(p + SIMD3(epsilon, 0, 0), inflation: inflation, strain: strain,
                              variation: variation, sway: sway) - q) / epsilon
        let dy = (coordinates(p + SIMD3(0, epsilon, 0), inflation: inflation, strain: strain,
                              variation: variation, sway: sway) - q) / epsilon
        let dz = (coordinates(p + SIMD3(0, 0, epsilon), inflation: inflation, strain: strain,
                              variation: variation, sway: sway) - q) / epsilon
        let normal = simd_normalize(q + SIMD3(0, 0.00001, 0))
        let worldArea = simd_length(SIMD3(simd_dot(dx, normal), simd_dot(dy, normal), simd_dot(dz, normal)))
            / max(abs(simd_dot(dx, simd_cross(dy, dz))), 0.00001)
        let restRadii = gumRadii(0)
        let restArea = restRadii.x * restRadii.y * restRadii.z * simd_length(normal / restRadii)
        return max(1, worldArea / restArea)
    }

    private static func weakShoulder(_ local: SIMD3<Float>, variation: Float) -> Float {
        let bias = shapeBias(variation)
        let centre = (SIMD2(local.x, local.y) - SIMD2<Float>(0.43 + 0.16 * bias.x,
                                                            0.34 + 0.09 * bias.y)) / SIMD2(0.62, 0.46)
        return exp(-simd_dot(centre, centre) * 1.5) * smoothstep(-0.35, 0.45, local.z)
    }

    private static func ellipsoid(_ p: SIMD3<Float>, _ radii: SIMD3<Float>) -> Float {
        let k0 = simd_length(p / radii)
        let k1 = simd_length(p / (radii * radii))
        return k0 * (k0 - 1) / max(k1, 0.0001)
    }

    private static func smoothUnion(_ a: Float, _ b: Float, _ k: Float) -> Float {
        let h = saturate(0.5 + 0.5 * (b - a) / k)
        return mix(b, a, h) - k * h * (1 - h)
    }

    private static func tissueNoise(_ p: SIMD3<Float>) -> Float {
        let cell = SIMD3(floor(p.x), floor(p.y), floor(p.z))
        var f = p - cell
        f = f * f * (3 - 2 * f)
        let a = mix(hash31(cell), hash31(cell + SIMD3(1, 0, 0)), f.x)
        let b = mix(hash31(cell + SIMD3(0, 1, 0)), hash31(cell + SIMD3(1, 1, 0)), f.x)
        let c = mix(hash31(cell + SIMD3(0, 0, 1)), hash31(cell + SIMD3(1, 0, 1)), f.x)
        let d = mix(hash31(cell + SIMD3(0, 1, 1)), hash31(cell + SIMD3(1, 1, 1)), f.x)
        return mix(mix(a, b, f.y), mix(c, d, f.y), f.z)
    }

    private static func hash31(_ value: SIMD3<Float>) -> Float {
        var p = value * 0.1031
        p -= SIMD3(floor(p.x), floor(p.y), floor(p.z))
        p += SIMD3(repeating: simd_dot(p, SIMD3(p.y, p.z, p.x) + 33.33))
        let value = (p.x + p.y) * p.z
        return value - floor(value)
    }

    private static func saturate(_ value: Float) -> Float { min(max(value, 0), 1) }
    private static func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
    private static func smoothstep(_ a: Float, _ b: Float, _ value: Float) -> Float {
        let t = saturate((value - a) / (b - a))
        return t * t * (3 - 2 * t)
    }
}
