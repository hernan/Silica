# Ruby Language Support in Silica

This document defines the architecture and requirements for full Ruby language support on the `fruby` branch.

## 1. Baseline & Implemented Support

Before this work on `fruby`, Ruby existed in `SyntaxLanguage` (`Silica/Editor/Syntax/SyntaxLanguage.swift`) with baseline wiring (`gemfile`, `rakefile`, `podfile`, `fastfile`, `brewfile`; `.rb`, `.rake`, `.gemspec`, `.podspec`; `ruby` Markdown fence; `#` line comment; `SyntaxGrammar` regex fallback `Grammars.ruby`) and only `.rb` mapped in `FileIcon.swift`.

This document defines the architecture and implemented requirements for full Ruby language support on the `fruby` branch.

## 2. Architecture: `SyntaxTokenizer` Abstraction

Previously `SyntaxLanguage` was coupled directly to the concrete `SyntaxGrammar` struct (`Silica/Editor/Syntax/SyntaxGrammar.swift`), consumed in three places:
1. `SyntaxHighlighter` (`Silica/Editor/Syntax/SyntaxHighlighter.swift`)
2. `MarkdownHTMLRenderer.highlight(_:language:)` (`Silica/Editor/Preview/MarkdownHTMLRenderer.swift`)
3. `FontsAndColorsSettingsPane.highlightedSample` (`Silica/Views/SettingsView.swift`)

### Decoupling Behind `SyntaxTokenizer`

Introduce a `nonisolated protocol SyntaxTokenizer: Sendable` so any language can use either the declarative regex `SyntaxGrammar` or a dedicated stateful tokenizer/parser without changing `SyntaxHighlighter`, `MarkdownHTMLRenderer`, or `SyntaxTheme`:

```swift
nonisolated protocol SyntaxTokenizer: Sendable {
    /// Tokenizes `text` into UTF-16 `NSRange` tokens bounded by `text.length`.
    /// Where emitted ranges overlap, later tokens in the array take precedence.
    func tokenize(_ text: NSString) -> [SyntaxToken]
}
```

- **`SyntaxGrammar` conforms to `SyntaxTokenizer`:** All 25 other languages keep their existing regex `SyntaxGrammar` definitions unchanged.
- **`SyntaxLanguage.tokenizer` replaces `SyntaxLanguage.grammar`:** Call sites (`SyntaxHighlighter`, `MarkdownHTMLRenderer`, `SettingsView`) depend only on `any SyntaxTokenizer`.
- **Pure-Swift Stateful Ruby Scanner:** `.ruby` uses `RubyTokenizer.shared` (`Silica/Editor/Syntax/RubyTokenizer.swift`) written in pure Swift directly over UTF-16 code units, keeping zero C/external dependencies while accurately handling Ruby's context-sensitive grammar.
- **Future `ruby/prism` (`libprism`) Extension Point:** Because `RubyTokenizer` sits behind `SyntaxTokenizer`, a future Phase 4 can add `SyntaxDiagnostic` / `SyntaxAnalysis` (e.g. a `SyntaxDiagnosticProvider` refinement or `analyze(_:)` hook) and plug in `libprism` as an alternative `.ruby` backend for exact Ruby 3.x/4.x AST highlighting and live syntax checking — without touching `MarkdownHTMLRenderer` or the other 25 languages.

### Key `prism` Design Considerations to Preserve Now

To make plugging in `libprism` straightforward later:
1. **Keep tokenization pure & stateless per call:** `tokenize(_ text: NSString) -> [SyntaxToken]` takes an immutable snapshot and runs off the main thread (`Task.detached` in `SyntaxHighlighter`).
2. **Keep `TokenKind` as the shared vocabulary:** Any backend maps its tokens/AST nodes to `SyntaxTheme`'s existing 15 `TokenKind` cases (or future additive cases).
3. **UTF-16 `NSRange` contract:** `SyntaxToken.range` is always in UTF-16 code units (`NSString` length). The pure-Swift scanner operates on UTF-16 directly; a future `libprism` adapter will convert Prism's UTF-8 byte offsets into UTF-16 `NSRange`s.
4. **Diagnostics-ready pipeline:** `SyntaxHighlighter` already owns the 120ms edit debounce and applies attributes directly to `NSTextStorage` without dirtying undo. Extending it to also read optional diagnostics from a tokenizer fits naturally into that same pass.

