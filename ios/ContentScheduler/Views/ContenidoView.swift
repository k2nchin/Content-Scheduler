import SwiftUI
import PhotosUI

/// Pantalla «Contenido»: contadores, clientes de la semana, HOY, agregar videos y la cola.
struct ContenidoView: View {
    @Environment(AppStore.self) private var store
    @Environment(YouTubeService.self) private var youtube
    @Environment(MetaService.self) private var meta

    enum Filter: String, CaseIterable { case todos = "Todos", porProgramar = "Por programar", programados = "Programados", errores = "Errores" }

    @State private var filter: Filter = .todos
    @State private var grid = true
    @State private var clientsOpen = false
    @State private var picks: [PhotosPickerItem] = []
    @State private var slotPick: PhotosPickerItem?
    @State private var slotTime: Date?
    @State private var editing: UUID?
    @State private var importing = false
    @State private var confirmClear = false
    @State private var confirmPublish = false
    @State private var working = false

    var body: some View {
        Screen {
            AppHeader()
            PageTitle(kicker: Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "es"))), title: "Contenido")
            HStack(spacing: 10) {
                Button { confirmPublish = true } label: { Label("Publicar ahora", systemImage: "bolt").frame(maxWidth: .infinity) }
                    .buttonStyle(BoxButtonStyle())
                Button { programarTodo() } label: { Label("Programar todo", systemImage: "paperplane").frame(maxWidth: .infinity) }
                    .buttonStyle(BoxButtonStyle(filled: true))
            }
            .disabled(working)
            HStack(spacing: 8) {
                counter("Por programar", store.porProgramar.count, "square.stack.3d.up")
                counter("Programados", store.programados.count, "calendar.badge.checkmark")
                counter("Por revisar", store.porRevisar.count, "exclamationmark.circle", warn: true)
            }

            clientsBox
            hoyBox
            addBox

            HStack {
                Text("EN COLA").font(Theme.display(26)).foregroundStyle(Theme.fg)
                Spacer()
                Button { grid.toggle() } label: { Image(systemName: grid ? "list.bullet" : "square.grid.2x2").padding(10) }
                    .overlay(Rectangle().strokeBorder(Theme.line)).foregroundStyle(Theme.fg)
            }.padding(.top, 14)
            HStack(spacing: 0) {
                ForEach(Filter.allCases, id: \.self) { f in
                    Button(f.rawValue) { filter = f }
                        .font(.system(size: 12)).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .foregroundStyle(filter == f ? .white : Theme.muted)
                        .background(filter == f ? Theme.accent : Theme.bg2)
                }
            }.overlay(Rectangle().strokeBorder(Theme.line))
            HStack(spacing: 10) {
                Button { store.reorganize() } label: { Label("Reorganizar", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity) }
                    .buttonStyle(BoxButtonStyle())
                Button { confirmClear = true } label: { Label("Borrar cola", systemImage: "trash").frame(maxWidth: .infinity) }
                    .buttonStyle(BoxButtonStyle(color: Theme.red))
            }.disabled(store.upcoming.isEmpty)

            let list = filtered
            if list.isEmpty {
                Text("No hay videos aquí. Toca «Elegir archivos» para agregar.").font(.footnote).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity).padding(.vertical, 30)
            } else if grid {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(list) { p in Button { editing = p.id } label: { QueueCard(post: p, scheduled: store.isScheduled(p)) }.buttonStyle(.plain) }
                }
            } else {
                ForEach(list) { p in Button { editing = p.id } label: { PostRow(post: p) }.buttonStyle(.plain) }
            }
        }
        .sheet(item: $editing) { PostEditor(postID: $0) }
        .onChange(of: picks) { _, items in importVideos(items, at: nil) }
        .onChange(of: slotPick) { _, item in
            guard let item, let t = slotTime else { return }
            slotPick = nil
            importVideos([item], at: t)
        }
        .confirmationDialog("¿Borrar toda la cola de la app? Lo que ya se subió a YouTube se queda programado allá.", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Borrar cola", role: .destructive) { store.clearQueue() }
        }
        .confirmationDialog("¿Publicar ahora en YouTube el siguiente video de la cola?", isPresented: $confirmPublish, titleVisibility: .visible) {
            Button("Publicar ahora") { publicarAhora() }
        }
    }

    private var filtered: [Post] {
        switch filter {
        case .todos: store.upcoming
        case .porProgramar: store.porProgramar
        case .programados: store.programados
        case .errores: store.porRevisar
        }
    }

    private func counter(_ title: String, _ n: Int, _ icon: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(title).font(.caption2).foregroundStyle(Theme.muted).lineLimit(2).minimumScaleFactor(0.85)
                Spacer(minLength: 2)
                Image(systemName: icon).font(.caption).foregroundStyle(warn ? Theme.warn : Theme.muted)
            }
            Text("\(n)").font(Theme.display(30)).foregroundStyle(Theme.fg)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg2).overlay(Rectangle().strokeBorder(Theme.line))
    }

    private var clientsBox: some View {
        Box {
            Button { withAnimation { clientsOpen.toggle() } } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tus clientes esta semana").bold()
                        Text("Lo programado en cada cuenta para los próximos 7 días").font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Image(systemName: clientsOpen ? "chevron.up" : "chevron.down").foregroundStyle(Theme.muted)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if clientsOpen {
                let week = Date.now.addingTimeInterval(7 * 86_400)
                ForEach(youtube.accounts, id: \.id) { acc in
                    let n = store.programados.filter { $0.date <= week && ($0.yt?.account ?? youtube.channel?.id) == acc.id }.count
                    clientRow(.youtube, acc.title, n)
                }
                if meta.facebookConnected, let page = meta.page {
                    clientRow(.facebook, page.name, store.upcoming.filter { $0.date <= week && $0.fb?.state == .scheduled }.count)
                }
                if meta.instagramConnected, let ig = meta.page?.igUsername {
                    clientRow(.instagram, "@" + ig, store.upcoming.filter { $0.date <= week && $0.ig?.state == .waiting }.count)
                }
                if youtube.accounts.isEmpty && !meta.hasAccount {
                    Text("Conecta tus cuentas en Ajustes para verlas aquí.").font(.caption).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private func clientRow(_ n: Network, _ name: String, _ count: Int) -> some View {
        HStack {
            NetBadge(network: n)
            Text(name).font(.subheadline).lineLimit(1)
            Spacer()
            Text(count == 0 ? "Sin contenido" : "\(count) programados").font(.caption.bold()).foregroundStyle(count == 0 ? Theme.warn : Theme.ok)
        }
    }

    private var hoyBox: some View {
        let today = Calendar.current.startOfDay(for: .now)
        let slots = store.state.slots.sorted()
        let posts = store.state.posts.filter { Calendar.current.isDateInToday($0.date) }
        let filled = slots.filter { s in posts.contains { $0.date.hm == s } }.count
        return Box {
            HStack {
                Text("HOY").font(Theme.display(26)).foregroundStyle(Theme.fg)
                Spacer()
                (Text("\(filled)").foregroundStyle(Theme.accent) + Text(" de \(slots.count) horarios con video").foregroundStyle(Theme.muted)).font(.caption)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 10) {
                ForEach(slots, id: \.self) { s in
                    let p = s.split(separator: ":").compactMap { Int($0) }
                    let t = Calendar.current.date(bySettingHour: p.first ?? 0, minute: p.count > 1 ? p[1] : 0, second: 0, of: today) ?? today
                    let post = posts.first { $0.date.hm == s }
                    VStack(alignment: .leading, spacing: 4) {
                        Group {
                            if let post {
                                Button { editing = post.id } label: { Thumb(post: post, width: 90) }.buttonStyle(.plain)
                            } else if t < .now {
                                Rectangle().fill(Theme.bg3.opacity(0.5)).overlay(Image(systemName: "plus").foregroundStyle(Theme.line))
                            } else {
                                PhotosPicker(selection: $slotPick, matching: .videos) {
                                    Rectangle().fill(Theme.bg3.opacity(0.5)).overlay(Image(systemName: "plus").foregroundStyle(Theme.muted))
                                }.simultaneousGesture(TapGesture().onEnded { slotTime = t })
                            }
                        }
                        .frame(height: 92).frame(maxWidth: .infinity)
                        .overlay(Rectangle().strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [3])))
                        Text(t.formatted(.dateTime.hour().minute())).font(.subheadline)
                        Text(t < .now && post == nil ? "Pasó" : post == nil ? "Libre" : store.isScheduled(post!) ? "Programado" : "Por programar")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
    }

    private var addBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "plus").font(.title2).foregroundStyle(.white).frame(width: 48, height: 48).background(Theme.accent)
            Text("Agregar videos").font(.title3)
            Text("Elígelos de tu galería. Cada uno toma el siguiente horario libre.").font(.footnote).foregroundStyle(Theme.muted)
            if importing { ProgressView("Preparando videos…") }
            PhotosPicker(selection: $picks, maxSelectionCount: 20, matching: .videos) {
                Text("Elegir archivos").font(.system(size: 12.5, weight: .bold)).tracking(1.2).textCase(.uppercase)
                    .padding(.horizontal, 16).padding(.vertical, 12).foregroundStyle(Theme.fg)
                    .overlay(Rectangle().strokeBorder(Theme.fg.opacity(0.85), lineWidth: 1.2))
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().strokeBorder(Theme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, dash: [5])))
    }

    private func importVideos(_ items: [PhotosPickerItem], at time: Date?) {
        guard !items.isEmpty else { return }
        picks = []
        if let time, time < .now { slotTime = nil; return store.show("Ese horario ya pasó") }
        importing = true
        Task {
            var last: UUID?
            for item in items {
                if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                    last = await store.addVideo(from: movie.url, youtubeConnected: youtube.isConnected, at: time)
                }
            }
            importing = false
            slotTime = nil
            if items.count == 1, let last { editing = last }
            else if last != nil { store.show("\(items.count) videos agregados a la cola") }
            else { store.show("No se pudo leer el video.") }
        }
    }

    private func programarTodo() {
        guard youtube.isConnected else { return store.show("Conecta YouTube en Ajustes para programar.") }
        let pending = store.porProgramar.filter { $0.networks.contains(.youtube) && Publisher.fileURL($0) != nil && $0.date > .now }
        guard !pending.isEmpty else { return store.show("No hay videos listos para programar.") }
        working = true
        Task {
            for p in pending { await Publisher.upload(p.id, now: false, store: store, yt: youtube) }
            working = false
        }
    }

    private func publicarAhora() {
        guard youtube.isConnected else { return store.show("Conecta YouTube en Ajustes para publicar.") }
        guard let next = store.porProgramar.first(where: { $0.networks.contains(.youtube) && Publisher.fileURL($0) != nil }) else {
            return store.show("No hay videos con archivo en la cola.")
        }
        working = true
        Task { await Publisher.upload(next.id, now: true, store: store, yt: youtube); working = false }
    }
}

/// Tarjeta de la cola como en tu app: fecha, miniatura, estado, hashtags y redes.
struct QueueCard: View {
    let post: Post
    let scheduled: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                Thumb(post: post, width: 160).frame(maxWidth: .infinity).frame(height: 130).clipped()
                Text(post.date.formatted(.dateTime.weekday(.abbreviated).day().hour().minute().locale(Locale(identifier: "es"))))
                    .font(.caption2.bold()).padding(.horizontal, 7).padding(.vertical, 4)
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 5)).padding(6)
            }
            .overlay(alignment: .bottomLeading) {
                Text(label.uppercased()).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.5)
                    .foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 4)
                    .background(color).padding(6)
            }
            Text(post.title).font(.footnote.bold()).lineLimit(1).foregroundStyle(Theme.fg)
            Text(post.tags).font(.caption2).lineLimit(1).foregroundStyle(Theme.muted)
            HStack(spacing: 4) {
                ForEach(Network.allCases.filter { post.networks.contains($0) }) { n in
                    let ok = (n == .youtube && post.yt?.videoID != nil)
                        || (n == .facebook && (post.fb?.state == .scheduled || post.fb?.state == .published))
                        || (n == .instagram && post.ig?.state == .published)
                    HStack(spacing: 3) { NetLogo(network: n, size: 10); Text(ok ? "✓" : "") }.font(.system(size: 10, weight: .bold))
                        .foregroundStyle(ok ? Theme.ok : Theme.muted)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background((ok ? Theme.ok : Theme.muted).opacity(0.12), in: Capsule())
                }
            }
        }
        .padding(8).background(Theme.bg2).overlay(Rectangle().strokeBorder(Theme.line))
    }
    private var label: String {
        if post.yt?.state == .uploading { return "Subiendo \(Int((post.yt?.progress ?? 0) * 100))%" }
        if post.status == .error { return "Error" }
        if post.status == .published { return "Publicado" }
        return scheduled ? "Programado" : "Por programar"
    }
    private var color: Color {
        if post.status == .error { return Theme.red }
        if post.status == .published { return Theme.ok.opacity(0.8) }
        return scheduled ? Theme.accent.opacity(0.85) : Theme.bg3
    }
}
