import SwiftUI
import AVKit
import Speech

/// Estudio: recortar el video y ponerle subtítulos automáticos (reconocimiento de voz del iPhone).
struct StudioView: View {
    let postID: UUID
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?
    @State private var duration = 0.0
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var subtitles = true
    @State private var vertical = false
    @State private var track = true
    @State private var isHorizontal = false
    @State private var coverTime = 0.0
    @State private var coverImage: UIImage?
    @State private var useHook = false
    @State private var hookText = ""
    @State private var aiBusy = false
    @State private var working = false
    @State private var status = ""

    private var source: URL? { store.post(postID).flatMap(Publisher.fileURL) }

    var body: some View {
        NavigationStack {
            Screen {
                PageTitle(kicker: "Edita tu clip", title: "Estudio")
                if let player {
                    VideoPlayer(player: player)
                        .frame(height: 380).frame(maxWidth: .infinity)
                        .background(.black).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                if duration > 0 {
                    Box {
                        Text("RECORTAR").font(Theme.mono).foregroundStyle(Theme.muted)
                        HStack {
                            Text("Inicio").font(.footnote).frame(width: 52, alignment: .leading)
                            Slider(value: $start, in: 0...duration) { editing in if !editing { seek(start) } }
                            Text(clock(start)).font(.system(size: 12, design: .monospaced)).frame(width: 44)
                        }
                        HStack {
                            Text("Final").font(.footnote).frame(width: 52, alignment: .leading)
                            Slider(value: $end, in: 0...duration) { editing in if !editing { seek(max(start, end - 2)) } }
                            Text(clock(end)).font(.system(size: 12, design: .monospaced)).frame(width: 44)
                        }
                        Text("Duración del clip: \(clock(max(0, end - start)))" + (end - start > 180 ? " · más de 3 min no cuenta como Short" : ""))
                            .font(.caption).foregroundStyle(end - start > 180 ? Theme.warn : Theme.muted)
                    }
                    Box {
                        Text("PORTADA").font(Theme.mono).foregroundStyle(Theme.muted)
                        HStack(alignment: .top, spacing: 12) {
                            Group {
                                if let coverImage { Image(uiImage: coverImage).resizable().scaledToFill() } else { Theme.bg3 }
                            }
                            .frame(width: 72, height: 110).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 6) {
                                Slider(value: $coverTime, in: 0...duration) { editing in if !editing { Task { await grabCover() } } }
                                if NIM.isConfigured {
                                    Button { Task { await aiCover() } } label: { Label(aiBusy ? "Mirando el video…" : "✨ Elegir portada con IA", systemImage: "photo") }
                                        .font(.caption.bold()).foregroundStyle(Theme.accent).disabled(aiBusy)
                                }
                                Text("Elige el momento para la portada (\(clock(coverTime))). En YouTube se sube como miniatura; tu canal tiene que estar verificado por teléfono.")
                                    .font(.caption).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                    if isHorizontal {
                        Box {
                            Toggle(isOn: $vertical) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Convertir a vertical 9:16").bold()
                                    Text("Para Reels y Shorts.").font(.caption).foregroundStyle(Theme.muted)
                                }
                            }
                            if vertical { ReframePicker(track: $track) }
                        }
                    }
                    Box {
                        Toggle(isOn: $useHook) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Gancho en pantalla").bold()
                                Text("Texto grande arriba durante los primeros 3 segundos.").font(.caption).foregroundStyle(Theme.muted)
                            }
                        }
                        if useHook {
                            TextField("Ej.: Nadie esperaba esto 😳", text: $hookText).padding(12).background(Theme.bg3, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            if NIM.isConfigured {
                                Button { Task { await aiHook() } } label: { Label(aiBusy ? "Escribiendo…" : "✨ Escribir gancho con IA", systemImage: "text.bubble") }
                                    .font(.caption.bold()).foregroundStyle(Theme.accent).disabled(aiBusy)
                            }
                        }
                    }
                    Box {
                        Toggle(isOn: $subtitles) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Subtítulos automáticos").bold()
                                Text("El iPhone escucha el audio en español y pone el texto sobre el video.").font(.caption).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                    if working {
                        HStack { ProgressView(); Text(status).font(.footnote) }.frame(maxWidth: .infinity)
                    }
                    Button { apply() } label: { Text("Aplicar cambios") }
                        .buttonStyle(PrimaryButtonStyle()).disabled(working || end - start < 1)
                    Text("Se crea un video nuevo con estos cambios y reemplaza al anterior en este post.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() }.disabled(working) } }
            .task { await load() }
            .onChange(of: start) { _, v in if v > end - 1 { start = max(0, end - 1) } }
            .onChange(of: end) { _, v in if v < start + 1 { end = min(duration, start + 1) } }
        }
    }

    private func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
    private func seek(_ s: Double) { player?.seek(to: CMTime(seconds: s, preferredTimescale: 600)) }

    private func load() async {
        guard let source = await Publisher.ensureFile(postID, store: store) else { return }
        player = AVPlayer(url: source)
        let asset = AVURLAsset(url: source)
        if let d = try? await asset.load(.duration) {
            duration = max(1, d.seconds)
            end = duration
            coverTime = min(1, duration / 3)
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize), let t = try? await track.load(.preferredTransform) {
            let r = size.applying(t)
            isHorizontal = abs(r.width) > abs(r.height)
        }
        await grabCover()
    }

    /// La IA mira 6 momentos del video y elige el mejor para portada.
    private func aiCover() async {
        guard let source else { return }
        aiBusy = true
        defer { aiBusy = false }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 720, height: 720)
        let span: Double = end - start
        var times: [Double] = []
        for k in 0..<6 { times.append(start + span * (Double(k) + 0.5) / 6.0) }
        var frames: [(Double, UIImage)] = []
        for t in times {
            if let r = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)) { frames.append((t, UIImage(cgImage: r.image))) }
        }
        guard !frames.isEmpty else { return store.show("No se pudieron leer imágenes del video.") }
        do {
            let i = try await NIM.bestFrame(frames.map(\.1))
            coverTime = frames[i].0
            coverImage = frames[i].1
            store.show("La IA eligió la portada")
        } catch { store.show(error.localizedDescription) }
    }

    /// Gancho a partir de lo que se dice en el tramo elegido.
    private func aiHook() async {
        guard let source else { return }
        aiBusy = true
        defer { aiBusy = false }
        do {
            let asset = AVURLAsset(url: source)
            let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: min(end, start + 60), preferredTimescale: 600))
            let audio = try await StudioExport.exportAudio(asset, range: range)
            let text = try await StudioExport.transcribe(audio).map(\.text).joined(separator: " ")
            try? FileManager.default.removeItem(at: audio)
            hookText = try await NIM.hook(for: text.isEmpty ? (store.post(postID)?.title ?? "") : text)
        } catch { store.show(error.localizedDescription) }
    }

    private func grabCover() async {
        guard let source else { return }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1280, height: 1280)
        if let r = try? await gen.image(at: CMTime(seconds: coverTime, preferredTimescale: 600)) { coverImage = UIImage(cgImage: r.image) }
    }

    private func apply() {
        guard let source else { return }
        working = true
        player?.pause()
        Task {
            do {
                let url = try await StudioExport.run(source: source, start: start, end: end, subtitles: subtitles, vertical: vertical, track: track, hook: useHook ? hookText : nil) { status = $0 }
                if let coverImage, let jpeg = coverImage.jpegData(compressionQuality: 0.85) { store.update(postID) { $0.cover = jpeg } }
                await store.replaceVideo(of: postID, with: url)
                store.show(subtitles ? "Video recortado con subtítulos" : "Video recortado")
                dismiss()
            } catch {
                store.show(error.localizedDescription)
            }
            working = false
        }
    }
}

