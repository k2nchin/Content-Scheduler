import SwiftUI
import AVKit

/// Retocar un clip que ya cortó el iMac, sin bajarlo al teléfono.
///
/// Todo lo que tocas aquí se hace en el iMac y vuelve a renderizar allá: recortar
/// por los extremos, partir el clip en dos, reescribir los subtítulos, o bajarlo
/// con los ajustes de TikTok, Reels o Shorts.
struct EngineStudioView: View {
    @Environment(AppStore.self) private var store
    @Environment(YouTubeService.self) private var youtube
    @Environment(\.dismiss) private var dismiss

    let taskID: String
    @State var clip: ClipEngine.Clip
    /// Se llama cuando algo cambió en el iMac y la lista de atrás debe recargarse.
    var onChange: () -> Void = {}

    @State private var player: AVPlayer?
    @State private var cutStart = 0.0
    @State private var cutEnd = 0.0
    @State private var splitAt = 0.0
    @State private var captionText = ""
    @State private var captionPos = "bottom"
    @State private var captionSize = 24.0
    @State private var busy = false
    @State private var status = ""
    @State private var confirmDelete = false

    private var finalDuration: Double { max(1, clip.duration - cutStart - cutEnd) }

    var body: some View {
        NavigationStack {
            Screen {
                header
                previewBox
                trimBox
                splitBox
                captionsBox
                exportBox
                dangerBox
            }
            .toolbar(.hidden, for: .navigationBar)
            .confirmationDialog("¿Borrar este clip del iMac?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Borrar", role: .destructive) { remove() }
            } message: { Text("Se borra del trabajo en el iMac. Lo que ya bajaste al teléfono se queda.") }
        }
        .onAppear { setup() }
        .onDisappear { player?.pause() }
    }

    // MARK: Cabecera y vista previa

    @ViewBuilder private var header: some View {
        HStack {
            PageTitle(kicker: "Estudio", title: clip.hookTitle.isEmpty ? "Retocar el clip" : clip.hookTitle)
            Spacer(minLength: 0)
            Button("Cerrar") { dismiss() }
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted)
        }
        if busy {
            HStack(spacing: 10) {
                ProgressView()
                Text(status.isEmpty ? "Tu iMac está trabajando…" : status)
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var previewBox: some View {
        if let player {
            VideoPlayer(player: player)
                .aspectRatio(9 / 16, contentMode: .fit)
                .frame(maxHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
    }

    // MARK: Recortar

    @ViewBuilder private var trimBox: some View {
        Box {
            Text("RECORTAR").font(Theme.mono).foregroundStyle(Theme.muted)
            Text("Quita los segundos que sobran por delante y por detrás.")
                .font(.caption).foregroundStyle(Theme.muted)
            sliderRow("Por delante", value: $cutStart)
            sliderRow("Por detrás", value: $cutEnd)
            HStack {
                Text("Quedaría en")
                Spacer()
                Text("\(Int(finalDuration)) s").bold().foregroundStyle(Theme.accent)
            }
            .font(.caption)
            Button { apply() } label: {
                Label("Aplicar el recorte", systemImage: "scissors").frame(maxWidth: .infinity)
            }
            .buttonStyle(BoxButtonStyle(filled: true))
            .disabled(busy || (cutStart == 0 && cutEnd == 0) || finalDuration < 2)
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text("\(value.wrappedValue, specifier: "%.1f") s").font(.caption.bold()).foregroundStyle(Theme.muted)
            }
            Slider(value: value, in: 0...max(1, clip.duration / 2), step: 0.5).tint(Theme.accent)
        }
    }

    // MARK: Partir

    @ViewBuilder private var splitBox: some View {
        Box {
            Text("PARTIR EN DOS").font(Theme.mono).foregroundStyle(Theme.muted)
            Text("Útil cuando en un mismo clip hay dos momentos buenos.")
                .font(.caption).foregroundStyle(Theme.muted)
            HStack {
                Text("Cortar en el segundo").font(.caption)
                Spacer()
                Text("\(splitAt, specifier: "%.1f")").font(.caption.bold()).foregroundStyle(Theme.muted)
            }
            Slider(value: $splitAt, in: 1...max(2, clip.duration - 1), step: 0.5).tint(Theme.accent)
            Button { split() } label: {
                Label("Partir aquí", systemImage: "square.split.2x1").frame(maxWidth: .infinity)
            }
            .buttonStyle(BoxButtonStyle(filled: false))
            .disabled(busy)
        }
    }

    // MARK: Subtítulos

    @ViewBuilder private var captionsBox: some View {
        Box {
            Text("SUBTÍTULOS A MANO").font(Theme.mono).foregroundStyle(Theme.muted)
            Text("Si la transcripción se equivocó con un nombre o una palabra, corrígela aquí.")
                .font(.caption).foregroundStyle(Theme.muted)
            TextField("Lo que tiene que decir el subtítulo", text: $captionText, axis: .vertical)
                .lineLimit(3...8)
                .padding(12).background(Theme.bg3, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Picker("Posición", selection: $captionPos) {
                Text("Arriba").tag("top")
                Text("Centro").tag("middle")
                Text("Abajo").tag("bottom")
            }.pickerStyle(.segmented)
            HStack {
                Text("Tamaño").font(.caption)
                Slider(value: $captionSize, in: 12...72, step: 1).tint(Theme.accent)
                Text("\(Int(captionSize))").font(.caption.bold()).foregroundStyle(Theme.muted)
            }
            Button { saveCaptions() } label: {
                Label("Guardar los subtítulos", systemImage: "textformat").frame(maxWidth: .infinity)
            }
            .buttonStyle(BoxButtonStyle(filled: false))
            .disabled(busy || captionText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: Bajar

    @ViewBuilder private var exportBox: some View {
        Box {
            Text("BAJAR A LA COLA").font(Theme.mono).foregroundStyle(Theme.muted)
            Text("Con los ajustes de cada red: tamaño y calidad que pide cada una.")
                .font(.caption).foregroundStyle(Theme.muted)
            HStack(spacing: 10) {
                exportButton("TikTok", "tiktok")
                exportButton("Reels", "reels")
                exportButton("Shorts", "shorts")
            }
        }
    }

    private func exportButton(_ title: String, _ preset: String) -> some View {
        Button { exportIt(preset) } label: {
            Text(title).font(.caption.bold()).frame(maxWidth: .infinity)
        }
        .buttonStyle(BoxButtonStyle(filled: false))
        .disabled(busy)
    }

    @ViewBuilder private var dangerBox: some View {
        Button { confirmDelete = true } label: {
            Label("Borrar este clip", systemImage: "trash").frame(maxWidth: .infinity)
        }
        .buttonStyle(BoxButtonStyle(filled: false))
        .foregroundStyle(Theme.red)
        .disabled(busy)
    }

    // MARK: Acciones

    private func setup() {
        captionText = clip.text
        splitAt = max(1, clip.duration / 2)
        guard let r = ClipEngine.streamRequest(task: taskID, clip: clip.id), let url = r.url else { return }
        // El clip pide la clave, así que la cabecera viaja con la petición del reproductor.
        let headers = r.allHTTPHeaderFields ?? [:]
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
    }

    private func run(_ message: String, _ work: @escaping () async throws -> Void) {
        busy = true
        status = message
        Task {
            do {
                try await work()
                onChange()
            } catch {
                store.show(error.localizedDescription)
            }
            busy = false
            status = ""
        }
    }

    private func apply() {
        let cid = clip.id, tid = taskID, a = cutStart, b = cutEnd
        run("Recortando en el iMac…") {
            if let nuevo = try await ClipEngine.trim(task: tid, clip: cid, start: a, end: b) {
                await MainActor.run {
                    clip = nuevo
                    cutStart = 0; cutEnd = 0
                    splitAt = max(1, nuevo.duration / 2)
                    setup()
                }
            }
            await MainActor.run { store.show("Clip recortado") }
        }
    }

    private func split() {
        let cid = clip.id, tid = taskID, punto = splitAt
        run("Partiendo el clip…") {
            try await ClipEngine.split(task: tid, clip: cid, at: punto)
            await MainActor.run {
                store.show("Partido en dos. Los tienes en la lista.")
                dismiss()
            }
        }
    }

    private func saveCaptions() {
        let text = captionText
        let pos = captionPos
        let size = Int(captionSize)
        let cid = clip.id, tid = taskID
        run("Guardando los subtítulos…") {
            try await ClipEngine.captions(task: tid, clip: cid, text: text, position: pos, size: size)
            await MainActor.run { store.show("Subtítulos guardados") }
        }
    }

    private func exportIt(_ preset: String) {
        let connected = youtube.isConnected
        let titulo = clip.hookTitle
        let actual = clip, tid = taskID
        run("Preparando el archivo para \(preset)…") {
            let file = try await ClipEngine.export(task: tid, clip: actual, preset: preset)
            let id = await store.addVideo(from: file, youtubeConnected: connected)
            await MainActor.run {
                if !titulo.isEmpty { store.update(id) { $0.title = String(titulo.prefix(100)) } }
            }
            // Con Google Drive puesto, el clip se sube ahí y no ocupa el teléfono.
            let drive = DriveService.shared
            if drive.isConnected, drive.useDrive,
               let did = try? await drive.upload(file, name: (titulo.isEmpty ? "clip" : String(titulo.prefix(40))) + ".mp4") {
                await MainActor.run {
                    store.update(id) { $0.driveID = did }
                    store.deleteVideoFile(of: id)
                }
            }
            await MainActor.run {
                store.show("Clip en la cola")
                dismiss()
            }
        }
    }

    private func remove() {
        let cid = clip.id, tid = taskID
        run("Borrando…") {
            try await ClipEngine.delete(task: tid, clip: cid)
            await MainActor.run {
                store.show("Clip borrado")
                dismiss()
            }
        }
    }
}
