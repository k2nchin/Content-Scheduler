import SwiftUI
import PhotosUI

struct QueueView: View {
    @Environment(AppStore.self) private var store
    @Environment(YouTubeService.self) private var youtube
    @State private var filter: PostStatus?
    @State private var picks: [PhotosPickerItem] = []
    @State private var editing: Post.ID?
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Screen {
                let up = store.upcoming
                let today = up.filter { Calendar.current.isDateInToday($0.date) }.count
                let errors = up.filter { $0.status == .error }.count
                ScreenTitle(solid: "Tu", outline: "cola",
                            subtitle: "\(today) \(today == 1 ? "publicación" : "publicaciones") hoy" + (errors > 0 ? " · \(errors) con error" : ""))
                DemoBanner(text: youtube.isConnected
                           ? "YouTube publica de verdad. Facebook, Instagram y TikTok todavía son de prueba."
                           : "Conecta YouTube en Ajustes para publicar de verdad. Las demás redes todavía son de prueba.",
                           icon: "flask")
                filters(up)
                let list = filter.map { f in up.filter { $0.status == f } } ?? up
                if importing { ProgressView("Preparando video…").frame(maxWidth: .infinity).padding() }
                if list.isEmpty && !importing {
                    VStack(spacing: 10) {
                        Image(systemName: "tray").font(.largeTitle).foregroundStyle(Theme.line)
                        Text("Nada por aquí.\nToca + para agregar videos.").multilineTextAlignment(.center).foregroundStyle(Theme.muted)
                    }.frame(maxWidth: .infinity).padding(.vertical, 40)
                }
                ForEach(groups(list), id: \.0) { label, posts in
                    SectionLabel(text: label)
                    ForEach(posts) { p in Button { editing = p.id } label: { PostRow(post: p) }.buttonStyle(.plain) }
                }
                if filter == nil && !store.published.isEmpty {
                    SectionLabel(text: "Publicado reciente")
                    ForEach(store.published.prefix(3)) { p in Button { editing = p.id } label: { PostRow(post: p) }.buttonStyle(.plain) }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosPicker(selection: $picks, maxSelectionCount: 10, matching: .videos) {
                        Image(systemName: "plus").font(.headline).foregroundStyle(.white)
                            .frame(width: 34, height: 34).background(Theme.accent, in: RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .onChange(of: picks) { _, items in importVideos(items) }
            .sheet(item: $editing) { id in PostEditor(postID: id) }
        }
    }

    private func filters(_ up: [Post]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip("Todo · \(up.count)", nil)
                chip("Programados", .scheduled)
                chip("En aprobación", .approval)
                chip("Con error", .error)
            }
        }.scrollIndicators(.hidden)
    }

    private func chip(_ text: String, _ value: PostStatus?) -> some View {
        Button(text) { filter = value }
            .font(.footnote.weight(filter == value ? .semibold : .regular))
            .padding(.horizontal, 13).padding(.vertical, 7)
            .foregroundStyle(filter == value ? Theme.bg : Theme.muted)
            .background(filter == value ? Theme.fg : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(filter == value ? .clear : Theme.line))
    }

    private func groups(_ posts: [Post]) -> [(String, [Post])] {
        var out: [(String, [Post])] = []
        for p in posts {
            let l = p.date.dayLabel
            if out.last?.0 == l { out[out.count - 1].1.append(p) } else { out.append((l, [p])) }
        }
        return out
    }

    private func importVideos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        picks = []
        importing = true
        Task {
            var last: UUID?
            for item in items {
                if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                    last = await store.addVideo(from: movie.url, youtubeConnected: youtube.isConnected)
                }
            }
            importing = false
            if items.count == 1, let last { editing = last }
            else if last != nil { store.show("\(items.count) videos agregados. Tócalos para revisarlos.") }
            else { store.show("No se pudo leer el video.") }
        }
    }
}

extension UUID: @retroactive Identifiable { public var id: UUID { self } }
