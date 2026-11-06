// Copyright 2026 Google LLC
// SPDX-License-Identifier: Apache-2.0

import ARKit
import CompositorServices
import Metal
import RealityKit
import SwiftUI
import ThreeLiveCompiler

@MainActor
final class RemoteRenderer {
    let layer: LayerRenderer
    let scene: PrototypeScene
    let model: PrototypeModel
    let renderer: RealityRenderer
    let camera = Entity()
    let queue: MTLCommandQueue
    let renderFinished: MTLEvent
    let compositeFinished: MTLEvent
    let meshes: [DepthMesh]
    let compositor: EyeCompositor
    let worldTracking = WorldTrackingProvider()
    var eyeTextures: [String: MTLTexture] = [:]
    var lastPresentationTime: TimeInterval?
    var pendingRay: (origin: SIMD3<Float>, direction: SIMD3<Float>)?
    var sequence: UInt64 = 0
    var compositeSequence: UInt64 = 0
    var gpuFailure: String?

    init(layer: LayerRenderer, scene: PrototypeScene, model: PrototypeModel) throws {
        guard layer.configuration.layout == .dedicated,
              !layer.configuration.isFoveationEnabled,
              let queue = layer.device.makeCommandQueue(),
              let renderFinished = layer.device.makeEvent(),
              let compositeFinished = layer.device.makeEvent() else {
            throw PrototypeError.unavailable("Dedicated, non-foveated compositor targets required")
        }
        self.layer = layer
        self.scene = scene
        self.model = model
        self.queue = queue
        self.renderFinished = renderFinished
        self.compositeFinished = compositeFinished
        renderer = try RealityRenderer()
        meshes = try DepthMesh.collect(from: scene.root, device: layer.device)
        guard !meshes.isEmpty else { throw PrototypeError.unavailable("Scene has no depth geometry") }
        compositor = try EyeCompositor(device: layer.device,
            colorFormat: layer.configuration.colorFormat, depthFormat: layer.configuration.depthFormat)
        renderer.entities.append(scene.root)
        renderer.entities.append(camera)
        renderer.activeCamera = camera
        renderer.lighting.resource = scene.environment
        renderer.lighting.intensityExponent = -1
        renderer.cameraSettings.antialiasing = .multisample4X
        renderer.cameraSettings.colorBackground = .color(CGColor(gray: 0.025, alpha: 1))
    }

    func run(session: ARKitSession) async {
        defer {
            session.stop()
            layer.onSpatialEvent = { _ in }
            model.isImmersive = false
            model.trackedHead = nil
        }
        do {
            guard WorldTrackingProvider.isSupported else {
                throw PrototypeError.unavailable("Remote world tracking unavailable")
            }
            try await session.run([worldTracking])
            layer.onSpatialEvent = { [weak self] events in
                guard let self else { return }
                for event in events where event.phase == .ended && event.kind == .indirectPinch {
                    guard let ray = event.selectionRay else { continue }
                    let origin = SIMD3<Float>(Float(ray.origin.x), Float(ray.origin.y), Float(ray.origin.z))
                    let direction = SIMD3<Float>(Float(ray.direction.x), Float(ray.direction.y), Float(ray.direction.z))
                    // shortcut: retain one completed pinch per frame; queue input for faster interactions.
                    self.pendingRay = (origin, direction)
                }
            }
            model.status = "Waiting for remote compositor and tracked pose"
            while !Task.isCancelled && layer.state != .invalidated {
                if let gpuFailure { throw PrototypeError.unavailable(gpuFailure) }
                if layer.state != .running {
                    try await Task.sleep(for: .milliseconds(50))
                    continue
                }
                guard let frame = layer.queryNextFrame() else {
                    try await Task.sleep(for: .milliseconds(1))
                    continue
                }
                frame.startUpdate()
                frame.endUpdate()
                guard let timing = frame.predictTiming() else { continue }
                let delay = LayerRenderer.Clock().now.duration(to: timing.optimalInputTime)
                if delay > .zero { try await Task.sleep(for: delay) }
                let drawables = frame.queryDrawables()
                // An empty drawable list cancels the frame; the SDK forbids accessing it again.
                guard !drawables.isEmpty else { continue }
                frame.startSubmission()
                do {
                    var commands: [MTLCommandBuffer] = []
                    let reuseAfter = compositeSequence
                    for drawable in drawables {
                        if let command = try await render(drawable, reuseAfter: reuseAfter) { commands.append(command) }
                    }
                    // endSubmission measures CPU encoding, not GPU execution.
                    frame.endSubmission()
                    for command in commands { command.commit() }
                } catch {
                    frame.endSubmission()
                    throw error
                }
            }
            model.status = "Remote immersive space closed"
        } catch {
            model.status = "Immersive rendering stopped: \(error.localizedDescription)"
        }
    }

