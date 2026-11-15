import AppKit
import OSLog
import SwiftUI

/// Opens what's handed to Silica from outside the project tree: Finder's Open With,
/// files dropped on the Dock icon or the welcome window, the Open panel, `open -a`,
/// and `silica://` URL requests.
///
/// A folder opens as a project. A file opens as a tab in the open project that
/// contains it; otherwise in a window for the recent project or git repository it
/// belongs to, or else for the folder it's in.
final class ExternalOpener {
    static let shared = ExternalOpener()
    private init() {}

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Silica", category: "ExternalOpener")
    private static let maxQueuedRequests = 32
    private static let maxPendingFilesPerProject = 32

    struct OpenItem: Equatable {
        let fileURL: URL
        let line: Int?
    }

    private enum QueuedRequest: Equatable {
        case welcome
        case item(OpenItem)
    }

    /// SwiftUI's window opener, handed over by the menu commands (which exist even
    /// with no window open, as when Finder launches Silica with a file) and by the
    /// windows: the app delegate, where Finder's requests arrive, has no environment
    /// to read it from.
    var openWindow: OpenWindowAction? {
        // Later, as this can be set while SwiftUI is building the menus.
        didSet { DispatchQueue.main.async { self.flush() } }
    }

    /// For the menu commands, whose body runs on every update: sets the opener
    /// only the first time.
    func provide(_ openWindow: OpenWindowAction) {
        if self.openWindow == nil { self.openWindow = openWindow }
    }

    /// Requests that came in before any window could open others (at launch).
    private var queued: [QueuedRequest] = []
    /// Files to open once their project's window has loaded.
    private var pendingFiles: [RecentProject.ID: [OpenItem]] = [:]
    /// Projects whose windows are currently opening so rapid requests coalesce.
    private var openingProjects: Set<RecentProject.ID> = []
    private var workspaces: [WeakWorkspace] = []

    private struct WeakWorkspace {
        weak var workspace: WorkspaceModel?
    }

    func open(_ urls: [URL]) {
        for url in urls {
            if url.isFileURL {
                do {
                    let target = try ValidatedTarget.validate(path: url.path(percentEncoded: false), relativeTo: nil)
                    if openWindow != nil || queued.count < Self.maxQueuedRequests {
                        queued.append(.item(OpenItem(fileURL: target.resolvedFileURL, line: nil)))
                    }
                } catch {
                    Self.logger.error("Rejected file URL: \(error.description, privacy: .public)")
                }
            } else if url.scheme?.lowercased() == ExternalOpenRequest.scheme {
                do {
                    let request = try ExternalOpenRequest.parse(url: url)
                    if openWindow != nil || queued.count < Self.maxQueuedRequests {
                        switch request {
                        case .welcome:
                            queued.append(.welcome)
                        case .open(let target, let line):
                            queued.append(.item(OpenItem(fileURL: target.resolvedFileURL, line: line)))
                        }
                    }
                } catch {
                    Self.logger.error("Rejected silica:// URL: \(error.description, privacy: .public)")
                }
            } else {
                Self.logger.error("Rejected unsupported URL scheme: \(url.scheme ?? "<none>", privacy: .public)")
            }
        }
        flush()
    }

    // MARK: Project windows

    /// Called by a project window once its workspace has loaded; opens the files
    /// that were waiting for it.
    func workspaceDidOpen(_ workspace: WorkspaceModel, projectID: RecentProject.ID) {
        openingProjects.remove(projectID)
        workspaces.removeAll { $0.workspace == nil }
        workspaces.append(WeakWorkspace(workspace: workspace))
        for item in pendingFiles.removeValue(forKey: projectID) ?? [] {
            guard let validated = try? ValidatedTarget.validate(path: item.fileURL.path(percentEncoded: false), relativeTo: nil),
                  validated.kind == .regularFile else { continue }
            open(validated.resolvedFileURL, line: item.line, in: workspace)
        }
        focus(workspace)
    }

    /// Called when a workspace window failed to open its project.
    func workspaceDidFailToOpen(projectID: RecentProject.ID) {
        openingProjects.remove(projectID)
        pendingFiles.removeValue(forKey: projectID)
    }

    func workspaceDidClose(_ workspace: WorkspaceModel) {
        workspaces.removeAll { $0.workspace == nil || $0.workspace === workspace }
    }

    // MARK: Opening

    private func flush() {
        guard let openWindow, !queued.isEmpty else { return }
        let requests = queued
        queued = []
        for request in requests {
            switch request {
            case .welcome:
                openWindow(id: WindowID.welcome)
                NSApp.activate()
            case .item(let item):
                open(item, openWindow: openWindow)
            }
        }
    }

