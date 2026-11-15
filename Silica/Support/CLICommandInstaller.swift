import Darwin
import Foundation

/// Installs or removes a symlink to the bundled `silica` CLI helper in `~/.local/bin`.
struct CLICommandInstaller {
    static let standard = CLICommandInstaller(
        directoryURL: URL(filePath: RealHome.path, directoryHint: .isDirectory)
            .appending(path: ".local/bin", directoryHint: .isDirectory),
        helperURL: Bundle.main.bundleURL
            .appending(path: "Contents/Helpers/silica", directoryHint: .notDirectory)
    )

    enum Status: Equatable {
        case installed
        case installedElsewhere
        case conflict
        case notInstalled
    }

    enum InstallerError: LocalizedError {
        case missingBundledHelper
        case conflict

        var errorDescription: String? {
            switch self {
            case .missingBundledHelper:
                "The bundled ‘silica’ command could not be found inside the app."
            case .conflict:
                "A file or directory that is not a symbolic link already exists at ~/.local/bin/silica."
            }
        }
    }

    let directoryURL: URL
    let helperURL: URL

    var destinationURL: URL {
        directoryURL.appending(path: "silica", directoryHint: .notDirectory)
    }

    var status: Status {
        if let target = linkTarget {
            let linked = URL(filePath: target, relativeTo: directoryURL).resolvingSymlinksInPath()
            return linked == helperURL.resolvingSymlinksInPath() ? .installed : .installedElsewhere
        }
        var st = stat()
        return lstat(destinationPath, &st) == 0 ? .conflict : .notInstalled
    }

    func install() throws {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path(percentEncoded: false)) else {
            throw InstallerError.missingBundledHelper
        }
        guard status != .conflict else {
            throw InstallerError.conflict
        }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try removeLink()
        try FileManager.default.createSymbolicLink(at: destinationURL, withDestinationURL: helperURL)
    }

    func uninstall() throws {
        try removeLink()
    }

    private var destinationPath: String {
        destinationURL.path(percentEncoded: false)
    }

    private var linkTarget: String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: destinationPath)
    }

    private func removeLink() throws {
        guard linkTarget != nil else { return }
        try FileManager.default.removeItem(at: destinationURL)
    }

    private nonisolated static func canonicalPath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        return URL(filePath: expanded).resolvingSymlinksInPath().path(percentEncoded: false).trimmingTrailingSlash
    }

    func isOnShellPath() async -> Bool {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let directory = Self.canonicalPath(directoryURL.path(percentEncoded: false))
        let marker = "SILICA_PATH="
        return await Task.detached {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(filePath: shell)
            // Use printenv so PATH is always colon-separated, even in fish.
            process.arguments = ["-i", "-l", "-c", "printf '\(marker)'; /usr/bin/printenv PATH"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return true }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self)
            guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.contains(marker) }),
                  let path = line.components(separatedBy: marker).last
            else { return true }
            return path.split(separator: ":").contains { entry in
                Self.canonicalPath(String(entry)) == directory
            }
        }.value
    }
}
