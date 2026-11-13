import SwiftUI
import PhotosUI

struct CalendarView: View {
    @Environment(AppStore.self) private var store
    @Environment(YouTubeService.self) private var youtube
    @State private var selected = 0
    @State private var editing: UUID?
    @State private var pick: PhotosPickerItem?
    @State private var targetTime: Date?

    private var days: [Date] {
        let start = Calendar.current.startOfDay(for: .now)
        return (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: start) }
    }

    var body: some View {
        NavigationStack {
            Screen {
                ScreenTitle(solid: "Tus", outline: "horas", subtitle: "Cada video nuevo toma el siguiente horario libre.")
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
                            .background(i == selected ? Theme.fg : Theme.bg2, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
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
                                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4])))
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
}
