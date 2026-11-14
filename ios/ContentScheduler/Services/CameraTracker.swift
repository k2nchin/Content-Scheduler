import Foundation
import AVFoundation
import Vision
import CoreImage

/// Cámara virtual para pasar videos horizontales a 9:16 siguiendo a la persona.
/// Todo en el iPhone con Vision: caras → cuerpo → lo más llamativo, con suavizado de cámara profesional.
@MainActor
enum CameraTracker {
    private struct Sample { let t: Double; var x: Double?; var size: Double; var y: Double? = nil; var faceH: Double = 0 }
    struct Point { let t: Double; let x: Double; let y: Double; let zoom: Double }

    /// Analiza el tramo y devuelve la posición horizontal (0…1) del encuadre en cada momento.
    static func path(for url: URL, start: Double, end: Double, step: Double = 0.2, status: (String) -> Void) async throws -> [Point] {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)

        var samples: [Sample] = []
        var last: Double?
        var mouths: [Int: Double] = [:]   // apertura de boca anterior por posición de cara (para saber quién habla)
        let total = max(1, Int((end - start) / step))
        var i = 0
        var t = start
        while t <= end {
            if i % 10 == 0 { status("Siguiendo a la persona… \(Int(Double(i) / Double(total) * 100))%") }
            if let img = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                let target = detect(img, near: last, mouths: &mouths)
                samples.append(Sample(t: t - start, x: target?.x, size: target?.size ?? 0, y: target?.y, faceH: target?.h ?? 0))
                if let x = target?.x { last = x }
            } else {
                samples.append(Sample(t: t - start, x: nil, size: 0))
            }
            t += step; i += 1
        }
        return smooth(samples, step: step)
    }

    /// Busca a quién seguir en un cuadro:
    /// 1) quien está hablando (la boca que más se mueve entre cuadros),
    /// 2) si nadie habla claro, la misma persona de antes, y solo cambia si otra es claramente la principal,
    /// 3) si no hay caras: el cuerpo, y si tampoco, lo más llamativo de la imagen.
    private static func detect(_ cg: CGImage, near last: Double?, mouths: inout [Int: Double]) -> (x: Double, size: Double, y: Double, h: Double)? {
        let handler = VNImageRequestHandler(cgImage: cg)
        let faces = VNDetectFaceLandmarksRequest()
        try? handler.perform([faces])
        let obs = faces.results ?? []
        if !obs.isEmpty {
            struct F { let x, y, w, h, size, talk: Double }
            var now: [Int: Double] = [:]
            let fs: [F] = obs.map { o in
                let bb = o.boundingBox
                var open = 0.0
                if let lips = o.landmarks?.innerLips?.normalizedPoints, !lips.isEmpty {
                    let ys = lips.map { Double($0.y) }
                    open = (ys.max()! - ys.min()!) // apertura relativa a la cara
                }
                let key = Int((Double(bb.midX) * 10).rounded())   // misma cara ≈ misma zona
                now[key] = open
                let talk = abs(open - (mouths[key] ?? open))
                return F(x: Double(bb.midX), y: Double(bb.midY), w: Double(bb.width), h: Double(bb.height), size: Double(bb.width * bb.height), talk: talk)
            }
            mouths = now
            let speaker = fs.max { $0.talk < $1.talk }!
            let biggest = fs.max { $0.size < $1.size }!
            var pick: F
            if fs.count > 1 && speaker.talk > 0.06 && speaker.size > biggest.size * 0.35 {
                pick = speaker                                   // alguien está hablando claramente
            } else if let last {
                let closest = fs.min { abs($0.x - last) < abs($1.x - last) }!
                pick = biggest.size > closest.size * 1.6 ? biggest : closest
            } else {
                pick = biggest
            }
            return (pick.x, pick.size, pick.y, pick.h)
        }
        let bodies = VNDetectHumanRectanglesRequest()
        try? handler.perform([bodies])
        if let b = (bodies.results ?? []).max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
            return (Double(b.boundingBox.midX), Double(b.boundingBox.width * b.boundingBox.height), Double(b.boundingBox.maxY - b.boundingBox.height * 0.15), 0)
        }
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        try? handler.perform([saliency])
        if let o = (saliency.results?.first as? VNSaliencyImageObservation)?.salientObjects?.first {
            return (Double(o.boundingBox.midX), 0, Double(o.boundingBox.midY), 0)
        }
        return nil
    }

    /// Cámara suave: rellena huecos, ignora movimientos pequeños (zona muerta),
    /// suaviza hacia adelante y hacia atrás (se anticipa en vez de llegar tarde) y limita la velocidad.
    private static func smooth(_ s: [Sample], step: Double) -> [Point] {
        guard !s.isEmpty else { return [Point(t: 0, x: 0.5, y: 0.5, zoom: 1)] }
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
        // 5) zoom: si la cara sale pequeña (lejos), acercar hasta 1,6× para que se vea bien en vertical
        let zRaw = s.map { $0.faceH > 0 ? min(1.6, max(1.0, 0.22 / $0.faceH)) : 1.0 }
        let yRaw = s.map { $0.y ?? 0.55 }
        let z = ema(zRaw, a: 0.12), y = ema(yRaw, a: 0.12)
        return s.indices.map { Point(t: s[$0].t, x: out[$0], y: y[$0], zoom: z[$0]) }
    }

    private static func ema(_ v: [Double], a: Double) -> [Double] {
        guard v.count > 1 else { return v }
        var f = v, b = v
        for i in 1..<v.count { f[i] = f[i - 1] + a * (v[i] - f[i - 1]) }
        for i in stride(from: v.count - 2, through: 0, by: -1) { b[i] = b[i + 1] + a * (v[i] - b[i + 1]) }
        return zip(f, b).map { ($0 + $1) / 2 }
    }

    /// Encuadre en un momento dado (interpolado).
    static func point(at t: Double, in path: [Point]) -> Point {
        guard let first = path.first else { return Point(t: t, x: 0.5, y: 0.5, zoom: 1) }
        if t <= first.t { return first }
        for i in 1..<path.count where path[i].t >= t {
            let p0 = path[i - 1], p1 = path[i]
            let k = (t - p0.t) / max(p1.t - p0.t, 0.0001)
            return Point(t: t, x: p0.x + (p1.x - p0.x) * k, y: p0.y + (p1.y - p0.y) * k, zoom: p0.zoom + (p1.zoom - p0.zoom) * k)
        }
        return path.last!
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
            let t = req.compositionTime.seconds - startT
            let p = MainActor.assumeIsolated { CameraTracker.point(at: t, in: track) }
            // Ventana 9:16 (más chica = zoom), centrada en la persona y sin salirse del video
            let cropH = e.height / CGFloat(p.zoom)
            let cropW = min(e.width, cropH * 9 / 16)
            var minX = e.minX + CGFloat(p.x) * e.width - cropW / 2
            minX = max(e.minX, min(e.maxX - cropW, minX))
            var minY = e.minY + CGFloat(p.y) * e.height - cropH * 0.6   // la cara un poco arriba del centro
            minY = max(e.minY, min(e.maxY - cropH, minY))
            let rect = CGRect(x: minX, y: minY, width: cropW, height: cropH)
            let scale = out.height / cropH
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
