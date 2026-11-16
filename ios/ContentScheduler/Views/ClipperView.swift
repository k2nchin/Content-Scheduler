import SwiftUI
import PhotosUI
import AVKit
import UniformTypeIdentifiers

/// Clipper: de un video largo saca varios clips cortos y los manda a la cola.
struct ClipperView: View {
    /// En la barra de abajo no hay botón «Cerrar».
    var inTab = false
    @Environment(AppStore.self) private var store
    @Environment(YouTubeService.self) private var youtube
    @Environment(\.dismiss) private var dismiss

    struct Clip: Identifiable, Hashable { let id = UUID(); var start: Double; var end: Double; var energy: Double?; var ai: ClipAI.Result? = nil }
    enum Mode: String, CaseIterable { case ia = "IA", ambos = "IA + Energía", energia = "Energía", dividir = "Dividir", manual = "A mano" }
    enum Step { case fuente, ajustes, procesando, resultados }
    /// Clip ya creado, esperando que decidas qué hacer con él.
    struct Made: Identifiable { let id = UUID(); let url: URL; let clip: Clip; var thumb: UIImage?; var title: String }

    @State private var pick: PhotosPickerItem?
    @State private var importingFile = false
    @State private var live = false
    @State private var twitchOpen = false
    @State private var ytLiveOpen = false
    @State private var ytLink = ""
    @Environment(\.openURL) private var openURL
    private var drive: DriveService { DriveService.shared }
    @State private var source: URL?
    @State private var player: AVPlayer?
    @State private var duration = 0.0
    @State private var isHorizontal = false
    @State private var loading = false

    @State private var mode: Mode = .ia
    @State private var transcript: [StudioExport.Line] = []
    @State private var length = 30.0
    @State private var count = 5
    @State private var markStart = 0.0
    @State private var markEnd = 30.0
    @State private var clips: [Clip] = []
    @State private var levels: [Float] = []   // volumen por cada medio segundo

    @State private var vertical = true
    @State private var track = true
    @State private var subtitles = true
    @State private var hooks = true
    @State private var working = false
    @State private var status = ""
    @State private var step: Step = .fuente
    @State private var subStyle: SubStyle = .viral
    @State private var subEffect: SubEffect = .pop
    @State private var subPos: SubPosition = .abajo
    @State private var noSilence = true
    @State private var autoEmoji = true
    @State private var progressBar = true
    @State private var made: [Made] = []
    @State private var progress = 0.0
    @State private var stage = 0          // 0 escuchar, 1 elegir, 2 crear
    @State private var preview: Made?
    @State private var byScore = true

