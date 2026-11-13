import SwiftUI
import PhotosUI

struct ClipsView: View {
    @Environment(AppStore.self) private var store
    @Environment(YouTubeService.self) private var youtube
    @State private var link = ""
    @State private var pick: PhotosPickerItem?
    @State private var source = ""
    @State private var moments: [Moment] = []
    @State private var added: Set<UUID> = []

    struct Moment: Identifiable { let id = UUID(); let time: String; let score: Int; let meme: Bool; let quote: String }

    var body: some View {
        NavigationStack {
            Screen {
                ScreenTitle(solid: "Clips", outline: "IA", subtitle: "Sube un video o pega el link de tu en vivo. Se marcan los momentos de meme y los virales.")
                PhotosPicker(selection: $pick, matching: .videos) {
                    VStack(spacing: 6) {
                        Image(systemName: "icloud.and.arrow.up").font(.title).foregroundStyle(Theme.accent)
                        Text("Subir video largo o en vivo").bold()
                        Text("Se queda en tu teléfono").font(.footnote).foregroundStyle(Theme.muted)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 22)
                    .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1.5, dash: [6])))
                }
                .onChange(of: pick) { _, item in
                    guard item != nil else { return }
                    pick = nil
                    source = "video del teléfono"
                    makeMoments(seed: UInt64(Date.now.timeIntervalSince1970) % 997)
                }
                Text("o pega un link").font(.caption).foregroundStyle(Theme.muted)
                HStack {
                    TextField("https://youtube.com/live/…", text: $link)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(12).background(Theme.bg3, in: RoundedRectangle(cornerRadius: 10))
                    Button { analyze() } label: { Image(systemName: "wand.and.stars").frame(width: 46, height: 46) }
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(.white)
                }
                if !moments.isEmpty {
                    SectionLabel(text: "Momentos encontrados · \(source.prefix(28))")
                    DemoBanner(text: "Momentos de ejemplo. El análisis real con IA todavía no está conectado en la app.")
                    Card {
                        ForEach(moments) { m in
                            HStack(spacing: 12) {
                                VStack {
                                    Text(m.time).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.accent)
                                    Text("\(m.score)").font(Theme.display(22)).foregroundStyle(Theme.accent)
                                }.frame(width: 56)
                                VStack(alignment: .leading) {
                                    Text(m.meme ? "😂 Meme" : "🔥 Viral").bold().font(.subheadline)
                                    Text("“\(m.quote)”").font(.footnote).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                Button(added.contains(m.id) ? "✓" : "A la cola") { queue(m) }
                                    .font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(.white)
                                    .disabled(added.contains(m.id))
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                SectionLabel(text: "Reciclar lo que funcionó")
                Text("Tus videos publicados vuelven a la cola con un toque y hashtags nuevos.").font(.footnote).foregroundStyle(Theme.muted)
                if store.published.isEmpty {
                    Text("Aún no hay videos publicados.").foregroundStyle(Theme.muted)
                }
                ForEach(store.published.prefix(5)) { p in
                    HStack {
                        PostRow(post: p)
                        Button { store.recycle(p.id) } label: { Image(systemName: "arrow.clockwise").padding(12) }
                            .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }

    private func analyze() {
        guard link.hasPrefix("http") else { return store.show("Pega un link válido") }
        source = link.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "www.", with: "")
        makeMoments(seed: UInt64(link.count * 13))
    }

    private func makeMoments(seed: UInt64) {
        var gen = SeededRandom(seed: seed)
        let quotes = ["¡No puede ser, se cayó el micro!", "Esta parte la tienen que escuchar", "El chat se volvió loco con esto",
                      "Cuando te equivocas de letra en vivo", "La nota más alta de la noche"]
        moments = quotes.enumerated().map { i, q in
            Moment(time: String(format: "%02d:%02d", Int(gen.next() * 50), Int(gen.next() * 60)),
                   score: 98 - i * 6 - Int(gen.next() * 5), meme: i % 2 == 0, quote: q)
        }
    }

    private func queue(_ m: Moment) {
        store.state.posts.append(Post(title: m.quote, tags: m.meme ? "#meme #envivo" : "#viral #envivo",
                                      networks: store.defaultNetworks(youtubeConnected: youtube.isConnected),
                                      date: store.nextFreeSlot(), duration: 25, gradient: store.state.posts.count % Theme.gradients.count))
        added.insert(m.id)
        store.show("Clip agregado a la cola. Falta elegir su video.")
    }
}
