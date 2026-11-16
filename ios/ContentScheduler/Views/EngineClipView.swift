import SwiftUI

/// Mandar un link al motor de clipping del iMac y traerse los clips que devuelve.
///
/// El iPhone no corta nada aquí: solo manda el link, mira cómo va y se baja los clips.
/// Así puedes clipear un stream de cuatro horas sin que el teléfono sude ni se caliente.
struct EngineClipView: View {
    @Environment(AppStore.self) private var store
    @Environment(YouTubeService.self) private var youtube
    @Environment(\.dismiss) private var dismiss

    @State private var link = ""
    @State private var taskID = ""
    @State private var working = false
    @State private var progress = 0.0
    @State private var status = ""
    @State private var clips: [ClipEngine.Clip] = []
    @State private var chosen: Set<String> = []
    @State private var saving = false
    @State private var job: Task<Void, Never>?

    @AppStorage("engine.format") private var format = "vertical"
    @AppStorage("engine.mode") private var mode = "balanced"
    @AppStorage("engine.length") private var length = "auto"
    @AppStorage("engine.subtitles") private var subtitles = true
    @AppStorage("engine.instructions") private var instructions = ""
    @AppStorage("engine.workflow") private var workflow = "highlights"
    @AppStorage("engine.template") private var template = "default"
    @AppStorage("engine.broll") private var broll = false
    @State private var topic = ""
    @State private var partCount = 3
    @State private var workflows: [ClipEngine.Workflow] = []
    @State private var templates: [ClipEngine.CaptionTemplate] = []
    @State private var detail: ClipEngine.Clip?
    @State private var editing: ClipEngine.Clip?
    @State private var merging = false
    @State private var jobs: [ClipEngine.Job] = []

