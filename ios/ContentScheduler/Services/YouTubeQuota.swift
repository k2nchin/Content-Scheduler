import Foundation

/// Cuenta las subidas a YouTube del día para avisar antes de que se acabe la cuota.
/// La cuota (10.000 unidades, ~1.600 por subida) se reinicia a medianoche hora del Pacífico.
enum YouTubeQuota {
    static let dailyUploads = 6
    private static let key = "yt.quota"

    private static var today: String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let c = cal.dateComponents([.year, .month, .day], from: .now)
        return "\(c.year!)-\(c.month!)-\(c.day!)"
    }

    static var usedToday: Int {
        let d = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        return d[today] ?? 0
    }

    static var remaining: Int { max(0, dailyUploads - usedToday) }

    static func recordUpload() {
        UserDefaults.standard.set([today: usedToday + 1], forKey: key)
    }

    /// Aviso para mostrar antes de subir, o nil si hay cuota de sobra.
    static var warning: String? {
        switch remaining {
        case 0: return "Hoy ya subiste \(usedToday) videos: es probable que YouTube rechace este por cuota. Se reinicia a la medianoche de California."
        case 1: return "Es tu última subida a YouTube de hoy (la cuota alcanza para unas \(dailyUploads))."
        default: return nil
        }
    }
}
