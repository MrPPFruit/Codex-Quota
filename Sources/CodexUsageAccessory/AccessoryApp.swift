import AppKit
import CodexUsageCore
import CodexUsageUI

@main
@MainActor
public final class AccessoryApp: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private var overlayController: OverlayController?
    private var statusItemController: StatusItemController?
    private var lifecycleCoordinator: AccessoryLifecycleCoordinator?
    private var presenceMonitor: (any CodexPresenceMonitoring)?
    private var loginItemController: LoginItemController?
    private var smokePanel: OverlayPanel?
    private var smokeWindowEvidence: SmokeDiagnostic.Window?
    private var smokeTask: Task<Void, Never>?
    private var previewExitTask: Task<Void, Never>?
    private var isQuitting = false

    public static func main() {
        QuotaNumberFont.register()
        let application = NSApplication.shared
        let delegate = AccessoryApp()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let preview = AccessoryPreviewConfiguration.parse()
        let smokeConfiguration = SmokeDiagnostics.configuration()
        if let preview { store.snapshot = preview.snapshot }
        let panel = OverlayPanel()
        preview?.applyAppearance(panel: panel)
        let overlay = OverlayController(
            panel: panel,
            store: store,
            reduceMotionOverride: preview?.reduceMotionOverride,
            reduceTransparencyOverride: preview?.reduceTransparencyOverride,
            forcedExpanded: preview?.expanded == true ? true : nil,
            startsMonitoring: preview != nil
        )
        smokePanel = panel
        overlayController = overlay
        overlay.setLifecycleAvailable(preview != nil)
        let allowsLoginItemMutations = preview == nil
            && smokeConfiguration == nil
            && LoginItemEligibility.isStableInstallation(bundleURL: Bundle.main.bundleURL)
        let loginController = LoginItemController(
            service: allowsLoginItemMutations ? SystemLoginItemService() : DisabledLoginItemService(),
            allowsMutations: allowsLoginItemMutations
        )
        loginItemController = loginController
        loginController.prepareForLaunch()
        let statusController = StatusItemController(
            overlayController: overlay,
            store: store,
            visibilityStore: preview != nil || smokeConfiguration != nil
                ? TransientOverlayVisibilityStore()
                : UserDefaultsOverlayVisibilityStore(),
            loginItemController: loginController
        ) { [weak self] in
            self?.requestQuit()
        }
        statusItemController = statusController
        panel.contextMenuProvider = { [weak statusController] in
            statusController?.menuForOverlay()
        }
        if preview != nil {
            overlay.show()
        } else {
            let coordinator = AccessoryLifecycleCoordinator(
                store: store,
                overlayController: overlay,
                sessionFactory: { publishSnapshot in
                    guard let executable = try? await CodexExecutableLocator().locate(), !Task.isCancelled else {
                        return nil
                    }
                    return AccessoryUsageSession(
                        client: AppServerClient(executable: executable),
                        publishSnapshot: publishSnapshot
                    )
                },
                onPresenceChanged: { [weak statusController] isRunning in
                    statusController?.setCodexRunning(isRunning)
                }
            )
            lifecycleCoordinator = coordinator
            if smokeConfiguration != nil, let forcedPresence = SmokeDiagnostics.forcedCodexPresence() {
                coordinator.setCodexRunning(forcedPresence)
            } else {
                let monitor = SystemCodexPresenceMonitor()
                presenceMonitor = monitor
                monitor.start { [weak coordinator] isRunning in coordinator?.setCodexRunning(isRunning) }
            }
        }
        if let seconds = preview?.autoExitSeconds {
            previewExitTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                self?.requestQuit()
            }
        }
        if let (destination, exitDelay) = smokeConfiguration {
            smokeTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled else { return }
                self.smokeWindowEvidence = SmokeDiagnostics.captureWindow(panel)
                SmokeDiagnostics.write(
                    to: destination,
                    panel: panel,
                    statusItemCount: self.statusItemController?.statusItemCount ?? 0,
                    menuItemCount: self.statusItemController?.menuItemCount ?? 0,
                    exitedThroughControlledPath: false,
                    windowEvidence: self.smokeWindowEvidence
                )
                try? await Task.sleep(for: exitDelay)
                guard !Task.isCancelled else { return }
                self.requestQuit()
            }
        }
    }

    private func requestQuit() {
        guard !isQuitting else { return }
        isQuitting = true
        previewExitTask?.cancel()
        previewExitTask = nil
        Task {
            presenceMonitor?.stop()
            do {
                try await lifecycleCoordinator?.shutdownForQuit()
            } catch {
                store.snapshot = .unavailable
                isQuitting = false
                presenceMonitor?.start { [weak lifecycleCoordinator] isRunning in
                    lifecycleCoordinator?.setCodexRunning(isRunning)
                }
                return
            }
            if let configuration = SmokeDiagnostics.configuration(), let smokePanel {
                SmokeDiagnostics.write(
                    to: configuration.0,
                    panel: smokePanel,
                    statusItemCount: statusItemController?.statusItemCount ?? 0,
                    menuItemCount: statusItemController?.menuItemCount ?? 0,
                    exitedThroughControlledPath: true,
                    windowEvidence: smokeWindowEvidence
                )
            }
            smokeTask?.cancel()
            smokeTask = nil
            overlayController?.stopMonitoring()
            overlayController?.hide()
            statusItemController?.remove()
            statusItemController = nil
            NSApp.terminate(nil)
        }
    }
}
