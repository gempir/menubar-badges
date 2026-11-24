import AppKit
import CoreImage
import CoreText

/// Renders crisp Retina-ready `NSImage`s for menu bar status items and previews.
public enum BadgeIconRenderer {
    public static let maxMenuBarHeight: CGFloat = 22.0
    public static let defaultIconSize: CGFloat = CGFloat(AppPreferences.defaultIconSize)
    public static let defaultBadgeSize: CGFloat = CGFloat(AppPreferences.defaultBadgeSize)
    public static let defaultDotSize: CGFloat = CGFloat(AppPreferences.defaultDotSize)

    public struct RenderOptions: Equatable, Sendable {
        public var style: BadgeDisplayStyle
        public var countFormat: CountTextFormat
        public var iconSize: CGFloat
        public var badgeSize: CGFloat
        public var dotSize: CGFloat
        public var grayOutWhenNoUnread: Bool
        public var invertInDarkMode: Bool
        public var monochrome: Bool
        public var isDarkAppearance: Bool

        public init(
            style: BadgeDisplayStyle = .redBadge,
            countFormat: CountTextFormat = .parenthesized,
            iconSize: CGFloat = BadgeIconRenderer.defaultIconSize,
            badgeSize: CGFloat = BadgeIconRenderer.defaultBadgeSize,
            dotSize: CGFloat = BadgeIconRenderer.defaultDotSize,
            grayOutWhenNoUnread: Bool = false,
            invertInDarkMode: Bool = false,
            monochrome: Bool = false,
            isDarkAppearance: Bool = false
        ) {
            self.style = style
            self.countFormat = countFormat
            self.iconSize = min(max(iconSize, CGFloat(AppPreferences.iconSizeRange.lowerBound)), CGFloat(AppPreferences.iconSizeRange.upperBound))
            self.badgeSize = min(max(badgeSize, CGFloat(AppPreferences.badgeSizeRange.lowerBound)), CGFloat(AppPreferences.badgeSizeRange.upperBound))
            self.dotSize = min(max(dotSize, CGFloat(AppPreferences.dotSizeRange.lowerBound)), CGFloat(AppPreferences.dotSizeRange.upperBound))
            self.grayOutWhenNoUnread = grayOutWhenNoUnread
            self.invertInDarkMode = invertInDarkMode
            self.monochrome = monochrome
            self.isDarkAppearance = isDarkAppearance
        }
    }

    public struct RenderedStatusItemContent {
        public let image: NSImage
        public let title: String
        public let titleFontSize: CGFloat

