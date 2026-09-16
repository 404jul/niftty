import SwiftUI
import MetalKit
import CoreText
import GhosttyKit

/// A shader bundled with the app in Contents/Resources/Shaders.
struct BuiltInShader: Identifiable {
    let url: URL
    var id: String { url.lastPathComponent }
    var name: String { Self.displayName(forFile: url.lastPathComponent) }

    static func displayName(forFile file: String) -> String {
        let stem = (file as NSString).deletingPathExtension
        let words = stem
            .replacingOccurrences(of: "_cursor", with: "")
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.joined(separator: " ")
    }

    /// All bundled shaders, sorted by name.
    static func all() -> [BuiltInShader] {
        let urls = Bundle.main.urls(
            forResourcesWithExtension: "glsl",
            subdirectory: "Shaders"
        ) ?? []
        return urls
            .map { BuiltInShader(url: $0) }
            .sorted { $0.name < $1.name }
    }
}

/// The shaders page in the graphical settings editor. Shows live previews
/// of the shaders bundled with the app and lets the user pick one (or
/// none) which is written to the `custom-shader` setting.
struct ShadersPage: View {
    @ObservedObject var model: SettingsModel

    private let shaders = BuiltInShader.all()

    /// The currently selected custom-shader value (newline separated for
    /// multiple), or nil when there is no row.
    private var currentValue: String? {
        model.rows.first { $0.id == "custom-shader" }?.value
    }

    private func isSelected(_ shader: BuiltInShader) -> Bool {
        currentValue == shader.url.path
    }

    private var isNoneSelected: Bool {
        guard let value = currentValue else { return false }
        return value.isEmpty
    }

    private var customShaderPath: String? {
        guard let value = currentValue, !value.isEmpty,
              !shaders.contains(where: { $0.url.path == value })
        else { return nil }
        return value
    }

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 300, maximum: 400), spacing: 16)],
                spacing: 16
            ) {
                ShaderCard(
                    name: "None",
                    subtitle: "No cursor effects",
                    selected: isNoneSelected
                ) {
                    model.set("", for: "custom-shader")
                } preview: {
                    ShaderPreview(shaderURL: nil)
                }

                ForEach(shaders) { shader in
                    ShaderCard(
                        name: shader.name,
                        subtitle: shader.id,
                        selected: isSelected(shader)
                    ) {
                        model.set(shader.url.path, for: "custom-shader")
                    } preview: {
                        ShaderPreview(shaderURL: shader.url)
                    }
                }
            }
            .padding(20)

            if let custom = customShaderPath {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("A custom shader is configured:")
                        Text(custom)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button("Remove Custom Shader") {
                        model.set("", for: "custom-shader")
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }
}

private struct ShaderCard<Preview: View>: View {
    let name: String
    let subtitle: String
    let selected: Bool
    let onSelect: () -> Void
    @ViewBuilder let preview: Preview

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                preview
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                        .padding(8)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onSelect() }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline)
                    Text(subtitle)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(selected ? "Selected" : "Select") { onSelect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected)
            }
            .padding(.top, 10)
        }
        .padding(12)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
        )
    }
}

// MARK: - Previews

/// A shader preview that renders a mock terminal, optionally through a
/// Ghostty custom shader translated to Metal via the GhosttyKit C API.
/// Pass a nil shaderURL for the plain mock terminal.
struct ShaderPreview: NSViewRepresentable {
    let shaderURL: URL?

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.delegate = context.coordinator
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 30
        view.colorPixelFormat = .bgra8Unorm
        context.coordinator.attach(view: view, shaderURL: shaderURL)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.attach(view: nsView, shaderURL: shaderURL)
    }

    func makeCoordinator() -> ShaderPreviewRenderer {
        ShaderPreviewRenderer()
    }
}

// MARK: - Renderer

