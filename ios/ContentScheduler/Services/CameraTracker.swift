import Foundation
import AVFoundation
import Vision
import CoreImage

/// Cámara virtual para pasar videos horizontales a 9:16 siguiendo a la persona.
/// Todo en el iPhone con Vision: caras → cuerpo → lo más llamativo, con suavizado de cámara profesional.
@MainActor
enum CameraTracker {
    private struct Sample { let t: Double; var x: Double?; var size: Double }

    /// Analiza el tramo y devuelve la posición horizontal (0…1) del encuadre en cada momento.
    static func path(for url: URL, start: Double, end: Double, step: Double = 0.2, status: (String) -> Void) async throws -> [(t: Double, x: Double)] {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)

        var samples: [Sample] = []
        var last: Double?
        let total = max(1, Int((end - start) / step))
        var i = 0
        var t = start
        while t <= end {
            if i % 10 == 0 { status("Siguiendo a la persona… \(Int(Double(i) / Double(total) * 100))%") }
            if let img = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                let target = detect(img, near: last)
                samples.append(Sample(t: t - start, x: target?.x, size: target?.size ?? 0))
                if let x = target?.x { last = x }
            } else {
                samples.append(Sample(t: t - start, x: nil, size: 0))
            }
            t += step; i += 1
        }
        return smooth(samples, step: step)
    }

    /// Busca a quién seguir en un cuadro. Prefiere seguir a la misma persona (cerca de la última posición)
    /// y solo cambia si otra cara es claramente la principal (1,6 veces más grande).
    private static func detect(_ cg: CGImage, near last: Double?) -> (x: Double, size: Double)? {
        let handler = VNImageRequestHandler(cgImage: cg)
        let faces = VNDetectFaceRectanglesRequest()
        try? handler.perform([faces])
        let fs = (faces.results ?? []).map { (x: Double($0.boundingBox.midX), size: Double($0.boundingBox.width * $0.boundingBox.height)) }
        if !fs.isEmpty {
            let biggest = fs.max { $0.size < $1.size }!
            guard let last else { return biggest }
            let closest = fs.min { abs($0.x - last) < abs($1.x - last) }!
            return biggest.size > closest.size * 1.6 ? biggest : closest
        }
        let bodies = VNDetectHumanRectanglesRequest()
        try? handler.perform([bodies])
        if let b = (bodies.results ?? []).max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
            return (Double(b.boundingBox.midX), Double(b.boundingBox.width * b.boundingBox.height))
        }
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        try? handler.perform([saliency])
        if let o = (saliency.results?.first as? VNSaliencyImageObservation)?.salientObjects?.first {
            return (Double(o.boundingBox.midX), 0)
        }
        return nil
    }

    /// Cámara suave: rellena huecos, ignora movimientos pequeños (zona muerta),
    /// suaviza hacia adelante y hacia atrás (se anticipa en vez de llegar tarde) y limita la velocidad.
    private static func smooth(_ s: [Sample], step: Double) -> [(t: Double, x: Double)] {
        guard !s.isEmpty else { return [(0, 0.5)] }
        // 1) huecos: usa el valor conocido más cercano
        var xs = s.map { $0.x }
        let firstKnown = xs.first(where: { $0 != nil }) ?? 0.5
        var prev = firstKnown ?? 0.5
        for i in xs.indices { if let v = xs[i] { prev = v } else { xs[i] = prev } }
        var v = xs.map { $0 ?? 0.5 }
        // 2) zona muerta: no mover la cámara por cambios menores al 4 % del ancho
        var hold = v[0]
        for i in v.indices { if abs(v[i] - hold) > 0.04 { hold = v[i] }; v[i] = hold }
        // 3) suavizado de ida y vuelta
        let a = 0.25
        var f = v, b = v
        for i in 1..<max(v.count, 1) where i < v.count { f[i] = f[i - 1] + a * (v[i] - f[i - 1]) }
        if v.count > 1 { for i in stride(from: v.count - 2, through: 0, by: -1) { b[i] = b[i + 1] + a * (v[i] - b[i + 1]) } }
        var out = zip(f, b).map { ($0 + $1) / 2 }
        // 4) velocidad máxima: como mucho 35 % del ancho por segundo
        let maxStep = 0.35 * step
        for i in 1..<max(out.count, 1) where i < out.count {
            let d = out[i] - out[i - 1]
            if abs(d) > maxStep { out[i] = out[i - 1] + (d > 0 ? maxStep : -maxStep) }
        }
        return zip(s, out).map { ($0.t, $1) }
    }

    /// Posición del encuadre en un momento dado (interpolada).
    static func x(at t: Double, in path: [(t: Double, x: Double)]) -> Double {
        guard let first = path.first else { return 0.5 }
        if t <= first.t { return first.x }
        for i in 1..<path.count where path[i].t >= t {
            let p0 = path[i - 1], p1 = path[i]
            let k = (t - p0.t) / max(p1.t - p0.t, 0.0001)
            return p0.x + (p1.x - p0.x) * k
        }
        return path.last!.x
    }

    /// Exporta el tramo en 1080×1920 con la cámara siguiendo a la persona.
    static func render(_ url: URL, start: Double, end: Double, status: @escaping (String) -> Void) async throws -> URL {
        let track = try await path(for: url, start: start, end: end, status: status)
        status("Encuadrando en vertical…")
        let asset = AVURLAsset(url: url)
        let out = CGSize(width: 1080, height: 1920)
        let startT = start
        let vc = try await AVMutableVideoComposition.videoComposition(with: asset) { req in
            let src = req.sourceImage
            let e = src.extent
            let cropW = min(e.width, e.height * 9 / 16)
            let t = req.compositionTime.seconds - startT
            let cx = MainActor.assumeIsolated { CameraTracker.x(at: t, in: track) }
            var minX = e.minX + CGFloat(cx) * e.width - cropW / 2
            minX = max(e.minX, min(e.maxX - cropW, minX))
            let rect = CGRect(x: minX, y: e.minY, width: cropW, height: e.height)
            let scale = out.height / e.height
            let frame = src.cropped(to: rect)
                .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .cropped(to: CGRect(origin: .zero, size: out))
            req.finish(with: frame, context: nil)
        }
        vc.renderSize = out
        guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw YTError(message: "No se pudo preparar el video vertical.")
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        ex.videoComposition = vc
        ex.outputURL = dest
        ex.outputFileType = .mp4
        ex.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in ex.exportAsynchronously { c.resume() } }
        guard ex.status == .completed else { throw YTError(message: "No se pudo encuadrar: \(ex.error?.localizedDescription ?? "error")") }
        return dest
    }
}
