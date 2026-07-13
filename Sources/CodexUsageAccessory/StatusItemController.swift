import AppKit
import Combine
import CodexUsageCore
import CodexUsageUI

public enum StatusMenuPolicy {
    public static let itemTitles = ["显示额度气泡", "退出"]
    public static let bubbleEffectTitle = "气泡效果"
}

public enum StatusItemIconRenderer {
    public static let canvasSize = NSSize(width: 24, height: 14)
    public static let fiveHourMaximumWidth: CGFloat = 13
    public static let weeklyMaximumWidth: CGFloat = 7
    public static let fiveHourX: CGFloat = 10
    public static let weeklyX: CGFloat = 13

    public static func fillWidth(remainingPercent: Double?, maximumWidth: CGFloat) -> CGFloat {
        guard let remainingPercent else { return 0 }
        return maximumWidth * min(max(remainingPercent, 0), 100) / 100
    }

    public static func makeImage(fiveHourPercent: Double?, weeklyPercent: Double?) -> NSImage {
        let image = NSImage(size: canvasSize, flipped: false) { _ in
            drawChevron()
            drawBar(
                x: fiveHourX,
                y: 8,
                height: 3,
                maximumWidth: fiveHourMaximumWidth,
                remainingPercent: fiveHourPercent
            )
            drawBar(
                x: weeklyX,
                y: 3,
                height: 2,
                maximumWidth: weeklyMaximumWidth,
                remainingPercent: weeklyPercent
            )
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Codex Quota"
        return image
    }

    public static func accessibilityLabel(for snapshot: UsageSnapshot) -> String {
        let fiveHour = percentageDescription(snapshot.fiveHour.remainingPercent)
        let weekly = percentageDescription(snapshot.weekly.remainingPercent)
        return "Codex Quota，5小时剩余\(fiveHour)，本周剩余\(weekly)"
    }

    private static func drawChevron() {
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        guard let chevron = NSImage(
            systemSymbolName: "chevron.right",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration) else { return }
        chevron.draw(in: NSRect(x: 0, y: 1, width: 8, height: 12))
    }

    private static func drawBar(
        x: CGFloat,
        y: CGFloat,
        height: CGFloat,
        maximumWidth: CGFloat,
        remainingPercent: Double?
    ) {
        let width = fillWidth(remainingPercent: remainingPercent, maximumWidth: maximumWidth)
        guard width > 0 else {
            guard remainingPercent == nil else { return }
            let markerSize = min(height, 1.5)
            let marker = NSRect(x: x, y: y + ((height - markerSize) / 2), width: markerSize, height: markerSize)
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSBezierPath(ovalIn: marker).fill()
            return
        }
        let fill = NSRect(x: x, y: y, width: width, height: height)
        NSColor.black.setFill()
        let radius = min(width, height) / 2
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }

    private static func percentageDescription(_ value: Double?) -> String {
        guard let value else { return "不可用" }
        return "\(Int(value.rounded()))%"
    }
}

@MainActor
public final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let overlayController: OverlayController
    private let defaults: UserDefaults
    private let visibilityStore: any OverlayVisibilityStoring
    private let loginItemController: LoginItemController
    private let onQuit: () -> Void
    private var snapshotCancellable: AnyCancellable?
    private let visibilityItem = NSMenuItem()
    private let contextVisibilityItem = NSMenuItem()
    private let overlayContextMenu = NSMenu()
    private let loginItem = NSMenuItem()
    private let contextLoginItem = NSMenuItem()
    private var presetItems: [NSMenuItem] = []
    private var contextPresetItems: [NSMenuItem] = []
    private var codexIsRunning = false
    private var latestSnapshot = UsageSnapshot.unavailable