/// Renders a mock terminal scene, optionally through a Ghostty custom
/// shader translated to Metal via `ghostty_shader_msl`.
///
/// The uniform buffer must exactly match `shadertoy.Uniforms` in
/// src/renderer/shadertoy.zig (offsets frozen by a unit test there).
final class ShaderPreviewRenderer: NSObject, MTKViewDelegate {
    private(set) var device: MTLDevice
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var plainPipeline: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?
    private var uniformBuffer: MTLBuffer?
    private var terminalTexture: MTLTexture?
    private(set) var shaderURL: URL?
    private var lastCursorKey = ""
    private var textureKey = ""
    private var startTime = Date()
    private var drawableSize = CGSize(width: 1, height: 1)

    private let cell = CGSize(width: 12, height: 24)
    private let padding: CGFloat = 16

    /// Uniform buffer byte offsets, mirroring shadertoy.Uniforms.
    private enum U {
        static let resolution = 0
        static let time = 12
        static let timeDelta = 16
        static let frameRate = 20
        static let frame = 24
        static let mouse = 160
        static let sampleRate = 192
        static let currentCursor = 208
        static let previousCursor = 224
        static let currentCursorColor = 240
        static let previousCursorColor = 256
        static let currentCursorStyle = 272
        static let previousCursorStyle = 276
        static let cursorVisible = 280
        static let cursorChangeTime = 284
        static let timeFocus = 288
        static let focus = 292
        static let background = 4400
        static let foreground = 4416
        static let cursorColor = 4432
        static let total = 4496
    }

    override init() {
        // Previews require a GPU; the settings UI is unusable without one
        // on any machine this app supports anyway.
        self.device = MTLCreateSystemDefaultDevice()!
        super.init()
        self.queue = device.makeCommandQueue()

        var uniforms = [UInt8](repeating: 0, count: U.total)
        setVec4(&uniforms, U.background, 0.11, 0.11, 0.13, 1)
        setVec4(&uniforms, U.foreground, 0.92, 0.92, 0.92, 1)
        setVec4(&uniforms, U.cursorColor, 0.95, 0.95, 0.95, 1)
        setVec4(&uniforms, U.currentCursorColor, 0.95, 0.95, 0.95, 1)
        setVec4(&uniforms, U.previousCursorColor, 0.95, 0.95, 0.95, 1)
        setI32(&uniforms, U.cursorVisible, 1)
        setI32(&uniforms, U.currentCursorStyle, 0)
        setI32(&uniforms, U.previousCursorStyle, 0)
        setI32(&uniforms, U.focus, 1)
        uniformBuffer = device.makeBuffer(bytes: uniforms, length: U.total)
    }

