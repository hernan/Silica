# Silica Architecture & Codebase Reference

This document summarizes the structure, conventions, and runtime architecture of Silica for future development on the `fruby` branch.

## 1. Overview & Build Configuration

- **Platform:** macOS 26.0+ (`MACOSX_DEPLOYMENT_TARGET = 26.0`), built with Xcode 27+ (`Silica.xcodeproj/project.xcproj`).
- **UI & Frameworks:** SwiftUI for windows, layout, settings, and sidebar; AppKit (`NSTextView`, TextKit 2, `NSScrollView`, `NSRulerView`, `NSView`, `PDFView`, `AVPlayer`) for the editor and media viewers; `WebKit` (`WKWebView` in `DocumentPreview.swift`) for previews.
- **Concurrency Model:** `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY = YES` (`Silica.xcodeproj/project.xcproj`). Types meant to run off the main actor (such as `SyntaxLanguage`, `SyntaxGrammar`, `SyntaxTheme`, `PreviewFormat`, `MarkdownHTMLRenderer`, `ProjectFileIndex`, `ProjectSearch`, `GitIgnoreFile`) are explicitly marked `nonisolated`.
- **Swift Packages:**
  - `swift-markdown` (`Markdown`) — GitHub-flavored Markdown AST parsing for `MarkdownHTMLRenderer`.
  - `Sparkle` — automatic updates (`AppUpdater.swift`, `docs/appcast.xml`).
- **Tests:** No automated test target exists yet in `Silica.xcodeproj/project.xcproj`. Verification is performed by building in Xcode (`⌘R`) and manually testing in both light and dark appearances (`CONTRIBUTING.md`).
- **Note on `docs/` vs `doc/`:** `docs/` at the repo root is used for GitHub Pages / Sparkle (`docs/appcast.xml`, `docs/.nojekyll`). Development reference docs live in `doc/`.

## 2. Directory Structure

| Folder | Purpose | Key Files |
|---|---|---|
| `Silica/App` | App entry point, delegate, menu commands | `SilicaApp.swift`, `AppDelegate.swift`, `AppCommands.swift`, `MenuShortcutRefresh.swift` |
| `Silica/Views` | SwiftUI scenes, sidebar, editor host, overlays, settings | `WorkspaceView.swift`, `EditorArea.swift`, `FileTreeView.swift`, `PinnedFolderTracker.swift`, `ProjectSearchView.swift`, `QuickOpenPanel.swift`, `SettingsView.swift`, `SettingsForm.swift`, `AboutSettingsView.swift`, `WelcomeView.swift` |
| `Silica/Editor` | AppKit TextKit 2 editor, editing commands, gutter, minimap | `TextController.swift`, `EditorTextView.swift`, `EditorTextView+Editing.swift`, `LineNumberRulerView.swift`, `MinimapView.swift` |
| `Silica/Editor/Syntax` | Tokenizer protocol, regex grammar engine, stateful Ruby scanner, language definitions, themes, async highlighter | `SyntaxTokenizer.swift`, `SyntaxGrammar.swift`, `RubyTokenizer.swift`, `SyntaxLanguage.swift`, `SyntaxHighlighter.swift`, `SyntaxTheme.swift` |
| `Silica/Editor/Preview` | Rendered HTML/Markdown/CSV previews | `PreviewFormat.swift`, `DocumentPreview.swift`, `MarkdownHTMLRenderer.swift`, `CSVHTMLRenderer.swift` |
| `Silica/Models` | Workspace state, buffers, file tree, gitignore, search, persistence | `WorkspaceModel.swift`, `EditorBuffer.swift`, `EditorSettings.swift`, `FileNode.swift`, `GitIgnore.swift`, `ProjectSearchModel.swift`, `QuickOpenModel.swift`, `FuzzyMatcher.swift`, `TreeFilter.swift`, `ProjectSessionStore.swift`, `RecentProjectsStore.swift` |
| `Silica/Support` | AppKit/Finder/FSEvents/window/icon helpers | `FileIcon.swift`, `ExternalOpener.swift`, `KeyWorkspace.swift`, `ProjectOpener.swift`, `ProjectWatcher.swift`, `UnsavedChangesGuard.swift`, `AppUpdater.swift`, `VisualEffectView.swift` |
| `Config` | Merged `Info.plist` keys (`CFBundleDocumentTypes` for `public.text`, `public.data`, `public.folder`, Sparkle keys) | `Config/Info.plist` |

