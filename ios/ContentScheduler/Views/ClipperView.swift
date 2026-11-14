import SwiftUI
import PhotosUI
import AVKit
import UniformTypeIdentifiers

/// Clipper: de un video largo saca varios clips cortos y los manda a la cola.
struct ClipperView: View {
    @Environment(AppStore.self) private var store
    @Environment(YouTubeService.self) private var youtube
    @Environment(\.dismiss) private var dismiss

    struct Clip: Identifiable, Hashable { let id = UUID(); var start: Double; var end: Double; var energy: Double? }
    enum Mode: String, CaseIterable { case energia = "Más energía", dividir = "Dividir", manual = "A mano" }

    @State private var pick: PhotosPickerItem?
    @State private var importingFile = false
    private var drive: DriveService { DriveService.shared }
    @State private var source: URL?
    @State private var player: AVPlayer?
    @State private var duration = 0.0
    @State private var isHorizontal = false
    @State private var loading = false

    @State private var mode: Mode = .energia
    @State private var length = 30.0
    @State private var count = 5
    @State private var markStart = 0.0
    @State private var markEnd = 30.0
    @State private var clips: [Clip] = []
    @State private var levels: [Float] = []   // volumen por cada medio segundo

    @State private var vertical = true
    @State private var subtitles = true
    @State private var working = false
    @State private var status = ""

