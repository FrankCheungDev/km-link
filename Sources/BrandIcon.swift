import AppKit

/// Brand icon helpers for KMLink.
enum AppBrand {
    /// Returns the bundled macOS app icon, falling back to a crisp vector mark
    /// when executed outside the `.app` bundle.
    static func appIcon() -> NSImage {
        if let bundled = Bundle.main.image(forResource: NSImage.Name("AppIcon")) {
            return bundled
        }
        let img = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            let body = rect.insetBy(dx: 12, dy: 12)
            let squircle = NSBezierPath(roundedRect: body, xRadius: 24, yRadius: 24)
            let bgGrad = NSGradient(
                starting: NSColor(calibratedRed: 0.06, green: 0.36, blue: 0.67, alpha: 1),
                ending: NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.30, alpha: 1)
            )
            bgGrad?.draw(in: squircle, angle: -45)

            let leftCard = NSBezierPath(roundedRect: NSRect(x: 28, y: 42, width: 34, height: 44), xRadius: 6, yRadius: 6)
            let rightCard = NSBezierPath(roundedRect: NSRect(x: 66, y: 42, width: 34, height: 44), xRadius: 6, yRadius: 6)
            NSColor.white.withAlphaComponent(0.18).setFill()
            leftCard.fill()
            rightCard.fill()
            NSColor.white.withAlphaComponent(0.45).setStroke()
            leftCard.lineWidth = 1.5
            rightCard.lineWidth = 1.5
            leftCard.stroke()
            rightCard.stroke()

            let arc = NSBezierPath()
            arc.move(to: NSPoint(x: 42, y: 54))
            arc.curve(to: NSPoint(x: 74, y: 66),
                      controlPoint1: NSPoint(x: 52, y: 68),
                      controlPoint2: NSPoint(x: 64, y: 70))
            NSColor(calibratedRed: 0.35, green: 0.88, blue: 1.0, alpha: 0.95).setStroke()
            arc.lineWidth = 3.2
            arc.lineCapStyle = .round
            arc.stroke()

            let cursor = NSBezierPath()
            cursor.move(to: NSPoint(x: 70, y: 74))
            cursor.line(to: NSPoint(x: 74, y: 51))
            cursor.line(to: NSPoint(x: 79, y: 57))
            cursor.line(to: NSPoint(x: 84, y: 49))
            cursor.line(to: NSPoint(x: 88, y: 51))
            cursor.line(to: NSPoint(x: 83, y: 59))
            cursor.line(to: NSPoint(x: 90, y: 61))
            cursor.close()
            NSColor.white.setFill()
            cursor.fill()
            return true
        }
        return img
    }
}