@MainActor
enum StudioExport {
    struct Word { let text: String; let start: Double; let end: Double }
    struct Line { let text: String; let start: Double; let end: Double; var words: [Word] = [] }

    static func run(source: URL, start: Double, end: Double, subtitles: Bool, vertical: Bool = false, track: Bool = true, hook: String? = nil, style: SubStyle = .viral, status: @escaping (String) -> Void) async throws -> URL {
        var source = source
        var start = start, end = end
        if vertical {
            status("Pasando a vertical 9:16…")
            source = track ? try await CameraTracker.render(source, start: start, end: end, status: status)
                           : try await makeVertical(source, start: start, end: end)
            end -= start; start = 0
        }
        let asset = AVURLAsset(url: source)
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))

        var lines: [Line] = []
        if subtitles {
            status("Escuchando el audio…")
            let audio = try await exportAudio(asset, range: range)
            lines = try await transcribe(audio)
            if NIM.isConfigured && !lines.isEmpty {
                status("Corrigiendo subtítulos con IA…")
                lines = (try? await NIM.fixSubtitles(lines)) ?? lines
            }
            try? FileManager.default.removeItem(at: audio)
            if lines.isEmpty { status("No se entendió voz; se recorta sin subtítulos…") }
        }

        status("Creando el video…")
        let comp = AVMutableComposition()
        guard let vSrc = try await asset.loadTracks(withMediaType: .video).first,
              let vDst = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw YTError(message: "No se pudo leer el video.")
        }
        try vDst.insertTimeRange(range, of: vSrc, at: .zero)
        if let aSrc = try await asset.loadTracks(withMediaType: .audio).first,
           let aDst = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try aDst.insertTimeRange(range, of: aSrc, at: .zero)
        }
        let transform = try await vSrc.load(.preferredTransform)
        let natural = try await vSrc.load(.naturalSize)
        vDst.preferredTransform = transform

        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw YTError(message: "No se pudo preparar la exportación.")
        }
        let hookText = hook?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let r0 = natural.applying(transform)
        let wmLayer = Watermark.layer(for: CGSize(width: abs(r0.width), height: abs(r0.height)))
        if !lines.isEmpty || !hookText.isEmpty || wmLayer != nil {
            let r = natural.applying(transform)
            let size = CGSize(width: abs(r.width), height: abs(r.height))
            let vc = AVMutableVideoComposition()
            vc.renderSize = size
            vc.frameDuration = CMTime(value: 1, timescale: 30)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vDst)
            layer.setTransform(transform, at: .zero)
            instruction.layerInstructions = [layer]
            vc.instructions = [instruction]

            let parent = CALayer(); parent.frame = CGRect(origin: .zero, size: size)
            let videoLayer = CALayer(); videoLayer.frame = parent.frame
            parent.addSublayer(videoLayer)
            let fontSize = size.width * style.sizeFactor
            for line in lines {
                // Con tiempos por palabra: una capa por palabra con esa palabra resaltada (como CapCut).
                // Sin tiempos (o estilo sin resaltado): una sola capa para toda la frase.
                let steps: [(start: Double, end: Double, hi: Int?)] = (style.highlight != nil && !line.words.isEmpty)
                    ? line.words.enumerated().map { i, w in
                        (w.start, i + 1 < line.words.count ? line.words[i + 1].start : line.end, i) }
                    : [(line.start, line.end, nil)]
                for (k, st) in steps.enumerated() {
                    let text = CATextLayer()
                    text.string = style.attributed(line.words.isEmpty ? [line.text] : line.words.map(\.text), highlight: st.hi, size: fontSize)
                    if let box = style.box { text.backgroundColor = box.cgColor; text.cornerRadius = fontSize * 0.28 }
                    text.alignmentMode = .center
                    text.isWrapped = true
                    text.contentsScale = 2
                    text.frame = CGRect(x: size.width * 0.06, y: size.height * 0.2, width: size.width * 0.88, height: fontSize * 2.8)
                    text.opacity = 0
                    let begin = st.start <= 0 ? AVCoreAnimationBeginTimeAtZero : st.start
                    let show = CABasicAnimation(keyPath: "opacity")
                    show.fromValue = 1
                    show.toValue = 1
                    show.beginTime = begin
                    show.duration = max(0.08, st.end - st.start)
                    show.isRemovedOnCompletion = true
                    text.add(show, forKey: "show")
                    if style.pop && (k == 0 || st.hi != nil) {
                        // Pequeño «pop» al aparecer, como los subtítulos virales
                        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
                        pop.values = k == 0 ? [0.8, 1.08, 1.0] : [0.96, 1.03, 1.0]
                        pop.keyTimes = [0, 0.6, 1]
                        pop.duration = 0.16
                        pop.beginTime = begin
                        pop.isRemovedOnCompletion = true
                        text.add(pop, forKey: "pop")
                    }
                    parent.addSublayer(text)
                }
            }
            if let wmLayer { parent.addSublayer(wmLayer) }
            if !hookText.isEmpty {
                // Gancho grande arriba durante los primeros 3 segundos
                let hookSize = size.width * 0.075
                let box = CATextLayer()
                box.string = NSAttributedString(string: hookText, attributes: [
                    .font: UIFont.systemFont(ofSize: hookSize, weight: .black),
                    .foregroundColor: UIColor.white,
                ])
                box.alignmentMode = .center
                box.isWrapped = true
                box.contentsScale = 2
                box.backgroundColor = UIColor(red: 1, green: 0.04, blue: 0.54, alpha: 0.92).cgColor
                box.cornerRadius = hookSize * 0.3
                box.frame = CGRect(x: size.width * 0.07, y: size.height * 0.68, width: size.width * 0.86, height: hookSize * 2.7)
                box.opacity = 0
                let show = CABasicAnimation(keyPath: "opacity")
                show.fromValue = 1; show.toValue = 1
                show.beginTime = AVCoreAnimationBeginTimeAtZero
                show.duration = 3
                show.isRemovedOnCompletion = true
                box.add(show, forKey: "hook")
                parent.addSublayer(box)
            }
            vc.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
            export.videoComposition = vc
        }

        let out = AppStore.videosDir.appendingPathComponent(UUID().uuidString + ".mp4")
        export.outputURL = out
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { c.resume() }
        }
        guard export.status == .completed else {
            throw YTError(message: "No se pudo crear el video: \(export.error?.localizedDescription ?? "error desconocido")")
        }
        return out
    }

    /// Video horizontal a 1080×1920: al centro, con el mismo video ampliado y difuminado de fondo.
    private static func makeVertical(_ url: URL, start: Double, end: Double) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let out = CGSize(width: 1080, height: 1920)
        let vc = try await AVMutableVideoComposition.videoComposition(with: asset) { req in
            let src = req.sourceImage.clampedToExtent().cropped(to: req.sourceImage.extent)
            let e = src.extent
            let fill = max(out.width / e.width, out.height / e.height)
            let bg = src.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
                .clampedToExtent().applyingGaussianBlur(sigma: 40)
            let bgE = src.transformed(by: CGAffineTransform(scaleX: fill, y: fill)).extent
            let bgMoved = bg.transformed(by: CGAffineTransform(translationX: -bgE.minX - (bgE.width - out.width) / 2, y: -bgE.minY - (bgE.height - out.height) / 2))
                .cropped(to: CGRect(origin: .zero, size: out))
            let fit = min(out.width / e.width, out.height / e.height)
            let fg = src.transformed(by: CGAffineTransform(scaleX: fit, y: fit))
            let fgE = fg.extent
            let fgMoved = fg.transformed(by: CGAffineTransform(translationX: -fgE.minX + (out.width - fgE.width) / 2, y: -fgE.minY + (out.height - fgE.height) / 2))
            req.finish(with: fgMoved.composited(over: bgMoved), context: nil)
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
        guard ex.status == .completed else { throw YTError(message: "No se pudo pasar a vertical: \(ex.error?.localizedDescription ?? "error")") }
        return dest
    }

    static func exportAudio(_ asset: AVAsset, range: CMTimeRange) async throws -> URL {
        guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw YTError(message: "Este video no tiene audio que se pueda leer.")
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        ex.outputURL = out
        ex.outputFileType = .m4a
        ex.timeRange = range
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in ex.exportAsynchronously { c.resume() } }
        guard ex.status == .completed else { throw YTError(message: "No se pudo leer el audio del video.") }
        return out
    }

    static func transcribe(_ audio: URL) async throws -> [Line] {
        let auth = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard auth == .authorized else {
            throw YTError(message: "Activa el reconocimiento de voz para Scheduler en Ajustes del iPhone → Privacidad.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES")), recognizer.isAvailable else {
            throw YTError(message: "El reconocimiento de voz en español no está disponible ahora.")
        }
        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.addsPunctuation = true
        let segments: [SFTranscriptionSegment] = try await withCheckedThrowingContinuation { cont in
            var done = false
            recognizer.recognitionTask(with: request) { result, error in
                if done { return }
                if let result, result.isFinal {
                    done = true
                    cont.resume(returning: result.bestTranscription.segments)
                } else if let error {
                    done = true
                    // Sin voz reconocible: se sigue sin subtítulos
                    if (error as NSError).code == 1110 { cont.resume(returning: []) } else { cont.resume(throwing: error) }
                }
            }
        }
        // Agrupar en frases cortas estilo CapCut (máx. 4 palabras o una pausa), guardando el tiempo de cada palabra
        var lines: [Line] = []
        var words: [Word] = []
        var to = 0.0
        func flush(_ tail: Double) {
            guard let first = words.first else { return }
            lines.append(Line(text: words.map(\.text).joined(separator: " "), start: first.start, end: to + tail, words: words))
            words = []
        }
        for s in segments {
            if !words.isEmpty && (words.count >= 4 || s.timestamp - to > 0.7) { flush(0.12) }
            words.append(Word(text: s.substring, start: s.timestamp, end: s.timestamp + s.duration))
            to = s.timestamp + s.duration
        }
        flush(0.3)
        return lines
    }
}


