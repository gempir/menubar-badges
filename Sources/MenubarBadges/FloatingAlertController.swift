import AppKit
import MenubarBadgesCore
import SwiftUI

/// Displays non-activating floating notifications (full-screen badge alert & optional attention arrow)
/// without ever stealing keyboard focus or activating the application.
@MainActor
final class FloatingAlertController {
    private let alertPanel: NonActivatingPanel
    private let arrowPanel: NonActivatingPanel
    private var hideAlertWorkItem: DispatchWorkItem?
    private var lastArrowShownAt: Date = .distantPast
    private let arrowState = AttentionArrowState()

    var onTap: (() -> Void)?

    init() {
        self.alertPanel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 88, height: 36),
            hasShadow: true
        )
        self.arrowPanel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 44, height: 48),
            hasShadow: false
        )
    }

    /// Shows a compact, popover-styled floating badge alert right below the menu bar status item.
    /// Auto-dismisses after `duration` seconds. Never steals keyboard focus.
    func showBadgeAlert(
        icon: NSImage,
        badge: BadgeValue,
        countFormat: CountTextFormat,
        anchorFrame: NSRect?,
        duration: TimeInterval = 3.0
    ) {
        guard badge.hasUnread else {
            hideBadgeAlert()
            return
        }

        hideAlertWorkItem?.cancel()

        let labelText = badge == .dot ? "" : badge.formattedInlineLabel(format: countFormat)
        let textWidth: CGFloat
        if labelText.isEmpty {
            textWidth = 10
        } else {
            let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            let measured = (labelText as NSString).size(withAttributes: [.font: font]).width
            textWidth = ceil(measured)
        }

        let panelSize = NSSize(width: max(54, 22 + 8 + textWidth + 24), height: 36)
        let origin = computeAlertOrigin(panelSize: panelSize, anchorFrame: anchorFrame)
        let frame = NSRect(origin: origin, size: panelSize)

        let container = FirstMouseClickableView(frame: NSRect(origin: .zero, size: panelSize))
        container.onClick = { [weak self] in
            self?.hideBadgeAlert()
            self?.onTap?()
        }

        // Explicitly initialize NSVisualEffectView at `panelSize` (prevents autoresizing 2x scaling bug).
        let visualEffect = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelSize))
        visualEffect.material = .popover
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 10
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.borderWidth = 0.5
        visualEffect.layer?.borderColor = NSColor.separatorColor.cgColor

        let contentView = FloatingAlertBannerView(
            icon: icon,
            badge: badge,
            countFormat: countFormat
        )
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        hostingView.autoresizingMask = [.width, .height]

        visualEffect.addSubview(hostingView)
        container.addSubview(visualEffect)

        alertPanel.contentView = container
        alertPanel.setFrame(frame, display: true)
        alertPanel.orderFrontRegardless()

        let workItem = DispatchWorkItem { [weak self] in
            self?.hideBadgeAlert()
        }
        hideAlertWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    func hideBadgeAlert() {
        hideAlertWorkItem?.cancel()
        hideAlertWorkItem = nil
        if alertPanel.isVisible {
            alertPanel.orderOut(nil)
        }
    }

    /// Shows a subtle pulsing red attention arrow below the status item (opt-in per app).
    func showAttentionArrow(anchorFrame: NSRect?) {
        let now = Date()
        guard !arrowPanel.isVisible || now.timeIntervalSince(lastArrowShownAt) >= 3.0 else {
            return
        }
        lastArrowShownAt = now

        let panelSize = NSSize(width: 44, height: 48)
        let origin = computeAlertOrigin(panelSize: panelSize, anchorFrame: anchorFrame)

        if arrowPanel.contentView == nil {
            let container = FirstMouseClickableView(frame: NSRect(origin: .zero, size: panelSize))
            container.onClick = { [weak self] in
                self?.hideAttentionArrow()
                self?.onTap?()
            }
            let hostingView = NSHostingView(rootView: AttentionArrowView(state: arrowState))
            hostingView.frame = NSRect(origin: .zero, size: panelSize)
            hostingView.autoresizingMask = [.width, .height]
            container.addSubview(hostingView)
            arrowPanel.contentView = container
        }

        arrowPanel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
        arrowState.pulseTrigger &+= 1
        arrowPanel.orderFrontRegardless()
    }

    func repositionAttentionArrow(anchorFrame: NSRect?) {
        guard arrowPanel.isVisible else { return }
        let origin = computeAlertOrigin(panelSize: arrowPanel.frame.size, anchorFrame: anchorFrame)
        arrowPanel.setFrameOrigin(origin)
    }

    func hideAttentionArrow() {
        if arrowPanel.isVisible {
            arrowPanel.orderOut(nil)
        }
    }

    func tearDown() {
        hideBadgeAlert()
        hideAttentionArrow()
    }

    private func computeAlertOrigin(panelSize: NSSize, anchorFrame: NSRect?) -> NSPoint {
        let screen = FullScreenDetector.screenContainingMouse() ?? NSScreen.main
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = screen?.visibleFrame ?? screenFrame

        let rawX: CGFloat
        if let anchor = anchorFrame, anchor.width > 0, screenFrame.contains(NSPoint(x: anchor.midX, y: screenFrame.midY)) {
            rawX = anchor.midX - panelSize.width / 2.0
        } else {
            rawX = visibleFrame.maxX - panelSize.width - 16.0
        }

        let clampedX = max(screenFrame.minX + 8.0, min(rawX, screenFrame.maxX - panelSize.width - 8.0))
        let topY = min(visibleFrame.maxY, screenFrame.maxY - 28.0)
        let y = topY - panelSize.height - 6.0
        return NSPoint(x: clampedX, y: y)
    }
}

private struct FloatingAlertBannerView: View {
    let icon: NSImage
    let badge: BadgeValue
    let countFormat: CountTextFormat

    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)

            if badge == .dot {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
            } else {
                Text(badge.formattedInlineLabel(format: countFormat))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
private final class AttentionArrowState: ObservableObject {
    @Published var pulseTrigger: Int = 0
}

private struct AttentionArrowView: View {
    @ObservedObject var state: AttentionArrowState
    @State private var offsetY: CGFloat = 0

    var body: some View {
        Image(systemName: "arrowtriangle.up.fill")
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(Color.red)
            .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 1)
            .offset(y: offsetY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 4)
            .onChange(of: state.pulseTrigger) { _ in
                animateBounce()
            }
            .onAppear {
                animateBounce()
            }
    }

    private func animateBounce() {
        withAnimation(.easeInOut(duration: 0.25).repeatCount(5, autoreverses: true)) {
            offsetY = 8
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.35) {
            withAnimation(.easeOut(duration: 0.2)) {
                offsetY = 0
            }
        }
    }
}
