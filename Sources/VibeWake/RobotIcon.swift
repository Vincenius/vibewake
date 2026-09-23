import AppKit

/// Menu bar robot icon, drawn in code since SF Symbols has no robot.
enum RobotIcon {
    /// Subtle green for "agents running" — softer than systemGreen so it doesn't shout.
    static let runningGreen = NSColor(srgbRed: 0.40, green: 0.80, blue: 0.50, alpha: 1)

    /// - Parameter color: nil → template image (white on a dark menu bar, black on a light one).
    static func image(color: NSColor?, alpha: CGFloat = 1) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            // Fade the whole shape as one layer so overlapping parts don't show seams.
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.setAlpha(alpha)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            defer { ctx.endTransparencyLayer() }
            (color ?? .black).setFill()

            // Antenna: stalk + ball
            NSBezierPath(rect: NSRect(x: 8.4, y: 13.5, width: 1.2, height: 2)).fill()
            NSBezierPath(ovalIn: NSRect(x: 7.4, y: 15, width: 3.2, height: 3)).fill()

            // Ears
            NSBezierPath(roundedRect: NSRect(x: 0.6, y: 6.5, width: 1.9, height: 4), xRadius: 0.8, yRadius: 0.8).fill()
            NSBezierPath(roundedRect: NSRect(x: 15.5, y: 6.5, width: 1.9, height: 4), xRadius: 0.8, yRadius: 0.8).fill()

            // Head with eyes and mouth punched out (even-odd).
            let head = NSBezierPath(roundedRect: NSRect(x: 2.8, y: 2.5, width: 12.4, height: 11.5), xRadius: 3.2, yRadius: 3.2)
            head.append(NSBezierPath(ovalIn: NSRect(x: 5.2, y: 7.6, width: 2.6, height: 2.9)))
            head.append(NSBezierPath(ovalIn: NSRect(x: 10.2, y: 7.6, width: 2.6, height: 2.9)))
            head.append(NSBezierPath(roundedRect: NSRect(x: 6.3, y: 4.6, width: 5.4, height: 1.4), xRadius: 0.7, yRadius: 0.7))
            head.windingRule = .evenOdd
            head.fill()
            return true
        }
        image.isTemplate = color == nil
        image.accessibilityDescription = "VibeWake"
        return image
    }
}