## 3. Core Architecture & Data Flow

### Windows & Workspace Lifecycle
- `SilicaApp` defines three scenes: `WindowID.welcome`, `WindowGroup` for `WindowID.workspace` (keyed by `RecentProject.ID`), and `WindowID.settings`.
- `WorkspaceWindow` resolves security-scoped bookmarks via `RecentProjectsStore`, instantiates `WorkspaceModel(rootURL:)`, and tracks key windows via `KeyWindowTracker` → `KeyWorkspace.shared`.
- `WorkspaceModel` owns:
  - The lazy `FileNode` tree (`root`) with `.gitignore` and `.git/info/exclude` evaluation (`GitIgnoreFile`, `GitIgnoreStack`).
  - `ProjectWatcher` (CoreServices `FSEventStreamRef`) watching the project folder and ignoring `/.git/` churn, triggering `workspace.refresh()`.
  - `openTabs: [URL]`, `activeTab: URL?`, and `buffers: [URL: EditorBuffer]`.
  - `QuickOpenModel` (`⌘P` / `⌘L` Go to Line) and `ProjectSearchModel` (`⇧⌘F`), both backed by `ProjectFileIndex.scan(root:)`.
  - Session persistence (`ProjectSessionStore`) saving open tabs, cursor offset, top visible line, and sidebar visibility.

### Buffers & Content Types (`EditorBuffer`)
When opening a `URL`, `EditorBuffer` classifies the file in order:
1. **Video** (`isVideo`): `UTType.conforms(to: .movie)`, with a binary-sniff exception for `.ts` / `.mts` so TypeScript files are not treated as MPEG transport streams.
2. **Image / PDF** (`isImage`, `isPDF`): ImageIO / PDFKit up to `maxPreviewSize` (200 MB). SVG is explicitly excluded from `isImage` so it opens as editable text.
3. **Text vs Binary / Too Large**: Up to `maxFileSize` (20 MB). Reads `Data`, checks `looksBinary` (NUL byte in first 8192 bytes), decodes UTF-8 or falls back to `NSString.stringEncoding(for:...)`.
4. **Text Editor**: Creates `TextController(text: text, language: resolvedLanguage)` via `SyntaxLanguage(url: url, text: text)` (stored on `EditorBuffer.language` and refreshed on `save()`, `move(to:)`, and `revert(to:)`) and computes `PreviewFormat(url: url)`.
5. **Disk Sync**: Tracks `DiskSnapshot` (modification date, byte size, SHA-256 digest) to auto-reload clean buffers changed externally and prompt before overwriting dirty buffers.

### Editor & TextKit 2 (`TextController`, `EditorTextView`)
- `TextController` creates an `NSScrollView` + `EditorTextView(usingTextLayoutManager: true)` (TextKit 2) per tab, keeping undo history, selection, and scroll position across tab switches.
- `LineNumberRulerView` draws logical line numbers on the transparent glass card using `NSTextLayoutManager` fragments.
- `MinimapView` renders a 100pt live character-block overview directly from `NSTextStorage` foreground colors.
- `EditorTextView` detects per-file indentation (`Indentation`: `usesTabs`, `width` ∈ {2, 4, 8} or `EditorSettings.shared.tabWidth` for unindented/new files), draws vertical indent guides, and implements editing commands in `EditorTextView+Editing.swift`:
  - `insertNewline(_:)` (auto-indent, bracket/colon block opening, `{|}` pair splitting)
  - `insertTab(_:)` / `insertBacktab(_:)` / `indentLines(_:)` / `outdentLines(_:)`
  - `toggleComment(_:)` (`lineComment` first, falling back to `blockComment`)
  - `moveLinesUp(_:)`, `moveLinesDown(_:)`, `duplicateLinesUp(_:)`, `duplicateLinesDown(_:)`

