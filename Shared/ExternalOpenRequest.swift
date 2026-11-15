import Darwin
import Foundation

nonisolated enum ValidatedTargetKind: Sendable, Equatable {
    case regularFile
    case directory
}

nonisolated struct ValidatedTarget: Sendable, Equatable {
    let resolvedFileURL: URL
    let kind: ValidatedTargetKind

    static func validate(
        path: String,
        relativeTo currentDirectoryPath: String? = nil
    ) throws(ExternalOpenValidationError) -> ValidatedTarget {
        guard !path.isEmpty else {
            throw .emptyPath
        }
        guard !Self.containsControlCharacters(path) else {
            throw .controlCharacters
        }
        guard path.utf8.count < Int(PATH_MAX) else {
            throw .pathTooLong
        }

        let candidatePath: String
        if path.hasPrefix("/") {
            candidatePath = path
        } else {
            let base = currentDirectoryPath ?? FileManager.default.currentDirectoryPath
            guard !base.isEmpty, base.hasPrefix("/"), !Self.containsControlCharacters(base) else {
                throw .inaccessible(path)
            }
            let trimmedBase = base.count > 1 && base.hasSuffix("/") ? String(base.dropLast()) : base
            candidatePath = trimmedBase == "/" ? "/" + path : trimmedBase + "/" + path
        }

        guard !Self.containsControlCharacters(candidatePath),
              candidatePath.utf8.count < Int(PATH_MAX) else {
            throw .pathTooLong
        }

        if Self.isForbiddenDevPath(candidatePath) {
            throw .forbiddenDevPath(path)
        }

        var linkStat = stat()
        if lstat(candidatePath, &linkStat) != 0 {
            switch errno {
            case ENOENT:
                throw .notFound(path)
            case ELOOP:
                throw .symlinkLoop(path)
            default:
                throw .inaccessible(path)
            }
        }

        let linkType = linkStat.st_mode & S_IFMT
        if linkType == S_IFLNK {
            var targetStat = stat()
            if stat(candidatePath, &targetStat) != 0 {
                switch errno {
                case ENOENT:
                    throw .brokenSymlink(path)
                case ELOOP:
                    throw .symlinkLoop(path)
                default:
                    throw .inaccessible(path)
                }
            }
        } else if linkType != S_IFREG && linkType != S_IFDIR {
            throw .unsupportedFileType(path)
        }

        var resolvedBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(candidatePath, &resolvedBuffer) != nil else {
            switch errno {
            case ENOENT:
                throw linkType == S_IFLNK ? .brokenSymlink(path) : .notFound(path)
            case ELOOP:
                throw .symlinkLoop(path)
            default:
                throw .inaccessible(path)
            }
        }

        let canonicalPath = String(cString: resolvedBuffer)
        guard !canonicalPath.isEmpty,
              canonicalPath.hasPrefix("/"),
              !Self.containsControlCharacters(canonicalPath),
              canonicalPath.utf8.count < Int(PATH_MAX) else {
            throw .inaccessible(path)
        }

        if Self.isForbiddenDevPath(canonicalPath) {
            throw .forbiddenDevPath(path)
        }

        var resolvedStat = stat()
        guard stat(canonicalPath, &resolvedStat) == 0 else {
            throw .inaccessible(path)
        }

        let kind: ValidatedTargetKind
        switch resolvedStat.st_mode & S_IFMT {
        case S_IFREG:
            kind = .regularFile
        case S_IFDIR:
            kind = .directory
        default:
            throw .unsupportedFileType(path)
        }

        let url = URL(
            filePath: canonicalPath,
            directoryHint: kind == .directory ? .isDirectory : .notDirectory
        )
        return ValidatedTarget(resolvedFileURL: url, kind: kind)
    }

    static func containsControlCharacters(_ string: String) -> Bool {
        string.unicodeScalars.contains { scalar in
            scalar.value <= 0x1F || scalar.value == 0x7F
        }
    }

    static func isForbiddenDevPath(_ path: String) -> Bool {
        let normalized = URL(filePath: path).standardizedFileURL.path(percentEncoded: false)
        for prefix in ["/dev", "/private/dev"] {
            if normalized == prefix || normalized.hasPrefix(prefix + "/") {
                return true
            }
        }
        return false
    }
}