## 3. Target Ruby Support Scope

### 3.1 File, Filename, Fence & Shebang Detection (`SyntaxLanguage.swift`, `EditorBuffer.swift`)
- **Filenames (lowercased):** `guardfile`, `capfile`, `vagrantfile`, `berksfile`, `thorfile`, `dangerfile`, `puppetfile`, `appfile`, `deliverfile`, `matchfile`, `scanfile`, `snapfile`, `gymfile`, `config.ru`, `.irbrc`, `.pryrc`, `.simplecov` (in addition to `gemfile`, `rakefile`, `podfile`, `fastfile`, `brewfile`).
- **Extensions:** `ru`, `thor`, `rbx`, `jbuilder`, `rabl`, `ruby` (in addition to `rb`, `rake`, `gemspec`, `podspec`).
- **Markdown fence aliases:** `"ruby": "rb"`, `"irb": "rb"`, `"pry": "rb"`, `"jruby": "rb"`.
- **Shebang detection:** `SyntaxLanguage.init?(url: URL, text: String? = nil)` falls back to `language(fromShebangIn:)` when filename/extension detection returns no match, handling `#!/usr/bin/ruby`, `#!/usr/bin/ruby3.3`, `#!/usr/bin/env [-S] [VAR=val] ruby`, `jruby` (plus versioned `python`, `sh`/`bash`/`zsh`/`fish`, and `node`). `EditorBuffer` stores `private(set) var language: SyntaxLanguage?`, initializes it on open, and refreshes it via `updateLanguage(text:)` on `save()`, `move(to:)`, and `revert(to:)`.

