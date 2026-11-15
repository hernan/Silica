import Darwin
import Foundation

nonisolated enum SafeFileReadResult: Sendable, Equatable {
    case data(Data)
    case tooLarge(Int64)
    case unreadable(String)
}

nonisolated enum SafeFileAccess {
    /// Returns `true` only if `url` is a local file URL that resolves (following symlinks)
    /// to an existing regular file outside `/dev`.
    static func isRegularFile(at url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let path = url.path(percentEncoded: false)
        guard let target = try? ValidatedTarget.validate(path: path, relativeTo: nil) else {
            return false
        }
        return target.kind == .regularFile
    }

    /// Reads a regular file up to `maxBytes` using `O_NONBLOCK | O_CLOEXEC` and `fstat`.
    /// Rejects devices, FIFOs, sockets, directories, broken symlinks, and files exceeding `maxBytes`.
    static func readRegularFile(at url: URL, maxBytes: Int) -> SafeFileReadResult {
        guard url.isFileURL else {
            return .unreadable("Not a local file URL.")
        }
        guard maxBytes >= 0 else {
            return .unreadable("Invalid byte limit.")
        }

        let rawPath = url.path(percentEncoded: false)
        let validated: ValidatedTarget
        do {
            validated = try ValidatedTarget.validate(path: rawPath, relativeTo: nil)
        } catch let error {
            return .unreadable(error.description)
        }

        guard validated.kind == .regularFile else {
            return .unreadable("“\(url.lastPathComponent)” is not a regular file.")
        }

        let canonicalPath = validated.resolvedFileURL.path(percentEncoded: false)
        let fd = Darwin.open(canonicalPath, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let message = String(cString: strerror(errno))
            return .unreadable(message)
        }
        defer { Darwin.close(fd) }

        var fdStat = stat()
        guard fstat(fd, &fdStat) == 0 else {
            let message = String(cString: strerror(errno))
            return .unreadable(message)
        }
        guard (fdStat.st_mode & S_IFMT) == S_IFREG else {
            return .unreadable("“\(url.lastPathComponent)” is not a regular file.")
        }

        let reportedSize = Int64(fdStat.st_size)
        if reportedSize > Int64(maxBytes) {
            return .tooLarge(reportedSize)
        }

        let limitPlusOne = maxBytes + 1
        var result = Data()
        if reportedSize > 0 {
            result.reserveCapacity(Int(min(reportedSize, Int64(maxBytes))))
        }

        let chunkSize = min(64 * 1024, max(1, limitPlusOne))
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        while result.count < limitPlusOne {
            let remaining = limitPlusOne - result.count
            let toRead = min(chunkSize, remaining)
            let bytesRead = buffer.withUnsafeMutableBytes { ptr -> Int in
                guard let base = ptr.baseAddress else { return 0 }
                return Darwin.read(fd, base, toRead)
            }
            if bytesRead > 0 {
                result.append(buffer, count: bytesRead)
            } else if bytesRead == 0 {
                break
            } else {
                if errno == EINTR { continue }
                let message = String(cString: strerror(errno))
                return .unreadable(message)
            }
        }

        if result.count > maxBytes {
            return .tooLarge(max(reportedSize, Int64(result.count)))
        }

        return .data(result)
    }

    /// Convenience wrapper that returns `Data` only when `readRegularFile` succeeds within `maxBytes`.
    static func readData(at url: URL, maxBytes: Int) -> Data? {
        if case .data(let data) = readRegularFile(at: url, maxBytes: maxBytes) {
            return data
        }
        return nil
    }

    /// Safely reads up to the first `maxBytes` of a regular file (e.g. for header sniffing),
    /// without failing if the file itself is larger than `maxBytes`.
    static func readPrefix(at url: URL, maxBytes: Int) -> Data? {
        guard url.isFileURL, maxBytes > 0 else { return nil }
        let rawPath = url.path(percentEncoded: false)
        guard let validated = try? ValidatedTarget.validate(path: rawPath, relativeTo: nil),
              validated.kind == .regularFile else {
            return nil
        }

        let canonicalPath = validated.resolvedFileURL.path(percentEncoded: false)
        let fd = Darwin.open(canonicalPath, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }

        var fdStat = stat()
        guard fstat(fd, &fdStat) == 0, (fdStat.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }

        var result = Data()
        let chunkSize = min(8192, maxBytes)
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        while result.count < maxBytes {
            let toRead = min(chunkSize, maxBytes - result.count)
            let bytesRead = buffer.withUnsafeMutableBytes { ptr -> Int in
                guard let base = ptr.baseAddress else { return 0 }
                return Darwin.read(fd, base, toRead)
            }
            if bytesRead > 0 {
                result.append(buffer, count: bytesRead)
            } else if bytesRead == 0 {
                break
            } else {
                if errno == EINTR { continue }
                return nil
            }
        }
        return result
    }
}

nonisolated enum RealHome {
    /// The user's home directory (not the sandbox container).
    static let path: String = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }()
}

nonisolated extension String {
    var trimmingTrailingSlash: String {
        count > 1 && hasSuffix("/") ? String(dropLast()) : self
    }
}