/// Cómo pasar a vertical: siguiendo a la persona (cámara virtual) o al centro con fondo difuminado.
struct ReframePicker: View {
    @Binding var track: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Button { track = true } label: { Label("Seguir a la persona", systemImage: "person.crop.rectangle").frame(maxWidth: .infinity) }
                    .font(.footnote).padding(.vertical, 9)
                    .foregroundStyle(track ? .white : Theme.muted).background(track ? Theme.accent : Theme.bg2)
                Button { track = false } label: { Label("Fondo difuminado", systemImage: "square.on.square").frame(maxWidth: .infinity) }
                    .font(.footnote).padding(.vertical, 9)
                    .foregroundStyle(!track ? .white : Theme.muted).background(!track ? Theme.accent : Theme.bg2)
            }.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(track ? "Una cámara virtual sigue la cara de quien habla, sin temblores, y llena toda la pantalla."
                       : "El video entero queda al centro con el fondo difuminado.")
                .font(.caption).foregroundStyle(Theme.muted)
        }
    }
}


/// Estilos de subtítulos tipo CapCut: fuentes gruesas, borde fuerte y la palabra que se dice resaltada.
enum SubStyle: String, CaseIterable, Hashable {
    case viral, verde, rosa, comic, bebas, poppins, clasico, caja

