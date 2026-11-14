import Foundation
import Testing
@testable import Silica

@Suite("SyntaxLanguage")
struct SyntaxLanguageTests {
    @Test(arguments: [
        ("Gemfile", SyntaxLanguage.ruby),
        ("Rakefile", SyntaxLanguage.ruby),
        ("Podfile", SyntaxLanguage.ruby),
        ("Fastfile", SyntaxLanguage.ruby),
        ("Brewfile", SyntaxLanguage.ruby),
        ("Guardfile", SyntaxLanguage.ruby),
        ("Capfile", SyntaxLanguage.ruby),
        ("Vagrantfile", SyntaxLanguage.ruby),
        ("config.ru", SyntaxLanguage.ruby),
        (".irbrc", SyntaxLanguage.ruby),
        (".pryrc", SyntaxLanguage.ruby),
        (".simplecov", SyntaxLanguage.ruby),
        ("app.rb", SyntaxLanguage.ruby),
        ("tasks.rake", SyntaxLanguage.ruby),
        ("foo.gemspec", SyntaxLanguage.ruby),
        ("show.json.jbuilder", SyntaxLanguage.ruby),
        ("user.rabl", SyntaxLanguage.ruby),
        ("Gemfile.lock", nil),
    ])
    func detectsRubyFilenamesAndExtensions(filename: String, expected: SyntaxLanguage?) {
        let detected = SyntaxLanguage(url: URL(filePath: "/tmp/\(filename)"))
        #expect(detected == expected)
    }

    @Test(arguments: [
        ("#!/usr/bin/env ruby\nputs 1", SyntaxLanguage.ruby),
        ("#!/usr/bin/env -S ruby -w\nputs 1", SyntaxLanguage.ruby),
        ("#!/usr/bin/ruby3.3 -w\nputs 1", SyntaxLanguage.ruby),
        ("#!/usr/bin/ruby3.4 -w\nputs 1", SyntaxLanguage.ruby),
        ("#!/usr/bin/ruby4.0 -w\nputs 1", SyntaxLanguage.ruby),
        ("#!/usr/bin/env -S ruby4.0 -w\nputs 1", SyntaxLanguage.ruby),
        ("#!/usr/bin/env jruby\nputs 1", SyntaxLanguage.ruby),
        ("#!/usr/bin/env RUBYOPT=-W0 ruby\nputs 1", SyntaxLanguage.ruby),
        ("#!/Users/ruby/bin/python3\nprint(1)", SyntaxLanguage.python),
        ("#!/usr/bin/env -S python3 /path/to/ruby/tool\nprint(1)", SyntaxLanguage.python),
        ("#!/bin/sh\necho hi", SyntaxLanguage.shell),
        ("#!/usr/bin/env node\nconsole.log(1)", SyntaxLanguage.javascript),
        ("puts 'no shebang'", nil),
    ])
    func detectsExtensionlessFilesByShebang(text: String, expected: SyntaxLanguage?) {
        let detected = SyntaxLanguage(url: URL(filePath: "/tmp/bin/script"), text: text)
        #expect(detected == expected)
    }

    @Test(arguments: ["ruby", "rb", "irb", "pry", "jruby"])
    func resolvesRubyMarkdownFences(fenceName: String) {
        #expect(SyntaxLanguage(fenceName: fenceName) == .ruby)
    }

    @Test func rubyLanguageRoutesToRubyTokenizer() {
        #expect(SyntaxLanguage.ruby.tokenizer is RubyTokenizer)
    }
}
