import SwiftUI

/// Vuelve a poner en la cola lo que ya se publicó desde la app.
struct ClipsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        NavigationStack {
            Screen {
                ScreenTitle(solid: "Reci", outline: "clar", subtitle: "Tus videos publicados vuelven a la cola con un toque y hashtags nuevos. Después eliges el archivo de video para subirlo.")
                if store.published.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.largeTitle).foregroundStyle(Theme.line)
                        Text("Aún no hay videos publicados.").foregroundStyle(Theme.muted)
                    }.frame(maxWidth: .infinity).padding(.vertical, 40)
                }
                ForEach(store.published) { p in
                    HStack {
                        PostRow(post: p)
                        Button { store.recycle(p.id) } label: { Image(systemName: "arrow.clockwise").padding(12) }
                            .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }
}
