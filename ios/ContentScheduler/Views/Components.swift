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
        Text(network.short)
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(dimmed ? Theme.muted : (network == .tiktok ? .black : .white))
            .frame(width: size, height: size)
            .background(dimmed ? Theme.bg3 : network.color, in: RoundedRectangle(cornerRadius: size * 0.27))
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
