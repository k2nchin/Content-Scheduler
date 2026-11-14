import SwiftUI
import PhotosUI
import UIKit

/// Marca de agua de tus clips: tu @ y/o tu logo, en una esquina.
enum Watermark {
    enum Corner: String, CaseIterable { case arribaIzq, arribaDer, abajoIzq, abajoDer
        var label: String {
            switch self { case .arribaIzq: "Arriba izq."; case .arribaDer: "Arriba der."; case .abajoIzq: "Abajo izq."; case .abajoDer: "Abajo der." }
        }
        var alignment: Alignment {
            switch self { case .arribaIzq: .topLeading; case .arribaDer: .topTrailing; case .abajoIzq: .bottomLeading; case .abajoDer: .bottomTrailing }
        }
    }

    private static let d = UserDefaults.standard
    static var enabled: Bool { d.bool(forKey: "wm.on") }
    static var text: String { d.string(forKey: "wm.text") ?? "" }
    static var corner: Corner { Corner(rawValue: d.string(forKey: "wm.corner") ?? "") ?? .arribaDer }
    static var opacity: Double { d.object(forKey: "wm.opacity") as? Double ?? 0.8 }

    static let logoURL = AppStore.documents.appendingPathComponent("watermark.png")
    static var logo: UIImage? { UIImage(contentsOfFile: logoURL.path) }
    /// Logo de Content Scheduler incluido en la app.
    static var brandLogo: UIImage? { UIImage(named: "cs-logo") }
    static func useBrandLogo() { saveLogo(brandLogo?.pngData()) }

    static func saveLogo(_ data: Data?) {
        if let data, let img = UIImage(data: data), let png = img.pngData() { try? png.write(to: logoURL, options: .atomic) }
        else { try? FileManager.default.removeItem(at: logoURL) }
    }

    /// Capa lista para poner sobre el video (o nil si está apagada o vacía).
    static func layer(for size: CGSize) -> CALayer? {
        let t = text.trimmingCharacters(in: .whitespaces)
        let img = logo
        guard enabled, !t.isEmpty || img != nil else { return nil }
        let margin = size.width * 0.045
        let logoH = size.width * 0.085
        let fontSize = size.width * 0.038
        let group = CALayer()
        var x: CGFloat = 0
        var w: CGFloat = 0
        var h: CGFloat = 0
        if let img, let cg = img.cgImage {
            let lw = logoH * img.size.width / max(img.size.height, 1)
            let l = CALayer()
            l.contents = cg
            l.contentsGravity = .resizeAspect
            l.frame = CGRect(x: 0, y: 0, width: lw, height: logoH)
            group.addSublayer(l)
            x = lw + (t.isEmpty ? 0 : fontSize * 0.4)
            w = x; h = logoH
        }
        if !t.isEmpty {
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = 4
            shadow.shadowOffset = CGSize(width: 0, height: 1)
            let attr = NSAttributedString(string: t, attributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: UIColor.white, .shadow: shadow,
            ])
            let tw = ceil(attr.size().width) + 4
            let th = ceil(attr.size().height)
            let tl = CATextLayer()
            tl.string = attr
            tl.contentsScale = 2
            tl.frame = CGRect(x: x, y: (max(h, th) - th) / 2, width: tw, height: th)
            group.addSublayer(tl)
            w = x + tw; h = max(h, th)
        }
        // Coordenadas del video: el origen está abajo a la izquierda
        let left = corner == .arribaIzq || corner == .abajoIzq
        let top = corner == .arribaIzq || corner == .arribaDer
        let topMargin = margin * 2.2   // un poco más abajo para no chocar con la interfaz de TikTok/Reels
        group.frame = CGRect(x: left ? margin : size.width - margin - w,
                             y: top ? size.height - topMargin - h : margin * 3,
                             width: w, height: h)
        group.opacity = Float(opacity)
        return group
    }
}

/// Ajustes de la marca de agua, con vista previa.
struct WatermarkSettings: View {
    @AppStorage("wm.on") private var on = false
    @AppStorage("wm.text") private var text = ""
    @AppStorage("wm.corner") private var corner = Watermark.Corner.arribaDer.rawValue
    @AppStorage("wm.opacity") private var opacity = 0.8
    @State private var logo = Watermark.logo
    @State private var pick: PhotosPickerItem?

    var body: some View {
        Toggle(isOn: Binding(get: { on }, set: { v in
            on = v
            // La primera vez, pone el logo de Content Scheduler
            if v && logo == nil && !UserDefaults.standard.bool(forKey: "wm.set") {
                Watermark.useBrandLogo(); logo = Watermark.logo
                UserDefaults.standard.set(true, forKey: "wm.set")
            }
        })) {
            VStack(alignment: .leading) {
                Text("Marca de agua").bold()
                Text("Tu @ y/o tu logo en todos los clips.").font(.caption).foregroundStyle(Theme.muted)
            }
        }
        if on {
            // Vista previa
            ZStack(alignment: Watermark.Corner(rawValue: corner)?.alignment ?? .topTrailing) {
                LinearGradient(colors: Theme.gradients[2], startPoint: .topLeading, endPoint: .bottomTrailing)
                HStack(spacing: 4) {
                    if let logo { Image(uiImage: logo).resizable().scaledToFit().frame(height: 18) }
                    if !text.isEmpty { Text(text).font(.system(size: 10, weight: .bold)).foregroundStyle(.white).shadow(radius: 2) }
                }
                .opacity(opacity).padding(8)
            }
            .frame(width: 110, height: 196).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxWidth: .infinity)
            TextField("@tucuenta", text: $text).textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(12).background(Theme.bg3, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Button { Watermark.useBrandLogo(); logo = Watermark.logo } label: {
                HStack(spacing: 10) {
                    Image("cs-logo").resizable().frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text("Usar logo de Content Scheduler").font(.subheadline.weight(.semibold))
                    Spacer()
                }.padding(10).background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }.buttonStyle(.plain).foregroundStyle(Theme.accent)
            HStack {
                PhotosPicker(selection: $pick, matching: .images) { Label(logo == nil ? "Elegir logo" : "Otro logo", systemImage: "photo") }
                    .buttonStyle(BoxButtonStyle())
                if logo != nil {
                    Button("Quitar logo") { Watermark.saveLogo(nil); logo = nil }.buttonStyle(BoxButtonStyle(color: Theme.red))
                }
            }
            Picker("Esquina", selection: $corner) {
                ForEach(Watermark.Corner.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }.pickerStyle(.segmented)
            HStack {
                Text("Opacidad").font(.footnote)
                Slider(value: $opacity, in: 0.3...1)
            }
            Text("Para el logo usa un PNG con fondo transparente.").font(.caption).foregroundStyle(Theme.muted)
                .onChange(of: pick) { _, item in
                    Task {
                        if let data = try? await item?.loadTransferable(type: Data.self) { Watermark.saveLogo(data); logo = Watermark.logo }
                        pick = nil
                    }
                }
        }
    }
}
