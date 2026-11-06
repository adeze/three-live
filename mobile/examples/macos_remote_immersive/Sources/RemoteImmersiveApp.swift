// Copyright 2026 Google LLC
// SPDX-License-Identifier: Apache-2.0

import AppKit
import ARKit
import CompositorServices
import Observation
import OSLog
import SwiftUI
import ThreeLiveCompiler

@MainActor @Observable
final class PrototypeModel {
    var scene: PrototypeScene?
    var status = "Compiling Torus Knot…"
    var isOpening = false
    var isImmersive = false
    var submittedFrames = 0
    var selections = 0
    var trackedHead: SIMD3<Float>?

    func prepare() async {
        do {
            scene = try await PrototypeScene.load()
            status = "Torus Knot ready"
        } catch {
            status = "Scene failed: \(error.localizedDescription)"
        }
    }
}

struct RemoteImmersiveApp: App {
    @State private var model = PrototypeModel()

    var body: some Scene {
        WindowGroup("Three Live · Vision Pro") {
            PrototypeWindow(model: model)
                .task { if model.scene == nil { await model.prepare() } }
        }
        .defaultSize(width: 580, height: 560)

        RemoteImmersiveSpace(id: "three-live-remote") {
            RemoteContent(model: model)
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}

private struct PrototypeWindow: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Bindable var model: PrototypeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Three Live → Vision Pro").font(.title)
            Text("macOS 27 / visionOS 27 · existing Torus Knot scene")
                .foregroundStyle(.secondary)
            Text(model.status).textSelection(.enabled)
            GroupBox("Mac-rendered immersion") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("RealityRenderer color + mesh depth → RemoteImmersiveSpace")
                    HStack {
                        Button("Open immersive view") {
                            model.isOpening = true
                            model.status = "Requesting remote immersive space…"
                            Task {
                                defer { model.isOpening = false }
                                switch await openImmersiveSpace(id: "three-live-remote") {
                                case .opened:
                                    model.isImmersive = true
                                case .userCancelled:
                                    model.status = "Connection cancelled"
                                case .error:
                                    model.status = "Could not open remote immersive space"
                                @unknown default:
                                    model.status = "Unknown remote-space result"
                                }
                            }
                        }
                        .disabled(model.scene == nil || model.isOpening || model.isImmersive)
                        Button("Close") {
                            Task { await dismissImmersiveSpace() }
                        }.disabled(!model.isImmersive && !model.isOpening)
                    }
                    Text("Look at the knot and pinch to toggle its scale.")
                    Text("Submitted frames: \(model.submittedFrames) · selections: \(model.selections)")
                        .monospacedDigit()
                    if let head = model.trackedHead {
                        Text(String(format: "Head: %.2f, %.2f, %.2f m", head.x, head.y, head.z))
                            .monospaced()
                    } else {
                        Text("No tracked headset pose received")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            if let scene = model.scene {
                SpatialPreviewPanel(usdzData: scene.usdzData)
            }
            Spacer(minLength: 0)
        }.padding(24)
    }
}

private struct RemoteContent: CompositorContent {
    @Environment(\.remoteDeviceIdentifier) private var device
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    var model: PrototypeModel

    var body: some CompositorContent {
        CompositorLayer(configuration: PrototypeLayerConfiguration()) { @MainActor layer in
            guard let device, let scene = model.scene else {
                model.status = "Remote device or compiled scene unavailable"
                return
            }
            Task { @MainActor in
                do {
                    let renderer = try RemoteRenderer(layer: layer, scene: scene, model: model)
                    await renderer.run(session: ARKitSession(device: device))
                } catch {
                    model.status = "Renderer failed: \(error.localizedDescription)"
                }
                if layer.state != .invalidated { await dismissImmersiveSpace() }
            }
        }
    }
}

private struct PrototypeLayerConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        // RealityRenderer has no rasterization-rate-map input or stereo output.
        configuration.isFoveationEnabled = false
        if capabilities.supportedLayouts(options: []).contains(.dedicated) {
            configuration.layout = .dedicated
        }
        // Remote devices reject near planes below their negotiated minimum before our renderer starts.
        configuration.defaultDepthRange.y = max(configuration.defaultDepthRange.y,
                                                capabilities.supportedMinimumNearPlaneDistance)
        let near = configuration.defaultDepthRange.y
        let color = configuration.colorFormat.rawValue
        let depth = configuration.depthFormat.rawValue
        Logger(subsystem: "com.google.threelive.remoteimmersive", category: "Compositor")
            .notice("Near plane: \(near); minimum: \(capabilities.supportedMinimumNearPlaneDistance); color: \(color); depth: \(depth)")
    }
}

@main
enum PrototypeMain {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--self-check") {
            do {
                try await runSelfChecks()
                print("PASS: projection, selection, compiler and offscreen GPU checks")
            } catch {
                print("FAIL: \(error)")
                exit(1)
            }
        } else {
            RemoteImmersiveApp.main()
        }
    }
}
