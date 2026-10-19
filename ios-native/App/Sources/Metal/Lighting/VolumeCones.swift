import Foundation
import Metal

// ================================================================
//  VOLUME CONES / ATMOSPHERE — the air of the world frame (owned by
//  WP2 «Свет и воздух»). Today: the abyss haze plane (transparent item
//  100, alpha) and the GPU-animated weather of 07-fx.js (item 700):
//  snowfall and low mist banks (alpha) and pink motes rising out of
//  the abyss (additive), counts by the effects tier. Shaders:
//  Atmosphere.metal. WP2 adds the analytic flashlight cones clipped at
//  the deck, fog decks, and snow / mist lit only inside the beams.
// ================================================================
final class Atmosphere {
    static let pipelines: [PipelineSpec] = [
        .world("haze", "vs_haze", "fs_haze", .alpha, .ihm1),
        .world("weatherAlpha", "vs_weather", "fs_weather", .alpha), .world("weatherAdd", "vs_weather", "fs_weather", .add),
    ]

    private var renderer: MetalRenderer!
    private var meshHaze: GPUMesh!
    private var texHaze: MTLTexture!
    private var psHaze: MTLRenderPipelineState?, psWeatherAlpha: MTLRenderPipelineState?, psWeatherAdd: MTLRenderPipelineState?
    // this frame's weather (quality med: 700 snowflakes, 6 mist banks, 420 motes) around the camera target
    private var snow = 0, mist = 0, motes = 0
    private var center = F4(0, 0, 0, 0)

    /// Resolve meshes / pipelines and register the haze and weather items (MetalWorld, once).
    func attach(_ r: MetalRenderer) {
        renderer = r
        meshHaze = r.store.mesh("level_haze")
        texHaze = r.store.texture("haze")
        psHaze = r.pipeline("haze"); psWeatherAlpha = r.pipeline("weatherAlpha"); psWeatherAdd = r.pipeline("weatherAdd")
        r.register(.transparent, order: 100, "haze") { [unowned self] enc in self.encodeHaze(enc) }
        r.register(.transparent, order: 700, "weather") { [unowned self] enc in self.encodeWeather(enc) }
    }

    /// This frame's weather around `focus` for the effects tier `fxK`.
    func build(focus: F3, fxK k: Float) {
        snow = k < 0.5 ? 350 : (k < 0.85 ? 700 : 1300)
        mist = k < 0.5 ? 0 : (k < 0.85 ? 6 : 14)
        motes = 420
        center = F4(focus.x, focus.y, focus.z, 0)
    }

    /// Transparent item 100: the abyss haze plane.
    private func encodeHaze(_ enc: MTLRenderCommandEncoder) {
        guard let ps = psHaze else { return }
        let r = renderer!
        r.use(enc, ps)
        r.bindMain(enc, texHaze)
        var mat = MaterialUniforms(pbr: .zero, floor: .zero)
        r.drawStatic(enc, meshHaze, &mat)
    }

    /// Transparent item 700: snowfall + mist (alpha), motes rising from the abyss (additive).
    private func encodeWeather(_ enc: MTLRenderCommandEncoder) {
        let r = renderer!
        if let ps = psWeatherAlpha, snow + mist > 0 {
            r.use(enc, ps)
            if snow > 0 { weather(enc, kind: 0, count: snow) }
            if mist > 0 { weather(enc, kind: 2, count: mist) }
        }
        if let ps = psWeatherAdd, motes > 0 {
            r.use(enc, ps)
            weather(enc, kind: 1, count: motes)
        }
    }

    private func weather(_ enc: MTLRenderCommandEncoder, kind: Float, count: Int) {
        var w = (F4(center.x, center.y, center.z, kind), F4(Float(count), 0, 0, 0))
        enc.setVertexBytes(&w, length: MemoryLayout<F4>.stride * 2, index: BufferIndex.instances)
        renderer.drawQuads(enc, count)
    }
}