    private func render(_ drawable: LayerRenderer.Drawable, reuseAfter: UInt64) async throws -> MTLCommandBuffer? {
        let duration = LayerRenderer.Clock.Instant.epoch.duration(to: drawable.frameTiming.presentationTime)
        let components = duration.components
        let timestamp = Double(components.seconds) + Double(components.attoseconds) / 1e18
        guard let anchor = worldTracking.queryDeviceAnchor(atTimestamp: timestamp), anchor.isTracked else {
            model.trackedHead = nil
            return nil
        }
        drawable.deviceAnchor = anchor
        let head = anchor.originFromAnchorTransform
        model.trackedHead = SIMD3(head.columns.3.x, head.columns.3.y, head.columns.3.z)
        scene.runtime.headPoseProvider = { XRPose(matrix: head) }
        let dt = lastPresentationTime.map { min(max(timestamp - $0, 0), 0.1) } ?? 0
        lastPresentationTime = timestamp
        if let ray = pendingRay {
            pendingRay = nil
            if meshes.contains(where: { $0.intersects(origin: ray.origin, direction: ray.direction) }),
               scene.runtime.handleTap(on: scene.selectable) {
                model.selections += 1
            }
        }
        scene.runtime.step(dt: dt)

        guard let command = queue.makeCommandBuffer() else {
            throw PrototypeError.unavailable("Could not allocate compositor command buffer")
        }
        // Scheduling snapshots camera state; GPU events order rendering, sampling and texture reuse.
        for (index, view) in drawable.views.enumerated() {
            let projection = drawable.computeProjection(viewIndex: index)
            let eyeProjection = EyeProjection(projection)
            let worldFromEye = head * view.transform
            camera.setTransformMatrix(worldFromEye, relativeTo: nil)
            camera.components.set(ProjectiveTransformCameraComponent(projectionMatrix: eyeProjection.symmetric))
            let target = drawable.colorTextures[view.textureMap.textureIndex]
            let texture = try eyeTexture(key: "\(drawable.target):\(index)", matching: target)
            let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
            sequence += 1
            let rendered = sequence
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                do {
                    try renderer.updateAndRender(deltaTime: index == 0 ? dt : 0, cameraOutput: output,
                        whenScheduled: { _ in continuation.resume() },
                        actionsBeforeRender: [.wait(for: compositeFinished, value: reuseAfter)],
                        actionsAfterRender: [.signal(renderFinished, value: rendered)])
                } catch { continuation.resume(throwing: error) }
            }
            command.encodeWaitForEvent(renderFinished, value: rendered)
            try compositor.encode(command: command, texture: texture, target: target,
                depthTarget: drawable.depthTextures[view.textureMap.textureIndex],
                viewport: view.textureMap.viewport, crop: eyeProjection.crop, meshes: meshes,
                viewProjection: projection * worldFromEye.inverse, backgroundDepth: eyeProjection.backgroundDepth)
        }
        compositeSequence += 1
        command.encodeSignalEvent(compositeFinished, value: compositeSequence)
        drawable.encodePresent(commandBuffer: command)
        command.addCompletedHandler { [weak self] completed in
            if let error = completed.error {
                let message = error.localizedDescription
                Task { @MainActor in
                    self?.gpuFailure = "GPU submission failed: \(message)"
                    self?.model.status = "GPU submission failed: \(message)"
                }
            }
        }
        model.submittedFrames += 1
        model.status = "Submitting tracked stereo frames"
        return command
    }

    private func eyeTexture(key: String, matching target: MTLTexture) throws -> MTLTexture {
        if let texture = eyeTextures[key], texture.width == target.width, texture.height == target.height {
            return texture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
            width: target.width, height: target.height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = layer.device.makeTexture(descriptor: descriptor) else {
            throw PrototypeError.unavailable("Could not allocate eye color texture")
        }
        eyeTextures[key] = texture
        return texture
    }

}
