import Darwin
import Foundation

@main
@MainActor
struct CLITests {
    private static var totalTests = 0
    private static var failedTests = 0

    // MARK: - Assertions & Test Helpers

    private static func runTest(_ name: String, _ block: () throws -> Void) {
        totalTests += 1
        print("  • \(name)...", terminator: " ")
        fflush(stdout)
        do {
            try block()
            print("OK")
        } catch {
            failedTests += 1
            print("FAILED")
            print("    💥 Error: \(error)")
        }
    }

    private static func assertTrue(
        _ condition: Bool,
        _ message: String = "Expected condition to be true",
        file: StaticString = #file,
        line: UInt = #line
    ) throws {
        guard condition else {
            throw TestFailure(message: "\(message) at \(file):\(line)")
        }
    }

    private static func assertFalse(
        _ condition: Bool,
        _ message: String = "Expected condition to be false",
        file: StaticString = #file,
        line: UInt = #line
    ) throws {
        guard !condition else {
            throw TestFailure(message: "\(message) at \(file):\(line)")
        }
    }

    private static func assertEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ message: String = "",
        file: StaticString = #file,
        line: UInt = #line
    ) throws {
        guard actual == expected else {
            let desc = message.isEmpty ? "Expected \(expected), got \(actual)" : message
            throw TestFailure(message: "\(desc) at \(file):\(line)")
        }
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func withTemporaryDirectory(_ block: (URL) throws -> Void) throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("silica-cli-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try block(tempDir)
    }

    private static func canonicalPath(for path: String) -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buf) != nil else {
            return normalizePath(path)
        }
        return normalizePath(String(cString: buf))
    }

    private static func normalizePath(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") {
            p.removeLast()
        }
        return p
    }

    private struct CLIExecutionResult {
        let exitStatus: Int32
        let stdout: String
        let stderr: String
    }

    private static func runCLIExecutable(
        _ executableURL: URL,
        arguments: [String],
        currentDirectory: URL? = nil
    ) throws -> CLIExecutionResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return CLIExecutionResult(
            exitStatus: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    private static func findBuiltHelperURL() -> URL? {
        let cwd = URL(filePath: FileManager.default.currentDirectoryPath)
        let candidate = cwd.appending(path: "build/DerivedData/Build/Products/Debug/Silica.app/Contents/Helpers/silica")
        if FileManager.default.isExecutableFile(atPath: candidate.path(percentEncoded: false)) {
            return candidate
        }
        if let env = ProcessInfo.processInfo.environment["SILICA_APP_PATH"] {
            let u = URL(filePath: env).appending(path: "Contents/Helpers/silica")
            if FileManager.default.isExecutableFile(atPath: u.path(percentEncoded: false)) {
                return u
            }
        }
        return nil
    }

    // MARK: - Test Suite Entry Point

    static func main() {
        print("=== Running Silica CLI & SafeFileAccess Test Suite ===")

        print("\n[Group 1] CLI Argument Parsing (parseCLIArguments)")
        runTest("0 arguments -> .open(.welcome)") {
            let result = ExternalOpenRequest.parseCLIArguments([])
            try assertEqual(result, .success(.open(.welcome)))
        }

        runTest("-h and --help -> .help") {
            try assertEqual(ExternalOpenRequest.parseCLIArguments(["-h"]), .success(.help))
            try assertEqual(ExternalOpenRequest.parseCLIArguments(["--help"]), .success(.help))
        }

        runTest("> 1 arguments -> .failure(.usage(...)) with exitStatus == 2") {
            let res2 = ExternalOpenRequest.parseCLIArguments(["file1", "file2"])
            switch res2 {
            case .failure(let err):
                try assertEqual(err.exitStatus, 2)
                try assertEqual(err, .usage("too many arguments"))
            case .success:
                try assertTrue(false, "Expected failure for 2 arguments")
            }

            let res3 = ExternalOpenRequest.parseCLIArguments(["a", "b", "c"])
            switch res3 {
            case .failure(let err):
                try assertEqual(err.exitStatus, 2)
                try assertEqual(err, .usage("too many arguments"))
            case .success:
                try assertTrue(false, "Expected failure for 3 arguments")
            }

            let resHelpExtra = ExternalOpenRequest.parseCLIArguments(["-h", "extra"])
            switch resHelpExtra {
            case .failure(let err):
                try assertEqual(err.exitStatus, 2)
            case .success:
                try assertTrue(false, "Expected failure for -h with extra args")
            }
        }

        runTest("unknown flags (-x, --unknown) -> .failure(.usage(...)) with exitStatus == 2") {
            let resX = ExternalOpenRequest.parseCLIArguments(["-x"])
            switch resX {
            case .failure(let err):
                try assertEqual(err.exitStatus, 2)
                try assertEqual(err, .usage("unknown option: -x"))
            case .success:
                try assertTrue(false, "Expected failure for -x")
            }

            let resUnknown = ExternalOpenRequest.parseCLIArguments(["--unknown"])
            switch resUnknown {
            case .failure(let err):
                try assertEqual(err.exitStatus, 2)
                try assertEqual(err, .usage("unknown option: --unknown"))
            case .success:
                try assertTrue(false, "Expected failure for --unknown")
            }
        }

        runTest("silica -- (missing path) and silica -- a b -> exitStatus == 2") {
            let resMissing = ExternalOpenRequest.parseCLIArguments(["--"])
            switch resMissing {
            case .failure(let err):
                try assertEqual(err.exitStatus, 2)
                try assertEqual(err, .usage("missing path after '--'"))
            case .success:
                try assertTrue(false, "Expected failure for missing path after --")
            }

            let resTooMany = ExternalOpenRequest.parseCLIArguments(["--", "a", "b"])
            switch resTooMany {
            case .failure(let err):
                try assertEqual(err.exitStatus, 2)
                try assertEqual(err, .usage("too many arguments"))
            case .success:
                try assertTrue(false, "Expected failure for too many args after --")
            }
        }

        runTest("silica -- -leading-dash.rb and -leading-dash.rb:12") {
            try withTemporaryDirectory { dir in
                let base = dir.path(percentEncoded: false)
                let filePath = dir.appendingPathComponent("-leading-dash.rb").path(percentEncoded: false)
                try "hello".write(toFile: filePath, atomically: true, encoding: .utf8)
                let canonical = canonicalPath(for: filePath)

                // Without --, -leading-dash.rb is rejected as an unknown option
                let withoutDashDash = ExternalOpenRequest.parseCLIArguments(["-leading-dash.rb"], currentDirectoryPath: base)
                switch withoutDashDash {
                case .failure(let err):
                    try assertEqual(err.exitStatus, 2)
                    try assertEqual(err, .usage("unknown option: -leading-dash.rb"))
                case .success:
                    try assertTrue(false, "Expected leading dash to be rejected without --")
                }

                // With --: file only
                let resFile = ExternalOpenRequest.parseCLIArguments(["--", "-leading-dash.rb"], currentDirectoryPath: base)
                guard case .success(.open(let reqFile)) = resFile,
                      case .open(let targetFile, let lineFile) = reqFile else {
                    throw TestFailure(message: "Failed to open -leading-dash.rb with --: \(resFile)")
                }
                try assertEqual(targetFile.kind, .regularFile)
                try assertEqual(targetFile.resolvedFileURL.path(percentEncoded: false), canonical)
                try assertEqual(lineFile, nil)

                // With --: file and line :12
                let resLine = ExternalOpenRequest.parseCLIArguments(["--", "-leading-dash.rb:12"], currentDirectoryPath: base)
                guard case .success(.open(let reqLine)) = resLine,
                      case .open(let targetLine, let lineNum) = reqLine else {
                    throw TestFailure(message: "Failed to open -leading-dash.rb:12 with --: \(resLine)")
                }
                try assertEqual(targetLine.kind, .regularFile)
                try assertEqual(targetLine.resolvedFileURL.path(percentEncoded: false), canonical)
                try assertEqual(lineNum, 12)
            }
        }

        runTest("existing regular file with and without :line (including 1 and 2147483647)") {
            try withTemporaryDirectory { dir in
                let base = dir.path(percentEncoded: false)
                let filePath = dir.appendingPathComponent("sample.txt").path(percentEncoded: false)
                try "sample text".write(toFile: filePath, atomically: true, encoding: .utf8)
                let canonical = canonicalPath(for: filePath)

                // No line
                let resPlain = ExternalOpenRequest.parseCLIArguments(["sample.txt"], currentDirectoryPath: base)
                guard case .success(.open(let reqPlain)) = resPlain,
                      case .open(let targetPlain, let linePlain) = reqPlain else {
                    throw TestFailure(message: "Failed to open plain file")
                }
                try assertEqual(targetPlain.kind, .regularFile)
                try assertEqual(targetPlain.resolvedFileURL.path(percentEncoded: false), canonical)
                try assertEqual(linePlain, nil)

                // Line 1
                let resLine1 = ExternalOpenRequest.parseCLIArguments(["sample.txt:1"], currentDirectoryPath: base)
                guard case .success(.open(let req1)) = resLine1,
                      case .open(let target1, let line1) = req1 else {
                    throw TestFailure(message: "Failed to open with line 1")
                }
                try assertEqual(target1.kind, .regularFile)
                try assertEqual(target1.resolvedFileURL.path(percentEncoded: false), canonical)
                try assertEqual(line1, 1)

                // Line 42
                let resLine42 = ExternalOpenRequest.parseCLIArguments(["sample.txt:42"], currentDirectoryPath: base)
                guard case .success(.open(let req42)) = resLine42,
                      case .open(let target42, let line42) = req42 else {
                    throw TestFailure(message: "Failed to open with line 42")
                }
                try assertEqual(target42.kind, .regularFile)
                try assertEqual(target42.resolvedFileURL.path(percentEncoded: false), canonical)
                try assertEqual(line42, 42)

                // Line 2147483647 (Int32.max)
                let resLineMax = ExternalOpenRequest.parseCLIArguments(["sample.txt:2147483647"], currentDirectoryPath: base)
                guard case .success(.open(let reqMax)) = resLineMax,
                      case .open(let targetMax, let lineMax) = reqMax else {
                    throw TestFailure(message: "Failed to open with max line")
                }
                try assertEqual(targetMax.kind, .regularFile)
                try assertEqual(targetMax.resolvedFileURL.path(percentEncoded: false), canonical)
                try assertEqual(lineMax, 2147483647)
            }
        }

        runTest("existing directory . or named directory -> .directory, line == nil") {
            try withTemporaryDirectory { dir in
                let base = dir.path(percentEncoded: false)
                let canonicalBase = canonicalPath(for: base)

                // "."
                let resDot = ExternalOpenRequest.parseCLIArguments(["."], currentDirectoryPath: base)
                guard case .success(.open(let reqDot)) = resDot,
                      case .open(let targetDot, let lineDot) = reqDot else {
                    throw TestFailure(message: "Failed to open . directory")
                }
                try assertEqual(targetDot.kind, .directory)
                try assertEqual(normalizePath(targetDot.resolvedFileURL.path(percentEncoded: false)), canonicalBase)
                try assertEqual(lineDot, nil)

                // Named directory
                let subDir = dir.appendingPathComponent("project_dir")
                try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
                let canonicalSub = canonicalPath(for: subDir.path(percentEncoded: false))

                let resNamed = ExternalOpenRequest.parseCLIArguments(["project_dir"], currentDirectoryPath: base)
                guard case .success(.open(let reqNamed)) = resNamed,
                      case .open(let targetNamed, let lineNamed) = reqNamed else {
                    throw TestFailure(message: "Failed to open named directory")
                }
                try assertEqual(targetNamed.kind, .directory)
                try assertEqual(normalizePath(targetNamed.resolvedFileURL.path(percentEncoded: false)), canonicalSub)
                try assertEqual(lineNamed, nil)
            }
        }

        runTest("directory with :42 suffix -> exitStatus == 1, .lineOnDirectory") {
            try withTemporaryDirectory { dir in
                let base = dir.path(percentEncoded: false)
                let subDir = dir.appendingPathComponent("my_project")
                try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

                let res = ExternalOpenRequest.parseCLIArguments(["my_project:42"], currentDirectoryPath: base)
                switch res {
                case .failure(let err):
                    try assertEqual(err.exitStatus, 1)
                    try assertEqual(err, .validation(.lineOnDirectory("my_project")))
                case .success:
                    try assertTrue(false, "Expected line on directory to fail")
                }
            }
        }

        runTest("literal file named notes:42 and literal directory named project:42") {
            try withTemporaryDirectory { dir in
                let base = dir.path(percentEncoded: false)

                // Literal file "notes:42"
                let notesPath = dir.appendingPathComponent("notes:42").path(percentEncoded: false)
                try "notes content".write(toFile: notesPath, atomically: true, encoding: .utf8)
                let canonicalNotes = canonicalPath(for: notesPath)

                let resNotes = ExternalOpenRequest.parseCLIArguments(["notes:42"], currentDirectoryPath: base)
                guard case .success(.open(let reqNotes)) = resNotes,
                      case .open(let targetNotes, let lineNotes) = reqNotes else {
                    throw TestFailure(message: "Failed to open literal file notes:42")
                }
                try assertEqual(targetNotes.kind, .regularFile)
                try assertEqual(targetNotes.resolvedFileURL.path(percentEncoded: false), canonicalNotes)
                try assertEqual(lineNotes, nil)

                // Literal directory "project:42"
                let projectPath = dir.appendingPathComponent("project:42")
                try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)
                let canonicalProj = canonicalPath(for: projectPath.path(percentEncoded: false))

                let resProj = ExternalOpenRequest.parseCLIArguments(["project:42"], currentDirectoryPath: base)
                guard case .success(.open(let reqProj)) = resProj,
                      case .open(let targetProj, let lineProj) = reqProj else {
                    throw TestFailure(message: "Failed to open literal directory project:42")
                }
                try assertEqual(targetProj.kind, .directory)
                try assertEqual(normalizePath(targetProj.resolvedFileURL.path(percentEncoded: false)), canonicalProj)
                try assertEqual(lineProj, nil)
            }
        }

        runTest("broken symlink named broken:42 (target does not exist, regular 'broken' exists)") {
            try withTemporaryDirectory { dir in
                let base = dir.path(percentEncoded: false)

                // Create regular file "broken"
                let brokenRegular = dir.appendingPathComponent("broken").path(percentEncoded: false)
                try "regular broken file".write(toFile: brokenRegular, atomically: true, encoding: .utf8)

                // Create broken symlink "broken:42" pointing to nonexistent target
                let brokenSymlink = dir.appendingPathComponent("broken:42").path(percentEncoded: false)
                let nonexistentTarget = dir.appendingPathComponent("does_not_exist").path(percentEncoded: false)
                Darwin.symlink(nonexistentTarget, brokenSymlink)

                let res = ExternalOpenRequest.parseCLIArguments(["broken:42"], currentDirectoryPath: base)
                switch res {
                case .failure(let err):
                    try assertEqual(err.exitStatus, 1)
                    try assertEqual(err, .validation(.brokenSymlink("broken:42")))
                case .success(let cmd):
                    try assertTrue(false, "Expected broken:42 to fail validation, but got success: \(cmd)")
                }
            }
        }

        runTest("symlink loop -> exitStatus == 1, .symlinkLoop") {
            try withTemporaryDirectory { dir in
                let base = dir.path(percentEncoded: false)

                let loop1 = dir.appendingPathComponent("loop1").path(percentEncoded: false)
                let loop2 = dir.appendingPathComponent("loop2").path(percentEncoded: false)
                Darwin.symlink(loop2, loop1)
                Darwin.symlink(loop1, loop2)

                let resLoop = ExternalOpenRequest.parseCLIArguments(["loop1"], currentDirectoryPath: base)
                switch resLoop {
                case .failure(let err):
                    try assertEqual(err.exitStatus, 1)
                    try assertEqual(err, .validation(.symlinkLoop("loop1")))
                case .success:
                    try assertTrue(false, "Expected symlink loop to fail")
                }

                let resLoopLine = ExternalOpenRequest.parseCLIArguments(["loop1:42"], currentDirectoryPath: base)
                switch resLoopLine {
                case .failure(let err):
                    try assertEqual(err.exitStatus, 1)
                    try assertEqual(err, .validation(.symlinkLoop("loop1")))
                case .success:
                    try assertTrue(false, "Expected symlink loop with line to fail")
                }
            }
        }

        runTest("invalid line numbers (0, -1, +5, 2147483648, 99999999999999999999, 12abc, ' 12')") {
            try withTemporaryDirectory { dir in
                let base = dir.path(percentEncoded: false)
                let file = dir.appendingPathComponent("sample.txt").path(percentEncoded: false)
                try "content".write(toFile: file, atomically: true, encoding: .utf8)

                let invalidNumbers = ["0", "-1", "+5", "2147483648", "99999999999999999999", "12abc", " 12"]
                for invalid in invalidNumbers {
                    let arg = "sample.txt:\(invalid)"
                    let res = ExternalOpenRequest.parseCLIArguments([arg], currentDirectoryPath: base)
                    switch res {
                    case .failure(let err):
                        try assertEqual(err.exitStatus, 1)
                        try assertEqual(err, .validation(.invalidLineNumber(invalid)))
                    case .success:
                        try assertTrue(false, "Expected failure for invalid line: \(invalid)")
                    }
                }
            }
        }

        runTest("filenames with spaces, Unicode, quotes, %, &, ?, #, +, and %2F round-trip") {
            try withTemporaryDirectory { dir in
                let base = dir.path(percentEncoded: false)

                let specialFilenames = [
                    "file with spaces and 🚀.txt",
                    "quote\"and'apostrophe.txt",
                    "percent%and&amp.txt",
                    "question?and#hash.txt",
                    "plus+sign.txt",
                    "literal%2Fencoded.txt",
                    "all_combined 🚀 %2F & ? # + ' \".txt"
                ]

                for name in specialFilenames {
                    let path = dir.appendingPathComponent(name).path(percentEncoded: false)
                    try "special content".write(toFile: path, atomically: true, encoding: .utf8)

                    // 1. CLI parsing without line
                    let resPlain = ExternalOpenRequest.parseCLIArguments([name], currentDirectoryPath: base)
                    guard case .success(.open(let reqPlain)) = resPlain else {
                        throw TestFailure(message: "Failed CLI parsing for '\(name)': \(resPlain)")
                    }

                    // Round-trip through URL
                    let urlPlain = reqPlain.url
                    let parsedPlain = try ExternalOpenRequest.parse(url: urlPlain)
                    try assertEqual(parsedPlain, reqPlain, "URL round-trip mismatch for '\(name)'")

                    // 2. CLI parsing with line 42
                    let argWithLine = "\(name):42"
                    let resWithLine = ExternalOpenRequest.parseCLIArguments([argWithLine], currentDirectoryPath: base)
                    guard case .success(.open(let reqLine)) = resWithLine else {
                        throw TestFailure(message: "Failed CLI parsing for '\(argWithLine)': \(resWithLine)")
                    }

                    let urlLine = reqLine.url
                    let parsedLine = try ExternalOpenRequest.parse(url: urlLine)
                    try assertEqual(parsedLine, reqLine, "URL round-trip with line mismatch for '\(argWithLine)'")

                    // 3. Specifically verify literal %2F did not turn into /
                    if name.contains("%2F") {
                        if case .open(let target, _) = parsedPlain {
                            let parsedName = target.resolvedFileURL.lastPathComponent
                            try assertTrue(parsedName.contains("%2F"), "Literal %2F turned into slash or changed in '\(parsedName)'")
                        }
                    }
                }
            }
        }

        runTest("control character filenames (\\t, \\n, \\0, 0x7F) -> .controlCharacters") {
            let ctrlNames = ["\tfile.txt", "file\n.txt", "file\0.txt", "file\u{7F}.txt"]
            for name in ctrlNames {
                let res = ExternalOpenRequest.parseCLIArguments([name])
                switch res {
                case .failure(let err):
                    try assertEqual(err.exitStatus, 1)
                    try assertEqual(err, .validation(.controlCharacters))
                case .success:
                    try assertTrue(false, "Expected control character filename to fail: \(name)")
                }
            }
        }

        runTest("overlong path (>= PATH_MAX) -> .pathTooLong") {
            let overlong = String(repeating: "a", count: Int(PATH_MAX))
            let res = ExternalOpenRequest.parseCLIArguments([overlong])
            switch res {
            case .failure(let err):
                try assertEqual(err.exitStatus, 1)
                try assertEqual(err, .validation(.pathTooLong))
            case .success:
                try assertTrue(false, "Expected overlong path to fail")
            }
        }

        runTest("/dev, /dev/null, /dev/zero, /dev/tty, and symlinks to /dev -> .forbiddenDevPath") {
            try withTemporaryDirectory { dir in
                let base = dir.path(percentEncoded: false)

                let devPaths = ["/dev", "/dev/null", "/dev/zero", "/dev/tty"]
                for p in devPaths {
                    let res = ExternalOpenRequest.parseCLIArguments([p], currentDirectoryPath: base)
                    switch res {
                    case .failure(let err):
                        try assertEqual(err.exitStatus, 1)
                        try assertEqual(err, .validation(.forbiddenDevPath(p)))
                    case .success:
                        try assertTrue(false, "Expected dev path \(p) to be rejected")
                    }
                }

                // Symlink pointing to /dev/null
                let symNull = dir.appendingPathComponent("link_to_null").path(percentEncoded: false)
                Darwin.symlink("/dev/null", symNull)
                let resSymNull = ExternalOpenRequest.parseCLIArguments(["link_to_null"], currentDirectoryPath: base)
                switch resSymNull {
                case .failure(let err):
                    try assertEqual(err.exitStatus, 1)
                    try assertEqual(err, .validation(.forbiddenDevPath("link_to_null")))
                case .success:
                    try assertTrue(false, "Expected symlink to /dev/null to be rejected")
                }

                // Symlink pointing to /dev
                let symDev = dir.appendingPathComponent("link_to_dev").path(percentEncoded: false)
                Darwin.symlink("/dev", symDev)
                let resSymDev = ExternalOpenRequest.parseCLIArguments(["link_to_dev"], currentDirectoryPath: base)
                switch resSymDev {
                case .failure(let err):
                    try assertEqual(err.exitStatus, 1)
                    try assertEqual(err, .validation(.forbiddenDevPath("link_to_dev")))
                case .success:
                    try assertTrue(false, "Expected symlink to /dev to be rejected")
                }
            }
        }

        print("\n[Group 2] App-Side URL Parsing (ExternalOpenRequest.parse(url:))")
        runTest("silica://welcome -> .welcome") {
            let url = URL(string: "silica://welcome")!
            let parsed = try ExternalOpenRequest.parse(url: url)
            try assertEqual(parsed, .welcome)
        }

        runTest("silica://welcome?foo=bar and silica://welcome/extra -> .malformedURL") {
            let badWelcome1 = URL(string: "silica://welcome?foo=bar")!
            do {
                _ = try ExternalOpenRequest.parse(url: badWelcome1)
                throw TestFailure(message: "Expected query on welcome to fail")
            } catch let err as ExternalOpenValidationError {
                try assertEqual(err, .malformedURL)
            }

            let badWelcome2 = URL(string: "silica://welcome/extra")!
            do {
                _ = try ExternalOpenRequest.parse(url: badWelcome2)
                throw TestFailure(message: "Expected route path on welcome to fail")
            } catch let err as ExternalOpenValidationError {
                try assertEqual(err, .malformedURL)
            }

            let badWelcome3 = URL(string: "silica://welcome/")!
            do {
                _ = try ExternalOpenRequest.parse(url: badWelcome3)
                throw TestFailure(message: "Expected slash path on welcome to fail")
            } catch let err as ExternalOpenValidationError {
                try assertEqual(err, .malformedURL)
            }
        }

        runTest("valid silica://open?path=... and with &line=42") {
            try withTemporaryDirectory { dir in
                let file = dir.appendingPathComponent("valid.txt").path(percentEncoded: false)
                try "valid file".write(toFile: file, atomically: true, encoding: .utf8)
                let canonical = canonicalPath(for: file)

                // Without line
                let urlNoLine = URL(string: "silica://open?path=\(canonical)")!
                let reqNoLine = try ExternalOpenRequest.parse(url: urlNoLine)
                guard case .open(let targetNoLine, let lineNoLine) = reqNoLine else {
                    throw TestFailure(message: "Failed to parse valid open URL without line")
                }
                try assertEqual(targetNoLine.kind, .regularFile)
                try assertEqual(targetNoLine.resolvedFileURL.path(percentEncoded: false), canonical)
                try assertEqual(lineNoLine, nil)

                // With line 42
                let urlLine = URL(string: "silica://open?path=\(canonical)&line=42")!
                let reqLine = try ExternalOpenRequest.parse(url: urlLine)
                guard case .open(let targetLine, let lineVal) = reqLine else {
                    throw TestFailure(message: "Failed to parse valid open URL with line")
                }
                try assertEqual(targetLine.kind, .regularFile)
                try assertEqual(targetLine.resolvedFileURL.path(percentEncoded: false), canonical)
                try assertEqual(lineVal, 42)
            }
        }

        runTest("rejects non-silica schemes, uppercase host, credentials, port, fragment, non-empty route path") {
            try withTemporaryDirectory { dir in
                let file = dir.appendingPathComponent("test.txt").path(percentEncoded: false)
                try "abc".write(toFile: file, atomically: true, encoding: .utf8)
                let canonical = canonicalPath(for: file)

                let invalidURLStrings = [
                    "http://open?path=\(canonical)",
                    "file://\(canonical)",
                    "custom://welcome",
                    "silica://OPEN?path=\(canonical)",
                    "silica://WELCOME",
                    "silica://Open?path=\(canonical)",
                    "silica://user:pass@open?path=\(canonical)",
                    "silica://user@open?path=\(canonical)",
                    "silica://open:8080?path=\(canonical)",
                    "silica://open?path=\(canonical)#frag",
                    "silica://welcome#frag",
                    "silica://open/sub?path=\(canonical)",
                    "silica://open/?path=\(canonical)"
                ]

                for raw in invalidURLStrings {
                    guard let u = URL(string: raw) else {
                        throw TestFailure(message: "Could not create URL from: \(raw)")
                    }
                    do {
                        _ = try ExternalOpenRequest.parse(url: u)
                        throw TestFailure(message: "Expected URL to be rejected: \(raw)")
                    } catch let err as ExternalOpenValidationError {
                        try assertEqual(err, .malformedURL, "Expected malformedURL for \(raw)")
                    }
                }
            }
        }

        runTest("rejects missing path, relative path, duplicate path or line, unknown query keys, malformed percent") {
            try withTemporaryDirectory { dir in
                let file = dir.appendingPathComponent("test.txt").path(percentEncoded: false)
                try "abc".write(toFile: file, atomically: true, encoding: .utf8)
                let canonical = canonicalPath(for: file)

                let badQueryURLs = [
                    "silica://open",
                    "silica://open?",
                    "silica://open?line=42",
                    "silica://open?path=relative/file.txt",
                    "silica://open?path=\(canonical)&path=\(canonical)",
                    "silica://open?path=\(canonical)&line=10&line=20",
                    "silica://open?path=\(canonical)&extra=val",
                    "silica://open?path=%ZZ",
                    "silica://open?path=%2",
                    "silica://open?path=%",
                    "silica://open?path=\(canonical)&foo",
                    "silica://open?=val",
                    "silica://open?path=\(canonical)&line=0",
                    "silica://open?path=\(canonical)&line=-5",
                    "silica://open?path=\(canonical)&line=99999999999999999999"
                ]

                for raw in badQueryURLs {
                    guard let u = URL(string: raw) else {
                        throw TestFailure(message: "Could not create URL from: \(raw)")
                    }
                    do {
                        _ = try ExternalOpenRequest.parse(url: u)
                        throw TestFailure(message: "Expected bad query URL to be rejected: \(raw)")
                    } catch let err as ExternalOpenValidationError {
                        switch err {
                        case .malformedURL, .invalidLineNumber:
                            break // expected
                        default:
                            throw TestFailure(message: "Unexpected error for \(raw): \(err)")
                        }
                    }
                }
            }
        }

        runTest("rejects oversized URL (> 16 KiB) with .requestTooLarge") {
            let hugeString = "silica://open?path=/" + String(repeating: "a", count: 17000)
            let hugeURL = URL(string: hugeString)!
            do {
                _ = try ExternalOpenRequest.parse(url: hugeURL)
                throw TestFailure(message: "Expected oversized URL to fail")
            } catch let err as ExternalOpenValidationError {
                try assertEqual(err, .requestTooLarge)
            }
        }

        runTest("rejects line on a directory with .lineOnDirectory") {
            try withTemporaryDirectory { dir in
                let canonical = canonicalPath(for: dir.path(percentEncoded: false))
                let url = URL(string: "silica://open?path=\(canonical)&line=42")!
                do {
                    _ = try ExternalOpenRequest.parse(url: url)
                    throw TestFailure(message: "Expected line on directory to fail")
                } catch let err as ExternalOpenValidationError {
                    try assertEqual(err, .lineOnDirectory(canonical))
                }
            }
        }

        print("\n[Group 3] SafeFileAccess")
        runTest("readRegularFile on normal file within maxBytes -> .data(...)") {
            try withTemporaryDirectory { dir in
                let file = dir.appendingPathComponent("hello.txt")
                let content = Data("Hello, Silica!".utf8)
                try content.write(to: file)

                let res1 = SafeFileAccess.readRegularFile(at: file, maxBytes: 100)
                try assertEqual(res1, .data(content))

                let resExact = SafeFileAccess.readRegularFile(at: file, maxBytes: content.count)
                try assertEqual(resExact, .data(content))

                // Check isRegularFile
                try assertTrue(SafeFileAccess.isRegularFile(at: file))
            }
        }

        runTest("readRegularFile on file of maxBytes + 1 bytes -> .tooLarge(...)") {
            try withTemporaryDirectory { dir in
                let file = dir.appendingPathComponent("overflow.txt")
                let content = Data("0123456789".utf8) // 10 bytes
                try content.write(to: file)

                let res = SafeFileAccess.readRegularFile(at: file, maxBytes: 9)
                try assertEqual(res, .tooLarge(10))
            }
        }

        runTest("readRegularFile on FIFO -> returns .unreadable immediately without blocking") {
            try withTemporaryDirectory { dir in
                let fifoPath = dir.appendingPathComponent("test_pipe").path(percentEncoded: false)
                try assertEqual(Darwin.mkfifo(fifoPath, 0o600), 0)

                let fifoURL = URL(filePath: fifoPath)
                let res = SafeFileAccess.readRegularFile(at: fifoURL, maxBytes: 1024)
                switch res {
                case .unreadable:
                    break // Success!
                default:
                    throw TestFailure(message: "Expected .unreadable for FIFO, got \(res)")
                }

                try assertFalse(SafeFileAccess.isRegularFile(at: fifoURL))
            }
        }

        runTest("readRegularFile on Unix domain socket -> returns .unreadable immediately") {
            let sockPath = "/tmp/silica_sock_\(UUID().uuidString.prefix(8)).sock"
            defer { unlink(sockPath) }
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            try assertTrue(fd >= 0, "Failed to create socket descriptor")
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            sockPath.withCString { cstr in
                _ = strncpy(&addr.sun_path.0, cstr, MemoryLayout.size(ofValue: addr.sun_path) - 1)
            }
            let len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let bindRes = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    Darwin.bind(fd, saPtr, len)
                }
            }
            Darwin.close(fd)
            try assertEqual(bindRes, 0)

            let sockURL = URL(filePath: sockPath)
            let res = SafeFileAccess.readRegularFile(at: sockURL, maxBytes: 1024)
            switch res {
            case .unreadable:
                break // Success!
            default:
                throw TestFailure(message: "Expected .unreadable for socket, got \(res)")
            }

            try assertFalse(SafeFileAccess.isRegularFile(at: sockURL))
        }

        runTest("readRegularFile on /dev/null and /dev/zero -> returns .unreadable immediately") {
            let nullURL = URL(filePath: "/dev/null")
            let zeroURL = URL(filePath: "/dev/zero")

            let resNull = SafeFileAccess.readRegularFile(at: nullURL, maxBytes: 1024)
            switch resNull {
            case .unreadable: break
            default: throw TestFailure(message: "Expected .unreadable for /dev/null, got \(resNull)")
            }

            let resZero = SafeFileAccess.readRegularFile(at: zeroURL, maxBytes: 1024)
            switch resZero {
            case .unreadable: break
            default: throw TestFailure(message: "Expected .unreadable for /dev/zero, got \(resZero)")
            }

            try assertFalse(SafeFileAccess.isRegularFile(at: nullURL))
            try assertFalse(SafeFileAccess.isRegularFile(at: zeroURL))
        }

        runTest("readPrefix reads only requested prefix and rejects FIFOs/directories") {
            try withTemporaryDirectory { dir in
                let file = dir.appendingPathComponent("large.txt")
                let content = Data("0123456789abcdefghij".utf8) // 20 bytes
                try content.write(to: file)

                // Read prefix of 10 bytes
                let prefix = SafeFileAccess.readPrefix(at: file, maxBytes: 10)
                try assertEqual(prefix, Data("0123456789".utf8))

                // Rejects directory
                let dirPrefix = SafeFileAccess.readPrefix(at: dir, maxBytes: 10)
                try assertEqual(dirPrefix, nil)

                // Rejects FIFO
                let fifoPath = dir.appendingPathComponent("prefix_fifo").path(percentEncoded: false)
                try assertEqual(Darwin.mkfifo(fifoPath, 0o600), 0)
                let fifoPrefix = SafeFileAccess.readPrefix(at: URL(filePath: fifoPath), maxBytes: 10)
                try assertEqual(fifoPrefix, nil)

                // Rejects Unix domain socket
                let shortSock = "/tmp/silica_pref_\(UUID().uuidString.prefix(8)).sock"
                let sockFd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                try assertTrue(sockFd >= 0, "Failed to create socket descriptor")
                defer {
                    Darwin.close(sockFd)
                    unlink(shortSock)
                }
                var sAddr = sockaddr_un()
                sAddr.sun_family = sa_family_t(AF_UNIX)
                shortSock.withCString { cstr in
                    _ = strncpy(&sAddr.sun_path.0, cstr, MemoryLayout.size(ofValue: sAddr.sun_path) - 1)
                }
                let bindResult = withUnsafePointer(to: &sAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        Darwin.bind(sockFd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                try assertEqual(bindResult, 0, "Failed to bind Unix domain socket")
                try assertEqual(SafeFileAccess.readPrefix(at: URL(filePath: shortSock), maxBytes: 10), nil)

                // Rejects dev paths
                try assertEqual(SafeFileAccess.readPrefix(at: URL(filePath: "/dev/null"), maxBytes: 10), nil)
                try assertEqual(SafeFileAccess.readPrefix(at: URL(filePath: "/dev/zero"), maxBytes: 10), nil)
            }
        }

        print("\n[Group 4] Compiled Binary Tests (Silica.app/Contents/Helpers/silica)")
        if let helperURL = findBuiltHelperURL() {
            runTest("silica binary --help and -h exit with 0 and print usage") {
                let resHelp = try runCLIExecutable(helperURL, arguments: ["--help"])
                try assertEqual(resHelp.exitStatus, 0)
                try assertTrue(resHelp.stdout.contains("Usage:"), "Expected usage in stdout")
                try assertTrue(resHelp.stdout.contains("silica <file[:line] | directory>"))

                let resH = try runCLIExecutable(helperURL, arguments: ["-h"])
                try assertEqual(resH.exitStatus, 0)
                try assertTrue(resH.stdout.contains("Usage:"))
            }

            runTest("silica binary with > 1 args, unknown option, or -- with no path exits with 2") {
                let resTwo = try runCLIExecutable(helperURL, arguments: ["a", "b"])
                try assertEqual(resTwo.exitStatus, 2)
                try assertTrue(resTwo.stderr.contains("silica: too many arguments"))
                try assertTrue(resTwo.stderr.contains("Try 'silica --help'"))

                let resOpt = try runCLIExecutable(helperURL, arguments: ["-z"])
                try assertEqual(resOpt.exitStatus, 2)
                try assertTrue(resOpt.stderr.contains("silica: unknown option: -z"))

                let resDash = try runCLIExecutable(helperURL, arguments: ["--"])
                try assertEqual(resDash.exitStatus, 2)
                try assertTrue(resDash.stderr.contains("silica: missing path after '--'"))
            }

            runTest("silica binary on invalid targets (/nonexistent, /dev/null, /dev, broken symlink, directory:42) exits with 1") {
                try withTemporaryDirectory { dir in
                    // /nonexistent
                    let resNon = try runCLIExecutable(helperURL, arguments: ["/nonexistent"])
                    try assertEqual(resNon.exitStatus, 1)
                    try assertTrue(resNon.stderr.contains("no such file or directory: /nonexistent"))

                    // /dev/null
                    let resNull = try runCLIExecutable(helperURL, arguments: ["/dev/null"])
                    try assertEqual(resNull.exitStatus, 1)
                    try assertTrue(resNull.stderr.contains("device paths under /dev are not supported: /dev/null"))

                    // /dev
                    let resDev = try runCLIExecutable(helperURL, arguments: ["/dev"])
                    try assertEqual(resDev.exitStatus, 1)
                    try assertTrue(resDev.stderr.contains("device paths under /dev are not supported: /dev"))

                    // broken symlink
                    let brokenLink = dir.appendingPathComponent("broken").path(percentEncoded: false)
                    Darwin.symlink("/nonexistent_target", brokenLink)
                    let resBroken = try runCLIExecutable(helperURL, arguments: ["broken"], currentDirectory: dir)
                    try assertEqual(resBroken.exitStatus, 1)
                    try assertTrue(resBroken.stderr.contains("broken symbolic link: broken"))

                    // directory:42
                    let subDir = dir.appendingPathComponent("subfolder")
                    try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
                    let resDir = try runCLIExecutable(helperURL, arguments: ["subfolder:42"], currentDirectory: dir)
                    try assertEqual(resDir.exitStatus, 1)
                    try assertTrue(resDir.stderr.contains("cannot specify a line number for directory: subfolder"))
                }
            }

            runTest("moving/copying helper outside Silica.app exits with 1 and writes error to stderr") {
                try withTemporaryDirectory { dir in
                    let outsideBinary = dir.appendingPathComponent("silica_outside")
                    try FileManager.default.copyItem(at: helperURL, to: outsideBinary)

                    let dummyFile = dir.appendingPathComponent("test.txt")
                    try "hello".write(to: dummyFile, atomically: true, encoding: .utf8)

                    let res = try runCLIExecutable(outsideBinary, arguments: ["test.txt"], currentDirectory: dir)
                    try assertEqual(res.exitStatus, 1)
                    try assertTrue(
                        res.stderr.contains("helper must be run from inside Silica.app/Contents/Helpers/silica"),
                        "Expected outside helper error in stderr, got: \(res.stderr)"
                    )
                }
            }

            runTest("running via symlink resolves symlink chain to enclosing Silica.app") {
                try withTemporaryDirectory { dir in
                    let symlinkURL = dir.appendingPathComponent("silica")
                    let intermediateURL = dir.appendingPathComponent("silica-helper")
                    try FileManager.default.createSymbolicLink(at: intermediateURL, withDestinationURL: helperURL)
                    try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: intermediateURL)

                    // Running --help through symlink succeeds with 0
                    let resHelp = try runCLIExecutable(symlinkURL, arguments: ["--help"])
                    try assertEqual(resHelp.exitStatus, 0)
                    try assertTrue(resHelp.stdout.contains("Usage:"))

                    let dummyFile = dir.appendingPathComponent("test.txt")
                    try "hello".write(to: dummyFile, atomically: true, encoding: .utf8)
                    let resFile = try runCLIExecutable(symlinkURL, arguments: [dummyFile.path(percentEncoded: false)])
                    try assertEqual(resFile.exitStatus, 0, "Opening through symlink failed: \(resFile.stderr)")
                    try assertEqual(resFile.stderr, "", "Unexpected error opening through symlink: \(resFile.stderr)")
                }
            }
        } else {
            print("  ⚠️ Skipped Group 4 (built helper not found at build/DerivedData/Build/Products/Debug/Silica.app/Contents/Helpers/silica)")
        }

        print("\n[Group 5] CLICommandInstaller")
        runTest("installer lifecycle (.notInstalled -> install -> .installed -> uninstall -> .notInstalled)") {
            try withTemporaryDirectory { dir in
                let binDir = dir.appendingPathComponent("bin")
                let helperDir = dir.appendingPathComponent("Silica.app/Contents/Helpers")
                try FileManager.default.createDirectory(at: helperDir, withIntermediateDirectories: true)
                let mockHelper = helperDir.appendingPathComponent("silica")
                try "#!/bin/sh\n".write(to: mockHelper, atomically: true, encoding: .utf8)
                Darwin.chmod(mockHelper.path(percentEncoded: false), 0o755)

                let installer = CLICommandInstaller(directoryURL: binDir, helperURL: mockHelper)
                try assertEqual(installer.status, .notInstalled)

                try installer.install()
                try assertEqual(installer.status, .installed)
                try assertTrue(FileManager.default.fileExists(atPath: installer.destinationURL.path(percentEncoded: false)))

                try installer.uninstall()
                try assertEqual(installer.status, .notInstalled)
                try assertFalse(FileManager.default.fileExists(atPath: installer.destinationURL.path(percentEncoded: false)))
            }
        }

        runTest("installer repairs .installedElsewhere back to .installed") {
            try withTemporaryDirectory { dir in
                let binDir = dir.appendingPathComponent("bin")
                try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

                let helperDir = dir.appendingPathComponent("Silica.app/Contents/Helpers")
                try FileManager.default.createDirectory(at: helperDir, withIntermediateDirectories: true)
                let mockHelper = helperDir.appendingPathComponent("silica")
                try "#!/bin/sh\n".write(to: mockHelper, atomically: true, encoding: .utf8)
                Darwin.chmod(mockHelper.path(percentEncoded: false), 0o755)

                let otherHelperDir = dir.appendingPathComponent("Other.app/Contents/Helpers")
                try FileManager.default.createDirectory(at: otherHelperDir, withIntermediateDirectories: true)
                let otherHelper = otherHelperDir.appendingPathComponent("silica")
                try "#!/bin/sh\n".write(to: otherHelper, atomically: true, encoding: .utf8)
                Darwin.chmod(otherHelper.path(percentEncoded: false), 0o755)

                let installer = CLICommandInstaller(directoryURL: binDir, helperURL: mockHelper)

                // Point symlink to otherHelper
                Darwin.symlink(otherHelper.path(percentEncoded: false), installer.destinationURL.path(percentEncoded: false))
                try assertEqual(installer.status, .installedElsewhere)

                // Repair
                try installer.install()
                try assertEqual(installer.status, .installed)
            }
        }

        runTest("installer refuses to overwrite .conflict on a non-symlink file") {
            try withTemporaryDirectory { dir in
                let binDir = dir.appendingPathComponent("bin")
                try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

                let helperDir = dir.appendingPathComponent("Silica.app/Contents/Helpers")
                try FileManager.default.createDirectory(at: helperDir, withIntermediateDirectories: true)
                let mockHelper = helperDir.appendingPathComponent("silica")
                try "#!/bin/sh\n".write(to: mockHelper, atomically: true, encoding: .utf8)
                Darwin.chmod(mockHelper.path(percentEncoded: false), 0o755)

                let installer = CLICommandInstaller(directoryURL: binDir, helperURL: mockHelper)

                // Create a regular file at destination
                let regularFile = installer.destinationURL.path(percentEncoded: false)
                try "existing regular script or binary".write(toFile: regularFile, atomically: true, encoding: .utf8)
                try assertEqual(installer.status, .conflict)

                do {
                    try installer.install()
                    try assertTrue(false, "Expected installer to refuse overwriting conflict")
                } catch CLICommandInstaller.InstallerError.conflict {
                }

                // Verify conflict status is preserved and file is untouched
                try assertEqual(installer.status, .conflict)
                let content = try String(contentsOfFile: regularFile, encoding: .utf8)
                try assertEqual(content, "existing regular script or binary")
            }
        }

        // Summary
        print("\n=======================================================")
        if failedTests > 0 {
            print("❌ Test suite FAILED: \(failedTests) failed, \(totalTests - failedTests) passed out of \(totalTests) tests.")
            Darwin.exit(1)
        } else {
            print("✅ Test suite PASSED: All \(totalTests) tests passed cleanly.")
            Darwin.exit(0)
        }
    }
}