    /// Load (or reload) a shader. Pass nil for the mock terminal only.
    /// Retrying a failed load is intentional so attach is idempotent.
    func attach(view: MTKView, shaderURL: URL?) {
        if self.shaderURL == shaderURL, pipeline != nil || shaderURL == nil {
            return
        }
        self.shaderURL = shaderURL
        terminalTexture = nil
        textureKey = ""

        pipeline = nil
        guard let shaderURL else { return }

        let msl = Ghostty.AllocatedString(
            ghostty_shader_msl((shaderURL.path as NSString).utf8String)
        ).string
        if msl.isEmpty { return }

        // A minimal full-screen triangle vertex function appended to the
        // translated fragment shader ("main0", produced by SPIRV-Cross).
        let source = msl + """


            struct NifttyVSOut {
                float4 position [[position]];
            };

            vertex NifttyVSOut niftty_fullscreen_vertex(uint vid [[vertex_id]]) {
                float2 pos = float2(float((vid << 1u) & 2u), float(vid & 2u));
                NifttyVSOut out;
                out.position = float4(pos * 2.0 - 1.0, 0.0, 1.0);
                return out;
            }
            """

        do {
            let library = try device.makeLibrary(source: source, options: nil)
            let vertexFn = try library.makeFunction(name: "niftty_fullscreen_vertex")
            let fragmentFn = try library.makeFunction(name: "main0")

            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertexFn
            desc.fragmentFunction = fragmentFn
            desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            // Fall back to the plain mock terminal for this preview.
            return
        }
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = size
        terminalTexture = nil
        textureKey = ""
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let queue,
              let cmd = queue.makeCommandBuffer(),
              let encoder = cmd.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        let time = Float(Date().timeIntervalSince(startTime))
        let cursor = animatedCursor(at: time)
        updateTerminalTexture(cursor: cursor)
        updateUniforms(time: time, cursor: cursor)

        let activePipeline = pipeline ?? plainPipeline(view: view)
        if let activePipeline, let terminalTexture {
            if sampler == nil { sampler = makeSampler() }
            encoder.setRenderPipelineState(activePipeline)
            if pipeline != nil, let uniformBuffer {
                encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 1)
            }
            encoder.setFragmentTexture(terminalTexture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        encoder.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: - Mock scene

    private struct Cursor {
        var x: Float
        var y: Float  // bottom edge (y-down, matching Ghostty)
        var w: Float
        var h: Float
        var col: Int
        var row: Int
        var bar: Bool
    }

    /// The cursor hops between two cells, alternating between block and
    /// bar widths so width-triggered effects (ripples, booms) fire.
    private func animatedCursor(at time: Float) -> Cursor {
        let period: Float = 2.4
        let second = time.truncatingRemainder(dividingBy: period) >= period / 2

        let col = second ? 22 : 8
        let row = second ? 3 : 2
        let w: Float = second ? Float(cell.width) * 0.25 : Float(cell.width)
        let h = Float(cell.height)
        let top = Float(padding) + Float(row) * h
        return Cursor(
            x: Float(padding) + Float(col) * Float(cell.width),
            y: top + h,
            w: w,
            h: h,
            col: col,
            row: row,
            bar: second)
    }

    private func updateUniforms(time: Float, cursor: Cursor) {
        guard let uniformBuffer else { return }
        let ptr = uniformBuffer.contents()

        let key = "\(cursor.col):\(cursor.row):\(cursor.bar)"
        if key != lastCursorKey {
            memcpy(ptr + U.previousCursor, ptr + U.currentCursor, 16)
            memcpy(ptr + U.previousCursorColor, ptr + U.currentCursorColor, 16)
            copy(ptr + U.cursorChangeTime, [time])
            lastCursorKey = key
        }

        copy(ptr + U.resolution, [
            Float(drawableSize.width), Float(drawableSize.height), 1,
        ])
        copy(ptr + U.time, [time])
        copy(ptr + U.timeDelta, [1.0 / 30.0])
        copy(ptr + U.frameRate, [30.0])
        copyI32(ptr + U.frame, Int32(time * 30))
        copy(ptr + U.currentCursor, [cursor.x, cursor.y, cursor.w, cursor.h])
    }

    /// Draw the mock terminal (text + cursor) and upload it as the
    /// iChannel0 texture. Only redrawn when the cursor moves or resizes.
    private func updateTerminalTexture(cursor: Cursor) {
        let width = max(Int(drawableSize.width), 1)
        let height = max(Int(drawableSize.height), 1)

        let key = "\(width)x\(height):\(cursor.col):\(cursor.row):\(cursor.bar)"
        if terminalTexture != nil, textureKey == key { return }
        textureKey = key

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        // Top-left origin so texture row 0 is the top of the terminal,
        // matching Metal's y-down fragment coordinates.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        ctx.setFillColor(CGColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Scale the mock scene so it fills the preview at any size.
        let scale = min(
            CGFloat(width) / (padding * 2 + cell.width * 32),
            CGFloat(height) / (padding * 2 + cell.height * 6))
        ctx.scaleBy(x: scale, y: scale)

        let font = CTFontCreateWithName(
            "Menlo" as CFString, cell.height * 0.68, nil)
        let fg = CGColor(red: 0.92, green: 0.92, blue: 0.92, alpha: 1)

        let lines = [
            "  ~ niftty",
            "  $ zig build",
            "  $ ssh host",
            "  $ ",
        ]
        for (i, line) in lines.enumerated() {
            drawText(
                line, in: ctx, font: font, color: fg,
                at: CGPoint(x: padding, y: padding + CGFloat(i) * cell.height))
        }

        // Cursor cell background right after the trailing prompt.
        ctx.setFillColor(CGColor(
            red: 0.95, green: 0.95, blue: 0.95, alpha: 0.85))
        ctx.fill(CGRect(
            x: CGFloat(cursor.x) / scale,
            y: CGFloat(cursor.y - cursor.h) / scale,
            width: CGFloat(cursor.w) / scale,
            height: CGFloat(cursor.h) / scale))

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false)
        desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else { return }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: ctx.data!,
            bytesPerRow: width * 4)
        terminalTexture = texture
    }

