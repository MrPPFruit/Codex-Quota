import Foundation
import Security

public enum CodexExecutableLocatorError: Error, Sendable, Equatable {
    case unsupportedInstallation
    case invalidBundleIdentity
    case missingAppServerCapability
}

public protocol CodexInstallationInspecting: Sendable {
    func bundleIdentifier(at applicationURL: URL) -> String?
    func isExecutableFile(at executableURL: URL) -> Bool
    func isCanonicalTrustedInstallation(applicationURL: URL, executableURL: URL) -> Bool
    func hasValidCodexSignature(applicationURL: URL) -> Bool
    func supportsAppServer(executableURL: URL) async -> Bool
}

public struct CodexExecutableLocator: Sendable {
    public static let applicationURL = URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
    public static let executableURL = applicationURL.appending(path: "Contents/Resources/codex")
    private let inspector: any CodexInstallationInspecting

    public init(inspector: any CodexInstallationInspecting = SystemCodexInstallationInspector()) {
        self.inspector = inspector
    }

    public func locate() async throws -> URL {
        guard inspector.bundleIdentifier(at: Self.applicationURL) == "com.openai.codex" else {
            throw CodexExecutableLocatorError.invalidBundleIdentity
        }
        guard inspector.isExecutableFile(at: Self.executableURL) else {
            throw CodexExecutableLocatorError.unsupportedInstallation
        }
        guard inspector.isCanonicalTrustedInstallation(applicationURL: Self.applicationURL, executableURL: Self.executableURL),
              inspector.hasValidCodexSignature(applicationURL: Self.applicationURL) else {
            throw CodexExecutableLocatorError.invalidBundleIdentity
        }
        guard await inspector.supportsAppServer(executableURL: Self.executableURL) else {
            throw CodexExecutableLocatorError.missingAppServerCapability
        }
        return Self.executableURL
    }
}

public struct SystemCodexInstallationInspector: CodexInstallationInspecting {
    public init() {}

    public func bundleIdentifier(at applicationURL: URL) -> String? {
        Bundle(url: applicationURL)?.bundleIdentifier
    }

    public func isExecutableFile(at executableURL: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    public func isCanonicalTrustedInstallation(applicationURL: URL, executableURL: URL) -> Bool {
        let canonicalApp = applicationURL.resolvingSymlinksInPath().standardizedFileURL
        let canonicalExecutable = executableURL.resolvingSymlinksInPath().standardizedFileURL
        return canonicalApp == applicationURL.standardizedFileURL
            && canonicalExecutable == executableURL.standardizedFileURL
            && canonicalExecutable.path.hasPrefix(canonicalApp.appending(path: "Contents/Resources", directoryHint: .isDirectory).path + "/")
    }

    public func hasValidCodexSignature(applicationURL: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(applicationURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }
        let requirementText = "identifier \"com.openai.codex\" and anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\"" as CFString
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
    }

    public func supportsAppServer(executableURL: URL) async -> Bool {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--help"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while process.isRunning, clock.now < deadline {
            if Task.isCancelled {
                _ = await Self.stopCapabilityProbe(process)
                return false
            }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                _ = await Self.stopCapabilityProbe(process)
                return false
            }
        }
        if process.isRunning, !(await Self.stopCapabilityProbe(process)) { return false }
        return !process.isRunning && process.terminationStatus == 0
    }

    static func stopCapabilityProbe(_ process: Process) async -> Bool {
        do {
            try await ChildProcessTerminator.stop(process)
            return true
        } catch {
            return false
        }
    }
}
