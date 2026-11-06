import simd

/// One material sheet sampled from the inflated surface. A local seam unzips
/// around two retained bridges; their severed ends stay attached to the pouch.
/// Deformation is reference-directed, not a calibrated fracture simulation.
struct GumFragments {
    struct Vertex {
        var position: SIMD4<Float>
        var normalThickness: SIMD4<Float>
        var material: SIMD4<Float>
        var source: SIMD4<Float>
    }
    struct Contact {
        let time: Float
        let position: SIMD3<Float>
        let velocity: SIMD3<Float>
    }
    static let glassZ: Float = GumSurfaceGeometry.glassZ
    private let rings = 49, columns = 64
    private let step: Float = 1 / 240
    private let seed: Float
    private let pole: SIMD3<Float>
    private let tangent: SIMD3<Float>
    private let bitangent: SIMD3<Float>
    private let radii: SIMD3<Float>
    private let centre: SIMD3<Float>
    private(set) var sourcePositions: [SIMD3<Float>] = []
    private(set) var positions: [SIMD3<Float>] = []
    private(set) var contacts: [Contact?] = []
    private(set) var triangles: [SIMD3<Int>] = []
    private(set) var materialVolumes: [Float] = []
    /// Boundary duplicates keep the identity of the original material point.
    private(set) var materialOrigins: [Int] = []
    private(set) var tearBoundaryPairs: [SIMD2<Int>] = []
    private(set) var severedBridgeCount = 0
    private(set) var time: Float = 0
    private var directions: [SIMD3<Float>] = []
    private var coordinates: [SIMD2<Float>] = []
    private var initialThickness: [Float] = []
    private let tearColumn = 48, tearLastRow = 19
    private let bridgeRows = [6...7, 12...13]
    private let bridgeBreakTimes: [Float] = [0.1125, 0.1375]
    private var seamSides: [Float] = []
    private var tick = 0