    var body: some View {
        NavigationStack {
            Screen {
                PageTitle(kicker: stepKicker, title: "Clipper")
                stepBar
                switch step {
                case .fuente: sourceStep
                case .ajustes: settingsStep
                case .procesando: processingStep
                case .resultados: resultsStep
                }
            }
            .animation(.snappy(duration: 0.25), value: step)
            .toolbar {
                if !inTab { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { discardAll(); cleanup(); dismiss() }.disabled(working) } }
            }
            .onChange(of: pick) { _, item in Task { await load(item); if source != nil { step = .ajustes } } }
            .fullScreenCover(isPresented: $live) { LiveClipperView() }
            .sheet(isPresented: $twitchOpen) { TwitchView() }
            .sheet(isPresented: $ytLiveOpen) { YouTubeLiveView() }
            .sheet(item: $preview) { m in ResultPreview(made: m, onQueue: { t in Task { await queue(m, title: t) } }, onDiscard: { discard(m) }) }
            .fileImporter(isPresented: $importingFile, allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie]) { result in
                guard case .success(let url) = result else { return }
                Task { await loadFile(url); if source != nil { step = .ajustes } }
            }
        }
    }

    // MARK: Pasos

    private var stepKicker: String {
        switch step { case .fuente: "Paso 1 · Fuente"; case .ajustes: "Paso 2 · Ajustes"; case .procesando: "Paso 3 · Creando"; case .resultados: "Paso 4 · Tus clips" }
    }

    private var stepBar: some View {
        let order: [Step] = [.fuente, .ajustes, .procesando, .resultados]
        let names = ["Fuente", "Ajustes", "Creando", "Clips"]
        let current = order.firstIndex(of: step) ?? 0
        return HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { i in
                VStack(spacing: 4) {
                    Rectangle().fill(i <= current ? Theme.accent : Theme.line).frame(height: 3)
                    Text(names[i]).font(.system(size: 10, weight: i == current ? .bold : .regular, design: .monospaced))
                        .foregroundStyle(i == current ? Theme.fg : Theme.muted)
                }
            }
        }
    }

    private func sourceCard(_ icon: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(.white).frame(width: 48, height: 48).background(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title3).foregroundStyle(Theme.fg)
                Text(detail).font(.footnote).foregroundStyle(Theme.muted)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
        }
        .padding(16).background(Theme.bg2).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private var sourceStep: some View {
        if let pack = PendingMarks.pack, !pack.offsets.isEmpty {
            Box {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "bookmark.fill").foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(pack.offsets.count) momentos de \(pack.channel)").bold()
                        Text("Elige el archivo del directo y se cortan solos en esos puntos.").font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 0)
                }
                Button("Descartar los momentos") { PendingMarks.clear() }
                    .font(.caption.bold()).foregroundStyle(Theme.red)
            }
        }
        PhotosPicker(selection: $pick, matching: .videos) {
            sourceCard("photo.on.rectangle", Theme.accent, "Video de tu galería", "Un en vivo, un ensayo, un podcast o un concierto.")
        }.buttonStyle(.plain)
        Button { importingFile = true } label: {
            sourceCard("folder", Color(hex: 0x1A73E8), "Archivos o Google Drive", "Para videos largos guardados en la nube.")
        }.buttonStyle(.plain)
        Button { live = true } label: {
            sourceCard("record.circle", .red, "Clipping en vivo", "Graba con la cámara y te va dando clips.")
        }.buttonStyle(.plain)
        Button { twitchOpen = true } label: {
            sourceCard("dot.radiowaves.left.and.right", Color(hex: 0x9146FF), "Twitch", "Clipea un directo cuando el chat explota.")
        }.buttonStyle(.plain)
        Button { ytLiveOpen = true } label: {
            sourceCard("play.rectangle.fill", Color(hex: 0xFF0000), "YouTube en vivo", "Marca los momentos en que el chat explota.")
        }.buttonStyle(.plain)
        if loading { ProgressView("Preparando video…").frame(maxWidth: .infinity) }
        Box {
            Text("TU VIDEO DE YOUTUBE").font(Theme.mono).foregroundStyle(Theme.muted)
            TextField("https://youtu.be/… o youtube.com/live/…", text: $ytLink)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(12).background(Theme.bg3, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Button {
                guard let id = youtubeID(ytLink) else { return store.show("Ese no parece un link de YouTube.") }
                openURL(URL(string: "https://studio.youtube.com/video/\(id)/edit")!)
            } label: { Label("Abrir descarga en YouTube Studio", systemImage: "arrow.down.circle").frame(maxWidth: .infinity) }
                .buttonStyle(BoxButtonStyle())
            Text("Solo videos de tu canal: en YouTube Studio toca ⋮ → Descargar y luego elígelo en «Archivos o Google Drive».")
                .font(.caption).foregroundStyle(Theme.muted)
        }
    }

    @ViewBuilder private var settingsStep: some View {
        if let player {
            VideoPlayer(player: player).frame(height: 220).background(.black).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        HStack {
            Text("Duración del video: \(clock(duration))").font(.caption).foregroundStyle(Theme.muted)
            Spacer()
            Button("Cambiar video") { cleanup(); step = .fuente }.font(.caption.bold())
        }
        SectionLabel(text: "Cómo elegir los momentos")
        modePicker
        if mode == .ia || mode == .ambos {
            if !ClipAI.isConfigured {
                DemoBanner(text: "Para usar la IA pon tu clave de NVIDIA en Ajustes → IA. Mientras tanto usa «Energía».", icon: "exclamationmark.triangle")
            } else {
                Text("La IA lee lo que se dice y elige lo más viral, con gancho, títulos por red y hashtags.").font(.caption).foregroundStyle(Theme.muted)
            }
        }
        if mode == .energia || mode == .ambos {
            Text("Energía: busca gritos, risas, aplausos y el coro en el audio.").font(.caption).foregroundStyle(Theme.muted)
        }
        if mode == .manual { manualBox; clipsList }
        if mode != .manual {
            SectionLabel(text: "Duración y cantidad")
            lengthPicker
            if mode != .dividir {
                Stepper("Cuántos clips: \(count)", value: $count, in: 1...15).font(.footnote)
            } else {
                Text("Salen \(Int(ceil(duration / length))) partes.").font(.footnote)
            }
        }
        SectionLabel(text: "Formato y estilo")
        optionsBox
        Box {
            Toggle(isOn: $noSilence) {
                VStack(alignment: .leading) {
                    Text("Quitar silencios").bold()
                    Text("Corta las pausas de más de 0,7 s para que el clip no pierda ritmo.").font(.caption).foregroundStyle(Theme.muted)
                }
            }
            Divider().overlay(Theme.line)
            Toggle(isOn: $autoEmoji) {
                VStack(alignment: .leading) {
                    Text("Emojis automáticos").bold()
                    Text("Pone un emoji grande según lo que se dice (🔥 😂 😳 🇩🇴…).").font(.caption).foregroundStyle(Theme.muted)
                }
            }.disabled(!subtitles)
            Divider().overlay(Theme.line)
            Toggle(isOn: $progressBar) {
                VStack(alignment: .leading) {
                    Text("Barra de progreso").bold()
                    Text("Una línea rosa abajo que se llena; ayuda a que vean el clip completo.").font(.caption).foregroundStyle(Theme.muted)
                }
            }
        }
        if subtitles {
            Box {
                Text("POSICIÓN").font(Theme.mono).foregroundStyle(Theme.muted)
                Picker("Posición", selection: $subPos) {
                    ForEach(SubPosition.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                Text("EFECTO").font(Theme.mono).foregroundStyle(Theme.muted)
                SubEffectPicker(effect: $subEffect)
                Text("ESTILO DE SUBTÍTULOS").font(Theme.mono).foregroundStyle(Theme.muted)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(SubStyle.allCases, id: \.self) { st in
                        Button { subStyle = st } label: {
                            (Text("ESTO ").foregroundStyle(st.textColor) + Text(st.sample).foregroundStyle(st.previewHighlight))
                                .font(st.previewFont).shadow(color: .black, radius: 1, x: 1, y: 1)
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(st.boxColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(Color.gray.opacity(0.35))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(subStyle == st ? Theme.accent : .clear, lineWidth: 2))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        Button { Task { await process() } } label: { Text(mode == .manual && clips.isEmpty ? "Marca al menos un clip" : "Crear clips") }
            .buttonStyle(PrimaryButtonStyle()).disabled(working || (mode == .manual && clips.isEmpty))
    }

    @ViewBuilder private var processingStep: some View {
        Box {
            ForEach(Array(["Escuchando el video", "Eligiendo los mejores momentos", "Creando los clips"].enumerated()), id: \.offset) { i, name in
                HStack(spacing: 10) {
                    Image(systemName: i < stage ? "checkmark.circle.fill" : i == stage ? "circle.dotted" : "circle")
                        .foregroundStyle(i < stage ? Theme.ok : i == stage ? Theme.accent : Theme.muted)
                    Text(name).font(.subheadline.weight(i == stage ? .bold : .regular)).foregroundStyle(i <= stage ? Theme.fg : Theme.muted)
                }
            }
            if stage == 2 { ProgressView(value: progress).tint(Theme.accent) }
            Text(status).font(.caption).foregroundStyle(Theme.muted)
        }
        Text("Puedes cambiar de pestaña; no cierres la app hasta que termine. Todo se hace en tu iPhone.").font(.caption).foregroundStyle(Theme.muted)
    }

    @ViewBuilder private var resultsStep: some View {
        HStack {
            Text("\(made.count) clips listos").font(.headline)
            Spacer()
            Button(byScore ? "Por puntaje" : "Por orden") { byScore.toggle() }.font(.caption.bold())
        }
        if made.isEmpty {
            Text("No quedó ningún clip. Prueba con otra duración o con «Energía».").font(.footnote).foregroundStyle(Theme.muted)
        }
        let list = byScore ? made.sorted { ($0.clip.ai?.score ?? Int(($0.clip.energy ?? 0) * 100)) > ($1.clip.ai?.score ?? Int(($1.clip.energy ?? 0) * 100)) } : made
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(list) { m in
                Button { preview = m } label: { ResultCard(made: m) }.buttonStyle(.plain)
            }
        }
        if !made.isEmpty {
            Button { Task { for m in made { await queue(m, title: m.title) } } } label: { Text("Mandar todos a la cola (\(made.count))") }
                .buttonStyle(PrimaryButtonStyle()).disabled(working)
        }
        Button { discardAll(); cleanup(); step = .fuente } label: { Text("Nuevo video").frame(maxWidth: .infinity) }
            .buttonStyle(BoxButtonStyle())
        Text(drive.isConnected && drive.useDrive ? "Al mandarlos a la cola se guardan en tu Google Drive, no en tu iPhone." : "Toca un clip para verlo, cambiar el título, mandarlo a la cola o descartarlo.")
            .font(.caption).foregroundStyle(Theme.muted)
    }

    // MARK: Modos

    private var modePicker: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            ForEach(Mode.allCases, id: \.self) { m in
                Button(m.rawValue) { mode = m }
                    .font(.footnote).lineLimit(1).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .foregroundStyle(mode == m ? .white : Theme.muted).background(mode == m ? Theme.accent : Theme.bg2)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var lengthPicker: some View {
        HStack(spacing: 0) {
            ForEach([15.0, 30.0, 60.0], id: \.self) { l in
                Button("\(Int(l)) s") { length = l }
                    .font(.footnote).frame(maxWidth: .infinity).padding(.vertical, 8)
                    .foregroundStyle(length == l ? Theme.bg : Theme.muted).background(length == l ? Theme.fg : Theme.bg2)
            }
        }.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var aiBox: some View {
        Box {
            Text("La IA (NVIDIA NIM) lee lo que se dice en el video y elige los momentos con más potencial viral, con gancho, títulos por red y hashtags. El iPhone transcribe el audio; solo el texto va a la IA.")
                .font(.caption).foregroundStyle(Theme.muted)
            if !ClipAI.isConfigured {
                DemoBanner(text: "Falta conectar la IA: pon tu clave de NVIDIA en Ajustes → IA. Mientras tanto usa «Energía».", icon: "exclamationmark.triangle")
            }
            lengthPicker
            Stepper("Cuántos clips: \(count)", value: $count, in: 1...15).font(.footnote)
            Button { Task { await findAI() } } label: {
                Label(transcript.isEmpty ? "Analizar con IA" : "Buscar otra vez con IA", systemImage: "sparkles")
            }
            .buttonStyle(BoxButtonStyle(filled: true)).disabled(working || !ClipAI.isConfigured)
            if !transcript.isEmpty {
                Text("Transcripción lista: \(transcript.count) frases.").font(.caption).foregroundStyle(Theme.muted)
            }
        }
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
                            if let ai = c.ai {
                                HStack(spacing: 6) {
                                    Text("\(ai.score)").font(.system(size: 12, weight: .heavy, design: .monospaced))
                                        .foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(ai.score >= 70 ? Theme.ok : ai.score >= 45 ? Theme.warn : Theme.muted)
                                    Text(ai.titles.youtube.isEmpty ? ai.hook : ai.titles.youtube).font(.caption.bold()).lineLimit(2)
                                }
                                if !ai.reason.isEmpty { Text(ai.reason).font(.caption2).foregroundStyle(Theme.muted).lineLimit(3) }
                                if !ai.hashtags.isEmpty { Text(ai.hashtags.joined(separator: " ")).font(.caption2).foregroundStyle(Theme.accent).lineLimit(1) }
                            }
                        }
                        Spacer()
                        // Guardar en Fotos: suspendido por ahora (los clips no se guardan en el iPhone)
                        Button { } label: { Label("Guardar", systemImage: "square.and.arrow.down").font(.caption.bold()) }
                            .disabled(true).foregroundStyle(Theme.muted.opacity(0.5))
                        Button { clips.removeAll { $0.id == c.id } } label: { Image(systemName: "xmark") }.foregroundStyle(Theme.muted)
                    }
                    .padding(10).background(Theme.bg2).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                        Text("Para Reels y Shorts.").font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                if vertical { ReframePicker(track: $track) }
                Divider().overlay(Theme.line)
            }
            if clips.contains(where: { !($0.ai?.hook ?? "").isEmpty }) {
                Toggle(isOn: $hooks) {
                    VStack(alignment: .leading) {
                        Text("Gancho en pantalla").bold()
                        Text("Pone el gancho de la IA arriba en los primeros 3 segundos de cada clip.").font(.caption).foregroundStyle(Theme.muted)
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

    /// Saca el id del video de un link de YouTube (youtu.be, watch?v=, shorts, live).
    private func youtubeID(_ link: String) -> String? {
        guard let u = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)), let host = u.host?.lowercased(), host.contains("youtu") else { return nil }
        if let v = u.queryItems?.first(where: { $0.name == "v" })?.value { return v }
        let parts = u.path.split(separator: "/").map(String.init)
        if host.contains("youtu.be") { return parts.first }
        if let i = parts.firstIndex(where: { ["shorts", "live", "embed"].contains($0) }), i + 1 < parts.count { return parts[i + 1] }
        return nil
    }

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
        transcript = []
        applyPendingMarks()
    }

    /// Convierte los momentos marcados en el directo en clips, ajustados a la duración del archivo.
    private func applyPendingMarks() {
        guard let pack = PendingMarks.pack, !pack.offsets.isEmpty else { return }
        let marks = pack.offsets.filter { $0 < duration + 60 }
        guard !marks.isEmpty else {
            store.show("Los momentos no caben en este video: ¿es el directo completo?")
            return
        }
        var out: [Clip] = []
        for m in marks {
            let end = min(duration, m + 5)
            let start = max(0, end - length)
            guard end - start >= 3, !out.contains(where: { start < $0.end && end > $0.start }) else { continue }
            out.append(Clip(start: start, end: end))
        }
        guard !out.isEmpty else { return }
        clips = out
        mode = .manual
        PendingMarks.clear()
        store.show("\(out.count) clips marcados desde el directo de \(pack.channel)")
    }

    private func findAI() async {
        guard let source else { return }
        working = true
        defer { working = false }
        do {
            if transcript.isEmpty {
                transcript = try await ClipAI.transcribe(source, duration: duration) { status = $0 }
                if transcript.isEmpty { return store.show("No se entendió voz en el video. Usa «Energía» para videos sin diálogo.") }
            }
            status = "La IA está eligiendo los mejores momentos…"
            if NIM.isConfigured {
                let found = try await NIM.findClips(lines: transcript, duration: duration, count: count, length: length)
                if found.isEmpty { return store.show("La IA no encontró momentos claros. Prueba con otra duración o con «Energía».") }
                clips = found.map { Clip(start: $0.start, end: $0.end, energy: nil, ai: $0) }.sorted { $0.start < $1.start }
                seek(clips[0].start)
                return
            }
            let token: String
            if youtube.isConnected { token = try await youtube.activeToken() }
            else if DriveService.shared.isConnected { token = try await DriveService.shared.accessToken() }
            else { return store.show("Conecta YouTube o Google Drive en Ajustes para usar la IA.") }
            let found = try await ClipAI.findClips(lines: transcript, duration: duration, count: count, length: length, token: token)
            if found.isEmpty { return store.show("La IA no encontró momentos claros. Prueba con otra duración o con «Energía».") }
            clips = found.map { Clip(start: $0.start, end: $0.end, energy: nil, ai: $0) }.sorted { $0.start < $1.start }
            seek(clips[0].start)
        } catch {
            store.show(error.localizedDescription)
        }
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

    /// Paso 3: elige los momentos (según el modo) y crea cada clip; luego muestra los resultados.
    private func process() async {
        guard let source else { return }
        player?.pause()
        step = .procesando
        stage = 0; progress = 0
        switch mode {
        case .ia:
            await findAI()
        case .energia:
            stage = 1; await findEnergy()
        case .ambos:
            await findAI()
            let ai = clips
            stage = 1
            await findEnergy()
            var merged = ai
            for e in clips.sorted(by: { ($0.energy ?? 0) > ($1.energy ?? 0) }) where merged.count < count {
                if !merged.contains(where: { e.start < $0.end && e.end > $0.start }) { merged.append(e) }
            }
            clips = merged.sorted { $0.start < $1.start }
        case .dividir:
            clips = stride(from: 0.0, to: duration, by: length).map { Clip(start: $0, end: min(duration, $0 + length)) }.filter { $0.end - $0.start >= 3 }
        case .manual:
            break
        }
        guard !clips.isEmpty else { step = .ajustes; return }
        stage = 2
        working = true
        defer { working = false }
        for (i, c) in clips.enumerated() {
            status = "Creando clip \(i + 1) de \(clips.count)…"
            progress = Double(i) / Double(clips.count)
            do {
                let url = try await StudioExport.run(source: source, start: c.start, end: c.end, subtitles: subtitles,
                                                     vertical: vertical && isHorizontal, track: track,
                                                     hook: hooks ? c.ai?.hook : nil, style: subStyle, effect: subEffect,
                                                     removeSilence: noSilence, emojis: autoEmoji && subtitles, progressBar: progressBar, position: subPos) { _ in }
                let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 400, height: 400)
                let thumb = (try? await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image).map { UIImage(cgImage: $0) }
                var base = ""
                if let ai = c.ai { base = ai.titles.youtube.isEmpty ? ai.hook : ai.titles.youtube }
                let title = base.isEmpty ? "Clip \(i + 1)" : base
                made.append(Made(url: url, clip: c, thumb: thumb, title: title))
            } catch {
                store.show("Clip \(i + 1): \(error.localizedDescription)")
            }
        }
        progress = 1
        clips = []
        step = .resultados
        Notifier.send("✂️ Tus clips están listos", "\(made.count) clips para revisar en el Clipper.")
    }

    /// Manda un clip a la cola (con los textos de la IA) y, si está activado, a Google Drive.
    private func queue(_ m: Made, title: String) async {
        guard made.contains(where: { $0.id == m.id }) else { return }
        let id = await store.addVideo(from: m.url, youtubeConnected: youtube.isConnected)
        store.update(id) {
            $0.title = String(title.prefix(100))
            if let ai = m.clip.ai {
                $0.custom = [Network.instagram.rawValue: ai.titles.instagram, Network.facebook.rawValue: ai.titles.facebook].filter { !$0.value.isEmpty }
                if !ai.hashtags.isEmpty { $0.tags = ai.hashtags.joined(separator: " ") }
            }
        }
        if drive.isConnected && drive.useDrive, let did = try? await drive.upload(m.url, name: "\(title.prefix(40)).mp4") {
            store.update(id) { $0.driveID = did }
            store.deleteVideoFile(of: id)
        }
        made.removeAll { $0.id == m.id }
        store.show("Clip en la cola ✓")
        if made.isEmpty { cleanup(); step = .fuente }
    }

    private func discard(_ m: Made) {
        try? FileManager.default.removeItem(at: m.url)
        made.removeAll { $0.id == m.id }
    }

    private func discardAll() {
        for m in made { try? FileManager.default.removeItem(at: m.url) }
        made = []
    }

    private func cleanup() {
        player?.pause()
        if let source { try? FileManager.default.removeItem(at: source) }
        source = nil
        player = nil
    }
}

/// Tarjeta de un clip terminado (galería de resultados).
struct ResultCard: View {
    let made: ClipperView.Made
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let t = made.thumb { Image(uiImage: t).resizable().scaledToFill() } else { Theme.bg3 }
                }
                .frame(maxWidth: .infinity).frame(height: 210).clipped()
                if let score = made.clip.ai?.score {
                    Text("\(score)").font(.system(size: 13, weight: .heavy, design: .monospaced)).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(score >= 70 ? Theme.ok : score >= 45 ? Theme.warn : Theme.muted).padding(6)
                } else if let e = made.clip.energy {
                    Label("\(Int(e * 100))", systemImage: "waveform").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3).background(.black.opacity(0.6)).padding(6)
                }
                Image(systemName: "play.circle.fill").font(.system(size: 34)).foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 210)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(made.title).font(.footnote.bold()).lineLimit(2).foregroundStyle(Theme.fg)
            Text("\(Int(made.clip.end - made.clip.start)) s").font(.caption2).foregroundStyle(Theme.muted)
        }
        .padding(8).background(Theme.bg2).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Ver un clip terminado, cambiar su título y decidir: a la cola o descartar.
struct ResultPreview: View {
    let made: ClipperView.Made
    let onQueue: (String) -> Void
    let onDiscard: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            Screen {
                if let player {
                    VideoPlayer(player: player).frame(height: 420).background(.black).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                if let ai = made.clip.ai {
                    HStack(spacing: 8) {
                        Text("\(ai.score)").font(.system(size: 14, weight: .heavy, design: .monospaced)).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(ai.score >= 70 ? Theme.ok : ai.score >= 45 ? Theme.warn : Theme.muted)
                        Text("Potencial viral").font(.caption).foregroundStyle(Theme.muted)
                    }
                    if !ai.reason.isEmpty { Text(ai.reason).font(.footnote).foregroundStyle(Theme.muted) }
                    if !ai.hashtags.isEmpty { Text(ai.hashtags.joined(separator: " ")).font(.caption).foregroundStyle(Theme.accent) }
                }
                Text("Título").font(.caption).foregroundStyle(Theme.muted)
                TextField("Título", text: $title, axis: .vertical).lineLimit(1...3).padding(12).background(Theme.bg3, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Button { onQueue(title); dismiss() } label: { Text("A la cola") }.buttonStyle(PrimaryButtonStyle())
                Button(role: .destructive) { onDiscard(); dismiss() } label: { Text("Descartar") }
                    .buttonStyle(PrimaryButtonStyle(filled: false, color: Theme.red))
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } } }
            .onAppear { title = made.title; player = AVPlayer(url: made.url); player?.play() }
            .onDisappear { player?.pause() }
        }
    }
}

/// Mide el volumen (RMS) del audio por ventanas, leyendo las muestras reales del video.
enum AudioEnergy {
    static func levels(of url: URL, window: Double, range: CMTimeRange? = nil) async throws -> [Float] {
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
        if let range { reader.timeRange = range }
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
