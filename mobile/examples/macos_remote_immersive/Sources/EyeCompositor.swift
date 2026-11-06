// Copyright 2026 Google LLC
// SPDX-License-Identifier: Apache-2.0

import Metal
import simd

// Kept independent of LayerRenderer so the actual GPU passes can be checked without a headset.
@MainActor
struct EyeCompositor {
    let colorPipeline: MTLRenderPipelineState
    let depthPipeline: MTLRenderPipelineState
    let depthState: MTLDepthStencilState

    init(device: MTLDevice, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat) throws {
        let library = try device.makeLibrary(source: Self.shaders, options: nil)
        let colorDescriptor = MTLRenderPipelineDescriptor()
        colorDescriptor.vertexFunction = library.makeFunction(name: "screenVertex")
        colorDescriptor.fragmentFunction = library.makeFunction(name: "cropColor")
        colorDescriptor.colorAttachments[0].pixelFormat = colorFormat
        colorPipeline = try device.makeRenderPipelineState(descriptor: colorDescriptor)
        let depthDescriptor = MTLRenderPipelineDescriptor()
        depthDescriptor.vertexFunction = library.makeFunction(name: "depthVertex")
        depthDescriptor.depthAttachmentPixelFormat = depthFormat
        depthPipeline = try device.makeRenderPipelineState(descriptor: depthDescriptor)
        let state = MTLDepthStencilDescriptor()
        state.isDepthWriteEnabled = true
        state.depthCompareFunction = .greater
        guard let depthState = device.makeDepthStencilState(descriptor: state) else {
            throw PrototypeError.unavailable("Could not allocate depth state")
        }
        self.depthState = depthState
    }

    func encode(command: MTLCommandBuffer, texture: MTLTexture, target: MTLTexture,
                depthTarget: MTLTexture, viewport: MTLViewport, crop: SIMD4<Float>,
                meshes: [DepthMesh], viewProjection: simd_float4x4, backgroundDepth: Double) throws {
        let colorPass = MTLRenderPassDescriptor()
        colorPass.colorAttachments[0].texture = target
        colorPass.colorAttachments[0].loadAction = .dontCare
        colorPass.colorAttachments[0].storeAction = .store
        guard let colorEncoder = command.makeRenderCommandEncoder(descriptor: colorPass) else {
            throw PrototypeError.unavailable("Could not encode compositor color")
        }
        colorEncoder.setRenderPipelineState(colorPipeline)
        colorEncoder.setViewport(viewport)
        colorEncoder.setFragmentTexture(texture, index: 0)
        var crop = crop
        colorEncoder.setFragmentBytes(&crop, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        colorEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        colorEncoder.endEncoding()

        let depthPass = MTLRenderPassDescriptor()
        depthPass.depthAttachment.texture = depthTarget
        depthPass.depthAttachment.loadAction = .clear
        depthPass.depthAttachment.storeAction = .store
        depthPass.depthAttachment.clearDepth = backgroundDepth
        guard let depthEncoder = command.makeRenderCommandEncoder(descriptor: depthPass) else {
            throw PrototypeError.unavailable("Could not encode compositor depth")
        }
        depthEncoder.setRenderPipelineState(depthPipeline)
        depthEncoder.setDepthStencilState(depthState)
        depthEncoder.setViewport(viewport)
        for mesh in meshes {
            var mvp = viewProjection * mesh.worldTransform
            depthEncoder.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
            depthEncoder.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            depthEncoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indices.count,
                indexType: .uint32, indexBuffer: mesh.triangles, indexBufferOffset: 0)
        }
        depthEncoder.endEncoding()
    }

    static let shaders = """
    #include <metal_stdlib>
    using namespace metal;
    struct ScreenVertex { float4 position [[position]]; float2 uv; };
    vertex ScreenVertex screenVertex(uint id [[vertex_id]]) {
        float2 p = id == 0 ? float2(-1, -1) : (id == 1 ? float2(3, -1) : float2(-1, 3));
        return { float4(p, 0, 1), float2((p.x + 1) * .5, (1 - p.y) * .5) };
    }
    fragment float4 cropColor(ScreenVertex in [[stage_in]], texture2d<float> image [[texture(0)]],
                              constant float4 &crop [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 ndc = (float2(in.uv.x * 2 - 1, 1 - in.uv.y * 2) + crop.xy) / crop.zw;
        return image.sample(s, float2(ndc.x * .5 + .5, .5 - ndc.y * .5));
    }
    vertex float4 depthVertex(uint id [[vertex_id]], const device float3 *p [[buffer(0)]],
                             constant float4x4 &mvp [[buffer(1)]]) {
        return mvp * float4(p[id], 1);
    }
    """
}