        public init(image: NSImage, title: String, titleFontSize: CGFloat = 13.0) {
            self.image = image
            self.title = title
            self.titleFontSize = titleFontSize
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
            let image = drawRedBadgeOverlay(
                on: preparedIcon,
                badge: badge,
                iconSize: options.iconSize,
                badgeSize: options.badgeSize,
                dotSize: options.dotSize
            )
            return RenderedStatusItemContent(image: image, title: "")

        case .simpleDot:
            let image = drawSimpleDotOverlay(
                on: preparedIcon,
                hasUnread: badge.hasUnread,
                iconSize: options.iconSize,
                dotSize: options.dotSize
            )
            return RenderedStatusItemContent(image: image, title: "")

        case .iconAndCount:
            if badge == .dot {
                let image = drawSideDot(
                    nextTo: preparedIcon,
                    iconSize: options.iconSize,
                    dotSize: options.dotSize
                )
                return RenderedStatusItemContent(image: image, title: "")
            } else {
                let iconImage = drawResizedIcon(
                    preparedIcon,
                    size: NSSize(width: options.iconSize, height: options.iconSize)
                )
                let title = badge.hasUnread ? " " + badge.formattedInlineLabel(format: options.countFormat) : ""
                let fontSize = min(max(options.badgeSize + 2.0, 9.5), 16.0)
                return RenderedStatusItemContent(image: iconImage, title: title, titleFontSize: fontSize)
            }

        case .iconOnly:
            let iconImage = drawResizedIcon(
                preparedIcon,
                size: NSSize(width: options.iconSize, height: options.iconSize)
            )
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
    /// Dynamically adapts canvas dimensions to `iconSize`, `badgeSize`, and `dotSize` so badges never clip.
    public static func drawRedBadgeOverlay(
        on icon: NSImage,
        badge: BadgeValue,
        iconSize: CGFloat = BadgeIconRenderer.defaultIconSize,
        badgeSize: CGFloat = BadgeIconRenderer.defaultBadgeSize,
        dotSize: CGFloat = BadgeIconRenderer.defaultDotSize
    ) -> NSImage {
        guard badge.hasUnread else {
            return drawResizedIcon(icon, size: NSSize(width: iconSize, height: iconSize))
        }

        guard let label = badge.compactOverlayLabel else {
            return drawSimpleDotOverlay(on: icon, hasUnread: true, iconSize: iconSize, dotSize: dotSize)
        }

        let fontScale: CGFloat = label.count >= 3 ? 0.62 : 0.72
        let font = NSFont.systemFont(ofSize: max(6.0, badgeSize * fontScale), weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let attributed = NSAttributedString(string: label, attributes: attrs)
        let ctLine = CTLineCreateWithAttributedString(attributed)
        let glyphBounds = CTLineGetBoundsWithOptions(ctLine, .useGlyphPathBounds)

        let badgeHeight = badgeSize
        let horizontalPadding: CGFloat = label.count == 1 ? max(3.5, badgeSize * 0.34) : max(5.0, badgeSize * 0.46)
        let badgeWidth = max(badgeHeight, ceil(glyphBounds.width + horizontalPadding))

        let haloInset: CGFloat = 0.6
        let canvasHeight = min(maxMenuBarHeight, max(iconSize + 2.0, badgeHeight + haloInset * 2.0))
        let iconDrawSize = min(iconSize, canvasHeight - 1.0)

        // Hug the top-right corner of the icon (accounting for macOS icon ~10% transparent margin).
        // Single-digit circles overhang only slightly; wider pills expand cleanly to the right.
        let circleOverhang = max(0.5, min(1.5, badgeHeight * 0.10))
        let extraPillWidth = max(0.0, badgeWidth - badgeHeight)
        let badgeRightX = iconDrawSize + circleOverhang + extraPillWidth * 0.72
        let canvasWidth = ceil(max(iconDrawSize + haloInset, badgeRightX + haloInset))

        let image = NSImage(size: NSSize(width: canvasWidth, height: canvasHeight), flipped: false) { _ in
            NSGraphicsContext.current?.imageInterpolation = .high

            let iconY = max(0.0, (canvasHeight - iconDrawSize) / 2.0 - 0.5)
            let iconRect = NSRect(x: 0, y: iconY, width: iconDrawSize, height: iconDrawSize)
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)

            let badgeRect = NSRect(
                x: canvasWidth - haloInset - badgeWidth,
                y: canvasHeight - haloInset - badgeHeight,
                width: badgeWidth,
                height: badgeHeight
            )

            let haloRect = badgeRect.insetBy(dx: -haloInset, dy: -haloInset)
            NSColor.black.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: haloRect, xRadius: haloRect.height / 2, yRadius: haloRect.height / 2).fill()

            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: badgeRect, xRadius: badgeHeight / 2, yRadius: badgeHeight / 2).fill()

            // Center the exact optical ink bounding box of the glyphs inside the badge pill/circle.
            if let cgContext = NSGraphicsContext.current?.cgContext {
                cgContext.saveGState()
                cgContext.textMatrix = .identity
                let drawX = badgeRect.midX - glyphBounds.midX
                let drawY = badgeRect.midY - glyphBounds.midY
                cgContext.textPosition = CGPoint(x: drawX, y: drawY)
                CTLineDraw(ctLine, cgContext)
                cgContext.restoreGState()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Draws a crisp red unread dot overlaid at the top-right corner of the icon.
    public static func drawSimpleDotOverlay(
        on icon: NSImage,
        hasUnread: Bool,
        iconSize: CGFloat = BadgeIconRenderer.defaultIconSize,
        dotSize: CGFloat = BadgeIconRenderer.defaultDotSize
    ) -> NSImage {
        guard hasUnread else {
            return drawResizedIcon(icon, size: NSSize(width: iconSize, height: iconSize))
        }

        let dotDiameter = min(max(dotSize, 4.0), 12.0)
        let haloInset: CGFloat = 0.8
        let canvasHeight = min(maxMenuBarHeight, max(iconSize + 2.0, dotDiameter + haloInset * 2.0))
        let iconDrawSize = min(iconSize, canvasHeight - 1.0)
        let canvasWidth = ceil(iconDrawSize + max(0.5, dotDiameter * 0.14) + haloInset)

        let image = NSImage(size: NSSize(width: canvasWidth, height: canvasHeight), flipped: false) { _ in
            NSGraphicsContext.current?.imageInterpolation = .high

            let iconY = max(0.0, (canvasHeight - iconDrawSize) / 2.0 - 0.5)
            let iconRect = NSRect(x: 0, y: iconY, width: iconDrawSize, height: iconDrawSize)
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)

            let dotRect = NSRect(
                x: canvasWidth - haloInset - dotDiameter,
                y: canvasHeight - haloInset - dotDiameter,
                width: dotDiameter,
                height: dotDiameter
            )

            let haloRect = dotRect.insetBy(dx: -haloInset, dy: -haloInset)
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
    public static func drawSideDot(
        nextTo icon: NSImage,
        iconSize: CGFloat = BadgeIconRenderer.defaultIconSize,
        dotSize: CGFloat = BadgeIconRenderer.defaultDotSize
    ) -> NSImage {
        let dotDiameter = min(max(dotSize, 4.0), 12.0)
        let spacing: CGFloat = 3.5
        let canvasHeight = min(maxMenuBarHeight, max(iconSize + 2.0, dotDiameter + 2.0))
        let canvasSize = NSSize(width: ceil(iconSize + spacing + dotDiameter + 1.0), height: canvasHeight)

        let image = NSImage(size: canvasSize, flipped: false) { _ in
            NSGraphicsContext.current?.imageInterpolation = .high
            let iconRect = NSRect(
                x: 0,
                y: (canvasSize.height - iconSize) / 2.0,
                width: iconSize,
                height: iconSize
            )
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)

            let dotRect = NSRect(
                x: iconSize + spacing,
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
            let bodyRect = NSRect(x: 1.5, y: 1.5, width: 13.5, height: 13.5)
            let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 3.5, yRadius: 3.5)
            bodyPath.lineWidth = 1.5
            NSColor.labelColor.setStroke()
            bodyPath.stroke()

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