    var sample: String {
        switch self {
        case .viral: "VIRAL"; case .verde: "VERDE"; case .rosa: "ROSA CS"; case .comic: "CÓMIC"
        case .bebas: "BEBAS"; case .poppins: "Poppins"; case .clasico: "Clásico"; case .caja: "Caja"
        }
    }
    /// Fuente incluida en la app (nombre PostScript).
    var fontName: String? {
        switch self {
        case .viral: "ArchivoBlack-Regular"; case .verde: "Anton-Regular"; case .rosa: "Poppins-Black"
        case .comic: "LuckiestGuy-Regular"; case .bebas: "BebasNeue-Regular"; case .poppins: "Poppins-ExtraBold"
        case .clasico, .caja: nil
        }
    }
    var uppercase: Bool { self != .poppins && self != .clasico && self != .caja }
    var sizeFactor: CGFloat {
        switch self { case .verde, .bebas: 0.082; case .comic: 0.07; default: 0.064 }
    }
    var base: UIColor { self == .comic ? UIColor(red: 1, green: 0.9, blue: 0.1, alpha: 1) : .white }
    /// Color de la palabra que se está diciendo (nil = sin resaltado).
    var highlight: UIColor? {
        switch self {
        case .viral: UIColor(red: 1, green: 0.9, blue: 0.0, alpha: 1)
        case .verde: UIColor(red: 0.24, green: 1, blue: 0.42, alpha: 1)
        case .rosa: UIColor(red: 1, green: 0.04, blue: 0.54, alpha: 1)
        case .comic: .white
        case .bebas: UIColor(red: 0.25, green: 0.85, blue: 1, alpha: 1)
        case .poppins: UIColor(red: 1, green: 0.04, blue: 0.54, alpha: 1)
        case .clasico, .caja: nil
        }
    }
    var stroke: Bool { self != .caja }
    var pop: Bool { self != .clasico && self != .caja }
    var box: UIColor? { self == .caja ? UIColor.black.withAlphaComponent(0.7) : nil }