    init(variation: UInt32 = 0, inflation: Float = 1, strain: Float = 1,
         shapeVariation: Float = 0, sway: Float = 0) {
        seed = Float(variation % 65536) * 0.0137
        // Randomness changes the release shoulder and folds, not landing targets.
        pole = simd_normalize(SIMD3(0.24 + 0.10 * sin(seed), 0.38 + 0.07 * cos(seed * 1.7), 1))
        tangent = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), pole))
        bitangent = simd_cross(pole, tangent)
        let radius = 0.29 + 0.83 * inflation
        radii = SIMD3(1.03, 1, 0.87) * radius
        centre = GumSurfaceGeometry.centre(inflation: inflation, variation: shapeVariation, sway: sway)
        for row in 0..<rings {
            let u = Float(row) / Float(rings - 1)
            let theta = 0.002 + u * (.pi - 0.004)
            for column in 0..<columns {
                let v = Float(column) / Float(columns)
                let phi = v * 2 * .pi
                let direction = pole * cos(theta)
                    + (tangent * cos(phi) + bitangent * sin(phi)) * sin(theta)
                let source = GumSurfaceGeometry.point(direction: direction, inflation: inflation,
                                                      strain: strain, variation: shapeVariation, sway: sway)
                directions.append(direction); coordinates.append(SIMD2(u, v))
                materialOrigins.append(sourcePositions.count); seamSides.append(1)
                sourcePositions.append(source)
                initialThickness.append(GumSurfaceGeometry.thickness(source, inflation: inflation,
                                                                     strain: strain, variation: shapeVariation, sway: sway))
            }
        }
        for row in 0..<(rings - 1) {
            for column in 0..<columns {
                let next = (column + 1) % columns
                let a = row * columns + column, b = row * columns + next
                let c = (row + 1) * columns + column, d = (row + 1) * columns + next
                triangles += [SIMD3(a, c, b), SIMD3(b, c, d)]
            }
        }
        positions = sourcePositions
        contacts = Array(repeating: nil, count: positions.count)
        // Coincident seam boundaries leave the initial surface unchanged. Only
        // the two original narrow bands still span the opening as it propagates.
        for row in 0...tearLastRow where !bridgeRows.contains(where: { $0.contains(row) }) {
            splitSeam(row: row)
        }
        distributeRestVolume()
    }

    private mutating func splitSeam(row: Int) {
        let original = row * columns + tearColumn, duplicate = positions.count
        sourcePositions.append(sourcePositions[original]); positions.append(positions[original])
        directions.append(directions[original]); coordinates.append(coordinates[original])
        initialThickness.append(initialThickness[original]); contacts.append(contacts[original])
        materialOrigins.append(original); seamSides.append(-1)
        tearBoundaryPairs.append(SIMD2(original, duplicate))
        // Split shared boundary vertices, never delete material faces. The
        // original rest-face areas assign each half its own conserved volume.
        for band in max(0, row - 1)...min(row, rings - 2) {
            let first = (band * columns + tearColumn - 1) * 2
            for face in first...(first + 1) {
                for corner in 0..<3 where triangles[face][corner] == original {
                    triangles[face][corner] = duplicate
                }
            }
        }
    }

    private mutating func distributeRestVolume() {
        materialVolumes = Array(repeating: 0, count: positions.count)
        for face in triangles {
            let area = simd_length(simd_cross(sourcePositions[face.y] - sourcePositions[face.x],
                                              sourcePositions[face.z] - sourcePositions[face.x])) * 0.5
            for index in [face.x, face.y, face.z] {
                materialVolumes[index] += area * initialThickness[index] / 3
            }
        }
    }

    private func smooth(_ a: Float, _ b: Float, _ value: Float) -> Float {
        let t = min(max((value - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private func freePosition(_ index: Int, at t: Float) -> SIMD3<Float> {
        let p = freePositionWithoutNeck(index, at: t)
        let origin = materialOrigins[index], row = origin / columns
        guard let bridge = bridgeRows.firstIndex(where: { $0.contains(row) }) else { return p }
        let oppositeRow = bridgeRows[bridge].lowerBound + bridgeRows[bridge].upperBound - row
        let oppositeOrigin = oppositeRow * columns + origin % columns
        let opposite = seamSides[index] < 0
            ? tearBoundaryPairs.first(where: { $0.x == oppositeOrigin })!.y : oppositeOrigin
        let middle = (p + freePositionWithoutNeck(opposite, at: t)) * 0.5
        let angle = (coordinates[index].y - Float(tearColumn) / Float(columns)) * 2 * .pi
        let lip = exp(-pow(abs(atan2(sin(angle), cos(angle))) / 0.36, 2))
        let breaking = bridgeBreakTimes[bridge]
        let released = smooth(breaking, breaking + 0.035, t)
        let neck = smooth(breaking - 0.075, breaking, t) * (1 - released * 0.72)
        // Compress the current band width, rather than subtracting a rest-space
        // offset that could invert its row order as the membrane folds.
        return p + (middle - p) * neck * lip * 0.78
    }

    private func freePositionWithoutNeck(_ index: Int, at t: Float) -> SIMD3<Float> {
        let p = freePositionWithoutGatheredLip(index, at: t)
        let origin = materialOrigins[index], row = origin / columns
        guard row <= tearLastRow else { return p }
        let phi = (coordinates[index].y - Float(tearColumn) / Float(columns)) * 2 * .pi
        let distance = atan2(sin(phi), cos(phi))
        guard abs(distance) < 0.45 else { return p }
        let seamOrigin = row * columns + tearColumn
        let boundary = distance < -0.0001 || (abs(distance) < 0.0001 && seamSides[index] < 0)
            ? tearBoundaryPairs.first(where: { $0.x == seamOrigin })?.y ?? seamOrigin : seamOrigin
        let u = coordinates[index].x, end = Float(tearLastRow + 1) / Float(rings - 1)
        var gathered = smooth(0.004 + 0.12 * u, 0.042 + 0.12 * u, t)
            * (1 - smooth(end - 0.10, end, u))
        if let bridge = bridgeRows.firstIndex(where: { $0.contains(row) }) {
            gathered *= smooth(bridgeBreakTimes[bridge], bridgeBreakTimes[bridge] + 0.035, t)
        }
        // Gather the adjacent original material into each free lip. A mere
        // outward bump stretches and thins this band; transverse compression
        // genuinely increases its conserved thickness and gives it a rolled edge.
        let concentration = 0.90 * (1 - smooth(0.20, 0.45, abs(distance))) * gathered
        let edge = freePositionWithoutGatheredLip(boundary, at: t)
        return p + (edge - p) * concentration
    }

    private func freePositionWithoutGatheredLip(_ index: Int, at t: Float) -> SIMD3<Float> {
        let uv = coordinates[index], u = uv.x, phi = uv.y * 2 * .pi
        let seamAngle = Float(tearColumn) / Float(columns) * 2 * .pi
        let angularDistance = atan2(sin(phi - seamAngle), cos(phi - seamAngle))
        // One shoulder releases first. The far side holds briefly, so the
        // expanding puncture rolls an uneven lip instead of opening a ring.
        let releaseDelay = 0.004 + 0.046 * (1 - cos(angularDistance)) * 0.5 + 0.020 * u
        let puncture = smooth(releaseDelay, releaseDelay + 0.036, t)
        // Let the front-facing bridges neck before the bulk pouch rolls away.
        let open = smooth(releaseDelay + 0.080, releaseDelay + 0.190, t)
        let collapse = smooth(0.045, 0.205, t)
        let theta = 0.002 + u * (.pi - 0.004)
        // The free edge gathers the same material instead of erasing screen
        // holes. Uneven release retains a broad lower pouch as in the reference.
        let bias = 1 + 0.29 * sin(phi + seed) + 0.10 * cos(phi * 2 - 0.8)
        let releasedRoot = smooth(0.045, 0.175, t)
        // The retained attachment rolls into the same fold as it releases.
        // Its narrow opening stays oblique rather than becoming a circular ring.
        let angle = theta + (0.22 * puncture + 1.70 * open) * pow(1 - u, 1.45) * bias
            - releasedRoot * 0.57 * pow(u, 3) * (0.72 + 0.28 * sin(phi - 0.4))
        let longitude = phi + collapse * 0.20 * sin(phi + u * 4 + seed)
        let direction = pole * cos(angle)
            + (tangent * cos(longitude) + bitangent * sin(longitude)) * sin(angle)
        var p = sourcePositions[index] + (direction - directions[index]) * radii
        let end = Float(tearLastRow + 1) / Float(rings - 1)
        let tearFront = smooth(0.004 + 0.12 * u, 0.042 + 0.12 * u, t)
        let side = abs(angularDistance) < 0.0001 ? seamSides[index]
            : (angularDistance < 0 ? Float(-1) : Float(1))
        let lip = exp(-pow(abs(angularDistance) / 0.36, 2))
        let tip = 1 - smooth(end - 0.10, end, u)
        let crossSeam = -tangent * sin(seamAngle) + bitangent * cos(seamAngle)
        var gap = 0.17 * tearFront * tip * lip
        var edgeRelease: Float = 1
        let row = materialOrigins[index] / columns
        if let bridge = bridgeRows.firstIndex(where: { $0.contains(row) }) {
            let breaking = bridgeBreakTimes[bridge]
            let released = smooth(breaking, breaking + 0.035, t)
            if abs(angularDistance) < 0.0001 { gap *= released; edgeRelease = released }
        }
        p += crossSeam * gap * side
        // The material immediately beside the cut rolls back on itself. Real
        // geometry changes its normals and dual-area thickness at the free lip.
        let lipRoll = tearFront * tip * exp(-pow(abs(angularDistance) / 0.18, 2))
        p += (direction * (0.045 + 0.008 * sin(u * 37 + seed))
            - crossSeam * side * edgeRelease * 0.018) * lipRoll
        let fold = sin(phi * 3 + u * 7 + seed) + 0.38 * sin(phi * 7 - u * 11 + 1.2)
        let edge = pow(1 - u, 2)
        let gather = smooth(0.035, 0.23, t)
        p.x = centre.x + (p.x - centre.x) * (1 - gather * 0.56)
            + collapse * (0.065 * fold * edge + 0.10 * sin(u * 8 + phi + seed))
        p.y = -0.80 + (p.y + 0.80) * (1 - gather * 0.34)
            + collapse * (0.08 * fold * edge + 0.10 * sin(phi * 2 - u * 5))
        p.z *= 1 - collapse * 0.73
        p.z += collapse * 0.17 * fold * sin(u * .pi)
        // The video has no glass: this short forward travel is the adaptation.
        p.z += smooth(0.055, 0.225, t) * (Self.glassZ + 0.36)
        // The last loose folds follow their already adhered neighbours into
        // contact, instead of freezing as an unsupported pocket in mid-air.
        p.z += (Self.glassZ + 0.02 - p.z) * smooth(0.205, 0.29, t)
        return p
    }

    private func adheredPosition(_ contact: Contact, at t: Float) -> SIMD3<Float> {
        let age = min(max(t - contact.time, 0), 0.14)
        let settle = smooth(0, 0.14, age)
        let tangentTravel = SIMD2(contact.velocity.x, contact.velocity.y) * 0.0045 * settle
        let local = SIMD2(contact.position.x - centre.x, contact.position.y + 0.49)
        // Normal impact drives a soft local squeeze; adhesion then arrests motion.
        let pressure = min(max(contact.velocity.z / 14, 0), 1)
        let spread = local * (0.10 + pressure * 0.06) * settle
        let rawX = contact.position.x + tangentTravel.x + spread.x
        let overflow = max(abs(rawX) - 0.94, 0)
        let x = (rawX < 0 ? -1 : Float(1)) *
            (min(abs(rawX), 0.94) + overflow / (1 + overflow / 0.06))
        return SIMD3(x,
                     contact.position.y + tangentTravel.y + spread.y, Self.glassZ)
    }

    mutating func advance(to target: Float) {
        let finalTick = Int((min(max(target, 0), 0.65) / step + 0.0001).rounded(.down))
        while tick < finalTick {
            tick += 1
            let t = Float(tick) * step
            if severedBridgeCount < bridgeRows.count && t >= bridgeBreakTimes[severedBridgeCount] {
                for row in bridgeRows[severedBridgeCount] { splitSeam(row: row) }
                severedBridgeCount += 1
                distributeRestVolume()
            }
            for index in positions.indices {
                if let contact = contacts[index] {
                    positions[index] = adheredPosition(contact, at: t)
                    continue
                }
                let next = freePosition(index, at: t)
                if next.z >= Self.glassZ {
                    let origin = materialOrigins[index], row = origin / columns
                    let seam = (coordinates[index].y - Float(tearColumn) / Float(columns)) * 2 * .pi
                    let nearTear = row <= tearLastRow && abs(atan2(sin(seam), cos(seam))) < 0.48
                    // The freshly ruptured wet film can slide and gather along
                    // glass before adhesion arrests it. This retains the lips
                    // when the intact dome first touches the pane.
                    if t < 0.07 || (nearTear && t < 0.17) {
                        positions[index] = SIMD3(next.x, next.y, Self.glassZ - 0.00001)
                        continue
                    }
                    let previous = positions[index]
                    let fraction = min(max((Self.glassZ - previous.z) / max(next.z - previous.z, 0.00001), 0), 1)
                    var hit = previous + (next - previous) * fraction
                    hit.z = Self.glassZ
                    let contact = Contact(time: t - step * (1 - fraction), position: hit,
                                          velocity: (next - previous) / step)
                    contacts[index] = contact
                    positions[index] = adheredPosition(contact, at: t)
                } else { positions[index] = next }
            }
        }
        time = Float(tick) * step
    }

    var contactFraction: Float { Float(contacts.compactMap { $0 }.count) / Float(positions.count) }
    var restVolume: Float { materialVolumes.reduce(0, +) }

    /// Dual areas conserve total material volume as the wall stretches or folds.
    var surfaceData: (normals: [SIMD3<Float>], areas: [Float], thickness: [Float]) {
        var normals = Array(repeating: SIMD3<Float>.zero, count: positions.count)
        var areas = Array(repeating: Float(0), count: positions.count)
        for face in triangles {
            let normal = simd_cross(positions[face.y] - positions[face.x], positions[face.z] - positions[face.x])
            let area = simd_length(normal) / 6
            for index in [face.x, face.y, face.z] { normals[index] += normal; areas[index] += area }
        }
        let thickness = positions.indices.map { materialVolumes[$0] / max(areas[$0], 1e-12) }
        normals = normals.map { simd_length_squared($0) > 1e-16 ? simd_normalize($0) : SIMD3(0, 0, 1) }
        return (normals, areas, thickness)
    }

    var vertices: [Vertex] {
        let data = surfaceData
        let order = triangles.sorted {
            positions[$0.x].z + positions[$0.y].z + positions[$0.z].z
                < positions[$1.x].z + positions[$1.y].z + positions[$1.z].z
        }
        var result: [Vertex] = []
        result.reserveCapacity(order.count * 3)
        for face in order {
            for index in [face.x, face.y, face.z] {
                let contact = contacts[index].map { smooth(0, 0.06, time - $0.time) } ?? 0
                result.append(Vertex(position: SIMD4(positions[index], 1),
                    normalThickness: SIMD4(data.normals[index], data.thickness[index]),
                    material: SIMD4(coordinates[index].x, coordinates[index].y, seed, contact),
                    source: SIMD4(sourcePositions[index], initialThickness[index])))
            }
        }
        return result
    }
}
