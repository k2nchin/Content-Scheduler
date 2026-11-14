import SwiftUI
import PhotosUI

struct CalendarView: View {
    @Environment(AppStore.self) private var store
    @Environment(YouTubeService.self) private var youtube
    @State private var selected = 0
    @State private var editing: UUID?
    @State private var pick: PhotosPickerItem?
    @State private var targetTime: Date?
    @State private var hours: [YouTubeService.HourStat] = []
    @State private var loadingHours = false
    @State private var advice: String?
    @State private var advising = false
    @State private var newSlot = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: .now) ?? .now

    private var days: [Date] {
        let start = Calendar.current.startOfDay(for: .now)
        return (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: start) }
    }

    var body: some View {
        NavigationStack {
            Screen {
                AppHeader()
                PageTitle(kicker: "Tu semana", title: "Horarios")
                Text("Cada video nuevo toma el siguiente horario libre.").font(.footnote).foregroundStyle(Theme.muted)
                if youtube.isConnected { bestHoursBox }
                Box {
                    Text("HORARIOS DE PUBLICACIÓN").font(Theme.mono).foregroundStyle(Theme.muted)
                    FlowSlots(slots: store.state.slots.sorted()) { s in
                        if store.state.slots.count > 1 { store.state.slots.removeAll { $0 == s } } else { store.show("Deja al menos un horario") }
                    }
                    HStack {
                        DatePicker("Nuevo horario", selection: $newSlot, displayedComponents: .hourAndMinute).labelsHidden()
                        Spacer()
                        Button("Agregar") {
                            let s = newSlot.hm
                            if !store.state.slots.contains(s) { store.state.slots.append(s); store.show("Horario agregado") }
                        }.buttonStyle(BoxButtonStyle(filled: true))
                    }
                }
                HStack(spacing: 6) {
                    ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                        let has = store.state.posts.contains { Calendar.current.isDate($0.date, inSameDayAs: d) }
                        Button { selected = i } label: {
                            VStack(spacing: 3) {
                                Text(d.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "es"))).uppercased())
                                    .font(.system(size: 10)).foregroundStyle(i == selected ? Theme.bg.opacity(0.6) : Theme.muted)
                                Text("\(Calendar.current.component(.day, from: d))").font(.headline)
                                Circle().fill(has ? Theme.accent : .clear).frame(width: 6, height: 6)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .foregroundStyle(i == selected ? Theme.bg : Theme.fg)
                            .background(i == selected ? Theme.fg : Theme.bg2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }.buttonStyle(.plain)
                    }
                }
                let day = days[selected]
                SectionLabel(text: day.dayLabel)
                let ofDay = store.state.posts.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }
                let times = Set(store.state.slots + ofDay.map(\.date.hm)).sorted()
                ForEach(times, id: \.self) { t in
                    HStack(alignment: .center, spacing: 12) {
                        Text(t).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.muted).frame(width: 52, alignment: .leading)
                        VStack(spacing: 8) {
                            let ps = ofDay.filter { $0.date.hm == t }
                            if ps.isEmpty {
                                PhotosPicker(selection: $pick, matching: .videos) {
                                    HStack { Image(systemName: "plus"); Text("Espacio libre") }
                                        .font(.footnote).foregroundStyle(Theme.muted)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4])))
                                }
                                .simultaneousGesture(TapGesture().onEnded { targetTime = time(t, on: day) })
                            }
                            ForEach(ps) { p in Button { editing = p.id } label: { PostRow(post: p) }.buttonStyle(.plain) }
                        }
                    }
                    .padding(.vertical, 6)
                    Divider().overlay(Theme.line)
                }
            }
            .sheet(item: $editing) { PostEditor(postID: $0) }
            .onChange(of: pick) { _, item in addAtSlot(item) }
        }
    }

    private func time(_ hm: String, on day: Date) -> Date {
        let p = hm.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: p.first ?? 9, minute: p.count > 1 ? p[1] : 0, second: 0, of: day) ?? day
    }

    private func addAtSlot(_ item: PhotosPickerItem?) {
        guard let item, let when = targetTime else { return }
        pick = nil; targetTime = nil
        if when < .now { return store.show("Ese horario ya pasó") }
        Task {
            guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else { return store.show("No se pudo leer el video.") }
            editing = await store.addVideo(from: movie.url, youtubeConnected: youtube.isConnected, at: when)
        }
    }

    private var bestHoursBox: some View {
        Box {
            HStack {
                Text("MEJOR HORA SEGÚN TU CANAL").font(Theme.mono).foregroundStyle(Theme.muted)
                Spacer()
                if loadingHours { ProgressView() }
            }
            if hours.isEmpty && !loadingHours {
                Button { Task { await loadHours() } } label: { Label("Analizar mis últimos 50 videos", systemImage: "sparkles") }
                    .buttonStyle(BoxButtonStyle())
            }
            let top = Array(hours.prefix(3))
            let maxV = max(top.first?.avgViews ?? 1, 1)
            ForEach(top) { h in
                HStack(spacing: 10) {
                    Text(String(format: "%02d:00", h.hour)).font(.system(size: 14, weight: .bold, design: .monospaced)).frame(width: 56, alignment: .leading)
                    GeometryReader { g in
                        Capsule().fill(Theme.accent).frame(width: g.size.width * h.avgViews / maxV, height: 8).frame(maxHeight: .infinity)
                    }.frame(height: 18)
                    Text("\(compact(h.avgViews)) prom.").font(.caption).foregroundStyle(Theme.muted).frame(width: 74, alignment: .trailing)
                }
            }
            if !top.isEmpty {
                Text("Vistas promedio de tus videos según la hora en que se publicaron (\(hours.reduce(0) { $0 + $1.videos }) videos).")
                    .font(.caption).foregroundStyle(Theme.muted)
                if NIM.isConfigured {
                    Button {
                        advising = true
                        Task {
                            do { advice = try await NIM.timeAdvice(hours: hours, videos: try await youtube.topVideos()) } catch { store.show(error.localizedDescription) }
                            advising = false
                        }
                    } label: { Label(advising ? "Analizando…" : "✨ Consejo de la IA", systemImage: "sparkles") }
                        .buttonStyle(BoxButtonStyle()).disabled(advising)
                    if let advice { Text(advice).font(.footnote) }
                }
                Button {
                    store.state.slots = top.map { String(format: "%02d:00", $0.hour) }.sorted()
                    store.show("Horarios cambiados a tus mejores horas")
                } label: { Text("Usar estas horas") }.buttonStyle(BoxButtonStyle(filled: true))
            }
        }
    }

    private func loadHours() async {
        loadingHours = true
        do { hours = try await youtube.bestHours() } catch { store.show(error.localizedDescription) }
        if hours.isEmpty { store.show("Tu canal todavía no tiene videos para analizar.") }
        loadingHours = false
    }
}
