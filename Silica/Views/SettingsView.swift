import SwiftUI

/// Settings (⌘,), laid out like System Settings: a NavigationSplitView with a sidebar
/// of panes and the chosen pane's grouped Form as its detail. About (also what
/// Silica › About Silica shows) is the last pane.
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general, fontsAndColors, editor, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .fontsAndColors: "Fonts & Colors"
            case .editor: "Editor"
            case .about: "About"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .fontsAndColors: "textformat"
            case .editor: "text.cursor"
            case .about: "info"
            }
        }

        var tint: Color {
            switch self {
            case .general: .gray
            case .fontsAndColors: .blue
            case .editor: .orange
            case .about: .gray
            }
        }
    }

    @AppStorage(SettingsView.paneKey) private var pane: Pane = .general
    static let paneKey = "settingsTab"

    /// Panes in the sidebar's sections.
    private static let sections: [[Pane]] = [[.general, .fontsAndColors, .editor], [.about]]

    var body: some View {
        // A fixed sidebar: always shown, one width, no toggle button.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $pane) {
                ForEach(Self.sections, id: \.self) { panes in
                    Section {
                        ForEach(panes) { pane in
                            Label {
                                Text(pane.title)
                            } icon: {
                                SettingsIcon(pane: pane, size: 20)
                            }
                            .tag(pane)
                        }
                    }
                }
            }
            .toolbar(removing: .sidebarToggle)
            // Last, or the column ignores the width and comes out narrower.
            .navigationSplitViewColumnWidth(min: 215, ideal: 215, max: 215)
        } detail: {
            detail
                .formStyle(.grouped)
        }
        .frame(minWidth: 620, idealWidth: 760, maxWidth: .infinity,
               minHeight: 460, idealHeight: 560, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .general: GeneralSettingsPane()
        case .fontsAndColors: FontsAndColorsSettingsPane()
        case .editor: EditorSettingsPane()
        case .about: AboutSettingsView()
        }
    }
}

/// A pane's symbol in white on a tinted rounded square, as System Settings draws them.
struct SettingsIcon: View {
    let pane: SettingsView.Pane
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(pane.tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: pane.symbol)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

/// Appearance, how projects open and show their files, and update checks.
private struct GeneralSettingsPane: View {
    @Bindable private var settings = EditorSettings.shared
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $settings.appearance) {
                    Text("System").tag(EditorSettings.Appearance.system)
                    Text("Light").tag(EditorSettings.Appearance.light)
                    Text("Dark").tag(EditorSettings.Appearance.dark)
                }
                .tabsPickerStyle()
                Picker("Background", selection: $settings.windowBackground) {
                    Text("Translucent").tag(EditorSettings.WindowBackground.translucent)
                    Text("Opaque").tag(EditorSettings.WindowBackground.opaque)
                }
                .tabsPickerStyle()
                Toggle("Glass effect", isOn: $settings.usesGlassEffect)
            }

            Section("Projects") {
                Toggle("Reopen a project’s tabs where you left them", isOn: $settings.restoresTabs)
                Toggle("Keep parent folders in view while scrolling the file tree", isOn: $settings.pinsParentFolders)
            }

            CommandLineSettingsSection()

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
                LabeledContent("Version \(AppInfo.version) (\(AppInfo.build))") {
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            }
        }
    }
}

private struct CommandLineSettingsSection: View {
    private let installer = CLICommandInstaller.standard
    @State private var status = CLICommandInstaller.standard.status
    @State private var isOnPath = true
    @State private var error: Error?

    var body: some View {
        Section("Command Line") {
            LabeledContent {
                button
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("‘silica’ command")
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(subtitleIsWarning ? Color.orange : Color.secondary)
                }
            }
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
        .alert("Couldn’t Update the ‘silica’ Command", isPresented: hasError, presenting: error) { _ in
            Button("OK") {}
        } message: { error in
            Text(error.localizedDescription)
        }
    }

    private var subtitle: String {
        switch status {
        case .installed where !isOnPath:
            "Installed, but ~/.local/bin isn’t in your shell’s PATH. Add it to your shell profile."
        case .installed:
            "Installed in ~/.local/bin/silica"
        case .installedElsewhere:
            "Linked to a different copy of Silica"
        case .conflict:
            "A file that isn’t a link already exists at ~/.local/bin/silica"
        case .notInstalled:
            "Open projects and files from the terminal"
        }
    }

    private var subtitleIsWarning: Bool {
        switch status {
        case .installed: !isOnPath
        case .installedElsewhere, .conflict: true
        case .notInstalled: false
        }
    }