    private func drawText(
        _ string: String, in ctx: CGContext,
        font: CTFont, color: CGColor, at position: CGPoint
    ) {
        guard let attributed = CFAttributedStringCreate(
            nil, string as CFString,
            [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: color,
            ] as CFDictionary
        ) else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = position
        CTLineDraw(line, ctx)
    }

    private func copyI32(_ dst: UnsafeMutableRawPointer, _ value: Int32) {
        var v = value
        memcpy(dst, &v, 4)
    }

    /// A trivial textured blit pipeline used when no custom shader is
    /// loaded ("None" card) or the custom shader failed to compile.
    private func plainPipeline(view: MTKView) -> MTLRenderPipelineState? {
        if let plainPipeline { return plainPipeline }

        let source = """
            #include <metal_stdlib>
            using namespace metal;

            struct VSOut {
                float4 position [[position]];
                float2 uv;
            };

            vertex VSOut niftty_textured_vertex(uint vid [[vertex_id]]) {
                float2 pos = float2(float((vid << 1u) & 2u), float(vid & 2u));
                VSOut out;
                out.position = float4(pos * 2.0 - 1.0, 0.0, 1.0);
                out.uv = pos;
                return out;
            }

            fragment float4 niftty_textured_fragment(
                VSOut in [[stage_in]],
                texture2d<float> tex [[texture(0)]],
                sampler smplr [[sampler(0)]]
            ) {
                return tex.sample(smplr, in.uv);
            }
            """
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = try library.makeFunction(
                name: "niftty_textured_vertex")
            desc.fragmentFunction = try library.makeFunction(
                name: "niftty_textured_fragment")
            desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            plainPipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            return nil
        }
        return plainPipeline
    }

    private func makeSampler() -> MTLSamplerState? {
        let desc = MTLSamplerDescriptor()
        desc.sAddressMode = .clampToEdge
        desc.tAddressMode = .clampToEdge
        desc.minFilter = .linear
        desc.magFilter = .linear
        return device.makeSamplerState(descriptor: desc)
    }

    // MARK: - Uniform helpers

    private func copy(_ dst: UnsafeMutableRawPointer, _ values: [Float]) {
        values.withUnsafeBufferPointer { buf in
            memcpy(dst, buf.baseAddress, buf.count * MemoryLayout<Float>.stride)
        }
    }

    private func setVec4(
        _ buf: inout [UInt8], _ offset: Int,
        _ x: Float, _ y: Float, _ z: Float, _ w: Float
    ) {
        withUnsafeBytes(of: x) { buf.replaceSubrange(offset..<offset + 4, with: $0) }
        withUnsafeBytes(of: y) {
            buf.replaceSubrange(offset + 4..<offset + 8, with: $0)
        }
        withUnsafeBytes(of: z) {
            buf.replaceSubrange(offset + 8..<offset + 12, with: $0)
        }
        withUnsafeBytes(of: w) {
            buf.replaceSubrange(offset + 12..<offset + 16, with: $0)
        }
    }

    private func setI32(_ buf: inout [UInt8], _ offset: Int, _ value: Int32) {
        withUnsafeBytes(of: value) { buf.replaceSubrange(offset..<offset + 4, with: $0) }
    }
}
