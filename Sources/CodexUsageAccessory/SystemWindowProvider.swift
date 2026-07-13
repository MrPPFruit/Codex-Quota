import AppKit
import CodexUsageCore
import CoreGraphics

@MainActor
public protocol WindowSnapshotProviding {
    func currentSnapshots() -> [WindowSnapshot]
}

@MainActor
public final class SystemWindowProvider: WindowSnapshotProviding {
    public static let codexBundleIdentifier = "com.openai.codex"

    private let targetBundleIdentifier: String

    public init(targetBundleIdentifier: String = SystemWindowProvider.codexBundleIdentifier) {
        self.targetBundleIdentifier = targetBundleIdentifier
    }

    public func currentSnapshots() -> [WindowSnapshot] {
        guard let rawWindows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]],
              let mainDisplayMaxY = NSScreen.screens.first?.frame.maxY else { return [] }
        let bundleIDs = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications.compactMap { app in
            app.bundleIdentifier.map { (app.processIdentifier, $0) }
        })

        return rawWindows.compactMap { info in
            guard let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  bundleIDs[ownerPID] == targetBundleIdentifier,
                  let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
            let quartzBounds = (info[kCGWindowBounds as String] as? NSDictionary)
                .flatMap { CGRect(dictionaryRepresentation: $0) }
            return WindowSnapshot(
                windowID: windowID,
                ownerPID: ownerPID,
                bundleIdentifier: targetBundleIdentifier,
                layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                bounds: quartzBounds.map {
                    WindowCoordinateConverter.appKitBounds(fromQuartz: $0, mainDisplayMaxY: mainDisplayMaxY)
                },
                sharingState: (info[kCGWindowSharingState as String] as? NSNumber)?.intValue,
                isOnScreen: (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue,
                nameFieldPresent: info.keys.contains(kCGWindowName as String)
            )
        }
    }
}