nonisolated enum ExternalOpenValidationError: Error, Equatable, CustomStringConvertible {
    case emptyPath
    case controlCharacters
    case pathTooLong
    case notFound(String)
    case brokenSymlink(String)
    case symlinkLoop(String)
    case inaccessible(String)
    case unsupportedFileType(String)
    case forbiddenDevPath(String)
    case invalidLineNumber(String)
    case lineOnDirectory(String)
    case requestTooLarge
    case malformedURL

    var description: String {
        switch self {
        case .emptyPath:
            "path must not be empty"
        case .controlCharacters:
            "path must not contain control characters"
        case .pathTooLong:
            "path exceeds maximum length"
        case .notFound(let path):
            "no such file or directory: \(path)"
        case .brokenSymlink(let path):
            "broken symbolic link: \(path)"
        case .symlinkLoop(let path):
            "too many levels of symbolic links: \(path)"
        case .inaccessible(let path):
            "cannot access path: \(path)"
        case .unsupportedFileType(let path):
            "unsupported file type (must be a regular file or directory): \(path)"
        case .forbiddenDevPath(let path):
            "device paths under /dev are not supported: \(path)"
        case .invalidLineNumber(let value):
            "invalid line number '\(value)' (must be 1..2147483647)"
        case .lineOnDirectory(let path):
            "cannot specify a line number for directory: \(path)"
        case .requestTooLarge:
            "request URL exceeds maximum size"
        case .malformedURL:
            "malformed silica:// URL"
        }
    }
}

nonisolated enum ExternalOpenRequest: Sendable, Equatable {
    case welcome
    case open(target: ValidatedTarget, line: Int?)

    static let scheme = "silica"
    static let maxEncodedURLLength = 16 * 1024
    static let maxLineNumber = Int(Int32.max)

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .welcome:
            components.host = "welcome"
        case .open(let target, let line):
            components.host = "open"
            var items = [
                URLQueryItem(name: "path", value: target.resolvedFileURL.path(percentEncoded: false))
            ]
            if let line {
                items.append(URLQueryItem(name: "line", value: String(line)))
            }
            components.queryItems = items
        }
        guard let url = components.url else {
            preconditionFailure("Failed to construct URL for ExternalOpenRequest")
        }
        return url
    }

    /// Parses a `silica://` URL and validates its target on disk.
    static func parse(url: URL) throws(ExternalOpenValidationError) -> ExternalOpenRequest {
        let raw = url.absoluteString
        guard !raw.isEmpty, raw.utf8.count <= Self.maxEncodedURLLength else {
            throw .requestTooLarge
        }
        guard !ValidatedTarget.containsControlCharacters(raw) else {
            throw .malformedURL
        }
        guard let components = URLComponents(string: raw),
              components.scheme?.lowercased() == Self.scheme,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              components.path.isEmpty,
              let host = components.host,
              host == host.lowercased() else {
            throw .malformedURL
        }

        switch host {
        case "welcome":
            guard components.percentEncodedQuery == nil,
                  components.queryItems == nil else {
                throw .malformedURL
            }
            return .welcome

        case "open":
            guard let rawQuery = components.percentEncodedQuery,
                  !rawQuery.isEmpty,
                  Self.hasValidQueryEncoding(rawQuery),
                  let queryItems = components.queryItems,
                  !queryItems.isEmpty else {
                throw .malformedURL
            }

            var decodedPath: String?
            var rawLine: String?

            for item in queryItems {
                switch item.name {
                case "path":
                    guard decodedPath == nil, let value = item.value, !value.isEmpty else {
                        throw .malformedURL
                    }
                    decodedPath = value
                case "line":
                    guard rawLine == nil, let value = item.value, !value.isEmpty else {
                        throw .malformedURL
                    }
                    rawLine = value
                default:
                    throw .malformedURL
                }
            }

            guard let path = decodedPath, path.hasPrefix("/") else {
                throw .malformedURL
            }

            let parsedLine: Int?
            if let rawLine {
                parsedLine = try Self.parseLineNumber(rawLine)
            } else {
                parsedLine = nil
            }

            let target = try ValidatedTarget.validate(path: path, relativeTo: nil)
            if parsedLine != nil, target.kind == .directory {
                throw .lineOnDirectory(path)
            }
            return .open(target: target, line: parsedLine)

        default:
            throw .malformedURL
        }
    }

    /// Parses a single CLI positional target argument (`<file[:line] | directory>`).
    static func parseTargetArgument(
        _ argument: String,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath
    ) throws(ExternalOpenValidationError) -> ExternalOpenRequest {
        guard !argument.isEmpty else {
            throw .emptyPath
        }
        guard !ValidatedTarget.containsControlCharacters(argument) else {
            throw .controlCharacters
        }
        guard argument.utf8.count < Int(PATH_MAX) else {
            throw .pathTooLong
        }

        // Rule 2: Check whether the complete literal path exists (including broken symlinks)
        // before interpreting a trailing :<digits> suffix.
        do {
            let literalTarget = try ValidatedTarget.validate(
                path: argument,
                relativeTo: currentDirectoryPath
            )
            return .open(target: literalTarget, line: nil)
        } catch .notFound {
            // Fall through to check for a trailing :<line> suffix on an existing file.
        } catch let error {
            throw error
        }

        // Rule 3: Only when the literal path is absent, check for a trailing :<suffix>
        // in the final path component.
        if let (basePath, suffix) = Self.splitTrailingColonInLastComponent(of: argument),
           Self.looksLikeLineAttempt(suffix, basePath: basePath, currentDirectoryPath: currentDirectoryPath) {
            let line = try Self.parseLineNumber(suffix)
            let target = try ValidatedTarget.validate(
                path: basePath,
                relativeTo: currentDirectoryPath
            )
            guard target.kind == .regularFile else {
                throw .lineOnDirectory(basePath)
            }
            return .open(target: target, line: line)
        }

        throw .notFound(argument)
    }

    static func parseLineNumber(_ raw: String) throws(ExternalOpenValidationError) -> Int {
        guard !raw.isEmpty,
              raw.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let value = Int(raw),
              value >= 1,
              value <= Self.maxLineNumber else {
            throw .invalidLineNumber(raw)
        }
        return value
    }

    private static func splitTrailingColonInLastComponent(of argument: String) -> (base: String, suffix: String)? {
        guard let colonIndex = argument.lastIndex(of: ":") else {
            return nil
        }
        if let slashIndex = argument.lastIndex(of: "/"), colonIndex < slashIndex {
            return nil
        }
        let base = String(argument[..<colonIndex])
        let suffix = String(argument[argument.index(after: colonIndex)...])
        guard !base.isEmpty, !base.hasSuffix("/"), !suffix.isEmpty else {
            return nil
        }
        return (base, suffix)
    }

    /// Treating `:<suffix>` as a line-number attempt when either `suffix` is all ASCII digits
    /// or the base path actually exists on disk (so e.g. `existing.rb:0` or `existing.rb:-1`
    /// reports an invalid line number).
    private static func looksLikeLineAttempt(
        _ suffix: String,
        basePath: String,
        currentDirectoryPath: String
    ) -> Bool {
        if suffix.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) {
            return true
        }
        let candidatePath: String
        if basePath.hasPrefix("/") {
            candidatePath = basePath
        } else {
            let trimmed = currentDirectoryPath.count > 1 && currentDirectoryPath.hasSuffix("/")
                ? String(currentDirectoryPath.dropLast())
                : currentDirectoryPath
            candidatePath = trimmed == "/" ? "/" + basePath : trimmed + "/" + basePath
        }
        var st = stat()
        return lstat(candidatePath, &st) == 0
    }

    private static func hasValidQueryEncoding(_ rawQuery: String) -> Bool {
        let parts = rawQuery.split(separator: "&", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return false }
        for part in parts {
            guard !part.isEmpty,
                  let eq = part.firstIndex(of: "="),
                  eq > part.startIndex else {
                return false
            }
            if !Self.hasValidPercentEscapes(part) {
                return false
            }
        }
        return true
    }

    private static func hasValidPercentEscapes(_ substring: Substring) -> Bool {
        let bytes = Array(substring.utf8)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x25 /* % */ {
                guard i + 2 < bytes.count,
                      Self.isHexDigit(bytes[i + 1]),
                      Self.isHexDigit(bytes[i + 2]) else {
                    return false
                }
                i += 3
            } else {
                i += 1
            }
        }
        return true
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39)
            || (byte >= 0x41 && byte <= 0x46)
            || (byte >= 0x61 && byte <= 0x66)
    }
}

