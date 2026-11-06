// Copyright 2026 Google LLC
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Metal
import RealityKit
import simd
import ThreeLiveCompiler

enum PrototypeError: Error, LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let reason): reason }
    }
}

@MainActor
final class PrototypeScene {
    let usdzData: Data
    let root: Entity
    let selectable: Entity
    let runtime: XRLiveRealityKitSession
    let environment: EnvironmentResource

    private init(usdzData: Data, root: Entity, selectable: Entity,
                 runtime: XRLiveRealityKitSession, environment: EnvironmentResource) {
        self.usdzData = usdzData
        self.root = root
        self.selectable = selectable
        self.runtime = runtime
        self.environment = environment
    }

    static func load() async throws -> PrototypeScene {
        guard let preset = SampleScenes.threeLivePresets.first(where: { $0.name == "Torus Knot" }) else {
            throw PrototypeError.unavailable("Existing Torus Knot preset missing")
        }
        let glb = try await ThreeCompiler.compileGLB(preset.script)
        let usdz = try await ThreeCompiler.glbToUSDZ(glb)
        let entity = try await RealityKitHelper.loadEntity(fromUSDZ: usdz)
        guard let selectable = entity.findEntity(named: "RubyTorusKnot"),
              let runtime = XRLiveRealityKitSession(glbData: glb, root: entity) else {
            throw PrototypeError.unavailable("Compiled scene lost named object or runtime graph")
        }
        let root = Entity()
        root.addChild(entity)
        root.position = [0, 1.3, -2]
        root.scale = SIMD3(repeating: 0.45)
        runtime.installStudioLights(exposure: 2)
        let environment = try await makeEnvironment()
        return PrototypeScene(usdzData: usdz, root: root, selectable: selectable,
                              runtime: runtime, environment: environment)
    }

    private static func makeEnvironment() async throws -> EnvironmentResource {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: 128, height: 64, bitsPerComponent: 8,
                bytesPerRow: 128 * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: colorSpace,
                colors: [CGColor(gray: 0.12, alpha: 1), CGColor(gray: 0.8, alpha: 1)] as CFArray,
                locations: nil) else {
            throw PrototypeError.unavailable("Could not create studio reflection environment")
        }
        // Broad environment illumination gives metallic surfaces something to reflect between key lights.
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0),
                                   end: CGPoint(x: 0, y: 64), options: [])
        guard let image = context.makeImage() else {
            throw PrototypeError.unavailable("Could not create studio environment image")
        }
        return try await EnvironmentResource(equirectangular: image, options: .init())
    }
}

struct EyeProjection {
    let symmetric: simd_float4x4
    // xy: original off-axis offset, zw: symmetric frustum expansion.
    let crop: SIMD4<Float>
    let backgroundDepth: Double

    init(_ projection: simd_float4x4) {
        let offset = SIMD2(projection.columns.2.x, projection.columns.2.y)
        let extent = SIMD2(1 + abs(offset.x), 1 + abs(offset.y))
        var symmetric = projection
        symmetric.columns.2.x = 0
        symmetric.columns.2.y = 0
        symmetric.columns.0.x /= extent.x
        symmetric.columns.1.y /= extent.y
        self.symmetric = symmetric
        crop = SIMD4(offset.x, offset.y, extent.x, extent.y)
        // shortcut: a 20m camera-space backdrop bounds disparity; use scene geometry for larger environments.
        let background = projection * SIMD4<Float>(0, 0, -20, 1)
        backgroundDepth = Double(max(0, min(1, background.z / background.w)))
    }
}

func rayHitsTriangle(origin: SIMD3<Float>, direction: SIMD3<Float>,
                     a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>) -> Bool {
    let edge1 = b - a, edge2 = c - a
    let p = simd_cross(direction, edge2)
    let determinant = simd_dot(edge1, p)
    guard abs(determinant) > 0.000001 else { return false }
    let t = origin - a
    let u = simd_dot(t, p) / determinant
    guard u >= 0, u <= 1 else { return false }
    let q = simd_cross(t, edge1)
    let v = simd_dot(direction, q) / determinant
    return v >= 0 && u + v <= 1 && simd_dot(edge2, q) / determinant > 0
}

@MainActor
struct DepthMesh {
    let entity: Entity
    let instanceTransform: simd_float4x4
    let positions: [SIMD3<Float>]
    let indices: [UInt32]
    let vertices: MTLBuffer
    let triangles: MTLBuffer

    var worldTransform: simd_float4x4 {
        entity.transformMatrix(relativeTo: nil) * instanceTransform
    }

    static func collect(from entity: Entity, device: MTLDevice) throws -> [DepthMesh] {
        var meshes: [DepthMesh] = []
        if let component = entity.components[ModelComponent.self] {
            let contents = component.mesh.contents
            for instance in contents.instances {
                guard let model = contents.models[instance.model] else { continue }
                for part in model.parts {
                    let positions = part.positions.elements
                    guard let indices = part.triangleIndices?.elements,
                          !positions.isEmpty, !indices.isEmpty,
                          indices.count.isMultiple(of: 3),
                          indices.allSatisfy({ Int($0) < positions.count }),
                          let vertices = device.makeBuffer(bytes: positions,
                              length: positions.count * MemoryLayout<SIMD3<Float>>.stride),
                          let triangles = device.makeBuffer(bytes: indices,
                              length: indices.count * MemoryLayout<UInt32>.stride) else {
                        throw PrototypeError.unavailable("Unsupported or invalid triangle mesh")
                    }
                    meshes.append(DepthMesh(entity: entity, instanceTransform: instance.transform,
                        positions: positions, indices: indices, vertices: vertices, triangles: triangles))
                }
            }
        }
        for child in entity.children {
            meshes += try collect(from: child, device: device)
        }
        return meshes
    }

    func intersects(origin: SIMD3<Float>, direction: SIMD3<Float>) -> Bool {
        let localFromWorld = worldTransform.inverse
        let o = localFromWorld * SIMD4(origin, 1)
        let d = localFromWorld * SIMD4(direction, 0)
        let localOrigin = SIMD3(o.x, o.y, o.z), localDirection = SIMD3(d.x, d.y, d.z)
        return stride(from: 0, to: indices.count, by: 3).contains { index in
            rayHitsTriangle(origin: localOrigin, direction: localDirection,
                a: positions[Int(indices[index])], b: positions[Int(indices[index + 1])],
                c: positions[Int(indices[index + 2])])
        }
    }
}
