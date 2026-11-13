import SwiftUI

/// Comentarios de YouTube: responder uno por uno, con respuestas rápidas, o en automático a los pendientes.
struct CommentsView: View {
    @Environment(AppStore.self) private var store
    @Environment(YouTubeService.self) private var youtube

    @AppStorage("cs.replyTemplates") private var templatesRaw =
        "¡Gracias por comentar, {nombre}! 🙌\nMuchas gracias por el apoyo, {nombre} 🔥\n¡Qué bueno que te gustó, {nombre}! Sígueme para más 🎶"
    @AppStorage("cs.autoReply") private var autoReply = false

    @State private var comments: [YouTubeService.Comment] = []
    @State private var drafts: [String: String] = [:]
    @State private var onlyPending = true
    @State private var loading = false
    @State private var sending: Set<String> = []
    @State private var editingTemplates = false
    @State private var confirmAll = false

    private var templates: [String] {
        templatesRaw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    private var pending: [YouTubeService.Comment] { comments.filter { !$0.replied } }
    private var shown: [YouTubeService.Comment] { onlyPending ? pending : comments }

    var body: some View {
        Screen {
            AppHeader()
            PageTitle(kicker: "Tu público", title: "Comentarios")
            if !youtube.isConnected {
                DemoBanner(text: "Conecta YouTube en Ajustes para ver y responder tus comentarios.", icon: "info.circle")
            } else {
                Card {
                    Toggle(isOn: $autoReply) {
                        VStack(alignment: .leading) {
                            Text("Respuesta automática").bold()
                            Text("Al abrir esta pantalla, responde a los pendientes con tus respuestas rápidas (máx. 15 cada vez).")
                                .font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                    Divider().overlay(Theme.line)
                    Button { editingTemplates = true } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Respuestas rápidas").bold()
                                Text("\(templates.count) guardadas · {nombre} se cambia por el nombre de quien comenta")
                                    .font(.caption).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(Theme.muted)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                HStack {
                    Picker("Mostrar", selection: $onlyPending) {
                        Text("Sin responder · \(pending.count)").tag(true)
                        Text("Todos · \(comments.count)").tag(false)
                    }.pickerStyle(.segmented)
                }
                if !pending.isEmpty && !templates.isEmpty {
                    Button { confirmAll = true } label: { Label("Responder a todos los pendientes", systemImage: "bubble.left.and.bubble.right") }
                        .buttonStyle(PrimaryButtonStyle(filled: false, color: Theme.fg))
                }
                if loading { ProgressView().frame(maxWidth: .infinity).padding() }
                if !loading && shown.isEmpty {
                    Text(onlyPending ? "No tienes comentarios pendientes. 🎉" : "Todavía no hay comentarios.")
                        .foregroundStyle(Theme.muted).frame(maxWidth: .infinity).padding(.vertical, 30)
                }
                ForEach(shown) { c in commentCard(c) }
                Text("Cada respuesta usa cuota de la API de YouTube (unas 200 respuestas al día con la cuota gratis).")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $editingTemplates) { TemplatesEditor(raw: $templatesRaw) }
        .confirmationDialog("¿Responder a \(min(pending.count, 15)) comentarios con tus respuestas rápidas?", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("Responder") { Task { await replyAll(limit: 15) } }
        }
    }

    private func commentCard(_ c: YouTubeService.Comment) -> some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text(c.author).font(.subheadline.bold())
                Spacer()
                Text(c.date.dayLabel).font(.caption).foregroundStyle(Theme.muted)
            }
            Text(c.text).font(.subheadline)
            if let url = URL(string: "https://youtu.be/\(c.videoID)") {
                Link("Ver video", destination: url).font(.caption.bold())
            }
            if c.replied {
                Label("Respondido", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Theme.ok)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(templates, id: \.self) { t in
                            Button(fill(t, c)) { drafts[c.id] = fill(t, c) }
                                .font(.caption).lineLimit(1)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .overlay(Capsule().strokeBorder(Theme.line))
                        }
                    }
                }.scrollIndicators(.hidden)
                HStack {
                    TextField("Escribe tu respuesta…", text: Binding(get: { drafts[c.id] ?? "" }, set: { drafts[c.id] = $0 }), axis: .vertical)
                        .lineLimit(1...4).padding(10)
                        .background(Theme.bg3, in: RoundedRectangle(cornerRadius: 10))
                    Button {
                        Task { await send(c, text: drafts[c.id] ?? "") }
                    } label: {
                        if sending.contains(c.id) { ProgressView().frame(width: 40, height: 40) }
                        else { Image(systemName: "paperplane.fill").frame(width: 40, height: 40) }
                    }
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(.white)
                    .disabled((drafts[c.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending.contains(c.id))
                }
            }
        }
    }

    private func fill(_ template: String, _ c: YouTubeService.Comment) -> String {
        let name = c.author.trimmingCharacters(in: CharacterSet(charactersIn: "@")).split(separator: " ").first.map(String.init) ?? ""
        return template.replacingOccurrences(of: "{nombre}", with: name)
    }

    private func load() async {
        guard youtube.isConnected, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            comments = try await youtube.comments()
            if autoReply && !pending.isEmpty && !templates.isEmpty { await replyAll(limit: 15) }
        } catch {
            store.show(error.localizedDescription)
        }
    }

    @discardableResult
    private func send(_ c: YouTubeService.Comment, text: String) async -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        sending.insert(c.id)
        defer { sending.remove(c.id) }
        do {
            try await youtube.reply(to: c.commentID, text: t)
            if let i = comments.firstIndex(where: { $0.id == c.id }) { comments[i].replied = true }
            drafts[c.id] = nil
            return true
        } catch {
            store.show(error.localizedDescription)
            return false
        }
    }

    private func replyAll(limit: Int) async {
        var done = 0
        for (i, c) in pending.prefix(limit).enumerated() {
            let template = templates[i % templates.count]
            if await send(c, text: fill(template, c)) { done += 1 } else { break }
            try? await Task.sleep(for: .milliseconds(600))
        }
        if done > 0 { store.show("\(done) \(done == 1 ? "comentario respondido" : "comentarios respondidos")") }
    }
}

struct TemplatesEditor: View {
    @Binding var raw: String
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Screen {
                Text("Una respuesta por línea. Escribe {nombre} donde quieras el nombre de quien comenta.")
                    .font(.footnote).foregroundStyle(Theme.muted)
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 240).padding(10)
                    .background(Theme.bg3, in: RoundedRectangle(cornerRadius: 10))
            }
            .navigationTitle("Respuestas rápidas").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Guardar") { raw = text; dismiss() } }
            }
            .onAppear { text = raw }
        }
    }
}