    var body: some View {
        NavigationStack {
            Screen {
                PageTitle(kicker: "Saca lo mejor", title: "Clipper")
                if source == nil {
                    PhotosPicker(selection: $pick, matching: .videos) {
                        VStack(spacing: 10) {
                            Image(systemName: "scissors").font(.system(size: 34)).foregroundStyle(Theme.accent)
                            Text("Elegir video largo").font(.headline).foregroundStyle(Theme.fg)
                            Text("Un en vivo, un ensayo o un concierto. Se queda en tu iPhone.").font(.caption).foregroundStyle(Theme.muted)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 34)
                        .overlay(Rectangle().strokeBorder(Theme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, dash: [5])))
                    }
                    Button { importingFile = true } label: {
                        Label("Elegir desde Archivos (Google Drive, iCloud…)", systemImage: "folder").frame(maxWidth: .infinity)
                    }.buttonStyle(BoxButtonStyle())
                    Text("Para ver tu Google Drive aquí, instala la app de Google Drive y actívala en Archivos → Explorar → ⋯ → Editar.")
                        .font(.caption).foregroundStyle(Theme.muted)
                    if loading { ProgressView("Preparando video…").frame(maxWidth: .infinity) }
                } else {
                    if let player {
                        VideoPlayer(player: player).frame(height: 240).background(.black).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    Text("Duración: \(clock(duration))").font(.caption).foregroundStyle(Theme.muted)
                    modePicker
                    switch mode {
                    case .energia: energyBox
                    case .dividir: splitBox
                    case .manual: manualBox
                    }
                    clipsList
                    optionsBox
                    if working { HStack { ProgressView(); Text(status).font(.footnote) }.frame(maxWidth: .infinity) }
                    Text(drive.isConnected && drive.useDrive
                         ? "Los clips se guardan en tu Google Drive (carpeta «Content Scheduler»), no en tu iPhone. «Guardar» estará disponible más adelante."
                         : "Los clips no se guardan en tu galería: se quedan en la app hasta subirse. Conecta Google Drive en Ajustes para guardarlos en la nube.")
                        .font(.caption).foregroundStyle(Theme.muted)
                    Button { Task { await createClips() } } label: { Text(clips.isEmpty ? "Agrega clips primero" : "Crear \(clips.count) clips y mandar a la cola") }
                        .buttonStyle(PrimaryButtonStyle()).disabled(clips.isEmpty || working)
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { cleanup(); dismiss() }.disabled(working) } }
            .onChange(of: pick) { _, item in Task { await load(item) } }
            .fileImporter(isPresented: $importingFile, allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie]) { result in
                guard case .success(let url) = result else { return }
                Task { await loadFile(url) }
            }
        }
    }

    // MARK: Modos

    private var modePicker: some View {
        HStack(spacing: 0) {
            ForEach(Mode.allCases, id: \.self) { m in
                Button(m.rawValue) { mode = m }
                    .font(.footnote).frame(maxWidth: .infinity).padding(.vertical, 10)
                    .foregroundStyle(mode == m ? .white : Theme.muted).background(mode == m ? Theme.accent : Theme.bg2)
            }
        }.overlay(Rectangle().strokeBorder(Theme.line))
    }

    private var lengthPicker: some View {
        HStack(spacing: 0) {
            ForEach([15.0, 30.0, 60.0], id: \.self) { l in
                Button("\(Int(l)) s") { length = l }
                    .font(.footnote).frame(maxWidth: .infinity).padding(.vertical, 8)
                    .foregroundStyle(length == l ? Theme.bg : Theme.muted).background(length == l ? Theme.fg : Theme.bg2)
            }
        }.overlay(Rectangle().strokeBorder(Theme.line))
    }

    private var energyBox: some View {
        Box {
            Text("La app mide el volumen real del audio y busca los tramos más intensos (gritos, risas, aplausos, el coro).")
                .font(.caption).foregroundStyle(Theme.muted)
            lengthPicker
            Stepper("Cuántos clips: \(count)", value: $count, in: 1...15).font(.footnote)
            if !levels.isEmpty { energyGraph }
            Button {
                Task { await findEnergy() }
            } label: { Label(levels.isEmpty ? "Analizar el audio" : "Buscar momentos", systemImage: "waveform") }
                .buttonStyle(BoxButtonStyle(filled: true)).disabled(working)
        }
    }

    private var energyGraph: some View {
        let maxL = max(levels.max() ?? 1, 0.0001)
        return GeometryReader { g in
            ZStack(alignment: .bottomLeading) {
                Path { p in
                    let n = max(levels.count, 1)
                    for (i, l) in levels.enumerated() {
                        let x = g.size.width * CGFloat(i) / CGFloat(n)
                        let h = g.size.height * CGFloat(l / maxL)
                        p.addRect(CGRect(x: x, y: g.size.height - h, width: max(1, g.size.width / CGFloat(n)), height: h))
                    }
                }.fill(Theme.muted.opacity(0.5))
                ForEach(clips) { c in
                    Rectangle().fill(Theme.accent.opacity(0.45))
                        .frame(width: max(2, g.size.width * (c.end - c.start) / duration))
                        .offset(x: g.size.width * c.start / duration)
                }
            }
        }
        .frame(height: 60)
    }

    private var splitBox: some View {
        Box {
            Text("Corta todo el video en partes iguales, una detrás de otra.").font(.caption).foregroundStyle(Theme.muted)
            lengthPicker
            Text("Salen \(Int(ceil(duration / length))) partes.").font(.footnote)
            Button {
                clips = stride(from: 0.0, to: duration, by: length).map { Clip(start: $0, end: min(duration, $0 + length)) }
                    .filter { $0.end - $0.start >= 3 }
            } label: { Label("Dividir", systemImage: "rectangle.split.3x1") }
                .buttonStyle(BoxButtonStyle(filled: true))
        }
    }

    private var manualBox: some View {
        Box {
            Text("Mueve el video hasta donde quieras y marca inicio y final.").font(.caption).foregroundStyle(Theme.muted)
            HStack {
                Text("Inicio").font(.footnote).frame(width: 50, alignment: .leading)
                Slider(value: $markStart, in: 0...max(duration, 1)) { e in if !e { seek(markStart) } }
                Text(clock(markStart)).font(.system(size: 12, design: .monospaced)).frame(width: 44)
            }
            HStack {
                Text("Final").font(.footnote).frame(width: 50, alignment: .leading)
                Slider(value: $markEnd, in: 0...max(duration, 1)) { e in if !e { seek(max(markStart, markEnd - 2)) } }
                Text(clock(markEnd)).font(.system(size: 12, design: .monospaced)).frame(width: 44)
            }
            HStack(spacing: 10) {
                Button("Inicio = ahora") { markStart = now() }.buttonStyle(BoxButtonStyle())
                Button("Final = ahora") { markEnd = now() }.buttonStyle(BoxButtonStyle())
            }
            Button {
                guard markEnd - markStart >= 2 else { return store.show("El clip tiene que durar al menos 2 segundos") }
                clips.append(Clip(start: markStart, end: markEnd))
                clips.sort { $0.start < $1.start }
            } label: { Label("Agregar este clip", systemImage: "plus") }
                .buttonStyle(BoxButtonStyle(filled: true))
        }
    }

    private var clipsList: some View {
        Group {
            if !clips.isEmpty {
                SectionLabel(text: "Clips (\(clips.count))")
                ForEach(clips) { c in
                    HStack {
                        Button { seek(c.start); player?.play() } label: { Image(systemName: "play.circle.fill").font(.title2) }
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(clock(c.start)) → \(clock(c.end))").font(.system(size: 14, weight: .semibold, design: .monospaced))
                            Text("\(Int(c.end - c.start)) s" + (c.energy.map { " · energía \(Int($0 * 100))%" } ?? "")).font(.caption).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        // Guardar en Fotos: suspendido por ahora (los clips no se guardan en el iPhone)
                        Button { } label: { Label("Guardar", systemImage: "square.and.arrow.down").font(.caption.bold()) }
                            .disabled(true).foregroundStyle(Theme.muted.opacity(0.5))
                        Button { clips.removeAll { $0.id == c.id } } label: { Image(systemName: "xmark") }.foregroundStyle(Theme.muted)
                    }
                    .padding(10).background(Theme.bg2).overlay(Rectangle().strokeBorder(Theme.line))
                }
            }
        }
    }

    private var optionsBox: some View {
        Box {
            if isHorizontal {
                Toggle(isOn: $vertical) {
                    VStack(alignment: .leading) {
                        Text("Vertical 9:16").bold()
                        Text("Para Reels y Shorts, con fondo difuminado.").font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                Divider().overlay(Theme.line)
            }
            Toggle(isOn: $subtitles) {
                VStack(alignment: .leading) {
                    Text("Subtítulos automáticos").bold()
                    Text("Tarda más: el iPhone escucha cada clip.").font(.caption).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    // MARK: Acciones

    private func clock(_ s: Double) -> String {
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t % 3600 / 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
    private func seek(_ s: Double) { player?.seek(to: CMTime(seconds: s, preferredTimescale: 600)) }
    private func now() -> Double { player?.currentTime().seconds ?? 0 }

    private func load(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        loading = true
        defer { loading = false; pick = nil }
        guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else { return store.show("No se pudo leer el video.") }
        await open(movie.url)
    }

    /// Video elegido en Archivos (Drive, iCloud…): se copia a la app para poder cortarlo.
    private func loadFile(_ url: URL) async {
        loading = true
        defer { loading = false }
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        let dest = AppStore.videosDir.appendingPathComponent(UUID().uuidString + "." + (url.pathExtension.isEmpty ? "mov" : url.pathExtension))
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            await open(dest)
        } catch {
            store.show("No se pudo abrir ese archivo. Si está en Drive, márcalo «Disponible sin conexión» e intenta otra vez.")
        }
    }

    private func open(_ url: URL) async {
        cleanup()
        source = url
        player = AVPlayer(url: url)
        let asset = AVURLAsset(url: url)
        duration = (try? await asset.load(.duration).seconds) ?? 0
        markEnd = min(duration, 30)
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize), let t = try? await track.load(.preferredTransform) {
            let r = size.applying(t)
            isHorizontal = abs(r.width) > abs(r.height)
        }
        vertical = isHorizontal
        clips = []
        levels = []
    }

    private func findEnergy() async {
        guard let source else { return }
        working = true
        defer { working = false }
        if levels.isEmpty {
            status = "Analizando el audio…"
            do { levels = try await AudioEnergy.levels(of: source, window: 0.5) }
            catch { return store.show(error.localizedDescription) }
            if levels.isEmpty { return store.show("Este video no tiene audio para analizar.") }
        }
        let win = max(1, Int(length / 0.5))
        guard levels.count > win else {
            clips = [Clip(start: 0, end: duration, energy: 1)]
            return
        }
        // Suma de volumen de cada tramo posible y se eligen los más fuertes sin que se encimen
        var sums: [(i: Int, v: Float)] = []
        var acc: Float = levels[0..<win].reduce(0, +)
        sums.append((0, acc))
        for i in 1...(levels.count - win) {
            acc += levels[i + win - 1] - levels[i - 1]
            sums.append((i, acc))
        }
        let best = sums.map(\.v).max() ?? 1
        var chosen: [Clip] = []
        for s in sums.sorted(by: { $0.v > $1.v }) where chosen.count < count {
            let st = Double(s.i) * 0.5, en = min(duration, st + length)
            if chosen.contains(where: { st < $0.end && en > $0.start }) { continue }
            chosen.append(Clip(start: st, end: en, energy: Double(s.v / max(best, 0.0001))))
        }
        clips = chosen.sorted { $0.start < $1.start }
        if !clips.isEmpty { seek(clips[0].start) }
    }

    private func createClips() async {
        guard let source else { return }
        working = true
        player?.pause()
        var made = 0
        for (i, c) in clips.enumerated() {
            status = "Creando clip \(i + 1) de \(clips.count)…"
            do {
                let url = try await StudioExport.run(source: source, start: c.start, end: c.end, subtitles: subtitles, vertical: vertical && isHorizontal) { _ in }
                let id = await store.addVideo(from: url, youtubeConnected: youtube.isConnected)
                if drive.isConnected && drive.useDrive {
                    status = "Guardando clip \(i + 1) en Google Drive…"
                    do {
                        let did = try await drive.upload(url, name: "Clip \(i + 1) · \(Date.now.formatted(.dateTime.day().month().hour().minute())).mp4")
                        store.update(id) { $0.driveID = did }
                        store.deleteVideoFile(of: id)   // ya está en la nube: no ocupa espacio en el iPhone
                    } catch {
                        store.show("Clip \(i + 1) quedó en el iPhone: \(error.localizedDescription)")
                    }
                }
                made += 1
            } catch {
                store.show("Clip \(i + 1): \(error.localizedDescription)")
            }
        }
        working = false
        if made > 0 {
            store.show("\(made) clips agregados a la cola")
            cleanup()
            dismiss()
        }
    }

    private func cleanup() {
        player?.pause()
        if let source { try? FileManager.default.removeItem(at: source) }
        source = nil
        player = nil
    }
}

/// Mide el volumen (RMS) del audio por ventanas, leyendo las muestras reales del video.
enum AudioEnergy {
    static func levels(of url: URL, window: Double) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let rate = 8_000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw YTError(message: "No se pudo leer el audio del video.") }
        let per = Int(rate * window)
        var levels: [Float] = []
        var sum: Double = 0
        var n = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == noErr,
                  let ptr else { continue }
            ptr.withMemoryRebound(to: Int16.self, capacity: length / 2) { samples in
                for i in 0..<(length / 2) {
                    let v = Double(samples[i]) / 32768
                    sum += v * v
                    n += 1
                    if n == per {
                        levels.append(Float((sum / Double(n)).squareRoot()))
                        sum = 0; n = 0
                    }
                }
            }
        }
        if n > per / 4 { levels.append(Float((sum / Double(n)).squareRoot())) }
        return levels
    }
}