    public init(
        overlayController: OverlayController,
        store: UsageStore,
        defaults: UserDefaults = .standard,
        visibilityStore: any OverlayVisibilityStoring = UserDefaultsOverlayVisibilityStore(),
        loginItemController: LoginItemController,
        onQuit: @escaping () -> Void
    ) {
        self.overlayController = overlayController
        self.defaults = defaults
        self.visibilityStore = visibilityStore
        self.loginItemController = loginItemController
        self.onQuit = onQuit
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.title = ""
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "Codex Quota"
        visibilityItem.title = StatusMenuPolicy.itemTitles[0]
        visibilityItem.target = self
        visibilityItem.action = #selector(toggleVisibility)
        let quitItem = NSMenuItem(title: StatusMenuPolicy.itemTitles[1], action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        let presetMenu = makePresetMenu()
        presetItems = presetMenu.items
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(visibilityItem)
        menu.addItem(presetMenu.root)
        menu.addItem(.separator())
        loginItem.target = self
        loginItem.action = #selector(toggleLoginItem)
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        statusItem.menu = menu

        contextVisibilityItem.target = self
        contextVisibilityItem.action = #selector(toggleVisibility)
        let contextQuitItem = NSMenuItem(title: StatusMenuPolicy.itemTitles[1], action: #selector(quit), keyEquivalent: "")
        contextQuitItem.target = self
        let contextPresetMenu = makePresetMenu()
        contextPresetItems = contextPresetMenu.items
        overlayContextMenu.delegate = self
        overlayContextMenu.addItem(contextVisibilityItem)
        overlayContextMenu.addItem(contextPresetMenu.root)
        overlayContextMenu.addItem(.separator())
        contextLoginItem.target = self
        contextLoginItem.action = #selector(toggleLoginItem)
        overlayContextMenu.addItem(contextLoginItem)
        overlayContextMenu.addItem(.separator())
        overlayContextMenu.addItem(contextQuitItem)
        snapshotCancellable = store.$snapshot.sink { [weak self] snapshot in
            self?.latestSnapshot = snapshot
            self?.updateStatusItem(for: snapshot)
        }
        if visibilityStore.load() { overlayController.show() } else { overlayController.hide() }
        synchronizeMenuState()
    }

    public func menuWillOpen(_ menu: NSMenu) { synchronizeMenuState() }

    private func synchronizeMenuState() {
        let title = codexIsRunning ? "显示额度气泡" : "Codex 启动后显示气泡"
        visibilityItem.title = title
        contextVisibilityItem.title = title
        let visibilityState: NSControl.StateValue = overlayController.isVisible ? .on : .off
        visibilityItem.state = visibilityState
        contextVisibilityItem.state = visibilityState
        let loginPresentation = loginItemController.presentation
        for item in [loginItem, contextLoginItem] {
            item.title = loginPresentation.title
            item.state = NSControl.StateValue(rawValue: loginPresentation.state)
            item.isEnabled = loginPresentation.isEnabled
        }
        let selected = BubbleAppearancePreset.resolve(
            storedRawValue: defaults.string(forKey: BubbleAppearancePreset.storageKey)
        )
        for item in presetItems + contextPresetItems {
            item.state = item.representedObject as? String == selected.rawValue ? .on : .off
        }
    }

    private func makePresetMenu() -> (root: NSMenuItem, items: [NSMenuItem]) {
        let root = NSMenuItem(title: StatusMenuPolicy.bubbleEffectTitle, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: StatusMenuPolicy.bubbleEffectTitle)
        let items = BubbleAppearancePreset.allCases.map { preset in
            let item = NSMenuItem(title: preset.displayName, action: #selector(selectPreset), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.rawValue
            submenu.addItem(item)
            return item
        }
        root.submenu = submenu
        return (root, items)
    }

    private func updateStatusItem(for snapshot: UsageSnapshot) {
        statusItem.button?.image = StatusItemIconRenderer.makeImage(
            fiveHourPercent: snapshot.fiveHour.remainingPercent,
            weeklyPercent: snapshot.weekly.remainingPercent
        )
        let label = codexIsRunning
            ? StatusItemIconRenderer.accessibilityLabel(for: snapshot)
            : "Codex Quota，等待 Codex"
        statusItem.button?.setAccessibilityLabel(label)
    }

    @objc private func toggleVisibility() {
        let shouldShow = !overlayController.isVisible
        visibilityStore.save(shouldShow)
        if shouldShow { overlayController.show() } else { overlayController.hide() }
        synchronizeMenuState()
    }

    @objc private func toggleLoginItem() {
        loginItemController.performMenuAction()
        synchronizeMenuState()
    }

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              BubbleAppearancePreset(rawValue: rawValue) != nil else { return }
        defaults.set(rawValue, forKey: BubbleAppearancePreset.storageKey)
        synchronizeMenuState()
    }

    @objc private func quit() { onQuit() }

    public func setCodexRunning(_ isRunning: Bool) {
        codexIsRunning = isRunning
        updateStatusItem(for: latestSnapshot)
        synchronizeMenuState()
    }

    public var menuItemCount: Int { statusItem.menu?.items.count ?? 0 }
    public var statusItemCount: Int { statusItem.button == nil ? 0 : 1 }

    public func menuForOverlay() -> NSMenu {
        synchronizeMenuState()
        return overlayContextMenu
    }

    public func remove() { NSStatusBar.system.removeStatusItem(statusItem) }
}
