// Copyright 2026 Google LLC
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import ImageIO
import Metal
import RealityKit
import ThreeLiveCompiler
import USDKit

@MainActor
func runSelfChecks() async throws {
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw PrototypeError.unavailable(message) }
    }

    let projection = simd_float4x4(columns: (
        SIMD4(1.7, 0, 0, 0), SIMD4(0, 1.7, 0, 0),
        SIMD4(0.2, -0.1, 0.05 / 99.95, -1), SIMD4(0, 0, 5 / 99.95, 0)))
    let eye = EyeProjection(projection)
    for point: SIMD4<Float> in [[0.2, 0.1, -2, 1], [-0.4, -0.2, -1, 1]] {
        let original = projection * point, symmetric = eye.symmetric * point
        let expected = SIMD2((original.x / original.w + eye.crop.x) / eye.crop.z,
                             (original.y / original.w + eye.crop.y) / eye.crop.w)
        try check(simd_length(expected - SIMD2(symmetric.x, symmetric.y) / symmetric.w) < 0.00001,
                  "Off-axis crop does not preserve projection")
    }
    let triangle: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) = ([-1, -1, -2], [1, -1, -2], [0, 1, -2])
    try check(rayHitsTriangle(origin: .zero, direction: [0, 0, -1],
                             a: triangle.0, b: triangle.1, c: triangle.2), "Selection ray missed triangle")
    try check(!rayHitsTriangle(origin: .zero, direction: [0, 0, 1],
                              a: triangle.0, b: triangle.1, c: triangle.2), "Selected behind ray")
    try check(!rayHitsTriangle(origin: [3, 0, 0], direction: [0, 0, -1],
                              a: triangle.0, b: triangle.1, c: triangle.2), "Selection accepted miss")

    let scene = try await PrototypeScene.load()
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw PrototypeError.unavailable("No Metal GPU for offscreen check")
    }
    let meshes = try DepthMesh.collect(from: scene.root, device: device)
    try check(!meshes.isEmpty && meshes.allSatisfy { !$0.indices.isEmpty }, "Depth geometry absent")
    let before = scene.selectable.scale
    try check(scene.runtime.handleTap(on: scene.selectable), "Existing graph did not accept select")
    scene.runtime.step(dt: 0.2)
    scene.runtime.step(dt: 0.2)
    try check(simd_length(scene.selectable.scale - before) > 0.01, "Existing onSelect graph did not scale object")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("scene.usdz")
    try scene.usdzData.write(to: url)
    let stage = try USDStage.open(url)
    try SpatialPreviewPanel.setScale(in: stage, enlarged: true)
    try SpatialPreviewPanel.setScale(in: stage, enlarged: false)

    let renderer = try RealityRenderer()
    let camera = Entity()
    camera.components.set(ProjectiveTransformCameraComponent(projectionMatrix: eye.symmetric))
    camera.position = [0, 1.3, 0]
    renderer.entities.append(camera)
    renderer.entities.append(scene.root)
    renderer.activeCamera = camera
    renderer.lighting.resource = scene.environment
    renderer.lighting.intensityExponent = -1
    renderer.cameraSettings.antialiasing = .multisample4X
    renderer.cameraSettings.colorBackground = .color(CGColor(gray: 0.02, alpha: 1))
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
        width: 128, height: 128, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
    descriptor.storageMode = .shared
    descriptor.pixelFormat = .rgba16Float
    guard let texture = device.makeTexture(descriptor: descriptor), let rendered = device.makeEvent() else {
        throw PrototypeError.unavailable("Could not allocate self-check texture")
    }
    let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
    descriptor.pixelFormat = .bgra8Unorm_srgb
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        do {
            try renderer.updateAndRender(deltaTime: 0, cameraOutput: output,
                whenScheduled: { _ in continuation.resume() },
                actionsAfterRender: [.signal(rendered, value: 1)])
        } catch { continuation.resume(throwing: error) }
    }
    var pixels = [UInt8](repeating: 0, count: 128 * 128 * 4)
    let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
        width: 128, height: 128, mipmapped: false)
    depthDescriptor.usage = [.renderTarget]
    depthDescriptor.storageMode = .private
    guard let target = device.makeTexture(descriptor: descriptor),
          let depth = device.makeTexture(descriptor: depthDescriptor),
          let readback = device.makeBuffer(length: 128 * 128 * MemoryLayout<Float>.stride, options: .storageModeShared),
          let queue = device.makeCommandQueue(), let command = queue.makeCommandBuffer() else {
        throw PrototypeError.unavailable("Could not allocate compositor self-check targets")
    }
    let compositor = try EyeCompositor(device: device, colorFormat: .bgra8Unorm_srgb, depthFormat: .depth32Float)
    command.encodeWaitForEvent(rendered, value: 1)
    try compositor.encode(command: command, texture: texture, target: target, depthTarget: depth,
        viewport: MTLViewport(originX: 0, originY: 0, width: 128, height: 128, znear: 0, zfar: 1),
        crop: eye.crop, meshes: meshes,
        viewProjection: projection * camera.transformMatrix(relativeTo: nil).inverse,
        backgroundDepth: eye.backgroundDepth)
    guard let blit = command.makeBlitCommandEncoder() else {
        throw PrototypeError.unavailable("Could not encode depth readback")
    }
    blit.copy(from: depth, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
        sourceSize: MTLSize(width: 128, height: 128, depth: 1), to: readback, destinationOffset: 0,
        destinationBytesPerRow: 128 * 4, destinationBytesPerImage: 128 * 128 * 4)
    blit.endEncoding()
    await withCheckedContinuation { continuation in
        command.addCompletedHandler { _ in continuation.resume() }
        command.commit()
    }
    if let error = command.error { throw error }
    let depths = UnsafeBufferPointer(start: readback.contents().assumingMemoryBound(to: Float.self), count: 128 * 128)
    try check(eye.backgroundDepth > 0 && eye.backgroundDepth < 1, "Backdrop must have finite valid depth")
    let covered = depths.filter { $0 > Float(eye.backgroundDepth) + 0.00001 && $0 <= 1 }.count
    try check(covered > 50 && covered < 128 * 128, "Compositor depth pass has no valid geometry/background")
    target.getBytes(&pixels, bytesPerRow: 128 * 4, from: MTLRegionMake2D(0, 0, 128, 128), mipmapLevel: 0)
    let varied = stride(from: 0, to: pixels.count, by: 4).filter {
        abs(Int(pixels[$0]) - Int(pixels[0])) + abs(Int(pixels[$0 + 1]) - Int(pixels[1]))
            + abs(Int(pixels[$0 + 2]) - Int(pixels[2])) > 12
    }.count
    try check(varied > 50, "RealityRenderer produced no visible offscreen geometry")
    let colorMask = (0..<128 * 128).map { index in
        (0..<3).contains { abs(Int(pixels[index * 4 + $0]) - Int(pixels[$0])) > 3 }
    }
    let colored = colorMask.filter { $0 }.count
    let unmatched = colorMask.indices.filter { index in
        guard colorMask[index] else { return false }
        let x = index % 128, y = index / 128
        // Allow two texels for color filtering at 128px; this is a coarse overlap check.
        return !(max(0, y - 2)...min(127, y + 2)).contains { row in
            (max(0, x - 2)...min(127, x + 2)).contains { depths[row * 128 + $0] > Float(eye.backgroundDepth) + 0.00001 }
        }
    }.count
    try check(colored > 50, "Compositor color pass has no visible geometry")
    let outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/remote-immersive")
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    func savePNG(_ bytes: [UInt8], name: String) throws {
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: 128, height: 128, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 512, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                .union(.byteOrder32Little), provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(outputDirectory.appendingPathComponent(name) as CFURL,
            "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        try check(CGImageDestinationFinalize(destination), "Could not save GPU verification image")
    }
    try savePNG(pixels, name: "self-check.png")
    let overlay: [UInt8] = colorMask.indices.flatMap { index in
        let depth = depths[index] > Float(eye.backgroundDepth) + 0.00001
        return [colorMask[index] && !depth ? 255 : 0, colorMask[index] && depth ? 255 : 0,
                depth && !colorMask[index] ? 255 : 0, 255].map(UInt8.init)
    }
    try savePNG(overlay, name: "self-check-depth-overlay.png")
    try check(unmatched * 100 < colored * 5, "Compositor color/depth silhouettes disagree: \(unmatched)/\(colored)")
    print("GPU: \(varied) RealityRenderer pixels; \(covered) depth pixels; \(unmatched)/\(colored) color/depth mismatches")
}
