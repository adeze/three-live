# Three Live remote spatial prototype

Requires Xcode 27+, macOS 27+, and Apple Vision Pro running visionOS 27+.
One Mac app compares two outputs using the existing **Torus Knot** preset from
`mobile/examples/ios_swiftui/SampleScenes.swift`. No visionOS app is required.

From the repository root:

```bash
./script/build_and_run.sh --self-check
./script/build_and_run.sh
```

The script bootstraps XcodeGen locally when necessary, builds an ad-hoc-signed
app under `.build/remote-immersive`, and launches its `.app` bundle. Additional
modes: `--build-only`, `--verify`, `--debug`, `--logs`, `--telemetry`. The Codex Run
action calls the same script. SwiftPM uses the root manifest and its pinned
compiler XCFramework, or a locally built full XCFramework if present; updating
`Cargo.lock` alone does not rebuild that native binary.

## Choose an output

**Spatial Preview** sends a USD stage to Quick Look on Vision Pro. Connect Mac
Virtual Display for automatic endpoint selection, or choose a nearby device in
the picker. Select **Preview on Vision Pro**, inspect/manipulate the object in
Quick Look, and use **Enlarge live** on the Mac to test USD stage replication.
Quick Look offers its own immersive presentation. It renders the scene on the
headset and does not execute Three Live's behavior graph. Closing either end
releases the session and its temporary USDZ.

**Mac-rendered immersion** uses `RemoteImmersiveSpace` and `CompositorLayer`.
Select **Open immersive view**, choose the headset, then look at the knot and
pinch. The existing `onSelect` graph toggles its scale. A ray must intersect its
actual triangles; the hole and background do not select it. The Mac window
reports submitted frames, accepted selections, and received head position.
Use **Close** or the headset's system dismissal to exit. Compare modes one at a
time; they are independent sessions.

## Rendering boundary

```text
Existing scene → Rust/Boa → GLB + USDZ
    ├─ USDKit stage → Spatial Preview → Quick Look on Vision Pro
    └─ RealityKit entities + Three Live runtime on Mac
         → RealityRenderer per-eye color
         → crop to compositor projection + static-mesh depth pass
         → RemoteImmersiveSpace → Vision Pro
```

RealityRenderer in SDK 27.2 exposes color output, but no public stereo/depth
output or rasterization-rate-map input. The prototype disables foveation and
requires dedicated per-eye targets. It renders serially into offscreen textures
using supported symmetric reverse-Z cameras, crops into each compositor's
off-axis projection, and renders matching reverse-Z depth from the loaded mesh.
Each eye waits only until RealityRenderer schedules its commands, which captures
camera state. GPU events order color rendering, compositor sampling, and texture
reuse. Display and recording targets use separate eye textures. Submission ends
after CPU encoding, before final command buffers are committed; the CPU does not
wait for each eye's GPU completion. ARKit supplies predicted head pose at presentation time;
camera transforms include each eye's offset. Formats and the minimum near-plane
distance come from the remote compositor's negotiated configuration. Completed indirect pinches are
applied between frames, never midway through a stereo render.

This intentionally covers one opaque, static mesh and its transform animation.
It does not cover skinned/deformed meshes, transparency, Three.js custom
shaders, general scene editing, or production frame-rate optimization.

## Verification

`--self-check` exits nonzero on failure. It checks off-axis projection math,
selection hit/miss/behind-ray cases, the real Rust compile/load path, the
existing selection graph, USDKit scale edits, visible RealityRenderer GPU
output, and actual compositor color/depth GPU passes. A rendered image is saved
to `.build/remote-immersive/self-check.png`. It does not connect to a headset.

Hardware acceptance still requires both sessions on Vision Pro: live USD
replication, correct stereo/orientation, stable world placement while moving
the head, pinch hit/miss behavior, dismissal/reconnection, and acceptable
latency. Compilation and offscreen output do not establish those outcomes.

### Observed on 2026-11-05

Built with Xcode 27.2 on macOS 27.2. The user confirmed both remote immersion and
Quick Look model visibility on Vision Pro. The remote app recorded 2,612
compositor submissions and three accepted triangle-hit selections, then returned
to its closed state. Spatial Preview reached connected state and sharing progress
1.0. Live USD edits, placement accuracy, and latency were not separately validated.

The first remote attempt crashed before rendering with
`Layer configuration not supported unsupportedNearPlaneDistance`: the requested
0.05 m near plane violated the device's 0.10 m minimum. Configuration now preserves
negotiated formats and respects the supported minimum; the subsequent run streamed.

The user's remote screenshot still shows rectangular gaps around and within the
model. Quick Look presents a more complete model against passthrough. The 128px
offscreen color/depth test checks coarse silhouette overlap with a two-texel
filtering margin; it does not establish artifact-free remote reprojection.
The source of the hardware artifacts remains unresolved. Prefer Spatial Preview
for scene review while the custom compositor path is experimental.

### Rendering changes awaiting a headset retest

The remote path now uses the GPU event schedule described above, a uniform
camera-space backdrop at 20 m instead of infinite background depth, broad studio
image-based lighting, explicit 4× MSAA, and RGBA16Float eye intermediates. The
backdrop bounds the near-object/background depth disparity while preserving
foreground mesh depth; it limits this prototype to content within 20 m.

The updated macOS build and offscreen GPU checks pass. The attempted remote
reconnection returned `Could not open remote immersive space` with zero frames,
so these changes have not established that the headset gaps are resolved.
Apple documented depth-disparity streaming artifacts in its
[visionOS 26 release notes](https://developer.apple.com/documentation/visionos-release-notes/visionos-26-release-notes);
that is supporting diagnostic context, not proof of the same defect in visionOS 27.

The renderer, behavior runtime, tracking, and compositor integration are native
Swift/RealityKit/Metal. Rust compiles the procedural scene once before rendering.
A Swift-only application can create RealityKit entities or load prepared USDZ
assets instead. Removing asset compilation does not change the streaming path.

## Apple references

- [Spatial Preview (WWDC26)](https://developer.apple.com/videos/play/wwdc2026/282/)
- [RemoteImmersiveSpace](https://developer.apple.com/documentation/swiftui/remoteimmersivespace)
- [RealityRenderer](https://developer.apple.com/documentation/realitykit/realityrenderer)
- [ProjectiveTransformCameraComponent](https://developer.apple.com/documentation/realitykit/projectivetransformcameracomponent)
- [Mac spatial rendering (WWDC25)](https://developer.apple.com/videos/play/wwdc2025/294/)