### Syntax Highlighting (`Silica/Editor/Syntax`)
- `SyntaxTokenizer`: `nonisolated protocol` (`Sendable`) requiring `func tokenize(_ text: NSString) -> [SyntaxToken]`. Emits UTF-16 `NSRange` tokens bounded by `text.length`, where later tokens win on overlap.
- `SyntaxLanguage`: `nonisolated enum` (currently 26 cases) providing:
  - `init?(url:text:)` — exact filename matching (lowercased), `dockerfile.*` prefix matching, `pathExtension.lowercased()`, and `#!` shebang fallback when `text` is supplied.
  - `init?(fenceName:)` — Markdown code-fence resolution with aliases.
  - `displayName` — shown in the bottom-right `StatusBar` (`EditorArea.swift`).
  - `lineComment` and `blockComment` — used by `EditorTextView.toggleComment(_:)`.
  - `opensBlockWithColon` — used by `EditorTextView.insertNewline(_:)`.
  - `tokenizer: any SyntaxTokenizer` — returns `RubyTokenizer.shared` for `.ruby` and static `SyntaxGrammar` instances for the other 25 languages; consumed by `SyntaxHighlighter`, `MarkdownHTMLRenderer`, and `SettingsView`.
- `SyntaxGrammar`: Conforms to `SyntaxTokenizer` (`@unchecked Sendable`). Two-phase `NSRegularExpression` tokenizer (with `[.anchorsMatchLines]`):
  1. **`rules`**: Applied in declaration order; later rules overwrite earlier tokens where ranges overlap. Supports capture groups (`SyntaxPattern(..., group: N)`).
  2. **`spans`**: Combined into a single alternation `(\(p1))|(\(p2))|...` and scanned left-to-right so whichever comment/string starts first wins and overrides phase 1. **Constraint:** Span patterns must only use non-capturing groups `(?:...)` because capture group indices map 1-to-1 to `spanKinds`.
- `RubyTokenizer`: Conforms to `SyntaxTokenizer` (`RubyTokenizer.shared`). Single-pass stateful UTF-16 scanner handling nested `#{...}` and `#@`/`#$` shorthand interpolation, heredocs, percent literals, `/regex/` vs division disambiguation (including command-call forms), multiline strings, `=begin`..`=end` comments, symbols vs `::` vs hash labels, and Ruby numbers.
- `SyntaxHighlighter`: Runs synchronously on open for files `<= 100_000` UTF-16 units, debounces edits by 120 ms on a detached task for files `<= 2_000_000` UTF-16 units, and applies only `.foregroundColor` directly to `NSTextStorage` (avoiding dirty state / undo registration).
- `SyntaxTheme`: 9 themes (`one`, `github`, `xcode`, `solarized`, `catppuccin`, `gruvbox`, `tokyoNight`, `rosePine`, `dracula`), each with light and dark palettes dynamically resolved via `NSAppearance` and shared with `MarkdownHTMLRenderer` via `hexPair(for:)`.

### Previews (`Silica/Editor/Preview`)
- `PreviewFormat` supports `.markdown`, `.csv`, `.tsv`, and `.html` (toggled with `⇧⌘V`).
- `MarkdownHTMLRenderer` walks `swift-markdown`'s `Document` AST, emits `data-line` attributes for scroll sync, and highlights fenced code blocks via `SyntaxLanguage(fenceName:)` and `SyntaxTokenizer.tokenize(_:)`.
