import Foundation
import Testing
@testable import Silica

@Suite("RubyTokenizer")
struct RubyTokenizerTests {
    private struct TokenSlice: Equatable, CustomStringConvertible {
        let kind: TokenKind
        let text: String

        init(_ kind: TokenKind, _ text: String) {
            self.kind = kind
            self.text = text
        }

        var description: String { ".\(kind)(\(String(reflecting: text)))" }
    }

    // MARK: - Helpers

    private func tokenize(_ source: String) -> [SyntaxToken] {
        let ns = source as NSString
        let tokens = RubyTokenizer.shared.tokenize(ns)
        assertInvariants(tokens, length: ns.length)
        return tokens
    }

    private func slices(in source: String) -> [TokenSlice] {
        let ns = source as NSString
        return tokenize(source).map { TokenSlice($0.kind, ns.substring(with: $0.range)) }
    }

    /// Merges directly adjacent tokens of the same kind (for example opening quote + body)
    /// while still checking raw token invariants first.
    private func mergedSlices(in source: String) -> [TokenSlice] {
        let ns = source as NSString
        var merged: [(kind: TokenKind, range: NSRange)] = []
        for token in tokenize(source) {
            if let last = merged.last,
               last.kind == token.kind,
               NSMaxRange(last.range) == token.range.location {
                merged[merged.count - 1].range = NSRange(
                    location: last.range.location,
                    length: last.range.length + token.range.length
                )
            } else {
                merged.append((token.kind, token.range))
            }
        }
        return merged.map { TokenSlice($0.kind, ns.substring(with: $0.range)) }
    }

    private func assertInvariants(_ tokens: [SyntaxToken], length: Int) {
        var previousEnd = 0
        for token in tokens {
            #expect(token.range.location >= 0)
            #expect(token.range.length > 0)
            #expect(NSMaxRange(token.range) <= length)
            #expect(token.range.location >= previousEnd)
            previousEnd = NSMaxRange(token.range)
        }
    }

    // MARK: - Comments

