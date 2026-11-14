# Implementation Plan: `SyntaxTokenizer` Abstraction & Pure-Swift Ruby Scanner

This plan covers refactoring Silica's syntax layer behind a `SyntaxTokenizer` abstraction, implementing a pure-Swift stateful Ruby scanner (`RubyTokenizer`), improving Ruby file/icon/shebang/indexing support, and keeping a clean extension point for later investigating `ruby/prism` (`libprism`).

---

## Phase 1 — `SyntaxTokenizer` Abstraction (Zero Behavioral Change)

**Goal:** Decouple `SyntaxLanguage` and its consumers from the concrete `SyntaxGrammar` type while keeping all 26 existing languages working identically.

### Changes
1. **`Silica/Editor/Syntax/SyntaxTokenizer.swift`** *(new file)*
   - Define the minimal stateless UTF-16 protocol (leaving diagnostic types for Phase 4 so no unused types ship ahead of UI support):
     ```swift
     nonisolated protocol SyntaxTokenizer: Sendable {
         /// Tokenizes `text` into UTF-16 `NSRange` tokens bounded by `text.length`.
         /// Where emitted ranges overlap, later tokens in the array take precedence.
         func tokenize(_ text: NSString) -> [SyntaxToken]
     }
     ```
2. **`Silica/Editor/Syntax/SyntaxGrammar.swift`**
   - Conform `SyntaxGrammar: SyntaxTokenizer, @unchecked Sendable`.
3. **`Silica/Editor/Syntax/SyntaxLanguage.swift`**
   - Replace `var grammar: SyntaxGrammar` with `var tokenizer: any SyntaxTokenizer`.
   - Keep `Grammars` `private` for the other 25 regex languages.
4. **Update the 3 consumers of `.grammar`:**
   - `Silica/Editor/Syntax/SyntaxHighlighter.swift`: store `private let tokenizer: any SyntaxTokenizer` from `language.tokenizer` (and call `tokenizer.tokenize(text)`).
   - `Silica/Editor/Preview/MarkdownHTMLRenderer.swift`: `language.tokenizer.tokenize(text)`.
   - `Silica/Views/SettingsView.swift`: `SyntaxLanguage.swift.tokenizer.tokenize(text as NSString)`.

### Verification
- Build `Silica` in Xcode (`Debug`) — zero warnings, identical highlighting across Swift, Markdown preview, and Settings live preview.

---

## Phase 2 — Ruby File Detection, Shebangs, Icons & Indexing

**Goal:** Ensure all Ruby ecosystem files and extensionless Ruby scripts are recognized consistently across the editor, status bar, sidebar, and Quick Open.

### Changes
1. **`Silica/Editor/Syntax/SyntaxLanguage.swift`**
   - Expand `init?(url:text:)` filenames: `guardfile`, `capfile`, `vagrantfile`, `berksfile`, `thorfile`, `dangerfile`, `puppetfile`, `appfile`, `deliverfile`, `matchfile`, `scanfile`, `snapfile`, `gymfile`, `config.ru`, `.irbrc`, `.pryrc`, `.simplecov`.
   - Expand `init?(url:text:)` extensions: `ru`, `thor`, `rbx`, `jbuilder`, `rabl`, `ruby`.
   - Expand `init?(fenceName:)` aliases: `"irb": "rb"`, `"pry": "rb"`, `"jruby": "rb"`.
   - Add `init?(url: URL, text: String? = nil)` with `language(fromShebangIn:)` fallback handling `#!` lines (`ruby`, versioned `ruby3.3`, `jruby`, `env [-S] [VAR=val]`, plus versioned `python`, `sh`/`bash`/`zsh`/`fish`, `node`).
2. **`Silica/Models/EditorBuffer.swift`**
   - Store `private(set) var language: SyntaxLanguage?` instead of recomputing `SyntaxLanguage(url: url)` without content.
   - Resolve via `SyntaxLanguage(url: url, text: text)` on initial load, and refresh via `updateLanguage(text:)` on `save()`, `move(to:)`, and `revert(to:)`.
