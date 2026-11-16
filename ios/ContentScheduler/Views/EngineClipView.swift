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

    var body: some View {
        NavigationStack {
            Screen {
                HStack {
                    PageTitle(kicker: "Tu iMac", title: "Clipear por link")
                    Spacer(minLength: 0)
                    Button("Cerrar") { job?.cancel(); dismiss() }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted)
                }

                if clips.isEmpty {
                    linkBox
                    if !working { optionsBox }
                } else {
                    resultsHeader
                    ForEach(clips) { clip in clipRow(clip) }
                    saveBar
                }
            }
            .toolbar(.hidden, for: .navigationBar)
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
                    Text("Puedes cerrar la app: el iMac sigue cortando y los clips te esperan aquí.")
                        .font(.caption2).foregroundStyle(Theme.muted)
                    Button("Cancelar") { job?.cancel(); working = false; status = "" }
                        .font(.caption.bold()).foregroundStyle(Theme.red)
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

    @ViewBuilder private var optionsBox: some View {
        Box {
            Text("CÓMO LOS QUIERES").font(Theme.mono).foregroundStyle(Theme.muted)
            Picker("Formato", selection: $format) {
                Text("Vertical 9:16").tag("vertical")
                Text("Cuadrado").tag("square")
                Text("Horizontal").tag("horizontal")
            }.pickerStyle(.segmented)
            Picker("Calidad", selection: $mode) {
                Text("Rápido").tag("fast")
                Text("Normal").tag("balanced")
                Text("Máxima").tag("quality")
            }.pickerStyle(.segmented)
            Picker("Duración", selection: $length) {
                Text("Automática").tag("auto")
                Text("30 s").tag("30")
                Text("60 s").tag("60")
                Text("90 s").tag("90")
            }.pickerStyle(.segmented)
            Toggle("Subtítulos quemados", isOn: $subtitles).tint(Theme.accent)
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
            Text("Elige los que quieras y se bajan a la cola, listos para publicar.")
                .font(.caption).foregroundStyle(Theme.muted)
            HStack(spacing: 14) {
                Button(chosen.count == clips.count ? "Ninguno" : "Todos") {
                    chosen = chosen.count == clips.count ? [] : Set(clips.map(\.id))
                }.font(.caption.bold())
                Spacer()
                Button("Otro video") {
                    clips = []; chosen = []; link = ""; taskID = ""; progress = 0; status = ""
                }.font(.caption.bold()).foregroundStyle(Theme.muted)
            }
        }
    }

    private func clipRow(_ clip: ClipEngine.Clip) -> some View {
        Button {
            if chosen.contains(clip.id) { chosen.remove(clip.id) } else { chosen.insert(clip.id) }
        } label: {
            Box {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: chosen.contains(clip.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(chosen.contains(clip.id) ? Theme.accent : Theme.muted)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(clip.hookTitle.isEmpty ? "Clip \(Int(clip.start / 60)) min" : clip.hookTitle)
                            .bold().multilineTextAlignment(.leading)
                        Text("\(Int(clip.duration)) s · desde el minuto \(Int(clip.start / 60))")
                            .font(.caption).foregroundStyle(Theme.muted)
                        if !clip.text.isEmpty {
                            Text(clip.text).font(.caption).foregroundStyle(Theme.muted)
                                .lineLimit(2).multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 0)
                    if clip.virality > 0 {
                        VStack(spacing: 2) {
                            Text("\(clip.virality)").font(Theme.display(22)).foregroundStyle(scoreColor(clip.virality))
                            Text("de 100").font(.caption2).foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
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
        }
    }

    // MARK: Acciones

    private func start() {
        working = true
        progress = -1
        status = "Mandándole el video a tu iMac…"
        var options = ClipEngine.Options()
        options.format = format
        options.mode = mode
        options.length = length
        options.subtitles = subtitles
        options.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        job = Task {
            do {
                let id = try await ClipEngine.start(link, options: options)
                await MainActor.run { taskID = id }
                let result = try await ClipEngine.wait(id) { p, m in
                    progress = p
                    status = m
                }
                await MainActor.run {
                    clips = result
                    chosen = Set(result.prefix(3).map(\.id))
                    working = false
                    if result.isEmpty { store.show("Tu iMac no encontró nada que valga la pena en ese video.") }
                }
            } catch is CancellationError {
                await MainActor.run { working = false; status = "" }
            } catch {
                await MainActor.run {
                    working = false
                    store.show(error.localizedDescription)
                }
            }
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