    @Test func lineComments() {
        let source = """
        # top comment
        x = 1#inline comment
        """
        #expect(slices(in: source) == [
            TokenSlice(.comment, "# top comment"),
            TokenSlice(.number, "1"),
            TokenSlice(.comment, "#inline comment"),
        ])
    }

    @Test func blockCommentsAtColumnZero() {
        let source = """
        =begin
        everything here is ignored
        "not a string"
        =end ignored trailing text
        x = 42
        """
        #expect(slices(in: source) == [
            TokenSlice(.comment, "=begin\neverything here is ignored\n\"not a string\"\n=end ignored trailing text"),
            TokenSlice(.number, "42"),
        ])
    }

    @Test func indentedOrWordPrefixedBeginIsNotBlockComment() {
        let source = """
          =begin
        =begin_not_comment
        """
        #expect(slices(in: source).allSatisfy { $0.kind != .comment })
    }

    // MARK: - Strings, Backticks & Interpolation

    @Test func singleQuotedStringsIgnoreInterpolationAndEscapes() {
        let source = #"""
        a = 'hello\n\'world\' #{not_interp}'
        b = 'multi
        line'
        """#
        #expect(mergedSlices(in: source) == [
            TokenSlice(.string, #"'hello\n\'world\' #{not_interp}'"#),
            TokenSlice(.string, "'multi\nline'"),
        ])
    }

    @Test func doubleQuotedAndBacktickStringsWithNestedInterpolation() {
        let source = #"""
        s = "hi #{user.name({ a: 1 }) + "nested #{x}"}!"
        cmd = `echo #{dir}`
        """#
        #expect(slices(in: source) == [
            TokenSlice(.string, "\""),
            TokenSlice(.string, "hi "),
            TokenSlice(.preprocessor, "#{"),
            TokenSlice(.function, "name"),
            TokenSlice(.property, "a"),
            TokenSlice(.number, "1"),
            TokenSlice(.string, "\""),
            TokenSlice(.string, "nested "),
            TokenSlice(.preprocessor, "#{"),
            TokenSlice(.preprocessor, "}"),
            TokenSlice(.string, "\""),
            TokenSlice(.preprocessor, "}"),
            TokenSlice(.string, "!\""),
            TokenSlice(.string, "`"),
            TokenSlice(.string, "echo "),
            TokenSlice(.preprocessor, "#{"),
            TokenSlice(.preprocessor, "}"),
            TokenSlice(.string, "`"),
        ])
    }

    @Test func shorthandInterpolationForVariables() {
        let source = #"""
        "a=#@ivar b=#@@cvar c=#$gvar d=#$1 e=#@"
        """#
        #expect(slices(in: source) == [
            TokenSlice(.string, "\""),
            TokenSlice(.string, "a="),
            TokenSlice(.preprocessor, "#"),
            TokenSlice(.variable, "@ivar"),
            TokenSlice(.string, " b="),
            TokenSlice(.preprocessor, "#"),
            TokenSlice(.variable, "@@cvar"),
            TokenSlice(.string, " c="),
            TokenSlice(.preprocessor, "#"),
            TokenSlice(.variable, "$gvar"),
            TokenSlice(.string, " d=#$1 e=#@\""),
        ])
    }

    // MARK: - Heredocs

    @Test func heredocFormsAndInterpolation() {
        let source = """
        a = <<~SQL
          SELECT * FROM users WHERE id = #{user_id}
        SQL
        b = <<-'TXT'
          #{literal}
        TXT
        c = <<"END"
        hi #{name}
        END
        """
        #expect(mergedSlices(in: source) == [
            TokenSlice(.string, "<<~SQL"),
            TokenSlice(.string, "  SELECT * FROM users WHERE id = "),
            TokenSlice(.preprocessor, "#{"),
            TokenSlice(.preprocessor, "}"),
            TokenSlice(.string, "\nSQL"),
            TokenSlice(.string, "<<-'TXT'"),
            TokenSlice(.string, "  #{literal}\nTXT"),
            TokenSlice(.string, "<<\"END\""),
            TokenSlice(.string, "hi "),
            TokenSlice(.preprocessor, "#{"),
            TokenSlice(.preprocessor, "}"),
            TokenSlice(.string, "\nEND"),
        ])
    }

    @Test func multipleHeredocsOnOneLineDrainInOrder() {
        let source = """
        join(<<A, <<'B')
        first #{x}
        A
        second #{y}
        B
        done = 1
        """
        #expect(mergedSlices(in: source) == [
            TokenSlice(.function, "join"),
            TokenSlice(.string, "<<A"),
            TokenSlice(.string, "<<'B'"),
            TokenSlice(.string, "first "),
            TokenSlice(.preprocessor, "#{"),
            TokenSlice(.preprocessor, "}"),
            TokenSlice(.string, "\nA\nsecond #{y}\nB"),
            TokenSlice(.number, "1"),
        ])
    }

    @Test func heredocDisambiguatedFromShiftAndAppend() {
        let source = """
        1 << 2
        a<<b
        items << item
        """
        #expect(slices(in: source) == [
            TokenSlice(.number, "1"),
            TokenSlice(.number, "2"),
        ])
    }

    // MARK: - Percent Literals

    @Test func percentLiteralsWithNestedAndUnpairedDelimiters() {
        let source = """
        words = %w(one (two (three)) four)
        syms = %I[foo #{bar} baz]
        raw = %q|hello #{world}|
        bare = %(hi #{name})
        mod = a % b
        """
        #expect(mergedSlices(in: source) == [
            TokenSlice(.string, "%w(one (two (three)) four)"),
            TokenSlice(.string, "%I[foo "),
            TokenSlice(.preprocessor, "#{"),
            TokenSlice(.preprocessor, "}"),
            TokenSlice(.string, " baz]"),
            TokenSlice(.string, "%q|hello #{world}|"),
            TokenSlice(.string, "%(hi "),
            TokenSlice(.preprocessor, "#{"),
            TokenSlice(.preprocessor, "}"),
            TokenSlice(.string, ")"),
        ])
    }

    // MARK: - Regex vs Division

    @Test func regexLiteralsAndDivisionDisambiguation() {
        let source = """
        r1 = /foo[a\\/b]#{z}/imx
        r2 = %r{https?://[^/]+}i
        puts /hello/i
        d1 = a / b / c
        d2 = foo.bar / 2
        d3 = (a + b) / 2
        x /= 3
        """
        #expect(mergedSlices(in: source) == [
            TokenSlice(.string, "/foo[a\\/b]"),
            TokenSlice(.preprocessor, "#{"),
            TokenSlice(.preprocessor, "}"),
            TokenSlice(.string, "/imx"),
            TokenSlice(.string, "%r{https?://[^/]+}i"),
            TokenSlice(.keyword, "puts"),
            TokenSlice(.string, "/hello/i"),
            TokenSlice(.number, "2"),
            TokenSlice(.number, "2"),
            TokenSlice(.number, "3"),
        ])
    }

    @Test func regexWithCharacterClassContainingClosingDelimiter() {
        let source = """
        r = %r(a[)]b)
        s = /a[\\/]b/
        """
        #expect(mergedSlices(in: source) == [
            TokenSlice(.string, "%r(a[)]b)"),
            TokenSlice(.string, "/a[\\/]b/"),
        ])
    }

    // MARK: - Variables, Symbols, Hash Keys & Char Literals

    @Test func variablesAndSpecialGlobals() {
        let source = "@ivar + @@cvar + $gvar + $12 + $-w + $! + $? + $~"
        #expect(slices(in: source) == [
            TokenSlice(.variable, "@ivar"),
            TokenSlice(.variable, "@@cvar"),
            TokenSlice(.variable, "$gvar"),
            TokenSlice(.variable, "$12"),
            TokenSlice(.variable, "$-w"),
            TokenSlice(.variable, "$!"),
            TokenSlice(.variable, "$?"),
            TokenSlice(.variable, "$~"),
        ])
    }

    @Test func symbolsScopeResolutionAndHashLabels() {
        let source = """
        Foo::Bar.call(:sym, :valid?, :save!, :name=, :+, :<=>, :[]=, :"q_#{x}", :'raw')
        h = { foo: 1, bar?: true, a:, b: }
        t = cond ? yes : no
        t2 = flag ? 1:2
        """
        #expect(mergedSlices(in: source) == [
            TokenSlice(.type, "Foo"),
            TokenSlice(.type, "Bar"),
            TokenSlice(.function, "call"),
            TokenSlice(.attribute, ":sym"),
            TokenSlice(.attribute, ":valid?"),
            TokenSlice(.attribute, ":save!"),
            TokenSlice(.attribute, ":name="),
            TokenSlice(.attribute, ":+"),
            TokenSlice(.attribute, ":<=>"),
            TokenSlice(.attribute, ":[]="),
            TokenSlice(.attribute, ":\"q_"),
            TokenSlice(.preprocessor, "#{"),
            TokenSlice(.preprocessor, "}"),
            TokenSlice(.attribute, "\""),
            TokenSlice(.attribute, ":'raw'"),
            TokenSlice(.property, "foo"),
            TokenSlice(.number, "1"),
            TokenSlice(.property, "bar?"),
            TokenSlice(.keyword, "true"),
            TokenSlice(.property, "a"),
            TokenSlice(.property, "b"),
            TokenSlice(.number, "1"),
            TokenSlice(.number, "2"),
        ])
    }

    @Test func characterLiterals() {
        let source = #"""
        [?a, ?\n, ?\C-x, ?\u{1F600}, ?😀]
        """#
        #expect(slices(in: source) == [
            TokenSlice(.string, "?a"),
            TokenSlice(.string, #"?\n"#),
            TokenSlice(.string, #"?\C-x"#),
            TokenSlice(.string, #"?\u{1F600}"#),
            TokenSlice(.string, "?😀"),
        ])
    }

    // MARK: - Numbers, Methods & Keywords

    @Test func numberFormatsAndMethodDisambiguation() {
        let source = """
        [0xff_00, 0b1010_01, 0o755, 0d42, 1_000, 3.14e-2, 1r, 2i, 1.5ri]
        1.times
        1..5
        """
        #expect(slices(in: source) == [
            TokenSlice(.number, "0xff_00"),
            TokenSlice(.number, "0b1010_01"),
            TokenSlice(.number, "0o755"),
            TokenSlice(.number, "0d42"),
            TokenSlice(.number, "1_000"),
            TokenSlice(.number, "3.14e-2"),
            TokenSlice(.number, "1r"),
            TokenSlice(.number, "2i"),
            TokenSlice(.number, "1.5ri"),
            TokenSlice(.number, "1"),
            TokenSlice(.number, "1"),
            TokenSlice(.number, "5"),
        ])
    }

    @Test func methodDeclarationsAndCalls() {
        let source = """
        class User < Base
          def self.find?(id); end
          def User.build(name); end
          def name=(value); end
          def ==(other); false; end
          def []=(k, v); end
        end
        save!(user)
        """
        #expect(slices(in: source) == [
            TokenSlice(.keyword, "class"),
            TokenSlice(.type, "User"),
            TokenSlice(.type, "Base"),
            TokenSlice(.keyword, "def"),
            TokenSlice(.keyword, "self"),
            TokenSlice(.function, "find?"),
            TokenSlice(.keyword, "end"),
            TokenSlice(.keyword, "def"),
            TokenSlice(.type, "User"),
            TokenSlice(.function, "build"),
            TokenSlice(.keyword, "end"),
            TokenSlice(.keyword, "def"),
            TokenSlice(.function, "name="),
            TokenSlice(.keyword, "end"),
            TokenSlice(.keyword, "def"),
            TokenSlice(.function, "=="),
            TokenSlice(.keyword, "false"),
            TokenSlice(.keyword, "end"),
            TokenSlice(.keyword, "def"),
            TokenSlice(.function, "[]="),
            TokenSlice(.keyword, "end"),
            TokenSlice(.keyword, "end"),
            TokenSlice(.function, "save!"),
        ])
    }

    // MARK: - Regressions & Correctness Fixes

    @Test func newlinesResetExpressionContextForRegexCharAndPercentLiterals() {
        let source = """
        a = b
        /regex/.match(s)
        count = 10
        ?z
        items = [1]
        %(wrapped)
        """
        #expect(mergedSlices(in: source) == [
            TokenSlice(.string, "/regex/"),
            TokenSlice(.function, "match"),
            TokenSlice(.number, "10"),
            TokenSlice(.string, "?z"),
            TokenSlice(.number, "1"),
            TokenSlice(.string, "%(wrapped)"),
        ])
    }

    @Test func heredocsInsideInterpolationsDrainBeforeOuterLiteralResumes() {
        let nestedHeredocs = """
        x = <<OUTER
        #{foo(<<INNER)}
        inner body
        INNER
        outer body
        OUTER
        y = 1
        """
        #expect(slices(in: nestedHeredocs) == [
            TokenSlice(.string, "<<OUTER"),
            TokenSlice(.preprocessor, "#{"),
            TokenSlice(.function, "foo"),
            TokenSlice(.string, "<<INNER"),
            TokenSlice(.preprocessor, "}"),
            TokenSlice(.string, "\n"),
            TokenSlice(.string, "inner body\n"),
            TokenSlice(.string, "INNER"),
            TokenSlice(.string, "\n"),
            TokenSlice(.string, "outer body\n"),
            TokenSlice(.string, "OUTER"),
            TokenSlice(.number, "1"),
        ])

        let heredocInString = #"""
        s = "start #{foo(<<TAG)}
        inner
        TAG
        tail"
        z = 2
        """#
        #expect(mergedSlices(in: heredocInString) == [
            TokenSlice(.string, "\"start "),
            TokenSlice(.preprocessor, "#{"),
            TokenSlice(.function, "foo"),
            TokenSlice(.string, "<<TAG"),
            TokenSlice(.preprocessor, "}"),
            TokenSlice(.string, "\ninner\nTAG\ntail\""),
            TokenSlice(.number, "2"),
        ])
    }

    @Test func memberCalledDefAndScopedMethodDeclarations() {
        let source = """
        obj.def + 1
        obj&.def + 2
        Foo::def(x)
        private def hidden; end
        def Foo::Bar.baz; end
        def Foo::qux; end
        def ::Top::Mid.run; end
        """
        #expect(slices(in: source) == [
            TokenSlice(.number, "1"),
            TokenSlice(.number, "2"),
            TokenSlice(.type, "Foo"),
            TokenSlice(.function, "def"),
            TokenSlice(.keyword, "private"),
            TokenSlice(.keyword, "def"),
            TokenSlice(.function, "hidden"),
            TokenSlice(.keyword, "end"),
            TokenSlice(.keyword, "def"),
            TokenSlice(.type, "Foo"),
            TokenSlice(.type, "Bar"),
            TokenSlice(.function, "baz"),
            TokenSlice(.keyword, "end"),
            TokenSlice(.keyword, "def"),
            TokenSlice(.type, "Foo"),
            TokenSlice(.function, "qux"),
            TokenSlice(.keyword, "end"),
            TokenSlice(.keyword, "def"),
            TokenSlice(.type, "Top"),
            TokenSlice(.type, "Mid"),
            TokenSlice(.function, "run"),
            TokenSlice(.keyword, "end"),
        ])
    }

    @Test func ternaryWithoutSpacesAroundQuotedOrCallBranches() {
        let source = """
        a = flag ? 'x':'y'
        b = flag ? "p":"q"
        c = flag ? f():g()
        d = flag ? :ok:'err'
        e = foo=:bar
        render :index
        """
        #expect(mergedSlices(in: source) == [
            TokenSlice(.string, "'x'"),
            TokenSlice(.string, "'y'"),
            TokenSlice(.string, "\"p\""),
            TokenSlice(.string, "\"q\""),
            TokenSlice(.function, "f"),
            TokenSlice(.function, "g"),
            TokenSlice(.attribute, ":ok"),
            TokenSlice(.string, "'err'"),
            TokenSlice(.attribute, ":bar"),
            TokenSlice(.attribute, ":index"),
        ])
    }

    @Test func extendedCharacterEscapesAndDivisionFallback() {
        let escapes = #"""
        [?\x1b, ?\u0041, ?\0, ?\177, ?\cx, ?\M-\C-x, ?\C-\M-x]
        """#
        #expect(slices(in: escapes) == [
            TokenSlice(.string, #"?\x1b"#),
            TokenSlice(.string, #"?\u0041"#),
            TokenSlice(.string, #"?\0"#),
            TokenSlice(.string, #"?\177"#),
            TokenSlice(.string, #"?\cx"#),
            TokenSlice(.string, #"?\M-\C-x"#),
            TokenSlice(.string, #"?\C-\M-x"#),
        ])

        let division = """
        r1 = width /2 + height/ 2
        r2 = width /2 + height/2
        r3 = width /2 + height / 2
        m1 = match /abc/i
        m2 = gsub /a+/, "b"
        """
        #expect(mergedSlices(in: division) == [
            TokenSlice(.number, "2"),
            TokenSlice(.number, "2"),
            TokenSlice(.number, "2"),
            TokenSlice(.number, "2"),
            TokenSlice(.number, "2"),
            TokenSlice(.number, "2"),
            TokenSlice(.string, "/abc/i"),
            TokenSlice(.string, "/a+/"),
            TokenSlice(.string, "\"b\""),
        ])
    }

    // MARK: - Ruby 3.4 & 4.0 Foundation

    @Test func ruby34And40SyntaxConstructs() {
        let source = """
        nums.map { it / 2 }.then { /ok/.match?(it) }
        { it: 1 }
        if a? # comment
          && /b/
          || c?
          and /d/
          or /e/
        end
        def square(x) = x * x
        def self.match?(s) = /ok/.match?(s)
        def forward(*, **, &); target(*nil, **nil); end
        def fwd(...); target(...); end
        case res
        in { a:, b: /^ok/ => val }
          val
        end
        res => [first, *]
        (1..)
        """
        #expect(mergedSlices(in: source) == [
            TokenSlice(.number, "2"),
            TokenSlice(.string, "/ok/"),
            TokenSlice(.function, "match?"),
            TokenSlice(.property, "it"),
            TokenSlice(.number, "1"),
            TokenSlice(.keyword, "if"),
            TokenSlice(.comment, "# comment"),
            TokenSlice(.string, "/b/"),
            TokenSlice(.keyword, "and"),
            TokenSlice(.string, "/d/"),
            TokenSlice(.keyword, "or"),
            TokenSlice(.string, "/e/"),
            TokenSlice(.keyword, "end"),
            TokenSlice(.keyword, "def"),
            TokenSlice(.function, "square"),
            TokenSlice(.keyword, "def"),
            TokenSlice(.keyword, "self"),
            TokenSlice(.function, "match?"),
            TokenSlice(.string, "/ok/"),
            TokenSlice(.function, "match?"),
            TokenSlice(.keyword, "def"),
            TokenSlice(.function, "forward"),
            TokenSlice(.function, "target"),
            TokenSlice(.keyword, "nil"),
            TokenSlice(.keyword, "nil"),
            TokenSlice(.keyword, "end"),
            TokenSlice(.keyword, "def"),
            TokenSlice(.function, "fwd"),
            TokenSlice(.function, "target"),
            TokenSlice(.keyword, "end"),
            TokenSlice(.keyword, "case"),
            TokenSlice(.keyword, "in"),
            TokenSlice(.property, "a"),
            TokenSlice(.property, "b"),
            TokenSlice(.string, "/^ok/"),
            TokenSlice(.keyword, "end"),
            TokenSlice(.number, "1"),
        ])
    }

    @Test func memberAccessKeywordsAndPercentModuloDisambiguation() {
        let source = """
        half = range.begin / 2
        multiline = range
          .begin / 2
        step = iter.next / 2
        where.not(active: true)
        mod = (a%w) + (b%r) + 1
        words = foo %w(x y)
        """
        #expect(mergedSlices(in: source) == [
            TokenSlice(.number, "2"),
            TokenSlice(.number, "2"),
            TokenSlice(.number, "2"),
            TokenSlice(.function, "not"),
            TokenSlice(.property, "active"),
            TokenSlice(.keyword, "true"),
            TokenSlice(.number, "1"),
            TokenSlice(.string, "%w(x y)"),
        ])
    }

    @Test func largeBufferStabilityAndLinearPerformance() {
        let chunk = """
        def compute(items)
          items.select { it.valid? && it.score / 2 > 0 }
               .then { /ok/.match?(it.to_s) }
          if ready?
            && /ready/i.match?(status)
            || fallback?
            puts <<~MSG
              value=#{items.size}
            MSG
          end
        end

        """
        let chunkTokens = tokenize(chunk)
        let repeatCount = 600
        let largeSource = String(repeating: chunk, count: repeatCount)
        let ns = largeSource as NSString
        #expect(ns.length > 100_000)

        let clock = ContinuousClock()
        let start = clock.now
        let tokens = RubyTokenizer.shared.tokenize(ns)
        let elapsed = start.duration(to: clock.now)

        assertInvariants(tokens, length: ns.length)
        #expect(tokens.count == chunkTokens.count * repeatCount)
        #expect(elapsed < .seconds(2))

        // Guard against quadratic scanning on long division-heavy lines.
        let slashLine = String(repeating: "a / b / ", count: 2_000) + "1"
        let slashTokens = tokenize(slashLine)
        #expect(slashTokens.count == 1)
    }

    // MARK: - Unicode & Robustness

    @Test func utf16OffsetsRemainExactAroundEmojis() {
        let source = "# 😀\n\"a😀b\" + :ok + 123"
        #expect(mergedSlices(in: source) == [
            TokenSlice(.comment, "# 😀"),
            TokenSlice(.string, "\"a😀b\""),
            TokenSlice(.attribute, ":ok"),
            TokenSlice(.number, "123"),
        ])
    }

    @Test(arguments: [
        "",
        "\"",
        "'unterminated",
        "`cmd #{unclosed",
        "\"#{ { nested: 1",
        "=begin\nunclosed",
        "<<EOF\nunclosed",
        "%w(a (b",
        "/",
        "/unclosed",
        "$",
        "@",
        "@@",
        ":",
        "?",
        "?\\",
        "?\\M-",
        "?\\x",
        "0x",
        "def",
        "def self.",
        "def Foo::Bar.",
        "def f(x) =",
        "case x in",
        "if a\n  &&",
        "foo(*, **",
        "a%w",
        "\\",
        "😀",
    ])
    func malformedOrIncompleteBuffersTerminateCleanly(source: String) {
        _ = tokenize(source)
    }
}
