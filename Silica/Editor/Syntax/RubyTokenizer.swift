import Foundation

/// Stateful UTF-16 scanner for Ruby.
///
/// Handles Ruby constructs that `SyntaxGrammar`'s flat regex spans cannot model cleanly:
/// nested `#{...}` interpolation, `<<` / `<<-` / `<<~` heredocs, nested percent literals
/// (`%w(...)`, `%r{...}`, etc.), `/regex/` vs division disambiguation, multiline strings,
/// `=begin`..`=end` comments, symbols vs `::` vs hash labels, and special globals.
nonisolated struct RubyTokenizer: SyntaxTokenizer {
    static let shared = RubyTokenizer()

    func tokenize(_ text: NSString) -> [SyntaxToken] {
        let length = text.length
        guard length > 0 else { return [] }
        var chars = [unichar](repeating: 0, count: length)
        text.getCharacters(&chars, range: NSRange(location: 0, length: length))
        var scanner = Scanner(chars: chars)
        return scanner.run()
    }
}

// MARK: - Scanner

private nonisolated extension RubyTokenizer {
    enum ASCII {
        static let tab: unichar = 0x09
        static let newline: unichar = 0x0A
        static let carriageReturn: unichar = 0x0D
        static let space = unichar(UInt8(ascii: " "))
        static let bang = unichar(UInt8(ascii: "!"))
        static let doubleQuote = unichar(UInt8(ascii: "\""))
        static let hash = unichar(UInt8(ascii: "#"))
        static let dollar = unichar(UInt8(ascii: "$"))
        static let percent = unichar(UInt8(ascii: "%"))
        static let ampersand = unichar(UInt8(ascii: "&"))
        static let singleQuote = unichar(UInt8(ascii: "'"))
        static let lParen = unichar(UInt8(ascii: "("))
        static let rParen = unichar(UInt8(ascii: ")"))
        static let star = unichar(UInt8(ascii: "*"))
        static let plus = unichar(UInt8(ascii: "+"))
        static let comma = unichar(UInt8(ascii: ","))
        static let minus = unichar(UInt8(ascii: "-"))
        static let dot = unichar(UInt8(ascii: "."))
        static let slash = unichar(UInt8(ascii: "/"))
        static let zero = unichar(UInt8(ascii: "0"))
        static let one = unichar(UInt8(ascii: "1"))
        static let seven = unichar(UInt8(ascii: "7"))
        static let nine = unichar(UInt8(ascii: "9"))
        static let colon = unichar(UInt8(ascii: ":"))
        static let semicolon = unichar(UInt8(ascii: ";"))
        static let lessThan = unichar(UInt8(ascii: "<"))
        static let equals = unichar(UInt8(ascii: "="))
        static let greaterThan = unichar(UInt8(ascii: ">"))
        static let question = unichar(UInt8(ascii: "?"))
        static let at = unichar(UInt8(ascii: "@"))
        static let upperA = unichar(UInt8(ascii: "A"))
        static let upperB = unichar(UInt8(ascii: "B"))
        static let upperC = unichar(UInt8(ascii: "C"))
        static let upperD = unichar(UInt8(ascii: "D"))
        static let upperE = unichar(UInt8(ascii: "E"))
        static let upperF = unichar(UInt8(ascii: "F"))
        static let upperI = unichar(UInt8(ascii: "I"))
        static let upperM = unichar(UInt8(ascii: "M"))
        static let upperO = unichar(UInt8(ascii: "O"))
        static let upperQ = unichar(UInt8(ascii: "Q"))
        static let upperW = unichar(UInt8(ascii: "W"))
        static let upperX = unichar(UInt8(ascii: "X"))
        static let upperZ = unichar(UInt8(ascii: "Z"))
        static let lBracket = unichar(UInt8(ascii: "["))
        static let backslash = unichar(UInt8(ascii: "\\"))
        static let rBracket = unichar(UInt8(ascii: "]"))
        static let caret = unichar(UInt8(ascii: "^"))
        static let underscore = unichar(UInt8(ascii: "_"))
        static let backtick = unichar(UInt8(ascii: "`"))
        static let lowerA = unichar(UInt8(ascii: "a"))
        static let lowerB = unichar(UInt8(ascii: "b"))
        static let lowerD = unichar(UInt8(ascii: "d"))
        static let lowerE = unichar(UInt8(ascii: "e"))
        static let lowerF = unichar(UInt8(ascii: "f"))
        static let lowerI = unichar(UInt8(ascii: "i"))
        static let lowerM = unichar(UInt8(ascii: "m"))
        static let lowerN = unichar(UInt8(ascii: "n"))
        static let lowerO = unichar(UInt8(ascii: "o"))
        static let lowerQ = unichar(UInt8(ascii: "q"))
        static let lowerR = unichar(UInt8(ascii: "r"))
        static let lowerS = unichar(UInt8(ascii: "s"))
        static let lowerU = unichar(UInt8(ascii: "u"))
        static let lowerW = unichar(UInt8(ascii: "w"))
        static let lowerX = unichar(UInt8(ascii: "x"))
        static let lowerZ = unichar(UInt8(ascii: "z"))
        static let lBrace = unichar(UInt8(ascii: "{"))
        static let pipe = unichar(UInt8(ascii: "|"))
        static let rBrace = unichar(UInt8(ascii: "}"))
        static let tilde = unichar(UInt8(ascii: "~"))
    }

    struct DelimitedLiteral {
        /// `0` when the delimiter is not paired (e.g. `"`, `'`, `/`, `|`).
        let openChar: unichar
        let closeChar: unichar
        var nestDepth: Int
        let interpolated: Bool
        let isRegex: Bool
        var inCharClass: Bool
        let kind: TokenKind
    }

    enum DelimitedOutcome {
        case interpolation(DelimitedLiteral)
        case shorthand(DelimitedLiteral)
        case closed
        case eof
    }

    struct HeredocLiteral {
        let delimiter: [unichar]
        let indented: Bool
        let interpolated: Bool
    }

    enum Context {
        case interpolation(braceDepth: Int)
        case delimited(DelimitedLiteral)
        case heredoc(HeredocLiteral)
    }

    struct Scanner {
        let chars: [unichar]
        let length: Int
        var index = 0
        var tokens: [SyntaxToken] = []
        var canStartRegex = true
        var contextStack: [Context] = []
        var pendingHeredocs: [HeredocLiteral] = []

        init(chars: [unichar]) {
            self.chars = chars
            self.length = chars.count
        }

        mutating func run() -> [SyntaxToken] {
            while index < length {
                let before = index
                let stackDepth = contextStack.count
                switch contextStack.last {
                case nil, .interpolation:
                    scanCodeStep()
                case .delimited(let literal):
                    scanDelimitedStep(literal)
                case .heredoc(let heredoc):
                    scanHeredocStep(heredoc)
                }
                // Guarantee forward progress even on unexpected input.
                if index == before && contextStack.count >= stackDepth {
                    index += 1
                }
            }
            return tokens
        }

        // MARK: Code scanning

        private mutating func scanCodeStep() {
            let c = chars[index]

            // Newlines drain any heredocs opened earlier on this line.
            if isNewline(c) {
                consumeNewline()
                if !pendingHeredocs.isEmpty {
                    for heredoc in pendingHeredocs.reversed() {
                        contextStack.append(.heredoc(heredoc))
                    }
                    pendingHeredocs.removeAll(keepingCapacity: true)
                }
                return
            }

            if c == ASCII.space || c == ASCII.tab {
                while index < length && (chars[index] == ASCII.space || chars[index] == ASCII.tab) {
                    index += 1
                }
                return
            }

            // `=begin` .. `=end` block comment at column 0 of top-level code.
            if c == ASCII.equals, contextStack.isEmpty, isAtLineStart(index), matchesWord(Self.beginDirective, at: index) {
                scanBlockComment()
                return
            }

            // `#` single-line comment.
            if c == ASCII.hash {
                let start = index
                while index < length && !isNewline(chars[index]) { index += 1 }
                emit(.comment, start..<index)
                return
            }

            // Braces: track interpolation boundaries and block/hash nesting.
            if c == ASCII.lBrace {
                if case .interpolation(let depth) = contextStack.last {
                    contextStack[contextStack.count - 1] = .interpolation(braceDepth: depth + 1)
                }
                index += 1
                canStartRegex = true
                return
            }
            if c == ASCII.rBrace {
                if case .interpolation(let depth) = contextStack.last {
                    if depth > 1 {
                        contextStack[contextStack.count - 1] = .interpolation(braceDepth: depth - 1)
                        index += 1
                        canStartRegex = false
                        return
                    }
                    emit(.preprocessor, index..<(index + 1))
                    index += 1
                    contextStack.removeLast()
                    return
                }
                index += 1
                canStartRegex = false
                return
            }

            // Strings and backtick commands.
            if c == ASCII.singleQuote {
                startDelimited(open: 0, close: ASCII.singleQuote, interpolated: false, isRegex: false, kind: .string)
                return
            }
            if c == ASCII.doubleQuote {
                startDelimited(open: 0, close: ASCII.doubleQuote, interpolated: true, isRegex: false, kind: .string)
                return
            }
            if c == ASCII.backtick {
                startDelimited(open: 0, close: ASCII.backtick, interpolated: true, isRegex: false, kind: .string)
                return
            }

            // Percent literals (`%w(...)`, `%q|...|`, `%r{...}`, `%(...)`).
            if c == ASCII.percent, tryStartPercentLiteral() {
                return
            }

            // Heredoc openers (`<<EOF`, `<<-EOF`, `<<~EOF`, `<<'EOF'`, `<<"EOF"`).
            if c == ASCII.lessThan, index + 1 < length, chars[index + 1] == ASCII.lessThan, tryScanHeredocOpener() {
                return
            }

            // Regex literals (`/pattern/flags`) vs division (`/`).
            if c == ASCII.slash, tryStartRegexLiteral() {
                return
            }

            // Instance/class/global variables.
            if c == ASCII.at || c == ASCII.dollar, tryScanVariable() {
                return
            }

            // Symbols (`:sym`, `:"sym"`, `:'sym'`) vs `::` vs ternary `:`.
            if c == ASCII.colon {
                scanColonOrSymbol()
                return
            }

            // Character literals (`?a`, `?\n`) vs ternary `?`.
            if c == ASCII.question {
                scanQuestionOrCharLiteral()
                return
            }

            // Numbers (`0x`, `0b`, `0o`, `0d`, decimals, floats, `1r`, `2i`).
            if isDigit(c) {
                scanNumber()
                return
            }

            // Identifiers, keywords, constants, `def` declarations, calls, and hash labels.
            if isIdentStart(c) {
                scanIdentifierOrKeyword()
                return
            }

            // Punctuation & operators.
            scanPunctuationOrOperator(c)
        }

        // MARK: Comments & Literals

        private mutating func scanBlockComment() {
            let start = index
            index += Self.beginDirective.count
            while index < length {
                if isNewline(chars[index]) {
                    consumeNewline()
                    if index < length, matchesWord(Self.endDirective, at: index) {
                        index += Self.endDirective.count
                        while index < length && !isNewline(chars[index]) { index += 1 }
                        break
                    }
                } else {
                    index += 1
                }
            }
            emit(.comment, start..<index)
        }

        private mutating func startDelimited(
            open: unichar,
            close: unichar,
            interpolated: Bool,
            isRegex: Bool,
            kind: TokenKind,
            prefixLength: Int = 1
        ) {
            let start = index
            index += prefixLength
            emit(kind, start..<index)
            contextStack.append(.delimited(DelimitedLiteral(
                openChar: open,
                closeChar: close,
                nestDepth: open == 0 ? 0 : 1,
                interpolated: interpolated,
                isRegex: isRegex,
                inCharClass: false,
                kind: kind
            )))
        }

        private mutating func scanDelimitedStep(_ initial: DelimitedLiteral) {
            var literal = initial
            switch scanDelimitedSegment(&literal) {
            case .interpolation(let updated):
                contextStack[contextStack.count - 1] = .delimited(updated)
                contextStack.append(.interpolation(braceDepth: 1))
                canStartRegex = true
            case .shorthand(let updated):
                contextStack[contextStack.count - 1] = .delimited(updated)
            case .closed:
                contextStack.removeLast()
                canStartRegex = false
            case .eof:
                contextStack.removeLast()
            }
        }

        private mutating func scanDelimitedSegment(_ literal: inout DelimitedLiteral) -> DelimitedOutcome {
            let spanStart = index

            while index < length {
                let c = chars[index]

                if c == ASCII.backslash {
                    index += 1
                    if index < length { index += 1 }
                    continue
                }

                if literal.interpolated, c == ASCII.hash, index + 1 < length {
                    let next = chars[index + 1]
                    if next == ASCII.lBrace {
                        emit(literal.kind, spanStart..<index)
                        emit(.preprocessor, index..<(index + 2))
                        index += 2
                        return .interpolation(literal)
                    }
                    if (next == ASCII.at || next == ASCII.dollar),
                       let varEnd = shorthandInterpolationEnd(at: index + 1) {
                        emit(literal.kind, spanStart..<index)
                        emit(.preprocessor, index..<(index + 1))
                        emit(.variable, (index + 1)..<varEnd)
                        index = varEnd
                        return .shorthand(literal)
                    }
                }

                if literal.isRegex {
                    if literal.inCharClass {
                        if c == ASCII.rBracket { literal.inCharClass = false }
                        index += 1
                        continue
                    } else if c == ASCII.lBracket {
                        literal.inCharClass = true
                        index += 1
                        continue
                    }
                }

                if literal.openChar != 0 && c == literal.openChar {
                    literal.nestDepth += 1
                    index += 1
                    continue
                }

                if c == literal.closeChar {
                    if literal.openChar != 0 {
                        literal.nestDepth -= 1
                        if literal.nestDepth > 0 {
                            index += 1
                            continue
                        }
                    }
                    index += 1
                    if literal.isRegex {
                        while index < length && isRegexFlag(chars[index]) { index += 1 }
                    }
                    emit(literal.kind, spanStart..<index)
                    return .closed
                }

                index += 1
            }

            emit(literal.kind, spanStart..<index)
            return .eof
        }

        private mutating func tryStartPercentLiteral() -> Bool {
            guard index + 1 < length else { return false }
            let c1 = chars[index + 1]

            // `%q(...)`, `%Q[...]`, `%w{...}`, `%W<...>`, `%i|...|`, `%I/.../`, `%r{...}`, `%x(...)`, `%s(...)`
            if let spec = percentSpecifier(c1), index + 2 < length {
                let delim = chars[index + 2]
                if isPercentDelimiter(delim) {
                    let (open, close) = pairedDelimiter(delim)
                    startDelimited(
                        open: open,
                        close: close,
                        interpolated: spec.interpolated,
                        isRegex: spec.isRegex,
                        kind: .string,
                        prefixLength: 3
                    )
                    return true
                }
            }

            // Bare `%(...)`, `%[...]`, `%{...}`, etc. when in expression position.
            if canStartRegex && isPercentDelimiter(c1) {
                let (open, close) = pairedDelimiter(c1)
                startDelimited(
                    open: open,
                    close: close,
                    interpolated: true,
                    isRegex: false,
                    kind: .string,
                    prefixLength: 2
                )
                return true
            }

            return false
        }

        private mutating func tryStartRegexLiteral() -> Bool {
            guard index + 1 < length else { return false }
            let next = chars[index + 1]
            // Never treat `/=` as a regex literal; `/ /` can be a regex, whereas `/= ` is divide-assign.
            if next == ASCII.equals { return false }

            if !canStartRegex {
                // Command-call form like `puts /hello/`: requires whitespace before `/`,
                // no whitespace right after `/`, and a closing `/` on the same line.
                let precededBySpace = index > 0 && (chars[index - 1] == ASCII.space || chars[index - 1] == ASCII.tab)
                guard precededBySpace, !isWhitespaceOrNewline(next), hasSameLineRegexCloser(from: index + 1) else {
                    return false
                }
            }

            startDelimited(open: 0, close: ASCII.slash, interpolated: true, isRegex: true, kind: .string)
            return true
        }

        private func hasSameLineRegexCloser(from start: Int) -> Bool {
            var pos = start
            var inClass = false
            while pos < length {
                let c = chars[pos]
                if isNewline(c) { return false }
                if c == ASCII.backslash {
                    pos += 2
                    continue
                }
                if inClass {
                    if c == ASCII.rBracket { inClass = false }
                } else if c == ASCII.lBracket {
                    inClass = true
                } else if c == ASCII.slash {
                    return true
                }
                pos += 1
            }
            return false
        }

        // MARK: Heredocs

        private mutating func tryScanHeredocOpener() -> Bool {
            var pos = index + 2
            var indented = false
            if pos < length && (chars[pos] == ASCII.minus || chars[pos] == ASCII.tilde) {
                indented = true
                pos += 1
            }
            guard pos < length else { return false }

            let c = chars[pos]
            var interpolated = true
            var delimStart = pos
            var delimEnd = pos

            if c == ASCII.singleQuote || c == ASCII.doubleQuote || c == ASCII.backtick {
                interpolated = (c != ASCII.singleQuote)
                delimStart = pos + 1
                var end = delimStart
                while end < length && chars[end] != c && !isNewline(chars[end]) { end += 1 }
                guard end < length, chars[end] == c, end > delimStart else { return false }
                delimEnd = end
                pos = end + 1
            } else if isIdentStart(c) {
                // Disambiguate bare `a<<b` shift/append from `<<EOF` / `puts <<EOF`.
                let precededBySpaceOrStart = index == 0 || isWhitespaceOrNewline(chars[index - 1])
                guard indented || canStartRegex || precededBySpaceOrStart else { return false }
                delimStart = pos
                var end = pos + 1
                while end < length && isIdentContinue(chars[end]) { end += 1 }
                delimEnd = end
                pos = end
            } else {
                return false
            }

            let delimiter = Array(chars[delimStart..<delimEnd])
            emit(.string, index..<pos)
            index = pos
            pendingHeredocs.append(HeredocLiteral(delimiter: delimiter, indented: indented, interpolated: interpolated))
            canStartRegex = false
            return true
        }

        private mutating func scanHeredocStep(_ heredoc: HeredocLiteral) {
            if isAtLineStart(index), let delimiterEnd = matchHeredocDelimiterLine(heredoc) {
                emit(.string, index..<delimiterEnd)
                index = delimiterEnd
                contextStack.removeLast()
                canStartRegex = false
                return
            }

            let spanStart = index
            while index < length {
                let c = chars[index]
                if isNewline(c) {
                    consumeNewline()
                    emit(.string, spanStart..<index)
                    return
                }
                if heredoc.interpolated && c == ASCII.backslash {
                    index += 1
                    if index < length && !isNewline(chars[index]) { index += 1 }
                    continue
                }
                if heredoc.interpolated && c == ASCII.hash && index + 1 < length {
                    let next = chars[index + 1]
                    if next == ASCII.lBrace {
                        emit(.string, spanStart..<index)
                        emit(.preprocessor, index..<(index + 2))
                        index += 2
                        contextStack.append(.interpolation(braceDepth: 1))
                        canStartRegex = true
                        return
                    }
                    if (next == ASCII.at || next == ASCII.dollar),
                       let varEnd = shorthandInterpolationEnd(at: index + 1) {
                        emit(.string, spanStart..<index)
                        emit(.preprocessor, index..<(index + 1))
                        emit(.variable, (index + 1)..<varEnd)
                        index = varEnd
                        return
                    }
                }
                index += 1
            }

            emit(.string, spanStart..<index)
            contextStack.removeLast()
        }

        private func matchHeredocDelimiterLine(_ heredoc: HeredocLiteral) -> Int? {
            var pos = index
            if heredoc.indented {
                while pos < length && (chars[pos] == ASCII.space || chars[pos] == ASCII.tab) { pos += 1 }
            }
            let count = heredoc.delimiter.count
            guard pos + count <= length else { return nil }
            for i in 0..<count where chars[pos + i] != heredoc.delimiter[i] {
                return nil
            }
            let after = pos + count
            guard after == length || isNewline(chars[after]) else { return nil }
            return after
        }

        // MARK: Variables, Symbols, Numbers, Identifiers

        private mutating func tryScanVariable() -> Bool {
            guard let end = variableEnd(at: index) else { return false }
            emit(.variable, index..<end)
            index = end
            canStartRegex = false
            return true
        }

        private func shorthandInterpolationEnd(at start: Int) -> Int? {
            guard start < length else { return nil }
            let c = chars[start]
            if c == ASCII.at {
                var pos = start + 1
                if pos < length && chars[pos] == ASCII.at { pos += 1 }
                guard pos < length && isIdentStart(chars[pos]) else { return nil }
                pos += 1
                while pos < length && isIdentContinue(chars[pos]) { pos += 1 }
                return pos
            }
            if c == ASCII.dollar {
                var pos = start + 1
                guard pos < length && isIdentStart(chars[pos]) else { return nil }
                pos += 1
                while pos < length && isIdentContinue(chars[pos]) { pos += 1 }
                return pos
            }
            return nil
        }

        private func variableEnd(at start: Int) -> Int? {
            guard start + 1 < length else { return nil }
            let c = chars[start]
            let next = chars[start + 1]

            if c == ASCII.at {
                var pos = start + 1
                if next == ASCII.at {
                    pos += 1
                    guard pos < length else { return nil }
                }
                guard isIdentStart(chars[pos]) else { return nil }
                pos += 1
                while pos < length && isIdentContinue(chars[pos]) { pos += 1 }
                return pos
            }

            if c == ASCII.dollar {
                if isIdentStart(next) {
                    var pos = start + 2
                    while pos < length && isIdentContinue(chars[pos]) { pos += 1 }
                    return pos
                }
                if isDigit(next) {
                    var pos = start + 2
                    while pos < length && isDigit(chars[pos]) { pos += 1 }
                    return pos
                }
                if next == ASCII.minus && start + 2 < length && isIdentContinue(chars[start + 2]) {
                    return start + 3
                }
                if isSpecialGlobalChar(next) {
                    return start + 2
                }
            }
            return nil
        }

        private mutating func scanColonOrSymbol() {
            // `::` scope resolution operator.
            if index + 1 < length && chars[index + 1] == ASCII.colon {
                index += 2
                canStartRegex = true
                return
            }

            // Avoid turning `a?b:c` ternary into a symbol.
            let precededByIdent = index > 0 && isIdentContinue(chars[index - 1])
            guard !precededByIdent, index + 1 < length else {
                index += 1
                canStartRegex = true
                return
            }

            let next = chars[index + 1]
            if next == ASCII.doubleQuote || next == ASCII.singleQuote {
                emit(.attribute, index..<(index + 1))
                index += 1
                startDelimited(open: 0, close: next, interpolated: next == ASCII.doubleQuote, isRegex: false, kind: .attribute)
                return
            }

            if isIdentStart(next) {
                var end = index + 2
                while end < length && isIdentContinue(chars[end]) { end += 1 }
                if end < length && (chars[end] == ASCII.question || chars[end] == ASCII.bang) && !isFollowedByEquals(end) {
                    end += 1
                } else if end < length && chars[end] == ASCII.equals && !isFollowedByEquals(end) {
                    // Setter symbol `:` + `name=`
                    end += 1
                }
                emit(.attribute, index..<end)
                index = end
                canStartRegex = false
                return
            }

            if let opLen = operatorMethodLength(at: index + 1) {
                let end = index + 1 + opLen
                emit(.attribute, index..<end)
                index = end
                canStartRegex = false
                return
            }

            index += 1
            canStartRegex = true
        }

        private mutating func scanQuestionOrCharLiteral() {
            guard canStartRegex, index + 1 < length else {
                index += 1
                canStartRegex = true
                return
            }
            let next = chars[index + 1]
            guard !isWhitespaceOrNewline(next) else {
                index += 1
                canStartRegex = true
                return
            }
            let start = index
            index += 1
            if next == ASCII.backslash {
                index += 1
                if index < length {
                    // Handle `\C-x`, `\M-x`, `\u{...}` or single escaped char.
                    let esc = chars[index]
                    index += 1
                    if (esc == ASCII.upperC || esc == ASCII.upperM) && index + 1 < length && chars[index] == ASCII.minus {
                        index += 2
                    } else if esc == ASCII.lowerU && index < length && chars[index] == ASCII.lBrace {
                        while index < length && chars[index] != ASCII.rBrace && !isNewline(chars[index]) { index += 1 }
                        if index < length && chars[index] == ASCII.rBrace { index += 1 }
                    }
                }
            } else {
                index += 1
                if index < length && UTF16.isLeadSurrogate(next) && UTF16.isTrailSurrogate(chars[index]) {
                    index += 1
                }
            }
            emit(.string, start..<index)
            canStartRegex = false
        }

        private mutating func scanNumber() {
            let start = index
            if chars[index] == ASCII.zero, index + 1 < length {
                let prefix = chars[index + 1]
                if prefix == ASCII.lowerX || prefix == ASCII.upperX {
                    index += 2
                    while index < length && isHexOrUnderscore(chars[index]) { index += 1 }
                    consumeNumericSuffix()
                    emit(.number, start..<index)
                    canStartRegex = false
                    return
                }
                if prefix == ASCII.lowerB || prefix == ASCII.upperB {
                    index += 2
                    while index < length && (chars[index] == ASCII.zero || chars[index] == ASCII.one || chars[index] == ASCII.underscore) { index += 1 }
                    consumeNumericSuffix()
                    emit(.number, start..<index)
                    canStartRegex = false
                    return
                }
                if prefix == ASCII.lowerO || prefix == ASCII.upperO {
                    index += 2
                    while index < length && ((chars[index] >= ASCII.zero && chars[index] <= ASCII.seven) || chars[index] == ASCII.underscore) { index += 1 }
                    consumeNumericSuffix()
                    emit(.number, start..<index)
                    canStartRegex = false
                    return
                }
                if prefix == ASCII.lowerD || prefix == ASCII.upperD {
                    index += 2
                    while index < length && isDigitOrUnderscore(chars[index]) { index += 1 }
                    consumeNumericSuffix()
                    emit(.number, start..<index)
                    canStartRegex = false
                    return
                }
            }

            while index < length && isDigitOrUnderscore(chars[index]) { index += 1 }

            // Decimal fraction only when `.` is followed by a digit (keeps `1.times` / `1..5` intact).
            if index + 1 < length && chars[index] == ASCII.dot && isDigit(chars[index + 1]) {
                index += 1
                while index < length && isDigitOrUnderscore(chars[index]) { index += 1 }
            }

            // Exponent.
            if index < length && (chars[index] == ASCII.lowerE || chars[index] == ASCII.upperE) {
                var expPos = index + 1
                if expPos < length && (chars[expPos] == ASCII.plus || chars[expPos] == ASCII.minus) { expPos += 1 }
                if expPos < length && isDigit(chars[expPos]) {
                    index = expPos
                    while index < length && isDigitOrUnderscore(chars[index]) { index += 1 }
                }
            }

            consumeNumericSuffix()
            emit(.number, start..<index)
            canStartRegex = false
        }

        private mutating func consumeNumericSuffix() {
            if index + 1 < length && chars[index] == ASCII.lowerR && chars[index + 1] == ASCII.lowerI
                && (index + 2 == length || !isIdentContinue(chars[index + 2])) {
                index += 2
            } else if index < length && (chars[index] == ASCII.lowerR || chars[index] == ASCII.lowerI)
                && (index + 1 == length || !isIdentContinue(chars[index + 1])) {
                index += 1
            }
        }

        private mutating func scanIdentifierOrKeyword() {
            let start = index
            index += 1
            while index < length && isIdentContinue(chars[index]) { index += 1 }
            if index < length && (chars[index] == ASCII.question || chars[index] == ASCII.bang) && !isFollowedByEquals(index) {
                index += 1
            }

            // Modern hash key label `foo:` / `bar?:` (not `::` or `:=`).
            if index < length && chars[index] == ASCII.colon
                && (index + 1 == length || (chars[index + 1] != ASCII.colon && chars[index + 1] != ASCII.equals)) {
                emit(.property, start..<index)
                index += 1
                canStartRegex = true
                return
            }

            if matchesExact(Self.defKeyword, in: start..<index) {
                emit(.keyword, start..<index)
                scanMethodDeclarationName()
                canStartRegex = true
                return
            }

            let word = String(decoding: chars[start..<index], as: UTF16.self)

            if Self.keywords.contains(word) {
                emit(.keyword, start..<index)
                canStartRegex = Self.regexStarterKeywords.contains(word)
                return
            }

            if isUppercaseASCII(chars[start]) {
                emit(.type, start..<index)
                canStartRegex = false
                return
            }

            if isFollowedByOpenParen(from: index) {
                emit(.function, start..<index)
            }

            canStartRegex = false
        }

        private mutating func scanMethodDeclarationName() {
            while index < length && (chars[index] == ASCII.space || chars[index] == ASCII.tab) { index += 1 }
            guard index < length else { return }

            // Optional receiver prefix: `def self.foo` or `def Foo.bar` or `def obj.baz`
            if isIdentStart(chars[index]) {
                let firstStart = index
                var firstEnd = index + 1
                while firstEnd < length && isIdentContinue(chars[firstEnd]) { firstEnd += 1 }
                if firstEnd < length && chars[firstEnd] == ASCII.dot {
                    if matchesExact(Self.selfKeyword, in: firstStart..<firstEnd) {
                        emit(.keyword, firstStart..<firstEnd)
                    } else if isUppercaseASCII(chars[firstStart]) {
                        emit(.type, firstStart..<firstEnd)
                    }
                    index = firstEnd + 1
                }
            }

            guard index < length else { return }
            if isIdentStart(chars[index]) {
                let nameStart = index
                index += 1
                while index < length && isIdentContinue(chars[index]) { index += 1 }
                if index < length && (chars[index] == ASCII.question || chars[index] == ASCII.bang || chars[index] == ASCII.equals)
                    && !isFollowedByEquals(index) {
                    index += 1
                }
                emit(.function, nameStart..<index)
            } else if let opLen = operatorMethodLength(at: index) {
                emit(.function, index..<(index + opLen))
                index += opLen
            }
        }

        private mutating func scanPunctuationOrOperator(_ c: unichar) {
            if c == ASCII.rParen || c == ASCII.rBracket {
                index += 1
                canStartRegex = false
                return
            }
            if c == ASCII.lParen || c == ASCII.lBracket || c == ASCII.comma || c == ASCII.semicolon {
                index += 1
                canStartRegex = true
                return
            }
            if c == ASCII.dot {
                index += 1
                // Method calls after `.` shouldn't treat `/` as regex (`foo.bar / 2`),
                // though `..` / `...` range operators do allow regex.
                if index < length && chars[index] == ASCII.dot {
                    while index < length && chars[index] == ASCII.dot { index += 1 }
                    canStartRegex = true
                } else {
                    canStartRegex = false
                }
                return
            }
            index += 1
            canStartRegex = true
        }

        // MARK: Helpers

        private mutating func emit(_ kind: TokenKind, _ range: Range<Int>) {
            guard range.lowerBound < range.upperBound else { return }
            tokens.append(SyntaxToken(
                range: NSRange(location: range.lowerBound, length: range.upperBound - range.lowerBound),
                kind: kind
            ))
        }

        private mutating func consumeNewline() {
            guard index < length else { return }
            if chars[index] == ASCII.carriageReturn {
                index += 1
                if index < length && chars[index] == ASCII.newline { index += 1 }
            } else if chars[index] == ASCII.newline {
                index += 1
            }
        }

        private func isAtLineStart(_ pos: Int) -> Bool {
            pos == 0 || isNewline(chars[pos - 1])
        }

        private func matchesExact(_ units: [unichar], in range: Range<Int>) -> Bool {
            guard range.count == units.count else { return false }
            for i in 0..<units.count where chars[range.lowerBound + i] != units[i] {
                return false
            }
            return true
        }

        private func matchesWord(_ units: [unichar], at pos: Int) -> Bool {
            guard pos + units.count <= length else { return false }
            for i in 0..<units.count where chars[pos + i] != units[i] {
                return false
            }
            let after = pos + units.count
            return after == length || isWhitespaceOrNewline(chars[after])
        }

        private func isFollowedByEquals(_ pos: Int) -> Bool {
            pos + 1 < length && chars[pos + 1] == ASCII.equals
        }

        private func isFollowedByOpenParen(from pos: Int) -> Bool {
            var p = pos
            while p < length && (chars[p] == ASCII.space || chars[p] == ASCII.tab) { p += 1 }
            return p < length && chars[p] == ASCII.lParen
        }

        private func operatorMethodLength(at pos: Int) -> Int? {
            guard pos < length else { return nil }
            let c0 = chars[pos]
            let c1: unichar = pos + 1 < length ? chars[pos + 1] : 0
            let c2: unichar = pos + 2 < length ? chars[pos + 2] : 0

            // 3-char operators: `<=>`, `===`, `[]=`
            if (c0 == ASCII.lessThan && c1 == ASCII.equals && c2 == ASCII.greaterThan)
                || (c0 == ASCII.equals && c1 == ASCII.equals && c2 == ASCII.equals)
                || (c0 == ASCII.lBracket && c1 == ASCII.rBracket && c2 == ASCII.equals) {
                return 3
            }
            // 2-char operators: `==`, `=~`, `!=`, `!~`, `<<`, `>>`, `<=`, `>=`, `**`, `[]`, `+@`, `-@`, `~@`, `!@`
            if (c0 == ASCII.equals && (c1 == ASCII.equals || c1 == ASCII.tilde))
                || (c0 == ASCII.bang && (c1 == ASCII.equals || c1 == ASCII.tilde || c1 == ASCII.at))
                || (c0 == ASCII.lessThan && (c1 == ASCII.lessThan || c1 == ASCII.equals))
                || (c0 == ASCII.greaterThan && (c1 == ASCII.greaterThan || c1 == ASCII.equals))
                || (c0 == ASCII.star && c1 == ASCII.star)
                || (c0 == ASCII.lBracket && c1 == ASCII.rBracket)
                || ((c0 == ASCII.plus || c0 == ASCII.minus || c0 == ASCII.tilde) && c1 == ASCII.at) {
                return 2
            }
            // 1-char operators: `+`, `-`, `*`, `/`, `%`, `&`, `|`, `^`, `~`, `<`, `>`, `!`
            switch c0 {
            case ASCII.plus, ASCII.minus, ASCII.star, ASCII.slash, ASCII.percent, ASCII.ampersand,
                 ASCII.pipe, ASCII.caret, ASCII.tilde, ASCII.lessThan, ASCII.greaterThan, ASCII.bang:
                return 1
            default:
                return nil
            }
        }

        private func percentSpecifier(_ c: unichar) -> (interpolated: Bool, isRegex: Bool)? {
            switch c {
            case ASCII.lowerQ, ASCII.lowerW, ASCII.lowerI, ASCII.lowerS:
                (false, false)
            case ASCII.upperQ, ASCII.upperW, ASCII.upperI, ASCII.lowerX:
                (true, false)
            case ASCII.lowerR:
                (true, true)
            default:
                nil
            }
        }

        private func isPercentDelimiter(_ c: unichar) -> Bool {
            !isWhitespaceOrNewline(c) && !isIdentContinue(c) && c != ASCII.equals
        }

        private func pairedDelimiter(_ c: unichar) -> (open: unichar, close: unichar) {
            switch c {
            case ASCII.lParen: (ASCII.lParen, ASCII.rParen)
            case ASCII.lBracket: (ASCII.lBracket, ASCII.rBracket)
            case ASCII.lBrace: (ASCII.lBrace, ASCII.rBrace)
            case ASCII.lessThan: (ASCII.lessThan, ASCII.greaterThan)
            default: (0, c)
            }
        }

        // MARK: Character predicates

        private func isNewline(_ c: unichar) -> Bool {
            c == ASCII.newline || c == ASCII.carriageReturn
        }

        private func isWhitespaceOrNewline(_ c: unichar) -> Bool {
            c == ASCII.space || c == ASCII.tab || c == ASCII.newline || c == ASCII.carriageReturn
        }

        private func isDigit(_ c: unichar) -> Bool {
            c >= ASCII.zero && c <= ASCII.nine
        }

        private func isDigitOrUnderscore(_ c: unichar) -> Bool {
            isDigit(c) || c == ASCII.underscore
        }

        private func isHexOrUnderscore(_ c: unichar) -> Bool {
            isDigit(c)
                || (c >= ASCII.lowerA && c <= ASCII.lowerF)
                || (c >= ASCII.upperA && c <= ASCII.upperF)
                || c == ASCII.underscore
        }

        private func isUppercaseASCII(_ c: unichar) -> Bool {
            c >= ASCII.upperA && c <= ASCII.upperZ
        }

        private func isIdentStart(_ c: unichar) -> Bool {
            (c >= ASCII.lowerA && c <= ASCII.lowerZ)
                || (c >= ASCII.upperA && c <= ASCII.upperZ)
                || c == ASCII.underscore
        }

        private func isIdentContinue(_ c: unichar) -> Bool {
            isIdentStart(c) || isDigit(c)
        }

        private func isRegexFlag(_ c: unichar) -> Bool {
            switch c {
            case ASCII.lowerI, ASCII.lowerM, ASCII.lowerX, ASCII.lowerO,
                 ASCII.lowerU, ASCII.lowerN, ASCII.lowerE, ASCII.lowerS:
                true
            default:
                false
            }
        }

        private func isSpecialGlobalChar(_ c: unichar) -> Bool {
            switch c {
            case ASCII.bang, ASCII.at, ASCII.question, ASCII.tilde, ASCII.ampersand,
                 ASCII.backtick, ASCII.singleQuote, ASCII.plus, ASCII.semicolon, ASCII.comma,
                 ASCII.dot, ASCII.backslash, ASCII.slash, ASCII.lessThan, ASCII.greaterThan,
                 ASCII.colon, ASCII.star, ASCII.dollar, ASCII.underscore, ASCII.equals:
                true
            default:
                false
            }
        }

        // MARK: Keyword tables

        private static let beginDirective = Array("=begin".utf16)
        private static let endDirective = Array("=end".utf16)
        private static let defKeyword = Array("def".utf16)
        private static let selfKeyword = Array("self".utf16)

        private static let keywords: Set<String> = [
            "__ENCODING__", "__FILE__", "__LINE__", "BEGIN", "END",
            "alias", "and", "begin", "break", "case", "class", "def", "defined?",
            "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in",
            "module", "next", "nil", "not", "or", "redo", "rescue", "retry",
            "return", "self", "super", "then", "true", "undef", "unless", "until",
            "when", "while", "yield",
            "require", "require_relative", "include", "extend", "prepend",
            "refine", "using", "module_function", "attr", "attr_accessor",
            "attr_reader", "attr_writer", "private", "protected", "public",
            "lambda", "proc", "raise", "fail", "puts", "block_given?",
            "loop", "catch", "throw",
        ]

        /// Keywords after which `/` begins a regex literal rather than division.
        private static let regexStarterKeywords: Set<String> = [
            "and", "begin", "break", "case", "defined?", "do", "else", "elsif",
            "ensure", "if", "in", "next", "not", "or", "puts", "raise", "fail",
            "rescue", "return", "then", "unless", "until", "when", "while", "yield",
        ]
    }
}
