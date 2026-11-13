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
        Text(text.uppercased()).font(Theme.mono).tracking(1.6).foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 18)
    }
}

struct DemoBanner: View {
    let text: String
    var icon = "info.circle"
    var color = Theme.warn
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.footnote).foregroundStyle(color.opacity(0.9))
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4])))
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
            .background(status.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 6))
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
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4)).padding(4)
        }
        .frame(width: width, height: width * 1.36)
        .clipShape(RoundedRectangle(cornerRadius: 9))
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
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 6))
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
        .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var filled = true
    var color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold)).textCase(.uppercase).tracking(0.8)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .foregroundStyle(filled ? .white : color)
            .background(filled ? color : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(filled ? .clear : Theme.line))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// Fondo oscuro y desplazamiento comunes a cada pantalla.
struct Screen<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.bg.ignoresSafeArea())
    }
}

// MARK: Estructura de tu app (encabezado, título de página, barra inferior)

struct AppHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "play.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6))
                    .shadow(color: Theme.accent.opacity(0.5), radius: 12)
                Text("CONTENT SCHEDULER").font(Theme.display(22)).tracking(1).foregroundStyle(Theme.fg)
                Spacer()
            }
            HStack(spacing: 8) {
                Image(systemName: "rectangle.split.2x1").font(.caption).foregroundStyle(Theme.muted)
                Text("TU ESPACIO  /  ESTUDIO DE PUBLICACIÓN").font(Theme.mono).tracking(2).foregroundStyle(Theme.muted)
            }
            Divider().overlay(Theme.line)
        }
    }
}

struct PageTitle: View {
    let kicker: String
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(Theme.accent).frame(width: 7, height: 7)
                Text(kicker.uppercased()).font(.system(size: 13, weight: .medium, design: .monospaced)).tracking(3).foregroundStyle(Theme.accent)
            }
            (Text(title.uppercased()).foregroundStyle(Theme.fg) + Text(".").foregroundStyle(Theme.accent))
                .font(Theme.display(56))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 10)
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case contenido, horarios, metrica, comentarios, ajustes
    var id: String { rawValue }
    var label: String {
        switch self {
        case .contenido: "CONTENIDO"
        case .horarios: "HORARIOS"
        case .metrica: "MÉTRICA"
        case .comentarios: "COMENT."
        case .ajustes: "AJUSTES"
        }
    }
    var icon: String {
        switch self {
        case .contenido: "square.grid.2x2"
        case .horarios: "clock.arrow.circlepath"
        case .metrica: "chart.bar"
        case .comentarios: "bubble.left"
        case .ajustes: "slider.horizontal.3"
        }
    }
}

struct BottomBar: View {
    @Binding var tab: AppTab
    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { t in
                Button { tab = t } label: {
                    VStack(spacing: 5) {
                        Image(systemName: t.icon).font(.system(size: 19))
                            .frame(width: 48, height: 30)
                            .background(tab == t ? Theme.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 9))
                            .foregroundStyle(tab == t ? Theme.accent : Theme.muted)
                        Text(t.label).font(.system(size: 9.5, weight: tab == t ? .bold : .medium, design: .monospaced))
                            .foregroundStyle(tab == t ? Theme.fg : Theme.muted)
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(.plain)
            }
        }
        .padding(.top, 10).padding(.bottom, 4)
        .background(Theme.bg2.opacity(0.97))
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

/// Botón rectangular como los de tu app (Publicar ahora, Reporte…).
struct BoxButtonStyle: ButtonStyle {
    var filled = false
    var color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .bold)).textCase(.uppercase).tracking(1.2)
            .lineLimit(1).minimumScaleFactor(0.7)
            .padding(.horizontal, 12).padding(.vertical, 12)
            .foregroundStyle(filled ? .white : (color == Theme.accent ? Theme.fg : color))
            .background(filled ? color : .clear)
            .overlay(Rectangle().strokeBorder(filled ? .clear : (color == Theme.accent ? Theme.fg.opacity(0.85) : color), lineWidth: 1.2))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Recuadro con borde recto como las tarjetas de tu app.
struct Box<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bg2)
            .overlay(Rectangle().strokeBorder(Theme.line))
    }
}

extension UUID: @retroactive Identifiable { public var id: UUID { self } }
