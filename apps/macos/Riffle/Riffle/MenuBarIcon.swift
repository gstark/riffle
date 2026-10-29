// The menu bar icon: a fanned stack of three envelopes, as a template image that follows the menu bar color.
// The badged icon adds a dot at the top right when a site needs a sign-in again.

import AppKit

@MainActor
enum MenuBarIcon {
    static let image = make(badge: false)
    static let badged = make(badge: true)

    private static func make(badge: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
            guard let context = NSGraphicsContext.current else { return false }
            // Back to front. Each envelope pivots on the bottom center of the icon.
            for (degrees, alpha) in [(-16.0, 0.45), (-6.0, 0.7), (6.0, 1.0)] {
                context.saveGraphicsState()
                let transform = NSAffineTransform()
                transform.translateX(by: 10, yBy: 1.5)
                transform.rotate(byDegrees: degrees)
                transform.translateX(by: -10, yBy: -1.5)
                transform.concat()

                let body = NSRect(x: 3.5, y: 3, width: 13, height: 9)
                let outline = NSBezierPath(roundedRect: body, xRadius: 1.5, yRadius: 1.5)
                // Clear the envelopes behind, so their lines do not cross this one.
                context.compositingOperation = .clear
                outline.fill()
                context.compositingOperation = .sourceOver

                NSColor.black.withAlphaComponent(alpha).setStroke()
                outline.lineWidth = 1.2
                outline.stroke()

                let flap = NSBezierPath()
                flap.move(to: NSPoint(x: body.minX + 1, y: body.maxY - 1))
                flap.line(to: NSPoint(x: body.midX, y: body.midY - 0.5))
                flap.line(to: NSPoint(x: body.maxX - 1, y: body.maxY - 1))
                flap.lineWidth = 1.2
                flap.lineJoinStyle = .round
                flap.lineCapStyle = .round
                flap.stroke()
                context.restoreGraphicsState()
            }
            if badge {
                let dot = NSBezierPath(ovalIn: NSRect(x: 14, y: 10, width: 6, height: 6))
                // A clear ring around the dot, so it stands apart from the envelopes.
                context.compositingOperation = .clear
                NSBezierPath(ovalIn: NSRect(x: 13, y: 9, width: 8, height: 8)).fill()
                context.compositingOperation = .sourceOver
                NSColor.black.setFill()
                dot.fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = badge ? "Riffle, a site needs a sign-in" : "Riffle"
        return image
    }
}
