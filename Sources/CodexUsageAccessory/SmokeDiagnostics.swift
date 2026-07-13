import AppKit
import Darwin
import Foundation

struct SmokeDiagnostic: Codable {
    struct Window: Codable {
        let isKey: Bool
        let isMain: Bool
        let level: Int
        let isVisible: Bool
        let frame: Frame
    }

    struct Frame: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    let activationPolicy: String
    let window: Window
    let statusItemCount: Int
    let menuItemCount: Int
    let exitedThroughControlledPath: Bool
}

enum SmokeDiagnostics {
    static let pathVariable = "CODEX_ACCESSORY_SMOKE_DIAGNOSTIC_PATH"
    static let exitVariable = "CODEX_ACCESSORY_SMOKE_EXIT_AFTER_SECONDS"
    static let codexPresenceVariable = "CODEX_ACCESSORY_SMOKE_CODEX_PRESENCE"

    static func forcedCodexPresence(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool? {
        switch environment[codexPresenceVariable] {
        case "present": true
        case "absent": false
        default: nil
        }
    }

    static func configuration(environment: [String: String] = ProcessInfo.processInfo.environment) -> (URL, Duration)? {
        guard let path = environment[pathVariable], path.hasPrefix("/"),
              let secondsText = environment[exitVariable],
              let seconds = Int(secondsText), (1...10).contains(seconds)
        else { return nil }
        let destination = URL(fileURLWithPath: path).standardizedFileURL
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath()
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        guard destination.lastPathComponent == "internal.json",
              parent.lastPathComponent.hasPrefix("codex-accessory-smoke."),
              parent.deletingLastPathComponent() == temporaryRoot
        else { return nil }
        return (destination, .seconds(seconds))
    }

    @MainActor
    static func captureWindow(_ panel: NSPanel) -> SmokeDiagnostic.Window {
        let frame = panel.frame
        return .init(
            isKey: panel.isKeyWindow,
            isMain: panel.isMainWindow,
            level: panel.level.rawValue,
            isVisible: panel.isVisible,
            frame: .init(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height)
        )
    }

    @MainActor
    static func write(
        to destination: URL,
        panel: NSPanel,
        statusItemCount: Int,
        menuItemCount: Int,
        exitedThroughControlledPath: Bool,
        windowEvidence: SmokeDiagnostic.Window? = nil
    ) {
        let diagnostic = SmokeDiagnostic(
            activationPolicy: NSApp.activationPolicy() == .accessory ? "accessory" : "other",
            window: windowEvidence ?? captureWindow(panel),
            statusItemCount: statusItemCount,
            menuItemCount: menuItemCount,
            exitedThroughControlledPath: exitedThroughControlledPath
        )
        guard let data = try? JSONEncoder().encode(diagnostic) else { return }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString)")
        let manager = FileManager.default
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        do {
            let replaced: Int32 = temporary.withUnsafeFileSystemRepresentation { source in
                destination.withUnsafeFileSystemRepresentation { target in
                    guard let source, let target else { return Int32(-1) }
                    return Darwin.rename(source, target)
                }
            }
            guard replaced == 0 else { throw CocoaError(.fileWriteUnknown) }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            try? manager.removeItem(at: temporary)
        }
    }
}