3. **`Silica/Support/FileIcon.swift`**
   - Delegate language-based icon lookup to `SyntaxLanguage(url: url)` → `style(for: SyntaxLanguage)` after explicit special-case overrides (`license*`, `.gitignore`/`.gitattributes`, `.plist`, media, archives, `.lock`/`.resolved`, `.txt`/`.log`). `.ruby` maps to `(code, C.red)`, automatically covering all Ruby extensions and filenames (`Gemfile`, `Rakefile`, `Guardfile`, `config.ru`, `.irbrc`, etc.) while keeping `Gemfile.lock` as a lock icon.
4. **`Silica/Models/QuickOpenModel.swift`**
   - Add `".bundle"` to `ProjectFileIndex.skippedFolders`.

---

## Phase 3 — Pure-Swift Stateful Ruby Scanner (`RubyTokenizer`)

**Goal:** Replace `Grammars.ruby` with a linear-time, UTF-16 `RubyTokenizer` conforming to `SyntaxTokenizer`.

### File & Core Design
Create **`Silica/Editor/Syntax/RubyTokenizer.swift`** (`nonisolated struct RubyTokenizer: SyntaxTokenizer`), instantiated once (`static let shared = RubyTokenizer()`).

#### 1. Input Representation (Zero UTF-8/UTF-16 Translation)
- Copy UTF-16 code units from `NSString` into a contiguous `[unichar]` buffer via `getCharacters(_:range:)` so indexing is `O(1)` and emitted `NSRange(location: start, length: end - start)` values are exact for `NSTextStorage`.
- Guarantee forward progress on unexpected input and emit `[SyntaxToken]` in strict forward order without overlapping ranges (except explicit inner shorthand/interpolation tokens inside a segmented string).

#### 2. Scanner State Machine
Track explicit state in a `Scanner` struct:
- **`canStartRegex: Bool`**: Distinguishes `/regex/` from division `/`.
  - Set `true` after: BOF, operators/assignment, `,`, `;`, `(`, `[`, `{`, `..`/`...`, `::`, ternary `?`/`:`, hash label `foo:`, and `regexStarterKeywords` (`and`, `begin`, `break`, `case`, `defined?`, `do`, `else`, `elsif`, `ensure`, `if`, `in`, `next`, `not`, `or`, `puts`, `raise`, `fail`, `rescue`, `return`, `then`, `unless`, `until`, `when`, `while`, `yield`).
  - Set `false` after: identifiers, constants, numbers, strings, symbols, regexes, `.`, `)` `]` `}`, `@ivar`, `@@cvar`, `$gvar`, `?a` char literals, non-starter keywords (`true`/`false`/`nil`/`self`/`super`).
- **Context & Delimiter Stack (`[Context]`)**:
  - `.interpolation(braceDepth: Int)`: Ruby code inside `#{...}`, tracking nested `{` / `}` depth so inner blocks/hashes don't prematurely close the interpolation. When `}` drops `braceDepth` to `0`, emit `.preprocessor` and pop back to the enclosing literal.
  - `.delimited(DelimitedLiteral)`: Covers `'...'`, `"..."`, `` `...` ``, `:"..."`, `:'...'`, `%q`/`%Q`/`%w`/`%W`/`%i`/`%I`/`%r`/`%x`/`%s`/`%`, and `/regex/` with `openChar`/`closeChar`/`nestDepth`, `interpolated`, `isRegex`, `inCharClass`, and `kind`. `scanDelimitedSegment(_:)` returns `DelimitedOutcome` (`.interpolation`, `.shorthand`, `.closed`, `.eof`) cleanly separated from stack transitions in `scanDelimitedStep(_:)`.
  - `.heredoc(HeredocLiteral)`: Covers heredoc bodies with `delimiter`, `indented`, and `interpolated`, supporting `#{...}` and `#@`/`#$` shorthand interpolation.
  - `#{` and closing `}` emit `.preprocessor`; `#@ivar`, `#@@cvar`, and `#$gvar` shorthand interpolations emit `.preprocessor` + `.variable`.
