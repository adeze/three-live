// Copyright 2026 Google LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import OSLog
import SpatialPreview
import SwiftUI
import USDKit

@MainActor
struct SpatialPreviewPanel: View {
    let usdzData: Data
    @State private var endpointObserver = ConnectedSpatialEndpointObserver()
    @State private var session: USDPreviewSession?
    @State private var stage: USDStage?
    @State private var temporaryDirectory: URL?
    @State private var showingPicker = false
    @State private var busy = false
    @State private var closing = false
    @State private var attempt = UUID()
    @State private var startTask: Task<Void, Never>?
    @State private var progress = 0.0
    @State private var phase = "No active preview"
    @State private var enlarged = false
    @State private var errorMessage: String?
    private static let logger = Logger(subsystem: "com.google.threelive.remoteimmersive", category: "SpatialPreview")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spatial Preview (visionOS 27)").font(.headline)
            Text("Quick Look renders the USD scene on Vision Pro. Three Live behaviors do not run here.")
                .font(.caption)
            HStack {
                Button("Preview on Vision Pro") { startTask = Task { await chooseEndpoint() } }
                    .disabled(busy || closing || session != nil)
                Button(enlarged ? "Restore scale" : "Enlarge live") {
                    guard let stage else { return }
                    do {
                        try Self.setScale(in: stage, enlarged: !enlarged)
                        enlarged.toggle()
                    } catch { errorMessage = error.localizedDescription }
                }
                .disabled(busy || session?.state != .connected)
                Button(busy ? "Cancel preview" : "Close preview") { Task { await closePreview() } }
                    .disabled(closing || (!busy && session == nil))
            }
            Text(status).font(.caption)
            if session != nil { ProgressView(value: progress).accessibilityLabel("USD sharing progress") }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled) }
        }
        .sheet(isPresented: $showingPicker) {
            SpatialPreviewDevicePicker(isPresented: $showingPicker) { endpoint in
                showingPicker = false
                startTask = Task { await start(endpoint: endpoint) }
            }
        }
        .task(id: session.map { ObjectIdentifier($0) }) {
            guard let observed = session else { return }
            for await (state, fraction) in Observations({ (observed.state, observed.progress.fractionCompleted) }) {
                guard session === observed else { break }
                progress = fraction
                Self.logger.info("Session state: \(String(describing: state), privacy: .public); progress: \(fraction)")
                if state.isInvalidated {
                    attempt = UUID(); startTask?.cancel(); busy = false; closing = false
                    phase = "Preview closed on Vision Pro"; releaseStage(); break
                }
            }
        }
        .onChange(of: usdzData) { _, _ in Task { await closePreview() } }
        .onDisappear { Task { await closePreview() } }
    }

    private var status: String {
        if closing { return "Closing preview session…" }
        switch session?.state {
        case .connected: return "Quick Look connected; confirm the model is visible on Vision Pro."
        case .waiting: return "Waiting for Quick Look to connect; preview can be cancelled."
        case .interrupted: return "Connection interrupted"
        case .invalidated: return "Preview closed on Vision Pro"
        case nil: return phase
        @unknown default: return "Unknown preview state"
        }
    }

    private func chooseEndpoint() async {
        errorMessage = nil
        busy = true
        phase = "Finding connected Vision Pro…"
        let token = attempt
        defer { if attempt == token, session == nil { busy = false } }
        if endpointObserver.isEndpointAvailable {
            do {
                let endpoint = try await endpointObserver.endpoint
                guard !Task.isCancelled, attempt == token else { return }
                busy = false; await start(endpoint: endpoint)
            } catch {
                guard !Task.isCancelled, attempt == token else { return }
                errorMessage = error.localizedDescription; showingPicker = true
            }
        } else { phase = "Choose a Vision Pro"; showingPicker = true }
    }

    private func start(endpoint: SpatialPreviewEndpoint) async {
        guard !busy, !closing, !Task.isCancelled, session == nil else { return }
        let token = UUID()
        attempt = token
        busy = true
        phase = "Preparing USD stage…"
        progress = 0
        defer { if attempt == token { busy = false } }
        do {
            Self.logger.notice("Preparing USD stage (\(usdzData.count) bytes)")
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ThreeLivePreview-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            temporaryDirectory = directory
            let url = directory.appendingPathComponent("scene.usdz")
            try usdzData.write(to: url, options: .atomic)
            let stage = try USDStage.open(url)
            self.stage = stage
            let session = USDPreviewSession(stage: stage)
            self.session = session
            Self.logger.notice("USD stage loaded; calling USDPreviewSession.start (.unmodified)")
            // Preserve editable geometry; this small scene does not need reconstruction.
            try await session.start(endpoint: endpoint, parameters: .unmodified,
                                    viewerOptions: [.perObjectManipulation])
            guard attempt == token, !Task.isCancelled else {
                if !session.state.isInvalidated { try? await session.close() }
                return
            }
            Self.logger.notice("USDPreviewSession.start returned; state: \(String(describing: session.state), privacy: .public)")
        } catch {
            guard attempt == token, !Task.isCancelled else { return }
            Self.logger.error("USD preview start failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
            if session == nil { releaseStage() }
        }
    }

    private func closePreview() async {
        guard !closing else { return }
        let token = UUID()
        attempt = token; startTask?.cancel(); busy = false; closing = true; showingPicker = false
        defer { if attempt == token { closing = false } }
        Self.logger.notice("Closing USD preview")
        do {
            if let session, !session.state.isInvalidated { try await session.close() }
            guard attempt == token else { return }
            phase = "Preview closed"; releaseStage()
        } catch {
            guard attempt == token else { return }
            Self.logger.error("USD preview close failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    private func releaseStage() {
        session = nil
        stage = nil
        enlarged = false
        if let directory = temporaryDirectory {
            do {
                try FileManager.default.removeItem(at: directory)
                temporaryDirectory = nil
            } catch { errorMessage = error.localizedDescription }
        }
    }

    static func setScale(in stage: USDStage, enlarged: Bool) throws {
        guard let root = stage.defaultPrim else { throw PreviewError.missingRoot }
        if !root.transformOperations.contains(where: { $0.kind == .scale }) {
            root.addTransformOperation(type: .scale)
        }
        guard let scale = root.transformOperations.first(where: { $0.kind == .scale }) else {
            throw PreviewError.scaleWriteFailed
        }
        // shortcut: this preset has unit root scale; preserve authored scale before accepting arbitrary scenes.
        let value = enlarged ? 1.25 : 1.0
        let written: Bool
        switch scale.precision {
        case .double: written = scale.attribute.setValue(USDValue.Vec3d(value, value, value))
        case .float: written = scale.attribute.setValue(USDValue.Vec3f(Float(value), Float(value), Float(value)))
        case .half: written = scale.attribute.setValue(USDValue.Vec3h(Float16(value), Float16(value), Float16(value)))
        @unknown default: written = false
        }
        if !written { throw PreviewError.scaleWriteFailed }
    }

    private enum PreviewError: LocalizedError {
        case missingRoot, scaleWriteFailed
        var errorDescription: String? {
            switch self {
            case .missingRoot: return "USD stage has no default prim."
            case .scaleWriteFailed: return "Could not update the USD root scale."
            }
        }
    }
}