    @ViewBuilder
    private var button: some View {
        switch status {
        case .installed:
            Button("Uninstall") { perform(installer.uninstall) }
        case .installedElsewhere:
            Button("Repair") { perform(installer.install) }
        case .conflict:
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([installer.destinationURL])
            }
        case .notInstalled:
            Button("Install") { perform(installer.install) }
        }
    }

    private var hasError: Binding<Bool> {
        Binding { error != nil } set: { if !$0 { error = nil } }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            self.error = error
        }
        Task { await refresh() }
    }

    private func refresh() async {
        status = installer.status
        isOnPath = await installer.isOnShellPath()
    }
}

/// Editor font and syntax colors, with a live sample, and the sidebar's font size.
/// Changes apply to open windows at once.
private struct FontsAndColorsSettingsPane: View {
    @Bindable private var settings = EditorSettings.shared

    var body: some View {
        Form {
            Section("Font") {
                Text(highlightedSample)
                    .font(Font(settings.editorFont(ofSize: settings.fontSize)))
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.06)))
                    .padding(.vertical, 3)
                Picker("Font", selection: fontFamily) {
                    Text("SF Mono (System)").tag("")
                    Divider()
                    ForEach(EditorSettings.monospacedFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                LabeledContent("Size") {
                    HStack(spacing: 8) {
                        Text("\(Int(settings.fontSize)) pt")
                            .monospacedDigit()
                        Stepper("Size", value: fontSize, in: EditorSettings.fontSizeRange, step: 1)
                            .labelsHidden()
                    }
                }
            }

            Section("Sidebar") {
                LabeledContent("Size") {
                    HStack(spacing: 8) {
                        Text("\(Int(settings.sidebarFontSize)) pt")
                            .monospacedDigit()
                        Stepper("Sidebar size", value: $settings.sidebarFontSize,
                                in: EditorSettings.sidebarFontSizeRange, step: 1)
                            .labelsHidden()
                    }
                }
            }

            Section("Colors") {
                Picker("Syntax colors", selection: $settings.syntaxTheme) {
                    ForEach(SyntaxTheme.allCases) { theme in
                        Text(theme.name).tag(theme)
                    }
                }
            }
        }
    }

    private var sample: String {
        let indent = String(repeating: " ", count: settings.tabWidth)
        return "// Says hello.\nfunc greet(_ name: String) -> String {\n"
            + indent + "let count = 2\n"
            + indent + "return \"Hello, \\(name)!\"\n}"
    }

    /// The sample, colored by the chosen theme the way the editor colors Swift.
    private var highlightedSample: AttributedString {
        let text = sample
        var result = AttributedString(text)
        let theme = settings.syntaxTheme
        for token in SyntaxLanguage.swift.tokenizer.tokenize(text as NSString) {
            guard let range = Range(token.range, in: result) else { continue }
            result[range].foregroundColor = Color(nsColor: theme.color(for: token.kind))
        }
        return result
    }

    /// "" stands for the system font in the picker.
    private var fontFamily: Binding<String> {
        Binding(
            get: { settings.fontFamily ?? "" },
            set: { settings.fontFamily = $0.isEmpty ? nil : $0 }
        )
    }

    private var fontSize: Binding<CGFloat> {
        Binding(
            get: { settings.fontSize },
            set: { settings.setFontSize($0) }
        )
    }
}

/// What the editor shows beside the text, and indentation for new files.
private struct EditorSettingsPane: View {
    @Bindable private var settings = EditorSettings.shared

    var body: some View {
        Form {
            Section("Display") {
                Toggle("Show line numbers", isOn: $settings.showsLineNumbers)
                Toggle("Show indent guides", isOn: $settings.showsIndentGuides)
                Toggle("Show minimap", isOn: $settings.showsMinimap)
                Toggle("Wrap long lines", isOn: $settings.wrapsLines)
            }

            Section {
                Picker("Tab width", selection: $settings.tabWidth) {
                    ForEach(EditorSettings.tabWidths, id: \.self) { width in
                        Text("\(width) spaces").tag(width)
                    }
                }
                Picker("Indent new files with", selection: $settings.indentsWithTabs) {
                    Text("Spaces").tag(false)
                    Text("Tabs").tag(true)
                }
            } header: {
                Text("Indentation")
            } footer: {
                Text("Files that are already indented keep their own style.")
            }
        }
    }
}

private extension View {
    /// The capsule tabs treatment macOS 27 gives a picker, or plain segments on macOS 26.
    @ViewBuilder
    func tabsPickerStyle() -> some View {
        if #available(macOS 27.0, *) {
            pickerStyle(.tabs)
                .buttonBorderShape(.capsule)
        } else {
            pickerStyle(.segmented)
        }
    }
}
