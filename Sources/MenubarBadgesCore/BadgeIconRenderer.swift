import AppKit
import CoreImage

/// Renders crisp Retina-ready `NSImage`s for menu bar status items and previews.
public enum BadgeIconRenderer {
    public static let defaultCanvasHeight: CGFloat = 20
    public static let defaultIconSize: CGFloat = 18

    public struct RenderOptions: Equatable, Sendable {
        public var style: BadgeDisplayStyle
        public var countFormat: CountTextFormat
        public var grayOutWhenNoUnread: Bool
        public var invertInDarkMode: Bool
        public var monochrome: Bool
        public var isDarkAppearance: Bool

        public init(
            style: BadgeDisplayStyle = .redBadge,
            countFormat: CountTextFormat = .parenthesized,
            grayOutWhenNoUnread: Bool = false,
            invertInDarkMode: Bool = false,
            monochrome: Bool = false,
            isDarkAppearance: Bool = false
        ) {
            self.style = style
            self.countFormat = countFormat
            self.grayOutWhenNoUnread = grayOutWhenNoUnread
            self.invertInDarkMode = invertInDarkMode
            self.monochrome = monochrome
            self.isDarkAppearance = isDarkAppearance
        }
    }

    public struct RenderedStatusItemContent {
        public let image: NSImage
        public let title: String

        public init(image: NSImage, title: String) {
            self.image = image
            self.title = title
        }
    }

    /// Produces the icon image and optional button title for an `NSStatusItem`.
    public static func renderStatusItem(
        baseIcon: NSImage,
        badge: BadgeValue,
        options: RenderOptions
    ) -> RenderedStatusItemContent {
        let preparedIcon = prepareBaseIcon(baseIcon, badge: badge, options: options)

        switch options.style {
        case .redBadge:
            let image = drawRedBadgeOverlay(on: preparedIcon, badge: badge)
            return RenderedStatusItemContent(image: image, title: "")

        case .simpleDot:
            let image = drawSimpleDotOverlay(on: preparedIcon, hasUnread: badge.hasUnread)
            return RenderedStatusItemContent(image: image, title: "")

        case .iconAndCount:
            if badge == .dot {
                // Render a crisp unread dot beside the icon so dots look sharp and unmistakable.
                let image = drawSideDot(nextTo: preparedIcon)
                return RenderedStatusItemContent(image: image, title: "")
            } else {
                let iconImage = drawResizedIcon(preparedIcon, size: NSSize(width: defaultIconSize, height: defaultIconSize))
                let title = badge.hasUnread ? " " + badge.formattedInlineLabel(format: options.countFormat) : ""
                return RenderedStatusItemContent(image: iconImage, title: title)
            }

        case .iconOnly:
            let iconImage = drawResizedIcon(preparedIcon, size: NSSize(width: defaultIconSize, height: defaultIconSize))
            return RenderedStatusItemContent(image: iconImage, title: "")
        }
    }

    /// Prepares the base icon (dark mode inversion, grayscale dimming, or monochrome).
    public static func prepareBaseIcon(
        _ icon: NSImage,
        badge: BadgeValue,
        options: RenderOptions
    ) -> NSImage {
        var working = icon

        if options.invertInDarkMode && options.isDarkAppearance {
            working = invertedImage(from: working) ?? working
        }

        if options.monochrome {
            working = grayscaleImage(from: working, alpha: badge.hasUnread || !options.grayOutWhenNoUnread ? 1.0 : 0.45) ?? working
        } else if !badge.hasUnread && options.grayOutWhenNoUnread {
            working = grayscaleImage(from: working, alpha: 0.55) ?? working
        }

        return working
    }

