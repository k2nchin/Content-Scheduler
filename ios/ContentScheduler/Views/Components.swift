import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Video elegido desde Fotos: se copia dentro de la app para poder subirlo más tarde.
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = AppStore.videosDir.appendingPathComponent(UUID().uuidString + "." + ext)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest)
        }
    }
}

struct ScreenTitle: View {
    let solid: String
    let outline: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            (Text(solid + " ").foregroundStyle(Theme.fg) + Text(outline).foregroundStyle(Theme.accent))
                .font(Theme.display(44))
                .textCase(.uppercase)
            if let subtitle { Text(subtitle).foregroundStyle(Theme.muted).font(.subheadline) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.footnote).foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 18).padding(.horizontal, 4)
    }
}
struct DemoBanner: View {
    let text: String
    var icon = "info.circle"
    var color = Theme.warn
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).font(.body.weight(.semibold))
            Text(text).font(.footnote).foregroundStyle(Theme.fg)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}
struct NetBadge: View {
    let network: Network
    var size: CGFloat = 22
    var dimmed = false
    var body: some View {
        Image(network.logo)
            .resizable().renderingMode(.template).scaledToFit()
            .frame(width: size * 0.56, height: size * 0.56)
            .foregroundStyle(dimmed ? Theme.muted : (network == .tiktok ? .black : .white))
            .frame(width: size, height: size)
            .background(dimmed ? Theme.bg3 : network.color, in: RoundedRectangle(cornerRadius: size * 0.27))
            .accessibilityLabel(network.name)
    }
}

/// Logo suelto de la red, del color que se le dé.
struct NetLogo: View {
    let network: Network
    var size: CGFloat = 16
    var body: some View {
        Image(network.logo).resizable().renderingMode(.template).scaledToFit().frame(width: size, height: size)
    }
}

struct StatusPill: View {
    let status: PostStatus
    var body: some View {
        Text(status.label.uppercased())
            .font(.system(size: 9.5, weight: .medium, design: .monospaced)).tracking(0.8)
            .foregroundStyle(status.color)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(status.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct Thumb: View {
    let post: Post
    var width: CGFloat = 62
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let data = post.thumbnail, let img = UIImage(data: data) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                LinearGradient(colors: Theme.gradients[post.gradient % Theme.gradients.count], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            Text(post.durationText).font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4, style: .continuous)).padding(4)
        }
        .frame(width: width, height: width * 1.36)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct YTTag: View {
    let info: YTInfo
    var body: some View {
        let (text, color): (String, Color) = switch info.state {
        case .uploading: ("yt \(Int(info.progress * 100))%", Network.youtube.color)
        case .failed: ("yt !", Theme.red)
        case .privateLocked: ("yt privado", Theme.warn)
        case .scheduled, .published: ("yt ✓" + (info.views.map { " · " + compact(Double($0)) } ?? ""), Theme.ok)
        }
        Text(text).font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(color).padding(.horizontal, 6).padding(.vertical, 4)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct PostRow: View {
    let post: Post
    var body: some View {
        HStack(spacing: 12) {
            Thumb(post: post)
            VStack(alignment: .leading, spacing: 6) {
                Text(post.title).font(.subheadline.weight(.semibold)).lineLimit(2).foregroundStyle(Theme.fg)
                Label("\(post.date.dayLabel) · \(post.date.hm)", systemImage: "clock")
                    .font(.caption).foregroundStyle(Theme.muted)
                HStack(spacing: 4) {
                    ForEach(Network.allCases.filter { post.networks.contains($0) }) { NetBadge(network: $0) }
                    if let yt = post.yt { YTTag(info: yt).padding(.leading, 2) }
                }
            }
            Spacer(minLength: 0)
            StatusPill(status: post.status)
        }
        .padding(10)
        .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bg2, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
    }
}
struct PrimaryButtonStyle: ButtonStyle {
    var filled = true
    var color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity).padding(.vertical, 15)
            .foregroundStyle(filled ? .white : color)
            .background(filled ? color : color.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .shadow(color: filled ? color.opacity(0.35) : .clear, radius: 12, y: 5)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}
struct Screen<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(Theme.bg.ignoresSafeArea())
    }
}

// MARK: Estructura de tu app (encabezado, título de página, barra inferior)

/// En estilo Apple no hay cabecera de marca: el título grande de cada pantalla hace ese papel.
struct AppHeader: View {
    var body: some View { EmptyView() }
}
/// Título grande como en las apps de Apple (Fotos, Salud, Ajustes).
struct PageTitle: View {
    let kicker: String
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(kicker.capitalized(with: Locale(identifier: "es"))).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent).lineLimit(1)
            Text(title.capitalized(with: Locale(identifier: "es"))).font(.largeTitle.bold()).foregroundStyle(Theme.fg)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8).padding(.bottom, 4)
    }
}
enum AppTab: String, CaseIterable, Identifiable {
    case contenido, clipper, horarios, metrica, comentarios, ajustes
    var id: String { rawValue }
    var label: String {
        switch self {
        case .contenido: "CONTENIDO"
        case .clipper: "CLIPPER"
        case .horarios: "HORARIOS"
        case .metrica: "MÉTRICA"
        case .comentarios: "COMENT."
        case .ajustes: "AJUSTES"
        }
    }
    var icon: String {
        switch self {
        case .contenido: "square.grid.2x2"
        case .clipper: "scissors"
        case .horarios: "calendar"
        case .metrica: "chart.bar.xaxis"
        case .comentarios: "bubble.left.and.bubble.right"
        case .ajustes: "gearshape"
        }
    }
}