    private func open(_ item: OpenItem, openWindow: OpenWindowAction) {
        let validated: ValidatedTarget
        do {
            validated = try ValidatedTarget.validate(path: item.fileURL.path(percentEncoded: false), relativeTo: nil)
            if item.line != nil && validated.kind == .directory {
                throw ExternalOpenValidationError.lineOnDirectory(item.fileURL.path(percentEncoded: false))
            }
        } catch {
            Self.logger.error("Failed to revalidate item: \(error.localizedDescription, privacy: .public)")
            return
        }

        let url = validated.resolvedFileURL
        if validated.kind == .directory {
            if let workspace = openWorkspace(at: url) {
                focus(workspace)
                return
            }
            do {
                let project = try RecentProjectsStore.shared.register(url)
                if !openingProjects.contains(project.id) {
                    openingProjects.insert(project.id)
                    openWindow(id: WindowID.workspace, value: project.id)
                }
                NSApp.activate()
            } catch {
                Self.logger.error("Failed to register project: \(error.localizedDescription, privacy: .public)")
            }
            return
        }

        if validated.kind == .regularFile {
            if let workspace = openWorkspace(containing: url) {
                open(url, line: item.line, in: workspace)
                focus(workspace)
                return
            }
            do {
                let project = try RecentProjectsStore.shared.register(Self.projectFolder(for: url))
                if pendingFiles[project.id, default: []].count < Self.maxPendingFilesPerProject {
                    pendingFiles[project.id, default: []].append(OpenItem(fileURL: url, line: item.line))
                }
                if !openingProjects.contains(project.id) {
                    openingProjects.insert(project.id)
                    openWindow(id: WindowID.workspace, value: project.id)
                }
                NSApp.activate()
            } catch {
                Self.logger.error("Failed to register project for file: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Focuses the workspace window, deminiaturizing it if minimized, and activates the app.
    private func focus(_ workspace: WorkspaceModel) {
        if let window = workspace.window {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }

    /// Opens `url` as a tab, spelled the way the project spells its own files
    /// (e.g. `/tmp` vs `/private/tmp`) so it matches the tree's rows and other tabs.
    private func open(_ url: URL, line: Int?, in workspace: WorkspaceModel) {
        var target = url
        if let relative = Self.relativeComponents(of: url, in: workspace.rootURL) {
            target = relative.reduce(workspace.rootURL) { $0.appending(path: $1, directoryHint: .notDirectory) }
        }
        workspace.open(target)
        workspace.reveal(target)
        if let line {
            workspace.goToLine(line, in: target)
        }
    }

    /// The open project with root equal to `url`.
    private func openWorkspace(at url: URL) -> WorkspaceModel? {
        let target = Self.components(url)
        return workspaces
            .compactMap(\.workspace)
            .first { Self.components($0.rootURL) == target }
    }

    /// The open project with the deepest root above `url`.
    private func openWorkspace(containing url: URL) -> WorkspaceModel? {
        workspaces
            .compactMap(\.workspace)
            .filter { Self.relativeComponents(of: url, in: $0.rootURL) != nil }
            .max { Self.components($0.rootURL).count < Self.components($1.rootURL).count }
    }

    /// The folder to open a project window on for a file no open project contains:
    /// the deepest recent project above it, else the nearest git repository below
    /// the home folder, else the file's own folder.
    private static func projectFolder(for url: URL) -> URL {
        let recent = RecentProjectsStore.shared.projects
            .map { URL(filePath: $0.path, directoryHint: .isDirectory) }
            .filter { relativeComponents(of: url, in: $0) != nil }
            .max { components($0).count < components($1).count }
        if let recent { return recent }

        let folder = url.deletingLastPathComponent()
        let home = components(URL(filePath: RealHome.path, directoryHint: .isDirectory))
        var candidate = folder
        while components(candidate).count > home.count || !components(candidate).starts(with: home) {
            guard components(candidate).count > 1 else { break }
            let git = candidate.appending(path: ".git").path(percentEncoded: false)
            if FileManager.default.fileExists(atPath: git) { return candidate }
            candidate = candidate.deletingLastPathComponent()
        }
        return folder
    }

    private static func components(_ url: URL) -> [String] {
        url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    }

    /// Path components of `url` below `root`, or `nil` if it isn't inside it.
    private static func relativeComponents(of url: URL, in root: URL) -> [String]? {
        let rootComponents = components(root)
        let urlComponents = components(url)
        guard urlComponents.count > rootComponents.count, urlComponents.starts(with: rootComponents) else { return nil }
        return Array(urlComponents.dropFirst(rootComponents.count))
    }
}
