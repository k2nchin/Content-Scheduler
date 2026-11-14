import SwiftUI

enum Theme {
    // Estilo Apple: colores del sistema (se adaptan a modo claro y oscuro) + el rosa de la marca como acento.
    static let bg = Color(uiColor: .systemGroupedBackground)
    static let bg2 = Color(uiColor: .secondarySystemGroupedBackground)
    static let bg3 = Color(uiColor: .tertiarySystemFill)
    static let fg = Color(uiColor: .label)
    static let muted = Color(uiColor: .secondaryLabel)
    static let accent = Color(hex: 0xFF2D8A)
    static let line = Color(uiColor: .separator)
    static let ok = Color(uiColor: .systemGreen)
    static let warn = Color(uiColor: .systemOrange)
    static let red = Color(uiColor: .systemRed)
    static let radius: CGFloat = 14
    static let gradients: [[Color]] = [
        [Color(hex: 0xFF0A8A), Color(hex: 0x7A2CFF)],
        [Color(hex: 0xFF7A00), Color(hex: 0xFF0A8A)],
        [Color(hex: 0x00C2FF), Color(hex: 0x7A2CFF)],
        [Color(hex: 0x25F4EE), Color(hex: 0x3B82F6)],
        [Color(hex: 0xFFC65C), Color(hex: 0xFF3B30)],
        [Color(hex: 0x5EE6A8), Color(hex: 0x00C2FF)],
    ]

    /// Números y títulos grandes con San Francisco (como las apps de Apple).
    static func display(_ size: CGFloat) -> Font { .system(size: size * 0.78, weight: .bold, design: .rounded) }
    /// Encabezados de sección, como en Ajustes de iOS.
    static let mono = Font.footnote.weight(.semibold)
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
