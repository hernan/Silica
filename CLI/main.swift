import Darwin
import Foundation

nonisolated enum SilicaCLI {
    static func run() -> Never {
        let args = Array(CommandLine.arguments.dropFirst())
        switch ExternalOpenRequest.parseCLIArguments(args) {
        case .success(.help):
            print(ExternalOpenRequest.helpText)
            exit(0)

        case .failure(let error):
            writeStderr("silica: \(error.message)\n")
            if case .usage = error {
                writeStderr("Try 'silica --help' for more information.\n")
            }
            exit(error.exitStatus)

        case .success(.open(let request)):
            guard let appURL = resolveEnclosingAppURL() else {
                writeStderr("silica: helper must be run from inside Silica.app/Contents/Helpers/silica\n")
                exit(1)
            }

            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/open", directoryHint: .notDirectory)
            process.arguments = ["-a", appURL.path(percentEncoded: false), request.url.absoluteString]
            do {
                try process.run()
                process.waitUntilExit()
                exit(process.terminationStatus == 0 ? 0 : 1)
            } catch {
                writeStderr("silica: failed to open Silica: \(error.localizedDescription)\n")
                exit(1)
            }
        }
    }

    private static func resolveEnclosingAppURL() -> URL? {
        guard let rawExecutablePath = executablePath() else { return nil }
        var resolvedBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(rawExecutablePath, &resolvedBuffer) != nil else { return nil }
        let canonicalPath = String(cString: resolvedBuffer)

        let helperURL = URL(filePath: canonicalPath, directoryHint: .notDirectory)
        let helpersDir = helperURL.deletingLastPathComponent()
        let contentsDir = helpersDir.deletingLastPathComponent()
        let appURL = contentsDir.deletingLastPathComponent()

        guard helpersDir.lastPathComponent == "Helpers",
              contentsDir.lastPathComponent == "Contents",
              appURL.pathExtension == "app",
              FileManager.default.fileExists(
                  atPath: contentsDir.appending(path: "Info.plist").path(percentEncoded: false)
              ) else {
            return nil
        }
        return appURL
    }

    private static func executablePath() -> String? {
        if let arg0 = CommandLine.arguments.first, arg0.contains("/") {
            if arg0.hasPrefix("/") {
                return arg0
            }
            let cwd = FileManager.default.currentDirectoryPath
            return cwd == "/" ? "/" + arg0 : cwd + "/" + arg0
        }
        var size = UInt32(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buffer, &size) == 0 {
            return String(cString: buffer)
        }
        buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func writeStderr(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}

SilicaCLI.run()