### 3.2 Pure-Swift Stateful Ruby Scanner (`RubyTokenizer`)
Handles Ruby constructs that `SyntaxGrammar` regexes cannot express cleanly:
- **Comments:** `#...` line comments anywhere outside literals (including `x = 1#note`), and `=begin`..`=end` block comments at column 0 of top-level code.
- **Strings & Command Literals:** Multiline `'...'`, `"..."`, and `` `...` `` with backslash escapes.
- **Interpolation (`#{...}` and `#@`/`#$` shorthand):** Mode stack inside `"..."`, `` `...` ``, `/regex/`, interpolated heredocs, and interpolated `%Q`/`%W`/`%I`/`%r`/`%x`/`%` literals so Ruby expressions inside `#{...}` (including nested braces `{ a: 1 }`) highlight normally (`#{` and `}` colored as `.preprocessor`), and `#@ivar`, `#@@cvar`, `#$gvar` shorthand interpolations emit `.preprocessor` + `.variable`.
- **Heredocs:** `<<EOF`, `<<-EOF`, `<<~EOF`, `<<'EOF'`, `<<"EOF"`, `` <<`EOF` `` (including multiple heredocs queued on one line, matched after the newline, disambiguated from bitshift `<<` and array append).
- **Percent Literals:** `%q`, `%Q`, `%w`, `%W`, `%i`, `%I`, `%r`, `%x`, `%s`, and bare `%` (when `canStartRegex`) with paired nested delimiters (`()`, `[]`, `{}`, `<>`) and non-paired delimiters (`|...|`, `/.../`, etc.).
- **Regex Literals vs Division:** Expression-context tracking (`canStartRegex`) plus command-call lookahead (`puts /hello/`, `match /foo/`: space before `/`, non-whitespace after `/`, same-line closer `/`) to distinguish `/pattern/imxoun` (including `[...]` character classes, `#{...}`, and `#@`/`#$`) from `a / b` and `/=`.
- **Symbols & Hash Keys:** `:sym`, `:sym?`, `:sym!`, `:sym=`, `:operator`, `:"..."`, `:'...'`, and modern hash labels `key:` / `bar?:` (without breaking `Foo::Bar` or `a ? b : c`).
- **Variables:** `@ivar`, `@@cvar`, `$gvar`, numbered globals (`$0`–`$9+`), `$-x`, and special globals (`$!`, `$@`, `$?`, `$_`, `$~`, `$&`, `$``, `$'`, `$+`, etc.).
- **Methods, Types & Keywords:** `def self.name?` / `def Foo.bar=` / `def ==`, method calls followed by `(` (`foo?(...)` / `bar!(...)`), capitalized constants/types, full Ruby keyword set (`__FILE__`, `__LINE__`, `__ENCODING__`, `BEGIN`, `END`, `defined?`, `block_given?`, `include`, `extend`, `prepend`, `refine`, `using`, `module_function`, `attr`, `fail`, `loop`, `catch`, `throw`, etc.), `?a`/`?\C-x`/`?\u{...}` character literals, and Ruby numbers (`0x`, `0b`, `0o`, `0d`, underscores, floats, `r`/`i`/`ri` suffixes).

### 3.3 File Icons (`Silica/Support/FileIcon.swift`)
Delegates language-based icon/color lookup to `SyntaxLanguage(url: url)` → `FileIcon.style(for: SyntaxLanguage)` after explicit special-case overrides (`license*`, `.gitignore`/`.gitattributes`, `.plist`, media, archives, `.lock`/`.resolved`, `.txt`/`.log`). `.ruby` maps to `(code, C.red)`, giving consistent icons to all Ruby extensions and filenames (`Gemfile`, `Rakefile`, `Guardfile`, `config.ru`, `.irbrc`, etc.) while preserving `.lock` for `Gemfile.lock`.

### 3.4 Project Indexing (`Silica/Models/QuickOpenModel.swift`)
Add `".bundle"` to `ProjectFileIndex.skippedFolders` so un-gitignored Bundler caches don't flood Quick Open (`⌘P`) or Find in Project (`⇧⌘F`).

### 3.5 Editing & Indentation (`EditorTextView+Editing.swift` — optional follow-up)
`⌘/` line commenting (`#`) and 2-space indentation detection already work for existing Ruby files. Follow-up enhancements can add Ruby block auto-indent on Return (`def`, `class`, `module`, `if`, `unless`, `case`, `begin`, `do ...`) and a language default indent width (`2` for empty `.rb` files).

## 4. Verification Checklist (Manual, Light & Dark Mode)

1. Open a Ruby project with `.rb`, `Gemfile`, `Rakefile`, `.gemspec`, `.rake`, `config.ru`, and an extensionless `#!/usr/bin/env ruby` script.
2. Confirm status bar shows `Ruby`, sidebar icons match, and `Gemfile.lock` keeps its lock icon.
3. Verify highlighting in Light & Dark modes across multiple themes for:
   - `class Foo::Bar < Baz`, `def self.valid?(x)`, `def name=(v)`, `save!`
   - `:sym`, `:"quoted"`, `{ foo: 1, bar?: true }`, `a ? b : c`
   - `@ivar`, `@@cvar`, `$global`, `$!`, `$?`, `$1`
   - Multiline `"..."` / `'...'`, `#{interpolation + { a: 1 }.to_s}`, `` `cmd` ``
   - Heredocs (`<<~SQL ... SQL`, `<<'TXT' ... TXT`, multiple heredocs on one line)
   - Percent literals (`%w(a (b) c)`, `%i[foo bar]`, `%r{https?://.*}i`, `%q|raw|`)
   - `/regex/i` vs `a / b / c`, `#` and `=begin`/`=end` comments, `0d42`, `1r`, `2i`
   - Markdown preview (`⇧⌘V`) with fenced ```` ```ruby ```` blocks
4. Verify `Xcode` builds cleanly with zero new warnings.
