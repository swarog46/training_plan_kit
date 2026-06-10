//
//  Theme.swift
//  RunPlan
//
//  Centralized theme for light and dark mode support
//

import SwiftUI

struct Theme {
    // Text Colors
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let tertiaryText = Color.gray

    // Background Colors - Platform specific
    #if os(iOS)
    static let background = Color(.systemBackground)
    static let secondaryBackground = Color(.secondarySystemBackground)
    static let tertiaryBackground = Theme.gray6
    static let separator = Color(.separator)
    static let cardBackground = Color(.systemGray6)
    
    static let grayNavbarBackground = Color(hex: "1C1C1E")
    static let customGrayBackground = Color(hex: "2A2A2B")
    static let secondCustomGrayBackground = Color(hex: "3A3A3A")
    
    #elseif os(watchOS)
    static let background = Color.black
    static let secondaryBackground = Color(white: 0.1)
    static let tertiaryBackground = Color(white: 0.15)
    static let separator = Color.gray
    static let cardBackground = Color(white: 0.2)
    #endif

    // Brand Colors
    static let yellow = Color("AdaptiveYellow")
    static let indigo = Color.indigo
    static let green = Color.green
    static let mint = Color.mint
    static let orange = Color.orange
    static let pink = Color.pink
    static let cyan = Color.cyan
    static let purple = Color.purple

    // Overrides
    static let black = Color.black

    // Adaptive Text Colors
    #if os(iOS)
    static var sloganText: Color {
        Color(UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? UIColor(Theme.yellow) : UIColor(Theme.primaryText)
        })
    }
    
    static var customSegmentText: Color {
        Color(UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? UIColor(Theme.secondaryText) : UIColor(Theme.primaryText)
        })
    }
    
    static var globalHeaderBackground: Color {
        Color(UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? UIColor(Theme.grayNavbarBackground) : UIColor(Theme.background)
        })
    }
    
    static var customCardBackground: Color {
        Color(UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? UIColor(Theme.secondCustomGrayBackground) : UIColor.systemGray6
        })
    }
    
    static var customSegmentBackground: Color {
        Color(UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? UIColor(Theme.secondCustomGrayBackground) : UIColor(Theme.background)
        })
    }
    
    static var secondCustomCardBackground: Color {
        Color(UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? UIColor(Theme.customGrayBackground) : UIColor(Theme.secondaryBackground)
        })
    }
    
    static var plansBackground: Color {
        Color(UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? .systemBackground : UIColor(Theme.gray6)
        })
    }
    
    static var gray = Color(red: 142/255.0, green: 142/255.0, blue: 147/255.0)
    static var gray3 = Color(red: 199/255.0, green: 199/255.0, blue: 204/255.0)
    static var gray6 = Color(red: 244/255.0, green: 244/255.0, blue: 245/255.0)
    
    #elseif os(watchOS)
    static let sloganText = yellow
    #endif
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
