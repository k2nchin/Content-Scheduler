import SwiftUI

/// Comentarios de YouTube: responder, respuestas rápidas, reglas por palabra, spam y respuesta automática.
struct CommentsView: View {
    @Environment(AppStore.self) private var store
    @Environment(YouTubeService.self) private var youtube
    @Environment(MetaService.self) private var meta
    @State private var network: Network = .youtube
    private var netConnected: Bool {
        switch network {
        case .youtube: youtube.isConnected
        case .facebook: meta.facebookConnected
        case .instagram: meta.instagramConnected
        case .tiktok: false
        }
    }

    @AppStorage("cs.replyTemplates") private var templatesRaw = AutoReply.defaultTemplates
    @AppStorage("cs.replyRules") private var rulesRaw = AutoReply.defaultRules
    @AppStorage("cs.blockedWords") private var blockedRaw = AutoReply.defaultBlocked
    @AppStorage("cs.skipBlocked") private var skipBlocked = true
    @AppStorage("cs.autoReply") private var autoReply = false

    enum Show: String, CaseIterable { case pendientes = "Pendientes", todos = "Todos", spam = "Spam" }

    @State private var comments: [YouTubeService.Comment] = []
    @State private var drafts: [String: String] = [:]
    @State private var show: Show = .pendientes
    @State private var search = ""
    @State private var loading = false
    @State private var sending: Set<String> = []
    @State private var editing = false
    @State private var confirmAll = false

    private var templates: [String] { AutoReply.templates }
    private var pending: [YouTubeService.Comment] { comments.filter { !$0.replied && !AutoReply.answered.contains($0.id) && !AutoReply.isSpam($0) } }
    private var spam: [YouTubeService.Comment] { comments.filter { !$0.replied && AutoReply.isSpam($0) } }
    private var shown: [YouTubeService.Comment] {
        let base: [YouTubeService.Comment] = switch show { case .pendientes: pending; case .todos: comments; case .spam: spam }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? base : base.filter { $0.text.lowercased().contains(q) || $0.author.lowercased().contains(q) }
    }

