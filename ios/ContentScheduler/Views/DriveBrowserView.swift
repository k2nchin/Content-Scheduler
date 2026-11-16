import SwiftUI

/// Elegir un video de tu Google Drive para clipearlo.
///
/// Navega por tus carpetas, o busca por nombre en todo el Drive. Al tocar un
/// video se baja a la app y entra en el Clipper como cualquier otro.
struct DriveBrowserView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Qué hacer con el video que elijas.
    var onPick: (URL) -> Void

    @State private var drive = DriveService.shared
    @State private var items: [DriveService.Item] = []
    /// Las carpetas por las que vas entrando, para poder volver atrás.
    @State private var camino: [DriveService.Item] = []
    @State private var buscar = ""
    @State private var cargando = true
    @State private var bajando: String?
    @State private var progreso = ""

    var body: some View {
        NavigationStack {
            Screen {
                header
                searchBox
                if cargando {
                    ProgressView("Mirando tu Drive…").frame(maxWidth: .infinity).padding(.top, 30)
                } else if items.isEmpty {
                    vacio
                } else {
                    ForEach(items) { item in fila(item) }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .task { await cargar() }
    }

    // MARK: Partes

    @ViewBuilder private var header: some View {
        HStack {
            PageTitle(kicker: camino.isEmpty ? "Tu Google Drive" : camino.map(\.name).joined(separator: " › "),
                      title: "Elegir un video")
            Spacer(minLength: 0)
            Button("Cerrar") { dismiss() }
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.muted)
        }
        if !camino.isEmpty {
            Button { subirNivel() } label: {
                Label("Atrás", systemImage: "chevron.left").font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Theme.accent)
        }
        if let bajando {
            Box {
                HStack(spacing: 10) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bajando).lineLimit(1).font(.subheadline)
                        Text(progreso.isEmpty ? "Bajando de Drive…" : progreso)
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
    }

    @ViewBuilder private var searchBox: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
            TextField("Buscar en todo tu Drive", text: $buscar)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onSubmit { Task { await cargar() } }
            if !buscar.isEmpty {
                Button { buscar = ""; Task { await cargar() } } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(12)
        .background(Theme.bg3, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private var vacio: some View {
        Box {
            Text(buscar.isEmpty ? "Esta carpeta no tiene videos." : "No encontré nada con ese nombre.")
                .font(.subheadline)
            Text("Solo se enseñan carpetas y archivos de video.")
                .font(.caption).foregroundStyle(Theme.muted)
        }
    }

    private func fila(_ item: DriveService.Item) -> some View {
        Button {
            if item.isFolder { entrar(item) } else { elegir(item) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.isFolder ? "folder.fill" : "play.rectangle.fill")
                    .foregroundStyle(item.isFolder ? Theme.warn : Theme.accent)
                    .font(.title3).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        if !item.sizeLabel.isEmpty {
                            Text(item.sizeLabel).font(.caption2).foregroundStyle(Theme.muted)
                        }
                        if let d = item.date {
                            Text(d.dayLabel).font(.caption2).foregroundStyle(Theme.muted)
                        }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: item.isFolder ? "chevron.right" : "arrow.down.circle")
                    .foregroundStyle(Theme.muted).font(.footnote)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(bajando != nil)
    }

    // MARK: Moverse

    private func entrar(_ carpeta: DriveService.Item) {
        camino.append(carpeta)
        buscar = ""
        Task { await cargar() }
    }

    private func subirNivel() {
        guard !camino.isEmpty else { return }
        camino.removeLast()
        Task { await cargar() }
    }

    private func cargar() async {
        cargando = true
        do {
            items = try await drive.list(in: camino.last?.id, search: buscar)
        } catch {
            store.show(error.localizedDescription)
            items = []
        }
        cargando = false
    }

    private func elegir(_ video: DriveService.Item) {
        bajando = video.name
        progreso = video.sizeLabel.isEmpty ? "" : "Bajando \(video.sizeLabel) de Drive…"
        Task {
            do {
                let file = try await drive.download(video.id)
                await MainActor.run {
                    bajando = nil
                    onPick(file)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    bajando = nil
                    store.show(error.localizedDescription)
                }
            }
        }
    }
}