    func font(_ size: CGFloat) -> UIFont {
        if let n = fontName, let f = UIFont(name: n, size: size) { return f }
        return UIFont.systemFont(ofSize: size, weight: .heavy)
    }

    /// Frase con la palabra «highlight» en el color de resaltado.
    func attributed(_ words: [String], highlight hi: Int?, size: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = size * 0.12
        shadow.shadowOffset = CGSize(width: 0, height: size * 0.05)
        for (i, w) in words.enumerated() {
            var a: [NSAttributedString.Key: Any] = [.font: font(size), .foregroundColor: (i == hi ? (highlight ?? base) : base), .shadow: shadow]
            if stroke { a[.strokeColor] = UIColor.black; a[.strokeWidth] = -4.5 }
            out.append(NSAttributedString(string: (uppercase ? w.uppercased() : w) + (i < words.count - 1 ? " " : ""), attributes: a))
        }
        return out
    }

    // Para la vista previa en la app
    var textColor: Color { Color(uiColor: base) }
    var boxColor: Color { self == .caja ? .black.opacity(0.75) : .clear }
    var previewFont: Font { fontName.map { .custom($0, size: 15) } ?? .system(size: 14, weight: .heavy) }
    var previewHighlight: Color { highlight.map { Color(uiColor: $0) } ?? textColor }
}