- **Pending Heredoc Queue (`[HeredocLiteral]`)**:
  - When `<<`, `<<-`, or `<<~` opens a heredoc in code (guarded by `indented || canStartRegex || precededBySpaceOrStart` for bare identifiers, or quoted delimiters), emit the opener as `.string`, append to `pendingHeredocs`, and keep scanning the rest of the line (`foo(<<~A, <<~B)`).
  - On newline, push `pendingHeredocs.reversed()` onto `contextStack` so they drain in FIFO order, scanning each heredoc body until a matching delimiter line (ignoring leading spaces/tabs for `<<-` and `<<~`).

#### 3. Token Rules Inside Code Mode
In priority order at cursor `index`:
1. **Newlines & spaces:** Consume `\r\n`/`\n`/`\r` (draining `pendingHeredocs`), spaces/tabs.
2. **Column-0 `=begin`..`=end` block comment:** When `contextStack.isEmpty`, at line start, and `=begin` is followed by whitespace/newline/EOF, consume until a line-start `=end` followed by whitespace/newline/EOF (or EOF) → `.comment`.
3. **`#` line comment:** Consume `#` to newline/EOF → `.comment`.
4. **Braces (`{` / `}`):** Track `.interpolation(braceDepth:)`.
5. **Strings & backticks:** `'...'` (non-interpolated, multiline), `"..."` (interpolated, multiline), `` `...` `` (interpolated, multiline) → `.string`.
6. **Percent literals (`%`):** `%q`, `%Q`, `%w`, `%W`, `%i`, `%I`, `%r`, `%x`, `%s`, plus bare `%` when `canStartRegex` with valid non-whitespace/`=` delimiters; supports nested paired delimiters `()` `[]` `{}` `<>`, escapes `\`, and `#{...}`/`#@`/`#$` for interpolated variants → `.string`.
7. **Heredoc openers (`<<`, `<<-`, `<<~`):** Queue heredoc if valid opener; otherwise fall through to operator (`canStartRegex = true`).
8. **Regex literals (`/`):** Never treat `/=` as regex. Start regex when `canStartRegex` is `true`, or in command-call position (`!canStartRegex` with space/tab before `/`, non-whitespace after `/`, and `hasSameLineRegexCloser(from:)`); scan regex body with `[...]` class awareness, `#{...}` / `#@`/`#$` interpolation, and trailing `[imxounse]*` → `.string`.
9. **Variables:** `@[A-Za-z_]\w*`, `@@[A-Za-z_]\w*`, `$[A-Za-z_]\w*`, `$\d+`, `$-[A-Za-z0-9_]`, and special globals (`$!`, `$@`, `$?`, `$_`, `$~`, `$&`, `$``, `$'`, `$+`, etc.) → `.variable`.
10. **Symbols vs `::` vs Ternary `:`:**
    - `::` → advance 2 (`canStartRegex = true`).
    - When not preceded by `isIdentContinue`: `:"..."` / `:'...'` → `.attribute` delimited literal; `:[A-Za-z_]\w*[?!=]?` → `.attribute`; `:operator` (`<=>`, `===`, `[]=`, `==`, `=~`, `!=`, `!~`, `<<`, `>>`, `<=`, `>=`, `**`, `[]`, `+@`, `-@`, `~@`, `!@`, single-char operators) → `.attribute`.
11. **Character literals (`?a`, `?\n`, `?\C-x`, `?\M-x`, `?\u{...}`):** When `canStartRegex` and followed by non-whitespace → `.string`.
12. **Numbers:** `0[xX][0-9a-fA-F_]+`, `0[bB][01_]+`, `0[oO][0-7_]+`, `0[dD][0-9_]+`, decimals/floats `\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?` with `ri`/`r`/`i` suffixes → `.number`.
13. **Identifiers, Keywords, Constants, Method Defs, Calls, Hash Labels:**
    - Scan `[A-Za-z_]\w*[?!]?`:
    - Followed immediately by `:` (not `::` or `:=`) → `.property` (hash key `foo:`, `bar?:`).
    - `def`: emit `.keyword`, then `scanMethodDeclarationName()` handles optional `self.` (`.keyword`) / `Type.` (`.type`) / `obj.` prefix plus method name `[A-Za-z_]\w*[?!=]?` or operator method → `.function`.
    - Keyword table (`Set<String>`) → `.keyword` (updating `canStartRegex` via `regexStarterKeywords`).
    - Uppercase start (`A`–`Z`) → `.type`.
    - Followed by `(` (skipping spaces/tabs) → `.function`.
    - Otherwise plain identifier (`canStartRegex = false`).

### Wiring in `SyntaxLanguage.swift`
- Remove `Grammars.ruby`.
- In `SyntaxLanguage.tokenizer`: `case .ruby: RubyTokenizer.shared`.

---

## Phase 4 — Future Investigation Path: Diagnostics & `ruby/prism` (`libprism`)

Once a diagnostics UI or `libprism` integration is desired, investigating `libprism` requires zero changes to `MarkdownHTMLRenderer`, `SettingsView`, `SyntaxTheme`, or the 25 regex languages:

1. **Extend `SyntaxTokenizer` with diagnostic types (`Silica/Editor/Syntax/SyntaxTokenizer.swift`):**
   - Introduce `SyntaxDiagnostic` (`range: NSRange`, `message: String`, `severity: Severity`), `SyntaxAnalysis` (`tokens: [SyntaxToken]`, `diagnostics: [SyntaxDiagnostic]`), and a default `nonisolated extension SyntaxTokenizer { func analyze(_ text: NSString) -> SyntaxAnalysis { SyntaxAnalysis(tokens: tokenize(text)) } }` so existing tokenizers require no boilerplate.
2. **Package `libprism` as a local SwiftPM C library target** (or vendor `ruby/prism` C sources with `PRISM_EXPORT_SYMBOLS` / `pm_parser_init` / `pm_parse` / `pm_lex` — no Ruby VM needed).
3. **Implement `PrismRubyTokenizer: SyntaxTokenizer`:**
   - Parse UTF-8 bytes (`String` -> `utf8CString` or `Data`).
   - Build a lightweight UTF-8-byte-index → UTF-16-offset lookup table in one linear pass so every Prism `pm_location_t` (`start`, `end` pointers) converts to an exact `NSRange` in `O(1)`.
   - Map `parser.comment_list`, `pm_lex` / AST node types (constants, method defs, calls, symbols, ivars/cvars/gvars, interpolated strings, regexes, heredocs, numbers, keywords) to `TokenKind`.
   - Extract `parser.error_list` and `parser.warning_list` into `[SyntaxDiagnostic]` via `analyze(_:)`.
4. **Compare & Benchmark:** A/B test `RubyTokenizer` vs `PrismRubyTokenizer` on large Rails files, malformed/in-progress buffers, and `MarkdownHTMLRenderer` snippets, then decide whether to ship `PrismRubyTokenizer` (with live syntax error underlines/status indicator in `SyntaxHighlighter` / `StatusBar`) or keep the zero-dependency `RubyTokenizer`.

---

## Testing Strategy & Conformance Suite

Silica does not have a test target yet, but testing the syntax layer is **very straightforward** because `SyntaxTokenizer`, `SyntaxGrammar`, `SyntaxLanguage`, and `RubyTokenizer` only `import Foundation`, are `nonisolated` and `Sendable`, and expose a pure function (`tokenize(_ text: NSString) -> [SyntaxToken]`) with zero UI/AppKit dependencies.

### Test Harness Options (Pick One Before Phase 3)
1. **`SilicaTests` target in `Silica.xcodeproj` (Swift Testing / XCTest):**
   - Keeps the existing `Silica/Editor/Syntax/` folder layout untouched (`@testable import Silica`; `ENABLE_TESTABILITY = YES` is already enabled for `Debug` in `Silica.xcodeproj/project.xcproj`).
   - Run via `⌘U` in Xcode or `xcodebuild test`. Can also test `EditorBuffer`, `GitIgnore`, and `EditorTextView+Editing` later.
   - Trade-off: macOS app-hosted tests launch `Silica.app` as the test host and require adding a unit-test target in Xcode 27's `project.xcproj`.
2. **Local Swift Package (`Packages/SilicaSyntax` with `swift test`):**
   - Houses `SyntaxTokenizer`, `SyntaxGrammar`, `SyntaxLanguage`, and `RubyTokenizer` in a pure-`Foundation` SwiftPM package linked into the `Silica` target (just like `swift-markdown`).
   - Run via `swift test` in `< 1s` from the terminal with no app launch, no signing, and clean hosting for a future `libprism` C target (`Phase 4`).
   - Trade-off: moves the pure-Swift syntax files out of `Silica/Editor/Syntax/` into `Packages/SilicaSyntax/`.

### Phased Test Rollout
- **Test Phase A — Basics & Invariants (built alongside Phase 3):**
  - Small test helper asserting `(substring, TokenKind)` pairs plus structural invariants on every run (`NSMaxRange(token.range) <= text.length`, `token.range.length > 0`, and for `RubyTokenizer`, strictly non-overlapping, ascending ranges).
  - Focused unit tests for every Ruby construct: `#` and `=begin`/`=end` comments, multiline `'...'` / `"..."` / `` `...` ``, nested `#{...}` interpolation, heredocs (`<<`, `<<-`, `<<~`, `<<'EOF'`, multi-heredoc lines), nested percent literals (`%w(a (b) c)`, `%i[...]`, `%r{...}`), `/regex/` vs `a / b`, `:sym` / `:"sym"` / `foo:` vs `Foo::Bar`, `@`/`@@`/`$`/`$!` variables, `def self.foo?` / `def name=`, numbers (`0d`, `0x`, `1r`, `2i`), and `SyntaxLanguage` filename/shebang detection.
- **Test Phase B — Conformance & Regression Suite (post-Phase 3 / alongside Phase 4):**
  - **Unicode / UTF-16 offset tests:** Ruby strings, comments, and identifiers containing emojis and multi-byte UTF-8 characters to guarantee exact `NSRange` alignment (essential once `libprism` UTF-8 -> UTF-16 mapping is added).
  - **Real-world corpus / golden snapshot tests:** Tokenize curated Ruby fixtures (`Gemfile`, `Rakefile`, DSL/metaprogramming, incomplete/mid-edit buffers) and diff token snapshots to catch regressions.
  - **Fuzz / adversarial edge cases:** Unterminated strings/heredocs/comments/interpolations (must terminate cleanly in linear time without out-of-bounds ranges).
  - **Differential check (Phase 4):** Run `RubyTokenizer` and `PrismRubyTokenizer` side-by-side over the same Ruby corpus to spot discrepancies.

---

## Verification Across Phases

- **Build check:** `xcodebuild build -project Silica.xcodeproj -scheme Silica -configuration Debug` succeeds with zero new warnings.
- **Correctness check:** Create a scratch `.rb` test fixture (outside committed source or under `doc/examples/` if desired) exercising every construct (heredocs, nested `%w(a (b) c)`, `/regex/` vs `a / b`, `#{...}` with nested `{}` hashes, `def self.foo?`, `foo: :bar`, `=begin`/`=end`, shebang `bin/script`, `Gemfile`, `Rakefile`) and verify visually in Light & Dark modes and in Markdown ```` ```ruby ```` preview.
