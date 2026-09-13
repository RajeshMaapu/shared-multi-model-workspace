import SwiftUI
import WorkshopCore

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    static func themed(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(Color(hex: hex))
        })
    }
}

/// §3.3 color tokens.
enum WorkshopColors {
    static let navigationBackground = Color.themed(light: 0x3F0E40, dark: 0x241126)
    static let navigationHover = Color.themed(light: 0x522653, dark: 0x39203D)
    static let selectedNavigation = Color.themed(light: 0x1164A3, dark: 0x175D89)
    static let conversationSurface = Color.themed(light: 0xFFFFFF, dark: 0x1A1D21)
    static let secondarySurface = Color.themed(light: 0xF8F8F8, dark: 0x222529)
    static let primaryText = Color.themed(light: 0x1D1C1D, dark: 0xD1D2D3)
    static let secondaryText = Color.themed(light: 0x616061, dark: 0xABABAD)
    static let divider = Color.themed(light: 0xE5E5E5, dark: 0x393B3E)
    static let success = Color.themed(light: 0x2BAC76, dark: 0x38C98C)
    static let attention = Color.themed(light: 0x8A6116, dark: 0xE8B650)
    static let error = Color.themed(light: 0xC53030, dark: 0xF07B7B)

    static func engineer(_ id: EngineerID) -> Color {
        switch id {
        case .devin: return Color.themed(light: 0x1164A3, dark: 0x5FA8E0)
        case .kimi: return Color.themed(light: 0x2BAC76, dark: 0x38C98C)
        case .deepseek: return Color.themed(light: 0x8A6116, dark: 0xE8B650)
        }
    }

    static func health(_ health: EngineerHealth.Kind) -> Color {
        switch health {
        case .available: return success
        case .quotaLimited, .loginRequired: return attention
        case .incompatibleVersion, .unavailable: return error
        }
    }
}

extension Date {
    var relativeDescription: String {
        let seconds = Int(Date().timeIntervalSince(self))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }
}
