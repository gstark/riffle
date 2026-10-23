// Colors, fonts, and sizes for the Riffle interface.

import AppKit
import SwiftUI

enum Theme {
    // MARK: Colors

    static let panel = dynamic(light: 0xF5F5F7, dark: 0x29292C)
    static let text = dynamic(light: 0x1D1D1F, dark: 0xF2F2F4)
    // Both grays meet WCAG AA (4.5:1) on the panel color in light and dark mode.
    static let secondary = dynamic(light: 0x58585D, dark: 0xB4B4B9)
    static let tertiary = dynamic(light: 0x6E6E73, dark: 0x98989D)
    static let ink = dynamic(light: 0x1F3F7A, dark: 0xA9C0EC)
    static let selectedRow = dynamic(light: 0x1F3F7A, lightAlpha: 0.11, dark: 0xA9C0EC, darkAlpha: 0.16)
    static let selectedToken = dynamic(light: 0x1F3F7A, lightAlpha: 0.09, dark: 0xA9C0EC, darkAlpha: 0.13)

    private static func dynamic(light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? rgb(dark, alpha: darkAlpha)
                : rgb(light, alpha: lightAlpha)
        })
    }

    private static func rgb(_ hex: UInt32, alpha: CGFloat) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    // MARK: Type

    static let searchFont = Font.system(size: 26)
    static let searchIconSize: CGFloat = 22
    /// New York.
    static let sentenceFont = Font.system(size: 19, design: .serif)
    /// 19 pt at line height 1.7.
    static let sentenceLineHeight: CGFloat = 32
    static let titleFont = Font.system(size: 22, weight: .semibold)
    /// New York, to match the filter sentence.
    static let emptyTitleFont = Font.system(size: 26, weight: .semibold, design: .serif)
    static let emptyIconSize: CGFloat = 56
    static let subjectFont = Font.system(size: 19, weight: .semibold)
    static let detailFont = Font.system(size: 16.5)
    static let smallFont = Font.system(size: 15)

    // MARK: Sizes

    static let panelWidth: CGFloat = 880
    static let resultsMaxHeight: CGFloat = 640
    static let panelRadius: CGFloat = 24
    static let rowRadius: CGFloat = 12
    static let tokenRadius: CGFloat = 5
    static let margin: CGFloat = 26
    static let fadeIn: TimeInterval = 0.12

    // MARK: Resize

    /// The panel and its content change height together, with the same curve and duration.
    static let resizeDuration: TimeInterval = 0.24
    private static let resizeCurve: (x1: Double, y1: Double, x2: Double, y2: Double) = (0.25, 0.1, 0.25, 1)
    /// A new value for each use: CAMediaTimingFunction is not Sendable, so a shared static instance does not compile.
    static var resizeTiming: CAMediaTimingFunction {
        CAMediaTimingFunction(
            controlPoints: Float(resizeCurve.x1), Float(resizeCurve.y1), Float(resizeCurve.x2), Float(resizeCurve.y2)
        )
    }
    static let resizeAnimation = Animation.timingCurve(
        resizeCurve.x1, resizeCurve.y1, resizeCurve.x2, resizeCurve.y2, duration: resizeDuration
    )
}