    var body: some View {
        NavigationStack {
            Screen {
                HStack {
                    PageTitle(kicker: "Tu iMac", title: "Clipear por link")
                    Spacer(minLength: 0)
                    Button("Cerrar") { dismiss() }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted)
                }

                if clips.isEmpty {
                    linkBox
                    if !working {
                        modeBox
                        optionsBox
                        jobsBox
                    }
                } else {
                    resultsHeader
                    ForEach(clips) { clip in clipRow(clip) }
                    saveBar
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .task {
            // Lo que este motor permite lo dice él, no la app.
            workflows = (try? await ClipEngine.workflows()) ?? []
            templates = (try? await ClipEngine.captionTemplates()) ?? []
            await retomar()
            await cargarTrabajos()
        }
        .sheet(item: $detail) { c in scoreSheet(c) }
        .sheet(item: $editing) { c in
            EngineStudioView(taskID: taskID, clip: c, onChange: { Task { await refresh() } })
        }
        .onDisappear { job?.cancel() }
    }

    // MARK: El link

    @ViewBuilder private var linkBox: some View {
        Box {
            Text("LINK DEL VIDEO").font(Theme.mono).foregroundStyle(Theme.muted)
            TextField("youtube.com/watch?v=…  ·  twitch.tv/videos/…", text: $link)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(12).background(Theme.bg3, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .disabled(working)
            if working {
                VStack(alignment: .leading, spacing: 8) {
                    if progress >= 0 {
                        ProgressView(value: progress).tint(Theme.accent)
                    } else {
                        ProgressView().tint(Theme.accent)
                    }
                    Text(status.isEmpty ? "Mandándole el video a tu iMac…" : status)
                        .font(.caption).foregroundStyle(Theme.muted)
                    Text("Puedes cerrar la app: el iMac sigue cortando y al volver se retoma solo.")
                        .font(.caption2).foregroundStyle(Theme.muted)
                    Button("Dejar de mirar") { job?.cancel(); working = false; status = "" }
                        .font(.caption.bold()).foregroundStyle(Theme.muted)
                }
            } else {
                Button { start() } label: {
                    Label("Mandar al iMac", systemImage: "desktopcomputer").frame(maxWidth: .infinity)
                }
                .buttonStyle(BoxButtonStyle(filled: true))
                .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: Cómo quieres los clips

    /// Qué quieres que saque del video: momentos sueltos, una serie, un resumen…
    @ViewBuilder private var modeBox: some View {
        if !workflows.isEmpty {
            Box {
                Text("QUÉ SACAR DEL VIDEO").font(Theme.mono).foregroundStyle(Theme.muted)
                ForEach(workflows) { w in
                    Button { if w.available { workflow = w.id } } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: w.icon)
                                .foregroundStyle(workflow == w.id ? Theme.accent : Theme.muted)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(w.name).bold().foregroundStyle(w.available ? Theme.fg : Theme.muted)
                                Text(w.available ? w.detail : "Tu motor no tiene este modo activado.")
                                    .font(.caption).foregroundStyle(Theme.muted)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                            if workflow == w.id {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!w.available)
                }
                if workflow == "topic" {
                    TextField("¿De qué tiene que hablar? Ej: los chistes de Alofoke", text: $topic)
                        .padding(12).background(Theme.bg3, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if workflow == "series" {
                    Stepper("Partes: \(partCount)", value: $partCount, in: 2...10)
                }
            }
        }
    }

    /// El desglose de por qué la IA le puso esa nota.
    private func scoreSheet(_ c: ClipEngine.Clip) -> some View {
        NavigationStack {
            Screen {
                PageTitle(kicker: "Por qué este clip", title: c.hookTitle.isEmpty ? "Puntuación" : c.hookTitle)
                Box {
                    scoreRow("Gancho", "Si engancha en los primeros segundos", c.hook)
                    scoreRow("Enganche", "Si mantiene a la gente hasta el final", c.engagement)
                    scoreRow("Valor", "Si lo que se dice aporta algo", c.value)
                    scoreRow("Para compartir", "Si da ganas de mandárselo a alguien", c.shareable)
                    Divider().overlay(Theme.line)
                    HStack {
                        Text("Total").bold()
                        Spacer()
                        Text("\(c.virality) de 100").font(Theme.display(20)).foregroundStyle(scoreColor(c.virality))
                    }
                }
                if !c.text.isEmpty {
                    Box {
                        Text("LO QUE SE DICE").font(Theme.mono).foregroundStyle(Theme.muted)
                        Text(c.text).font(.callout)
                    }
                }
                Button("Cerrar") { detail = nil }
                    .buttonStyle(BoxButtonStyle(filled: false))
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func scoreRow(_ title: String, _ detail: String, _ v: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).bold()
                Spacer()
                Text("\(v)/25").font(.caption.bold()).foregroundStyle(scoreColor(v * 4))
            }
            ProgressView(value: Double(v) / 25).tint(scoreColor(v * 4))
            Text(detail).font(.caption2).foregroundStyle(Theme.muted)
        }
    }

    @ViewBuilder private var optionsBox: some View {
        Box {
            Text("CÓMO LOS QUIERES").font(Theme.mono).foregroundStyle(Theme.muted)
            Text("ENCUADRE").font(Theme.mono).foregroundStyle(Theme.muted)
            Picker("Encuadre", selection: $format) {
                Text("Auto 9:16").tag("vertical")
                Text("Completa").tag("vertical_fit")
                Text("Paneo").tag("vertical_pan")
                Text("Partida").tag("vertical_split")
                Text("Original").tag("original")
            }.pickerStyle(.segmented)
            Text(encuadreDetalle).font(.caption2).foregroundStyle(Theme.muted)
            Picker("Calidad", selection: $mode) {
                Text("Rápido").tag("fast")
                Text("Normal").tag("balanced")
                Text("Máxima").tag("quality")
            }.pickerStyle(.segmented)
            Picker("Duración", selection: $length) {
                Text("Auto").tag("auto")
                Text("15-30 s").tag("short")
                Text("30-60 s").tag("medium")
                Text("1-2 min").tag("long")
            }.pickerStyle(.segmented)
            Toggle("Subtítulos quemados", isOn: $subtitles).tint(Theme.accent)
            if subtitles && !templates.isEmpty {
                Picker("Estilo de subtítulos", selection: $template) {
                    ForEach(templates) { p in Text(p.name).tag(p.id) }
                }
                .pickerStyle(.menu).tint(Theme.accent)
                if let p = templates.first(where: { $0.id == template }), !p.detail.isEmpty {
                    Text(p.detail).font(.caption2).foregroundStyle(Theme.muted)
                }
            }
            Toggle("Meter imágenes de apoyo", isOn: $broll).tint(Theme.accent)
            Text("Pone video de archivo encima cuando solo se ve a alguien hablando.")
                .font(.caption2).foregroundStyle(Theme.muted)
            Text("QUÉ BUSCAR (opcional)").font(Theme.mono).foregroundStyle(Theme.muted)
            TextField("Por ejemplo: solo las peleas y los momentos de risa", text: $instructions, axis: .vertical)
                .lineLimit(1...3)
                .padding(12).background(Theme.bg3, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text("Si lo dejas vacío, la IA busca los mejores momentos ella sola.")
                .font(.caption2).foregroundStyle(Theme.muted)
        }
    }

    // MARK: Los clips que volvieron

    @ViewBuilder private var resultsHeader: some View {
        Box {
            Text(clips.count == 1 ? "Tu iMac devolvió 1 clip" : "Tu iMac devolvió \(clips.count) clips").bold()
            Text(DriveService.shared.isConnected && DriveService.shared.useDrive
                 ? "Al mandarlos a la cola se guardan en tu Google Drive, no en el iPhone."
                 : "Elige los que quieras y se bajan a la cola, listos para publicar.")
                .font(.caption).foregroundStyle(Theme.muted)
            HStack(spacing: 14) {
                Button(chosen.count == clips.count ? "Ninguno" : "Todos") {
                    chosen = chosen.count == clips.count ? [] : Set(clips.map(\.id))
                }.font(.caption.bold())
                Spacer()
                Button("Otro video") {
                    clips = []; chosen = []; link = ""; taskID = ""; progress = 0; status = ""
                    Task { await cargarTrabajos() }
                }.font(.caption.bold()).foregroundStyle(Theme.muted)
            }
        }
    }

    private func clipRow(_ clip: ClipEngine.Clip) -> some View {
        Box {
                HStack(alignment: .top, spacing: 12) {
                    EnginePreview(taskID: taskID, clip: clip)
                        .frame(width: 104)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: chosen.contains(clip.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(chosen.contains(clip.id) ? Theme.accent : Theme.muted)
                            Text(clip.hookTitle.isEmpty ? "Clip \(Int(clip.start / 60)) min" : clip.hookTitle)
                                .bold().multilineTextAlignment(.leading)
                        }
                        HStack(spacing: 6) {
                            if clip.partNumber > 0 {
                                Text("PARTE \(clip.partNumber)")
                                    .font(.caption2.bold()).foregroundStyle(Theme.bg)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Theme.accent, in: Capsule())
                            }
                            Text(momento(clip))
                                .font(.caption).foregroundStyle(Theme.muted)
                        }
                        if !clip.text.isEmpty {
                            Text(clip.text).font(.caption).foregroundStyle(Theme.muted)
                                .lineLimit(2).multilineTextAlignment(.leading)
                        }
                        Text("Retocar")
                            .font(.caption.bold()).foregroundStyle(Theme.accent)
                            .padding(.top, 2)
                            .contentShape(Rectangle())
                            .onTapGesture { editing = clip }
                    }
                    Spacer(minLength: 0)
                    if clip.virality > 0 {
                        VStack(spacing: 2) {
                            Text("\(clip.virality)").font(Theme.display(22)).foregroundStyle(scoreColor(clip.virality))
                            Text("por qué").font(.caption2).foregroundStyle(Theme.accent)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { detail = clip }
                    }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if chosen.contains(clip.id) { chosen.remove(clip.id) } else { chosen.insert(clip.id) }
        }
    }

    /// Los trabajos anteriores: el iMac los guarda aunque cierres la app.
    @ViewBuilder private var jobsBox: some View {
        if !jobs.isEmpty {
            Box {
                Text("TRABAJOS ANTERIORES").font(Theme.mono).foregroundStyle(Theme.muted)
                ForEach(jobs) { j in
                    Button { abrir(j) } label: {
                        HStack(spacing: 10) {
                            Circle().fill(colorDe(j)).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(j.source).lineLimit(1).font(.subheadline)
                                Text(textoDe(j)).font(.caption2).foregroundStyle(Theme.muted)
                            }
                            Spacer(minLength: 0)
                            if let d = j.date {
                                Text(d.dayLabel).font(.caption2).foregroundStyle(Theme.muted)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(j.failed)
                }
                Text("El iMac los guarda aunque cierres la app.")
                    .font(.caption2).foregroundStyle(Theme.muted)
            }
        }
    }

    private func colorDe(_ j: ClipEngine.Job) -> Color {
        j.done ? Theme.ok : (j.failed ? Theme.red : Theme.warn)
    }

    private func textoDe(_ j: ClipEngine.Job) -> String {
        if j.working { return "Trabajando…" }
        if j.failed { return "No salió nada" }
        return j.clips == 1 ? "1 clip" : "\(j.clips) clips"
    }

    private func cargarTrabajos() async {
        let lista = (try? await ClipEngine.jobs()) ?? []
        await MainActor.run { jobs = lista }
    }

    /// Si un trabajo quedó a medias al cerrar la app, se vuelve a enganchar a él.
    private func retomar() async {
        let guardado = ClipEngine.pending
        guard !guardado.isEmpty, taskID.isEmpty else { return }
        guard let s = try? await ClipEngine.status(guardado) else { return }
        if s.isDone {
            await MainActor.run {
                taskID = guardado
                clips = s.clips
                chosen = Set(s.clips.prefix(3).map(\.id))
                ClipEngine.pending = ""
            }
        } else if !s.isFailed {
            await MainActor.run { taskID = guardado; working = true }
            seguir(guardado)
        } else {
            ClipEngine.pending = ""
        }
    }

    /// Abre un trabajo de la lista: sus clips, o su progreso si sigue en marcha.
    private func abrir(_ j: ClipEngine.Job) {
        Task {
            guard let s = try? await ClipEngine.status(j.id) else {
                await MainActor.run { store.show("No pude abrir ese trabajo.") }
                return
            }
            await MainActor.run { taskID = j.id }
            if s.isDone {
                await MainActor.run {
                    clips = s.clips
                    chosen = Set(s.clips.prefix(3).map(\.id))
                    if s.clips.isEmpty { store.show("Ese trabajo no dejó ningún clip.") }
                }
            } else if s.isFailed {
                await MainActor.run { store.show(s.message.isEmpty ? "Ese trabajo falló." : s.message) }
            } else {
                await MainActor.run { working = true }
                seguir(j.id)
            }
        }
    }

    /// Vuelve a preguntarle al iMac por los clips de este trabajo.
    private func refresh() async {
        guard !taskID.isEmpty else { return }
        if let s = try? await ClipEngine.status(taskID) {
            await MainActor.run {
                clips = s.clips
                chosen = chosen.filter { id in s.clips.contains { $0.id == id } }
            }
        }
    }

    /// Qué hace cada encuadre, con las palabras del motor.
    private var encuadreDetalle: String {
        switch format {
        case "vertical_fit": return "Se ve todo el video, con barras arriba y abajo."
        case "vertical_pan": return "La cámara sigue a quien está hablando."
        case "vertical_split": return "Dos personas, una encima de la otra."
        case "original": return "Se queda tal cual, sin recortar."
        default: return "Recorta solo a 9:16 buscando a quien habla."
        }
    }

    /// Cuánto dura y de qué parte del video salió.
    private func momento(_ c: ClipEngine.Clip) -> String {
        let m = Int(c.start / 60)
        return "\(Int(c.duration)) s · " + (m > 0 ? "min \(m)" : "del principio")
    }

    private func scoreColor(_ v: Int) -> Color {
        v >= 75 ? Theme.ok : (v >= 50 ? Theme.warn : Theme.muted)
    }

    @ViewBuilder private var saveBar: some View {
        if saving {
            HStack { ProgressView(); Text(status).font(.caption).foregroundStyle(Theme.muted) }
                .frame(maxWidth: .infinity)
        } else {
            Button { save() } label: {
                Label(chosen.count == 1 ? "Bajar 1 clip a la cola" : "Bajar \(chosen.count) clips a la cola",
                      systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(BoxButtonStyle(filled: true))
            .disabled(chosen.isEmpty)
            if chosen.count >= 2 {
                Button { merge() } label: {
                    Label("Juntar los \(chosen.count) en un solo clip", systemImage: "arrow.triangle.merge")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(BoxButtonStyle(filled: false))
                .disabled(merging)
                Text("Se pegan en el orden en que salen en la lista.")
                    .font(.caption2).foregroundStyle(Theme.muted)
            }
        }
    }

    // MARK: Acciones

    private func start() {
        if workflow == "topic" && topic.trimmingCharacters(in: .whitespaces).isEmpty {
            store.show("Dile de qué tiene que hablar el clip.")
            return
        }
        working = true
        progress = -1
        status = "Mandándole el video a tu iMac…"
        var options = ClipEngine.Options()
        options.format = format
        options.mode = mode
        options.length = length
        options.subtitles = subtitles
        options.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        options.captionTemplate = template
        options.broll = broll
        options.workflow = workflow
        options.topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        options.partCount = partCount
        Task {
            do {
                let id = try await ClipEngine.start(link, options: options)
                await MainActor.run {
                    taskID = id
                    // Queda apuntado: si cierras la app, al volver se retoma.
                    ClipEngine.pending = id
                }
                seguir(id)
            } catch {
                await MainActor.run {
                    working = false
                    store.show(error.localizedDescription)
                }
            }
        }
    }

    /// Sigue un trabajo hasta que termina, lo abandones o falle.
    private func seguir(_ id: String) {
        job?.cancel()
        job = Task {
            do {
                let result = try await ClipEngine.wait(id) { p, m in
                    progress = p
                    status = m
                }
                await MainActor.run {
                    clips = result
                    chosen = Set(result.prefix(3).map(\.id))
                    working = false
                    ClipEngine.pending = ""
                    if result.isEmpty { store.show("Tu iMac no encontró nada que valga la pena en ese video.") }
                }
                await cargarTrabajos()
            } catch is CancellationError {
                // Solo se deja de mirar: el iMac sigue cortando y queda apuntado.
                await MainActor.run { working = false; status = "" }
            } catch {
                await MainActor.run {
                    working = false
                    ClipEngine.pending = ""
                    store.show(error.localizedDescription)
                }
                await cargarTrabajos()
            }
        }
    }

    private func merge() {
        // El orden lo manda la lista, no el orden en que los fuiste tocando.
        let ids = clips.filter { chosen.contains($0.id) }.map(\.id)
        let tid = taskID
        merging = true
        Task {
            do {
                try await ClipEngine.merge(task: tid, clips: ids)
                await refresh()
                await MainActor.run { chosen = []; store.show("Clips juntados") }
            } catch {
                await MainActor.run { store.show(error.localizedDescription) }
            }
            await MainActor.run { merging = false }
        }
    }

    /// Si tienes Google Drive puesto, el clip se sube ahí y se borra del teléfono.
    private func guardarEnDrive(_ id: UUID, file: URL, titulo: String) async {
        let drive = DriveService.shared
        guard drive.isConnected, drive.useDrive else { return }
        let nombre = (titulo.isEmpty ? "clip" : String(titulo.prefix(40))) + ".mp4"
        guard let did = try? await drive.upload(file, name: nombre) else { return }
        await MainActor.run {
            store.update(id) { $0.driveID = did }
            store.deleteVideoFile(of: id)
        }
    }

    private func save() {
        saving = true
        let picked = clips.filter { chosen.contains($0.id) }
        let connected = youtube.isConnected
        Task {
            var done = 0
            for (i, clip) in picked.enumerated() {
                await MainActor.run { status = "Bajando \(i + 1) de \(picked.count)…" }
                do {
                    let file = try await ClipEngine.download(task: taskID, clip: clip)
                    let id = await store.addVideo(from: file, youtubeConnected: connected)
                    await MainActor.run {
                        store.update(id) { post in
                            if !clip.hookTitle.isEmpty { post.title = String(clip.hookTitle.prefix(100)) }
                        }
                    }
                    await guardarEnDrive(id, file: file, titulo: clip.hookTitle)
                    done += 1
                } catch {
                    await MainActor.run { store.show(error.localizedDescription) }
                }
            }
            await MainActor.run {
                saving = false
                status = ""
                if done > 0 {
                    store.show(done == 1 ? "1 clip en la cola" : "\(done) clips en la cola")
                    dismiss()
                }
            }
        }
    }
}
