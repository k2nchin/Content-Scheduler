import SwiftUI

enum Theme {
    static let bg = Color(hex: 0x070708)
    static let bg2 = Color(hex: 0x101012)
    static let bg3 = Color(hex: 0x18181B)
    static let fg = Color(hex: 0xF5F3EF)
    static let muted = Color(hex: 0x8B8890)
    static let accent = Color(hex: 0xFF0A8A)
    static let line = Color(hex: 0x222126)
    static let ok = Color(hex: 0x5EE6A8)
    static let warn = Color(hex: 0xFFC65C)
    static let red = Color(hex: 0xFF6B6B)
    static let gradients: [[Color]] = [
        [Color(hex: 0xFF0A8A), Color(hex: 0x7A2CFF)],
        [Color(hex: 0xFF7A00), Color(hex: 0xFF0A8A)],
        [Color(hex: 0x00C2FF), Color(hex: 0x7A2CFF)],
        [Color(hex: 0x25F4EE), Color(hex: 0x3B82F6)],
        [Color(hex: 0xFFC65C), Color(hex: 0xFF3B30)],
        [Color(hex: 0x5EE6A8), Color(hex: 0x00C2FF)],
    ]

    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .black).width(.compressed) }
    static let mono = Font.system(size: 11, weight: .medium, design: .monospaced)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension Date {
    var dayLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "Hoy" }
        if cal.isDateInTomorrow(self) { return "Mañana" }
        if cal.isDateInYesterday(self) { return "Ayer" }
        return formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(Locale(identifier: "es")))
    }
    var hm: String { formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "es_ES"))) }
}

func compact(_ n: Double) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000).replacingOccurrences(of: ".0M", with: "M") }
    if n >= 1_000 { return String(format: "%.1fK", n / 1_000).replacingOccurrences(of: ".0K", with: "K") }
    return String(Int(n))
}
