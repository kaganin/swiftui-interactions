import simd
import Darwin

/// These checks cover a reference-directed connected deformation and its local
/// glass response. They do not claim a calibrated fracture or fluid simulation.
@main struct FragmentChecks {
    static func main() {
        setbuf(stdout, nil)
        let states: [SIMD2<Float>] = [SIMD2(1, 1), SIMD2(0.999, 0.98)]
        for state in states {
            for seed: UInt32 in [0, 1, 271, 65535] {
                checkSurface(seed: seed, inflation: state.x, strain: state.y)
            }
        }
        // Trial-to-trial inflation changes the surface handed to the tear. Each
        // profile must retain the same material and contact invariants.
        for shapeVariation: Float in [0.13, 0.39, 0.67, 0.89] {
            checkSurface(seed: 271, inflation: 1, strain: 1,
                         shapeVariation: shapeVariation)
        }
        // The same bent material must survive the dome-to-sheet handoff.
        checkSurface(seed: 271, inflation: 1, strain: 1,
                     shapeVariation: 0.13, sway: 0.03)
        checkSurface(seed: 271, inflation: 1, strain: 1,
                     shapeVariation: 0.67, sway: -0.03)
        let attachment = SIMD3<Float>(-0.025, -0.88, 0)
        precondition(GumSurfaceGeometry.distance(attachment, inflation: 0.72, strain: 0.72,
                                                 variation: 0.13, sway: 0.03)
                     == GumSurfaceGeometry.distance(attachment, inflation: 0.72, strain: 0.72,
                                                    variation: 0.13),
                     "Breath sway must leave the mouth attachment fixed")
        let shoulder = SIMD3<Float>(1, 0.25, 0.5)
        let profileA = GumSurfaceGeometry.point(direction: shoulder, inflation: 0.7,
                                                strain: 0.7, variation: 0.13)
        let profileB = GumSurfaceGeometry.point(direction: shoulder, inflation: 0.7,
                                                strain: 0.7, variation: 0.39)
        precondition(simd_distance(profileA, profileB) > 0.035,
                     "Different inflation cycles must visibly change the expanding silhouette")
        checkTearPropagation()
        var first = GumFragments(variation: 1)
        var second = GumFragments(variation: 271)
        first.advance(to: 0.65); second.advance(to: 0.65)
        precondition(first.positions != second.positions, "Material variation must affect the deformation")

        let setupStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var paced = GumFragments(variation: 271)
        let setupMS = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - setupStart) / 1e6
        var total: Double = 0, worst: Double = 0, count = 0
        for frame in 1...39 {
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            paced.advance(to: Float(frame) / 60)
            count += paced.vertices.count
            let ms = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6
            total += ms; worst = max(worst, ms)
        }
        print("Mac CPU setup: \(setupMS) ms; 60Hz advance + vertices: mean \(total / 39) ms, max \(worst) ms; \(count) vertices")
        print("PASS: locally propagating tear, stretching and severed attached bridges, conserved source material, local contact and wet spreading, pinned connected residue, deterministic rest")
    }

    static func checkSurface(seed: UInt32, inflation: Float, strain: Float,
                             shapeVariation: Float = 0, sway: Float = 0) {
        var film = GumFragments(variation: seed, inflation: inflation, strain: strain,
                                shapeVariation: shapeVariation, sway: sway)
        let source = film.sourcePositions, faces = film.triangles, volumes = film.materialVolumes
        let sourceFaces = faces.map { SIMD3(film.materialOrigins[$0.x], film.materialOrigins[$0.y], film.materialOrigins[$0.z]) }
        let originVolumes = volumesByOrigin(film)
        let restVolume = film.restVolume
        precondition(!source.isEmpty && film.positions == source && film.contactFraction == 0,
                     "Rupture must begin on the intact material surface before glass contact")
        precondition(source.count == film.contacts.count && source.count == volumes.count)
        let residual = source.map {
            abs(GumSurfaceGeometry.distance($0, inflation: inflation, strain: strain,
                                            variation: shapeVariation, sway: sway))
        }.max()!
        precondition(residual < 0.00002, "Every handoff landmark must lie on the actual inflated SDF")
        checkConnectivity(faces: faces, pointCount: source.count)
        checkGeometry(film)
        checkRenderedVertices(film)
        let sourceRadius = footprint(source, volumes: volumes).radius
        var previousContactCount = 0
        var pinned: [Int: SIMD3<Float>] = [:]
        var sawMixedContact = false, sawWetMotion = false, sawContactAdvance = false
        var maximumVolumeError: Double = 0
        for frame in 1...78 {
            film.advance(to: Float(frame) / 120)
            precondition(Array(film.sourcePositions.prefix(source.count)) == source
                         && film.triangles.map { SIMD3(film.materialOrigins[$0.x], film.materialOrigins[$0.y], film.materialOrigins[$0.z]) } == sourceFaces,
                         "A split may duplicate a boundary point, but must retain every original material face")
            let currentVolumes = volumesByOrigin(film)
            for origin in originVolumes.indices {
                precondition(abs(currentVolumes[origin] - originVolumes[origin]) < originVolumes[origin] * 0.00002 + 1e-12,
                             "Both sides of a severed boundary must retain their original combined material volume")
            }
            checkConnectivity(faces: film.triangles, pointCount: film.positions.count)
            checkGeometry(film)
            let data = film.surfaceData
            var volume: Double = 0
            for index in film.positions.indices {
                let localVolume = Double(data.areas[index]) * Double(data.thickness[index])
                let ownedVolume = film.materialVolumes[index]
                precondition(abs(localVolume - Double(ownedVolume)) <= Double(ownedVolume) * 0.00002 + 1e-12,
                             "Each material point must retain its volume as its dual area changes")
                volume += localVolume
                guard let contact = film.contacts[index] else {
                    precondition(film.positions[index].z < GumFragments.glassZ,
                                 "Uncontacted material must remain behind the glass")
                    continue
                }
                precondition(contact.time >= 0 && contact.time <= film.time && contact.time.isFinite,
                             "Contact belongs to this material point's first impact")
                precondition(isFinite(contact.position) && isFinite(contact.velocity)
                             && contact.position.z == GumFragments.glassZ
                             && film.positions[index].z == GumFragments.glassZ,
                             "Contact must stay on the glass without penetration or bounce")
                let age = film.time - contact.time
                if age > 0.01 && age < 0.14
                    && simd_distance(film.positions[index], contact.position) > 0.001 {
                    sawWetMotion = true
                }
                if age >= 0.14 {
                    if let fixed = pinned[index] {
                        precondition(film.positions[index] == fixed,
                                     "An adhered material point must stop moving after its own wet interval")
                    } else { pinned[index] = film.positions[index] }
                }
            }
            maximumVolumeError = max(maximumVolumeError, abs(volume - Double(restVolume)) / Double(restVolume))
            precondition(maximumVolumeError < 0.00002, "The connected surface must conserve total material volume")
            let contactCount = film.contacts.compactMap { $0 }.count
            precondition(contactCount >= previousContactCount, "Local contact must advance monotonically")
            if contactCount > 0 && contactCount < film.positions.count { sawMixedContact = true }
            if previousContactCount > 0 && contactCount > previousContactCount { sawContactAdvance = true }
            previousContactCount = contactCount
            if [12, 30, 48, 78].contains(frame) { checkRenderedVertices(film) }
        }
        precondition(sawMixedContact && sawContactAdvance,
                     "Some membrane must still be in the air while already contacted material spreads")
        precondition(sawWetMotion, "Local impact must include a visible wet relaxation before adhesion")
        let adheredVolume = film.positions.indices.filter { film.contacts[$0] != nil }.reduce(Float(0)) { $0 + film.materialVolumes[$1] }
        precondition(adheredVolume > restVolume * 0.995 && pinned.count == previousContactCount,
                     "The residue must reach the glass, including its loose folds, then finish local wet spreading")
        let finalRadius = footprint(film.positions, volumes: film.materialVolumes).radius
        precondition(finalRadius < sourceRadius,
                     "The residue must gather into a closer mass rather than expand into distant islands")
        let contactTimes = film.contacts.compactMap { $0?.time }
        precondition(contactTimes.max()! - contactTimes.min()! > 1 / 120,
                     "Contact must resolve across more than a single frame")
        for aspect: Float in [0.5, 0.67, 1.5] { checkProjection(film.positions, aspect: aspect) }
        let uncontactedMass = 1 - adheredVolume / restVolume
        print("Final uncontacted mass \(uncontactedMass * 100)%")
        let settled = film.positions
        film.advance(to: 3)
        precondition(film.positions == settled, "Settled residue must persist")
        var direct = GumFragments(variation: seed, inflation: inflation, strain: strain,
                                  shapeVariation: shapeVariation, sway: sway)
        direct.advance(to: 0.65)
        precondition(direct.positions == settled && direct.contacts.map { $0?.time } == film.contacts.map { $0?.time },
                     "Direct Reduced Motion evaluation and stepped playback must reach exactly the same result")
        print("PASS seed \(seed), shape \(shapeVariation), inflation/strain \(inflation)/\(strain): SDF residual \(residual), volume error \(maximumVolumeError), footprint radius \(sourceRadius) → \(finalRadius), contact \(contactTimes.min()!)...\(contactTimes.max()!)s")
    }

    static func volumesByOrigin(_ film: GumFragments) -> [Float] {
        var result = Array(repeating: Float(0), count: film.materialOrigins.max()! + 1)
        for index in film.positions.indices { result[film.materialOrigins[index]] += film.materialVolumes[index] }
        return result
    }

    static func checkTearPropagation() {
        var film = GumFragments(variation: 271)
        let sourceCount = film.positions.count
        func separation(_ row: Int, _ film: GumFragments) -> Float {
            guard let pair = film.tearBoundaryPairs.first(where: { film.materialOrigins[$0.x] / 64 == row }) else { return 0 }
            return simd_distance(film.positions[pair.x], film.positions[pair.y])
        }
        film.advance(to: 0.025)
        precondition(separation(1, film) > separation(18, film) * 4,
                     "A small shoulder puncture must lead the advancing tear tip")
        film.advance(to: 0.075)
        precondition(separation(18, film) > 0.005 && film.severedBridgeCount == 0,
                     "The tear must propagate while the two original bands still hold")
        let bandStart = 6 * 64 + 48, bandEnd = 7 * 64 + 48
        let originalWidth = simd_distance(film.sourcePositions[bandStart], film.sourcePositions[bandEnd])
        film.advance(to: 0.08)
        let data = film.surfaceData
        let lip = film.tearBoundaryPairs.first(where: { film.materialOrigins[$0.x] / 64 == 4 })!
        for index in [lip.x, lip.y] {
            let originalThickness = GumSurfaceGeometry.thickness(film.sourcePositions[index], inflation: 1, strain: 1)
            precondition(data.thickness[index] > originalThickness * 3,
                         "Both free lips must gather real material thickness instead of becoming thin invisible bumps")
        }
        let bridgeThickness = GumSurfaceGeometry.thickness(film.sourcePositions[bandStart], inflation: 1, strain: 1)
        precondition(data.thickness[bandStart] < bridgeThickness * 0.75,
                     "The held material bridge must still stretch thin while its free lips gather")
        func project(_ p: SIMD3<Float>) -> SIMD2<Float> {
            let w = 1 - p.z / 4.8
            return SIMD2(p.x / (1.35 * w), (p.y - 0.12) / (2.025 * w))
        }
        let initialProjection = film.sourcePositions.map(project)
        let lower = SIMD2(initialProjection.map(\.x).min()!, initialProjection.map(\.y).min()!)
        let upper = SIMD2(initialProjection.map(\.x).max()!, initialProjection.map(\.y).max()!)
        for row in [6, 12] {
            let relative = (project(film.positions[row * 64 + 48]) - lower) / (upper - lower)
            precondition(relative.x > 0.2 && relative.x < 0.8 && relative.y > 0.2 && relative.y < 0.8,
                         "Before severing, both bridges must remain inside the camera-facing body, away from its outer silhouette")
        }
        film.advance(to: 0.108334)
        let neckWidth = simd_distance(film.positions[bandStart], film.positions[bandEnd])
        precondition(neckWidth < originalWidth * 0.5 && film.positions.count == sourceCount,
                     "The retained bridge must visibly neck before its topology splits")
        film.advance(to: 0.1125)
        precondition(film.severedBridgeCount == 1 && film.positions.count == sourceCount + 2
                     && separation(6, film) < 0.00001,
                     "The first bridge must split at coincident tips without a positional jump")
        film.advance(to: 0.175)
        precondition(film.severedBridgeCount == 2 && film.positions.count == sourceCount + 4
                     && separation(6, film) > 0.04 && separation(12, film) > 0.04,
                     "The two severed ends must retract into their attached lips")
        print("PASS: puncture propagation; bridge width \(originalWidth) → \(neckWidth); four retained boundary tips recoil")
    }

    static func checkProjection(_ positions: [SIMD3<Float>], aspect: Float) {
        let framing = max(Float(1.7), 1.35 / aspect)
        var minimumY = Float.infinity
        var sideOrTopCount = 0
        var bottomCount = 0
        for p in positions {
            let w = 1 - p.z / 4.8
            let x = p.x / (aspect * framing * w)
            let shift = min(1.03 - 1 / framing, 0.88 * (framing - 1.5))
            let y = (p.y - 0.12) / (framing * w) - shift
            minimumY = min(minimumY, y)
            if !(w > 0 && x.isFinite && y.isFinite && abs(x) < 1 && y < 1) { sideOrTopCount += 1 }
            if y <= -1 { bottomCount += 1 }
        }
        // The attachment originates below the display, so its lower material
        // may remain cropped. The broad visible tear must still stay in frame.
        if sideOrTopCount > 0 || bottomCount > positions.count * 3 / 10 || minimumY <= -1.25 {
            print("Projection: aspect \(aspect), lower crop \(bottomCount)/\(positions.count), lowest y \(minimumY), side/top \(sideOrTopCount)")
            preconditionFailure("The visible tear must remain in frame around its offscreen attachment")
        }
    }

    static func checkConnectivity(faces: [SIMD3<Int>], pointCount: Int) {
        var adjacency = Array(repeating: [Int](), count: pointCount)
        for face in faces {
            precondition([face.x, face.y, face.z].allSatisfy { $0 >= 0 && $0 < pointCount }
                         && face.x != face.y && face.x != face.z && face.y != face.z,
                         "Faces must use distinct valid material IDs")
            adjacency[face.x] += [face.y, face.z]
            adjacency[face.y] += [face.x, face.z]
            adjacency[face.z] += [face.x, face.y]
        }
        var reached = Set([0]), queue = [0], cursor = 0
        while cursor < queue.count {
            for next in adjacency[queue[cursor]] where reached.insert(next).inserted { queue.append(next) }
            cursor += 1
        }
        precondition(reached.count == pointCount,
                     "All rendered material must belong to one connected surface, including after the opening")
    }

    static func checkGeometry(_ film: GumFragments) {
        precondition(film.positions.allSatisfy { isFinite($0) && $0.z <= GumFragments.glassZ + 0.000001 },
                     "Material positions must be finite and cannot pass through the glass")
        let data = film.surfaceData
        precondition(data.areas.allSatisfy { $0.isFinite && $0 > 0 }
                     && data.thickness.allSatisfy { $0.isFinite && $0 > 0 }
                     && data.normals.allSatisfy { isFinite($0) && abs(simd_length($0) - 1) < 0.001 },
                     "Folding must preserve usable areas, positive film thickness and unit normals")
    }

    static func checkRenderedVertices(_ film: GumFragments) {
        let vertices = film.vertices
        precondition(vertices.count == film.triangles.count * 3,
                     "The renderer must retain every connected material face through collapse")
        precondition(vertices.allSatisfy {
            isFinite(SIMD3($0.position.x, $0.position.y, $0.position.z)) && $0.position.w == 1
                && $0.normalThickness.w.isFinite && $0.normalThickness.w > 0
                && isFinite(SIMD3($0.source.x, $0.source.y, $0.source.z)) && $0.source.w > 0
                && $0.material.w >= 0 && $0.material.w <= 1
        }, "GPU vertices must keep continuous source attributes and finite local contact data")
    }

    static func footprint(_ positions: [SIMD3<Float>], volumes: [Float]) -> (centre: SIMD2<Float>, radius: Float) {
        let total = volumes.reduce(0, +)
        var centre = SIMD2<Float>.zero
        for index in positions.indices { centre += SIMD2(positions[index].x, positions[index].y) * volumes[index] / total }
        var variance: Float = 0
        for index in positions.indices {
            let offset = SIMD2(positions[index].x, positions[index].y) - centre
            variance += simd_length_squared(offset) * volumes[index] / total
        }
        return (centre, sqrt(variance))
    }

    static func isFinite(_ value: SIMD3<Float>) -> Bool { value.x.isFinite && value.y.isFinite && value.z.isFinite }
}
