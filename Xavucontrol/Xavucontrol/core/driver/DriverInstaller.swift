import Foundation

struct DriverInstallResult: Hashable {
    var success: Bool
    var message: String
}

struct DriverInstaller {
    private let driverBundleName = "XavucontrolVirtualCable"
    private let driverExtension = "driver"

    func bundledDriverURL() -> URL? {
        Bundle.main.url(
            forResource: driverBundleName,
            withExtension: driverExtension,
            subdirectory: "Drivers"
        )
    }

    func installBundledDriver() async -> DriverInstallResult {
        guard let bundledDriverURL = bundledDriverURL() else {
            return DriverInstallResult(
                success: false,
                message: "Bundled driver was not found in app resources. Build the Xavucontrol target first."
            )
        }

        let stagedDriverURL: URL
        do {
            stagedDriverURL = try stageSignedDriver(from: bundledDriverURL)
        } catch {
            return DriverInstallResult(success: false, message: error.localizedDescription)
        }

        let installScript = """
        set -eu
        SRC='\(shellEscapedPath(stagedDriverURL.path))'
        INSTALL_DIR='/Library/Audio/Plug-Ins/HAL'
        DEST="$INSTALL_DIR/XavucontrolVirtualCable.driver"
        /bin/mkdir -p "$INSTALL_DIR"
        /usr/bin/killall coreaudiod || true
        /bin/sleep 1
        /bin/rm -rf "$DEST"
        /bin/rm -f /tmp/xavucontrol_virtual_cable_diag_v1
        /usr/bin/ditto "$SRC" "$DEST"
        /usr/sbin/chown -R root:wheel "$DEST"
        /bin/chmod -R u=rwX,go=rX "$DEST"
        /usr/bin/touch "$INSTALL_DIR" "$DEST"
        /usr/bin/killall -9 coreaudiod || true
        /bin/sleep 1
        /bin/launchctl kickstart -k system/com.apple.audio.coreaudiod || true
        """

        let appleScript = "do shell script \(appleScriptStringLiteral(installScript)) with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return DriverInstallResult(success: false, message: "Failed to start installer: \(error.localizedDescription)")
        }

        let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        try? FileManager.default.removeItem(at: stagedDriverURL.deletingLastPathComponent())

        if process.terminationStatus == 0 {
            return DriverInstallResult(
                success: true,
                message: "Installed latest bundled virtual cable driver. Core Audio was restarted."
            )
        }

        let detail = [stderr, stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Installer exited with status \(process.terminationStatus)"
        return DriverInstallResult(success: false, message: detail)
    }

    func uninstallDriver() async -> DriverInstallResult {
        let uninstallScript = """
        set -eu
        DEST='/Library/Audio/Plug-Ins/HAL/XavucontrolVirtualCable.driver'
        /usr/bin/killall coreaudiod || true
        /bin/sleep 1
        /bin/rm -rf "$DEST"
        /bin/rm -f /tmp/xavucontrol_virtual_cable_diag_v1
        /usr/bin/touch '/Library/Audio/Plug-Ins/HAL'
        /usr/bin/killall -9 coreaudiod || true
        /bin/sleep 1
        /bin/launchctl kickstart -k system/com.apple.audio.coreaudiod || true
        """

        let appleScript = "do shell script \(appleScriptStringLiteral(uninstallScript)) with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return DriverInstallResult(success: false, message: "Failed to start uninstaller: \(error.localizedDescription)")
        }

        let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        if process.terminationStatus == 0 {
            return DriverInstallResult(
                success: true,
                message: "Removed virtual cable driver. Core Audio was restarted."
            )
        }

        let detail = [stderr, stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Uninstaller exited with status \(process.terminationStatus)"
        return DriverInstallResult(success: false, message: detail)
    }

    private func stageSignedDriver(from sourceURL: URL) throws -> URL {
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("xavucontrol-driver-install-\(UUID().uuidString)", isDirectory: true)
        let stagedDriverURL = stagingRoot
            .appendingPathComponent(driverBundleName)
            .appendingPathExtension(driverExtension)

        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceURL, to: stagedDriverURL)

        let xattrResult = runProcess(
            executable: "/usr/bin/xattr",
            arguments: ["-cr", stagedDriverURL.path]
        )
        if xattrResult.exitCode != 0 {
            throw InstallerError.commandFailed("Failed to clear driver extended attributes: \(xattrResult.output)")
        }

        let signingIdentity = try findDevelopmentSigningIdentity()
        let codesignResult = runProcess(
            executable: "/usr/bin/codesign",
            arguments: [
                "--force",
                "--deep",
                "--options",
                "runtime",
                "--sign",
                signingIdentity,
                stagedDriverURL.path
            ]
        )
        if codesignResult.exitCode != 0 {
            throw InstallerError.commandFailed("Failed to sign virtual cable driver: \(codesignResult.output)")
        }

        return stagedDriverURL
    }

    private func findDevelopmentSigningIdentity() throws -> String {
        let result = runProcess(
            executable: "/usr/bin/security",
            arguments: ["find-identity", "-v", "-p", "codesigning"]
        )
        guard result.exitCode == 0 else {
            throw InstallerError.commandFailed("Failed to inspect code signing identities: \(result.output)")
        }

        for line in result.output.components(separatedBy: .newlines) where line.contains("Apple Development") {
            let parts = line.components(separatedBy: "\"")
            if parts.count >= 3 {
                return parts[1]
            }
        }

        throw InstallerError.commandFailed("No Apple Development code signing identity found. Open Xcode account settings or install a development certificate.")
    }

    private func runProcess(executable: String, arguments: [String]) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (1, error.localizedDescription)
        }

        let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let output = [stderr, stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return (process.terminationStatus, output)
    }

    private enum InstallerError: LocalizedError {
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case let .commandFailed(message):
                return message
            }
        }
    }

    private func shellEscapedPath(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "'\\''")
    }

    private func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
