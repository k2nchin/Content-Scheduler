import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(YouTubeService.self) private var youtube
    @State private var newSlot = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: .now) ?? .now
    @State private var connecting = false
    @State private var confirmDisconnect = false

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Screen {
                ScreenTitle(solid: "Ajus", outline: "tes")
                SectionLabel(text: "Cuentas conectadas")
                Card {
                    Button {
                        if youtube.isConnected { confirmDisconnect = true } else { connect() }
                    } label: {
                        row(.youtube, title: "YouTube",
                            detail: youtube.channel.map { "Canal: \($0.title)" } ?? (connecting ? "Conectando…" : "Toca para conectar tu canal"),
                            on: youtube.isConnected)
                    }.buttonStyle(.plain)
                    ForEach([Network.facebook, .instagram, .tiktok]) { n in
                        Divider().overlay(Theme.line)
                        HStack(spacing: 12) {
                            NetBadge(network: n, size: 32, dimmed: true)
                            VStack(alignment: .leading) {
                                Text(n.name).bold().foregroundStyle(Theme.muted)
                                Text("Próximamente").font(.caption).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }

                SectionLabel(text: "Horarios de publicación")
                Card {
                    FlowSlots(slots: store.state.slots.sorted()) { s in
                        if store.state.slots.count > 1 { store.state.slots.removeAll { $0 == s } }
                        else { store.show("Deja al menos un horario") }
                    }
                    HStack {
                        DatePicker("Nuevo horario", selection: $newSlot, displayedComponents: .hourAndMinute).labelsHidden()
                        Spacer()
                        Button("Agregar") {
                            let s = newSlot.hm
                            if !store.state.slots.contains(s) { store.state.slots.append(s); store.show("Horario agregado") }
                        }.buttonStyle(PrimaryButtonStyle()).frame(width: 130)
                    }
                }

                Text("CONTENT SCHEDULER · iOS").font(Theme.mono).foregroundStyle(Theme.muted).frame(maxWidth: .infinity).padding(.top, 20)
            }
            .confirmationDialog("¿Desconectar YouTube?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("Desconectar", role: .destructive) { youtube.disconnect(); store.show("YouTube desconectado") }
            }
        }
    }

    private func connect() {
        connecting = true
        Task {
            do { try await youtube.connect(); store.show("YouTube conectado") }
            catch { store.show(error.localizedDescription) }
            connecting = false
        }
    }

    private func row(_ n: Network, title: String, detail: String, on: Bool) -> some View {
        HStack(spacing: 12) {
            NetBadge(network: n, size: 32)
            VStack(alignment: .leading) {
                Text(title).bold()
                Text(detail).font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer()
            Image(systemName: on ? "checkmark.circle.fill" : "plus.circle").foregroundStyle(on ? Theme.ok : Theme.accent).font(.title3)
        }
        .contentShape(Rectangle())
    }

    private func labeled(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).bold()
            Text(detail).font(.caption).foregroundStyle(Theme.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FlowSlots: View {
    let slots: [String]
    let remove: (String) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(slots, id: \.self) { s in
                HStack(spacing: 6) {
                    Text(s).font(.system(size: 13, design: .monospaced))
                    Button { remove(s) } label: { Image(systemName: "xmark").font(.caption2) }.foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line))
            }
        }
    }
}