nonisolated enum CLICommand: Sendable, Equatable {
    case help
    case open(ExternalOpenRequest)
}

nonisolated enum CLIParseError: Error, Equatable {
    case usage(String)
    case validation(ExternalOpenValidationError)

    var exitStatus: Int32 {
        switch self {
        case .usage: 2
        case .validation: 1
        }
    }

    var message: String {
        switch self {
        case .usage(let msg): msg
        case .validation(let err): err.description
        }
    }
}

extension ExternalOpenRequest {
    static let helpText = """
        Usage:
          silica
          silica <file[:line] | directory>
          silica -- <path>
          silica -h | --help

        Open a file or project directory in Silica, or open the Welcome window when
        invoked with no arguments.
        """

    /// Parses command-line arguments (excluding `argv[0]`).
    static func parseCLIArguments(
        _ arguments: [String],
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath
    ) -> Result<CLICommand, CLIParseError> {
        if arguments.isEmpty {
            return .success(.open(.welcome))
        }

        if arguments == ["-h"] || arguments == ["--help"] {
            return .success(.help)
        }

        let targetArg: String
        if arguments[0] == "--" {
            guard arguments.count == 2 else {
                return .failure(.usage(arguments.count < 2 ? "missing path after '--'" : "too many arguments"))
            }
            targetArg = arguments[1]
        } else {
            if arguments[0].hasPrefix("-") && arguments[0] != "-" {
                return .failure(.usage("unknown option: \(arguments[0])"))
            }
            guard arguments.count == 1 else {
                return .failure(.usage("too many arguments"))
            }
            targetArg = arguments[0]
        }

        do {
            let request = try Self.parseTargetArgument(
                targetArg,
                currentDirectoryPath: currentDirectoryPath
            )
            return .success(.open(request))
        } catch let error {
            return .failure(.validation(error))
        }
    }
}