    /// Draws the base icon resized cleanly into `size`.
    public static func drawResizedIcon(_ icon: NSImage, size: NSSize) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Draws a Dock-style red pill/circle badge (or red dot) at the top-right corner of the icon.
    /// Dynamically widens the canvas slightly for 2+ digit badges so numbers are never truncated.
    public static func drawRedBadgeOverlay(on icon: NSImage, badge: BadgeValue) -> NSImage {
        guard badge.hasUnread else {
            return drawResizedIcon(icon, size: NSSize(width: defaultIconSize, height: defaultIconSize))
        }

        // Dot badge
        guard let label = badge.compactOverlayLabel else {
            return drawSimpleDotOverlay(on: icon, hasUnread: true)
        }

        let font = NSFont.systemFont(ofSize: label.count >= 3 ? 7.5 : 8.5, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let textSize = (label as NSString).size(withAttributes: attrs)
        let badgeHeight: CGFloat = 11.0
        let horizontalPadding: CGFloat = label.count == 1 ? 3.5 : 4.5
        let badgeWidth = max(badgeHeight, ceil(textSize.width) + horizontalPadding)

        // Expand canvas width slightly when badge is wide (e.g. "42" or "99+") so it never clips.
        let canvasHeight: CGFloat = defaultCanvasHeight
        let iconDrawSize: CGFloat = 17.5
        let extraRight: CGFloat = max(0, badgeWidth - 11.0) * 0.6
        let canvasWidth: CGFloat = ceil(20.0 + extraRight)

        let image = NSImage(size: NSSize(width: canvasWidth, height: canvasHeight), flipped: false) { _ in
            NSGraphicsContext.current?.imageInterpolation = .high

            // Draw icon anchored bottom-left so badge sits crisply at top-right.
            let iconRect = NSRect(x: 0, y: 0.5, width: iconDrawSize, height: iconDrawSize)
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)

            let badgeRect = NSRect(
                x: canvasWidth - badgeWidth,
                y: canvasHeight - badgeHeight,
                width: badgeWidth,
                height: badgeHeight
            )

            // Subtle dark halo behind the pill for contrast against any icon color.
            let haloRect = badgeRect.insetBy(dx: -0.6, dy: -0.6)
            NSColor.black.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: haloRect, xRadius: haloRect.height / 2, yRadius: haloRect.height / 2).fill()

            // Crisp macOS notification red pill.
            NSColor.systemRed.setFill()
            let pillPath = NSBezierPath(roundedRect: badgeRect, xRadius: badgeHeight / 2, yRadius: badgeHeight / 2)
            pillPath.fill()

            // Center text inside pill.
            let textOrigin = NSPoint(
                x: badgeRect.midX - textSize.width / 2.0,
                y: badgeRect.midY - textSize.height / 2.0 - 0.3
            )
            (label as NSString).draw(at: textOrigin, withAttributes: attrs)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Draws a crisp red unread dot overlaid at the top-right corner of the icon.
    public static func drawSimpleDotOverlay(on icon: NSImage, hasUnread: Bool) -> NSImage {
        guard hasUnread else {
            return drawResizedIcon(icon, size: NSSize(width: defaultIconSize, height: defaultIconSize))
        }

        let canvasSize = NSSize(width: defaultCanvasHeight, height: defaultCanvasHeight)
        let iconDrawSize: CGFloat = 17.5
        let dotDiameter: CGFloat = 7.5

        let image = NSImage(size: canvasSize, flipped: false) { _ in
            NSGraphicsContext.current?.imageInterpolation = .high

            let iconRect = NSRect(x: 0, y: 1.0, width: iconDrawSize, height: iconDrawSize)
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)

            let dotRect = NSRect(
                x: canvasSize.width - dotDiameter - 0.5,
                y: canvasSize.height - dotDiameter - 0.5,
                width: dotDiameter,
                height: dotDiameter
            )

            // Subtle contrast ring.
            let haloRect = dotRect.insetBy(dx: -0.8, dy: -0.8)
            NSColor.black.withAlphaComponent(0.28).setFill()
            NSBezierPath(ovalIn: haloRect).fill()

            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Draws the icon with a crisp red dot placed directly beside it (for `iconAndCount` when badge is `.dot`).
    public static func drawSideDot(nextTo icon: NSImage) -> NSImage {
        let iconDrawSize: CGFloat = defaultIconSize
        let dotDiameter: CGFloat = 6.5
        let spacing: CGFloat = 3.5
        let canvasSize = NSSize(width: iconDrawSize + spacing + dotDiameter + 1.0, height: defaultCanvasHeight)

        let image = NSImage(size: canvasSize, flipped: false) { _ in
            NSGraphicsContext.current?.imageInterpolation = .high
            let iconRect = NSRect(
                x: 0,
                y: (canvasSize.height - iconDrawSize) / 2.0,
                width: iconDrawSize,
                height: iconDrawSize
            )
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)

            let dotRect = NSRect(
                x: iconDrawSize + spacing,
                y: (canvasSize.height - dotDiameter) / 2.0,
                width: dotDiameter,
                height: dotDiameter
            )
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Generates a default template control icon for Menubar Badges itself.
    public static func controlStatusIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            // Rounded square representing an app icon in the menu bar
            let bodyRect = NSRect(x: 1.5, y: 1.5, width: 13.5, height: 13.5)
            let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 3.5, yRadius: 3.5)
            bodyPath.lineWidth = 1.5
            NSColor.labelColor.setStroke()
            bodyPath.stroke()

            // Notification badge dot in top-right corner
            let dotRect = NSRect(x: 11.0, y: 11.0, width: 6.0, height: 6.0)
            NSColor.labelColor.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Image Filters

    public static func grayscaleImage(from source: NSImage, alpha: CGFloat = 1.0) -> NSImage? {
        guard let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let ciImage = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIColorControls") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(0.0, forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: nil)
        guard let outCG = context.createCGImage(output, from: output.extent) else { return nil }

        let targetSize = source.size == .zero ? NSSize(width: 64, height: 64) : source.size
        let result = NSImage(size: targetSize, flipped: false) { rect in
            NSImage(cgImage: outCG, size: targetSize).draw(
                in: rect,
                from: .zero,
                operation: .sourceOver,
                fraction: alpha
            )
            return true
        }
        result.isTemplate = false
        return result
    }

    public static func invertedImage(from source: NSImage) -> NSImage? {
        guard let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let ciImage = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIColorInvert") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: nil)
        guard let outCG = context.createCGImage(output, from: output.extent) else { return nil }
        let targetSize = source.size == .zero ? NSSize(width: 64, height: 64) : source.size
        let result = NSImage(cgImage: outCG, size: targetSize)
        result.isTemplate = false
        return result
    }
}