    var body: some View {
        Screen {
            AppHeader()
            PageTitle(kicker: "Tu público", title: "Comentarios")
            HStack(spacing: 0) {
                ForEach(Network.allCases) { n in
                    Button { network = n } label: {
                        VStack(spacing: 5) {
                            NetLogo(network: n, size: 18)
                            Text(n.name).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .foregroundStyle(network == n ? .white : Theme.muted)
                        .background(network == n ? Theme.accent : Theme.bg2)
                    }.buttonStyle(.plain)
                }
            }.overlay(Rectangle().strokeBorder(Theme.line))
            if network == .tiktok {
                DemoBanner(text: "TikTok todavía no permite leer ni responder comentarios desde otras apps. Próximamente.", icon: "info.circle")
            } else if !netConnected {
                DemoBanner(text: network == .youtube ? "Conecta YouTube en Ajustes para ver y responder tus comentarios."
                           : "Toca «Continuar con Facebook» en Ajustes para ver y responder los comentarios de \(network.name).", icon: "info.circle")
            } else {
                if network == .youtube { YTAccountPicker() }
                HStack(spacing: 10) {
                    stat("Pendientes", pending.count)
                    stat("Spam", spam.count)
                    stat("Auto hoy", AutoReply.todayCount)
                }
                Box {
                    Toggle(isOn: $autoReply) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Respuesta automática").bold()
                            Text("Responde sola a los pendientes al abrir la app y en segundo plano, con tus reglas y respuestas rápidas (máx. 15 cada vez).")
                                .font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                    Divider().overlay(Theme.line)
                    Button { editing = true } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Reglas y respuestas").bold()
                                Text("\(templates.count) respuestas · \(AutoReply.rules.count) reglas por palabra · \(AutoReply.blocked.count) palabras de spam")
                                    .font(.caption).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                HStack(spacing: 0) {
                    ForEach(Show.allCases, id: \.self) { s in
                        Button(s.rawValue) { show = s }
                            .font(.footnote).frame(maxWidth: .infinity).padding(.vertical, 10)
                            .foregroundStyle(show == s ? .white : Theme.muted).background(show == s ? Theme.accent : Theme.bg2)
                    }
                }.overlay(Rectangle().strokeBorder(Theme.line))
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                    TextField("Buscar comentario o persona", text: $search).textInputAutocapitalization(.never)
                }.padding(10).background(Theme.bg3)
                if show == .pendientes && !pending.isEmpty {
                    Button { confirmAll = true } label: { Label("Responder a todos los pendientes", systemImage: "bubble.left.and.bubble.right").frame(maxWidth: .infinity) }
                        .buttonStyle(BoxButtonStyle())
                }
                if loading { ProgressView().frame(maxWidth: .infinity).padding() }
                if !loading && shown.isEmpty {
                    Text(show == .pendientes ? "No tienes comentarios pendientes. 🎉" : "Nada por aquí.")
                        .foregroundStyle(Theme.muted).frame(maxWidth: .infinity).padding(.vertical, 30)
                }
                ForEach(shown) { c in commentCard(c) }
                Text(network == .youtube ? "Cada respuesta usa cuota de la API de YouTube (unas 200 al día con la cuota gratis)." : "Meta limita cuántas respuestas por hora se pueden enviar desde apps.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await load() }
        .task(id: "\(network.rawValue)-\(youtube.activeID ?? "")-\(meta.page?.id ?? "")") { comments = []; await load() }
        .sheet(isPresented: $editing) {
            RulesEditor(templates: $templatesRaw, rules: $rulesRaw, blocked: $blockedRaw, skipBlocked: $skipBlocked)
        }
        .confirmationDialog("¿Responder a \(min(pending.count, 15)) comentarios con tus reglas y respuestas rápidas?", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("Responder") { Task { await runAuto() } }
        }
    }

    private func stat(_ title: String, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(Theme.muted)
            Text("\(n)").font(Theme.display(26)).foregroundStyle(Theme.fg)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg2).overlay(Rectangle().strokeBorder(Theme.line))
    }

    private func commentCard(_ c: YouTubeService.Comment) -> some View {
        let done = c.replied || AutoReply.answered.contains(c.id)
        return Box {
            HStack(alignment: .firstTextBaseline) {
                Text(c.author).font(.subheadline.bold()).lineLimit(1)
                if AutoReply.isSpam(c) {
                    Text("SPAM").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(Theme.warn)
                        .padding(.horizontal, 5).padding(.vertical, 2).background(Theme.warn.opacity(0.15))
                }
                Spacer()
                Text(c.date.dayLabel).font(.caption).foregroundStyle(Theme.muted)
            }
            Text(c.text).font(.subheadline)
            HStack(spacing: 14) {
                if let url = URL(string: c.link ?? "https://youtu.be/\(c.videoID)") { Link("Ver publicación", destination: url).font(.caption.bold()) }
                Button { Task { await hide(c) } } label: { Label("Ocultar", systemImage: "eye.slash") }
                    .font(.caption.bold()).foregroundStyle(Theme.red)
            }
            if done {
                Label("Respondido", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Theme.ok)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        if let auto = AutoReply.reply(for: c) {
                            chip("✨ " + auto) { drafts[c.id] = auto }
                        }
                        ForEach(templates, id: \.self) { t in chip(AutoReply.fill(t, c)) { drafts[c.id] = AutoReply.fill(t, c) } }
                    }
                }.scrollIndicators(.hidden)
                HStack {
                    TextField("Escribe tu respuesta…", text: Binding(get: { drafts[c.id] ?? "" }, set: { drafts[c.id] = $0 }), axis: .vertical)
                        .lineLimit(1...4).padding(10).background(Theme.bg3)
                    Button { Task { await send(c, text: drafts[c.id] ?? "") } } label: {
                        if sending.contains(c.id) { ProgressView().frame(width: 42, height: 42) }
                        else { Image(systemName: "paperplane.fill").frame(width: 42, height: 42) }
                    }
                    .background(Theme.accent).foregroundStyle(.white)
                    .disabled((drafts[c.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending.contains(c.id))
                }
            }
        }
    }

    private func chip(_ text: String, _ action: @escaping () -> Void) -> some View {
        Button(text, action: action)
            .font(.caption).lineLimit(1).frame(maxWidth: 240)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .overlay(Capsule().strokeBorder(Theme.line))
    }

    private func load() async {
        guard netConnected, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            comments = network == .youtube ? try await youtube.comments() : try await meta.comments(network)
            if autoReply { await runAuto() }
        } catch {
            store.show(error.localizedDescription)
        }
    }

    private func runAuto() async {
        let net = network
        let n = await AutoReply.run(comments) { c, text in try await sendReply(net, c, text) }
        if n > 0 {
            for i in comments.indices where AutoReply.answered.contains(comments[i].id) { comments[i].replied = true }
            store.show("\(n) \(n == 1 ? "comentario respondido" : "comentarios respondidos")")
        }
    }

    private func send(_ c: YouTubeService.Comment, text: String) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        sending.insert(c.id)
        defer { sending.remove(c.id) }
        do {
            try await sendReply(network, c, t)
            AutoReply.answered.insert(c.id)
            if let i = comments.firstIndex(where: { $0.id == c.id }) { comments[i].replied = true }
            drafts[c.id] = nil
        } catch {
            store.show(error.localizedDescription)
        }
    }

    private func sendReply(_ n: Network, _ c: YouTubeService.Comment, _ text: String) async throws {
        if n == .youtube { try await youtube.reply(to: c.commentID, text: text) } else { try await meta.reply(n, to: c.commentID, text: text) }
    }

    private func hide(_ c: YouTubeService.Comment) async {
        do {
            if network == .youtube { try await youtube.hide(commentID: c.commentID) } else { try await meta.hide(network, commentID: c.commentID) }
            comments.removeAll { $0.id == c.id }
            store.show("Comentario ocultado")
        } catch {
            store.show(error.localizedDescription)
        }
    }
}

struct RulesEditor: View {
    @Binding var templates: String
    @Binding var rules: String
    @Binding var blocked: String
    @Binding var skipBlocked: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var t = ""
    @State private var r = ""
    @State private var b = ""

    var body: some View {
        NavigationStack {
            Screen {
                section("Respuestas rápidas", "Una por línea. {nombre} se cambia por el nombre de quien comenta.", $t, 150)
                section("Reglas por palabra", "Una por línea: palabras separadas por coma => respuesta.\nEjemplo: precio, cuánto => Escríbeme por DM, {nombre}", $r, 150)
                section("Palabras de spam", "Separadas por coma. Esos comentarios no se responden solos.", $b, 90)
                Toggle("No responder comentarios con spam o links", isOn: $skipBlocked).font(.subheadline)
            }
            .navigationTitle("Reglas y respuestas").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Guardar") { templates = t; rules = r; blocked = b; dismiss() } }
            }
            .onAppear { t = templates; r = rules; b = blocked }
        }
    }

    private func section(_ title: String, _ hint: String, _ text: Binding<String>, _ height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(Theme.mono).tracking(1.6).foregroundStyle(Theme.muted)
            Text(hint).font(.caption).foregroundStyle(Theme.muted)
            TextEditor(text: text).scrollContentBackground(.hidden).frame(minHeight: height).padding(8).background(Theme.bg3)
        }
    }
}
