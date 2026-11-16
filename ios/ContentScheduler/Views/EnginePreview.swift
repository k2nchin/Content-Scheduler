import SwiftUI
import AVKit

/// Vista previa de un clip que vive en el iMac, sin bajarlo al teléfono.
///
/// Arranca apagada, con su botón de play: así una lista de diez clips no abre
/// diez conexiones de video a la vez. Al tocarla, se reproduce en streaming.
struct EnginePreview: View {
    let taskID: String
    let clip: ClipEngine.Clip

    @State private var player: AVPlayer?
    @State private var cargando = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.bg3)
            if let player {
                VideoPlayer(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                portada
            }
        }
        .aspectRatio(9 / 16, contentMode: .fit)
        .frame(maxHeight: 260)
        .onDisappear { player?.pause() }
    }

    @ViewBuilder private var portada: some View {
        Button { reproducir() } label: {
            ZStack {
                // Un degradado para que el hueco no parezca un error de carga.
                LinearGradient(colors: Theme.gradients[abs(clip.id.hashValue) % Theme.gradients.count],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(0.22)
                VStack(spacing: 8) {
                    if cargando {
                        ProgressView().tint(Theme.fg)
                    } else {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(Theme.fg.opacity(0.92))
                    }
                    Text("\(Int(clip.duration)) s").font(.caption2).foregroundStyle(Theme.muted)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func reproducir() {
        guard player == nil, !cargando else { return }
        cargando = true
        guard let r = ClipEngine.streamRequest(task: taskID, clip: clip.id), let url = r.url else {
            cargando = false
            return
        }
        // El clip pide la clave, así que viaja en la cabecera de la petición.
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": r.allHTTPHeaderFields ?? [:]])
        let nuevo = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        nuevo.isMuted = false
        player = nuevo
        cargando = false
        nuevo.play()
    }
}