/// Barra de pestañas translúcida (vidrio esmerilado), íconos rellenos al seleccionar, como en iOS.
struct BottomBar: View {
    @Binding var tab: AppTab
    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { t in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { tab = t }
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.icon).symbolVariant(tab == t ? .fill : .none)
                            .font(.system(size: 20, weight: .medium)).frame(width: 52, height: 28)
                            .background(tab == t ? Theme.accent.opacity(0.16) : .clear, in: Capsule())
                        Text(t.label.capitalized(with: Locale(identifier: "es"))).font(.system(size: 10, weight: .medium))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(tab == t ? Theme.accent : Theme.muted)
                    .frame(maxWidth: .infinity)
                }.buttonStyle(.plain)
            }
        }
        .padding(.top, 8).padding(.bottom, 2)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
/// Botón secundario redondeado (como .bordered de iOS).
struct BoxButtonStyle: ButtonStyle {
    var filled = false
    var color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .lineLimit(1).minimumScaleFactor(0.75)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .foregroundStyle(filled ? .white : color)
            .background(filled ? color : color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
/// Tarjeta agrupada con esquinas continuas, como las de Ajustes y Salud.
struct Box<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bg2, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
    }
}
extension UUID: @retroactive Identifiable { public var id: UUID { self } }


/// Elegir con qué cuenta de YouTube trabajar (si hay más de una).
struct YTAccountPicker: View {
    @Environment(YouTubeService.self) private var youtube
    var body: some View {
        if youtube.accounts.count > 1, let active = youtube.channel {
            Menu {
                ForEach(youtube.accounts, id: \.id) { a in
                    Button { youtube.setActive(a.id) } label: {
                        if a.id == active.id { Label(a.title, systemImage: "checkmark") } else { Text(a.title) }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    NetBadge(network: .youtube, size: 22)
                    Text(active.title).font(.subheadline.bold()).lineLimit(1)
                    Spacer()
                    Text("Cambiar").font(.caption).foregroundStyle(Theme.muted)
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(Theme.muted)
                }
                .padding(12).background(Theme.bg2).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .foregroundStyle(Theme.fg)
        }
    }
}
