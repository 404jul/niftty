import Foundation
import Testing
@testable import Ghostty

struct CommandFeatureTests {
    // MARK: Lexer

    private func lex(_ line: String) -> [ShellLexer.Token] {
        ShellLexer.tokens(line)
    }

    @Test func lexerSplitsQuotedSpaceAndOperators() {
        #expect(lex("a \"b c\" | d>file") == [
            .init(text: "a", kind: .word),
            .init(text: "b c", kind: .word),
            .init(text: "|", kind: .op),
            .init(text: "d", kind: .word),
            .init(text: ">", kind: .redirect),
            .init(text: "file", kind: .word),
        ])
    }

    @Test func lexerMergesMultiCharOperators() {
        #expect(lex("a && b || c ;; d |& e &> f") == [
            .init(text: "a", kind: .word),
            .init(text: "&&", kind: .op),
            .init(text: "b", kind: .word),
            .init(text: "||", kind: .op),
            .init(text: "c", kind: .word),
            .init(text: ";;", kind: .op),
            .init(text: "d", kind: .word),
            .init(text: "|&", kind: .op),
            .init(text: "e", kind: .word),
            .init(text: "&>", kind: .redirect),
            .init(text: "f", kind: .word),
        ])
    }

    @Test func lexerKeepsEnvPrefixWhole() {
        #expect(lex("FOO=bar cmd --flag") == [
            .init(text: "FOO=bar", kind: .word),
            .init(text: "cmd", kind: .word),
            .init(text: "--flag", kind: .word),
        ])
    }

    @Test func lexerTreatsDigitRedirectAsOneToken() {
        #expect(lex("cmd 2>err 2>>all") == [
            .init(text: "cmd", kind: .word),
            .init(text: "2>", kind: .redirect),
            .init(text: "err", kind: .word),
            .init(text: "2>>", kind: .redirect),
            .init(text: "all", kind: .word),
        ])
    }

    @Test func lexerDropsUnquotedCommentButKeepsQuotedHash() {
        #expect(lex("ls -la # trailing comment") == [
            .init(text: "ls", kind: .word),
            .init(text: "-la", kind: .word),
        ])
        #expect(lex("echo '#not-a-comment'") == [
            .init(text: "echo", kind: .word),
            .init(text: "#not-a-comment", kind: .word),
        ])
    }

    @Test func lexerHandlesEscapes() {
        // Unquoted backslash escape preserves the space in one word.
        #expect(lex("echo a\\ b") == [
            .init(text: "echo", kind: .word),
            .init(text: "a b", kind: .word),
        ])
        // Double-quote escapes: \" $ stay escaped, \x stays literal.
        #expect(lex("echo \"a\\\"b \\$c \\d\"") == [
            .init(text: "echo", kind: .word),
            .init(text: "a\"b $c \\d", kind: .word),
        ])
        // Single quotes are fully literal: 'a\' closes after the
        // backslash, `b` continues the word unquoted, and the
        // trailing quote reopens and closes empty.
        #expect(lex("echo 'a\\'b $HOME'") == [
            .init(text: "echo", kind: .word),
            .init(text: "a\\b", kind: .word),
            .init(text: "$HOME", kind: .word),
        ])
    }

    @Test func lexerFlattensCommandSubstitution() {
        // Substitution contents are lexed and inlined, so both spellings
        // normalize identically.
        #expect(lex("echo $(date)") == [
            .init(text: "echo", kind: .word),
            .init(text: "date", kind: .word),
        ])
        #expect(lex("echo `date`") == lex("echo $(date)"))
        #expect(ShellLexer.normalize("echo $(date)") == ShellLexer.normalize("echo `date`"))
    }

    @Test func lexerFlattensNestedSubstitution() {
        #expect(lex("echo $(cmd $(sub) end)") == [
            .init(text: "echo", kind: .word),
            .init(text: "cmd", kind: .word),
            .init(text: "sub", kind: .word),
            .init(text: "end", kind: .word),
        ])
    }

    @Test func lexerFlattensProcessSubstitution() {
        #expect(lex("diff <(sort a) <(sort b)") == [
            .init(text: "diff", kind: .word),
            .init(text: "sort", kind: .word),
            .init(text: "a", kind: .word),
            .init(text: "sort", kind: .word),
            .init(text: "b", kind: .word),
        ])
    }

    @Test func lexerKeepsParameterExpansionWhole() {
        #expect(lex("echo ${HOME}/bin") == [
            .init(text: "echo", kind: .word),
            .init(text: "${HOME}/bin", kind: .word),
        ])
    }

    @Test func lexerEscapedParenDoesNotCloseSubstitution() {
        #expect(lex("echo $(a b\\) c)") == [
            .init(text: "echo", kind: .word),
            .init(text: "a", kind: .word),
            .init(text: "b)", kind: .word),
            .init(text: "c", kind: .word),
        ])
    }

    @Test func lexerMergesCaseTerminatorsAndFdDup() {
        #expect(lex("a ;;& b ;& c") == [
            .init(text: "a", kind: .word),
            .init(text: ";;&", kind: .op),
            .init(text: "b", kind: .word),
            .init(text: ";&", kind: .op),
            .init(text: "c", kind: .word),
        ])
        #expect(lex("cmd >&2 2>&1") == [
            .init(text: "cmd", kind: .word),
            .init(text: ">&", kind: .redirect),
            .init(text: "2", kind: .word),
            .init(text: "2>&1", kind: .redirect),
        ])
    }

    @Test func lexerSkipsHeredocBodies() {
        #expect(lex("cat <<EOF\nbody line\nEOF\necho done") == [
            .init(text: "cat", kind: .word),
            .init(text: "<<", kind: .redirect),
            .init(text: "echo", kind: .word),
            .init(text: "done", kind: .word),
        ])
        #expect(ShellLexer.normalize("cat << EOF\nx\nEOF") == "cat <<")
        // `<<-` strips leading tabs before matching the delimiter.
        #expect(lex("cat <<-END\n\tindented\nEND\nls") == [
            .init(text: "cat", kind: .word),
            .init(text: "<<-", kind: .redirect),
            .init(text: "ls", kind: .word),
        ])
    }

    @Test func normalizeCollapsesWhitespaceAndTrim() {
        #expect(ShellLexer.normalize("  ls   -la\t|grep  foo ") == "ls -la | grep foo")
        #expect(ShellLexer.normalize("   ") == "")
        #expect(ShellLexer.normalize("# only a comment") == "")
    }

    // MARK: SipHash

    @Test func sipHash13MatchesReferenceConstruction() {
        // Key 00..0f little-endian; the vendored 1-3 round counts were
        // cross-checked against the official SipHash reference vectors.
        let k0: UInt64 = 0x0706_0504_0302_0100
        let k1: UInt64 = 0x0f0e_0d0c_0b0a_0908
        #expect(SipHash13.hash(k0: k0, k1: k1, []) == 0xabac_0158_050f_c4dc)
        #expect(SipHash13.hash(k0: k0, k1: k1, [0x00]) == 0xc9f4_9bf3_7d57_ca93)
    }

    @Test func featureHashIsStableWithKnownVector() {
        // Pin the app key ("niftty-p" / "redictio") so it can never
        // silently change.
        #expect(CommandFeatureExtractor.hash("w:zig") == 0xa07c_1d8c_4169_e192)
        #expect(CommandFeatureExtractor.hash("c3:^zi") == 0x4ac3_36c8_0423_7f14)
        #expect(CommandFeatureExtractor.hash("w:zig") == CommandFeatureExtractor.hash("w:zig"))
    }

    // MARK: Extractor

    private func weight(of feature: String, in features: [(hash: UInt64, weight: Double)]) -> Double? {
        features.first { $0.hash == CommandFeatureExtractor.hash(feature) }?.weight
    }

    @Test func featureSetForZigBuildIncludesExpectedFeatures() {
        let features = CommandFeatureExtractor.features("zig build")
        #expect(weight(of: "w:zig", in: features) != nil)
        #expect(weight(of: "w:build", in: features) != nil)
        #expect(weight(of: "b:zig build", in: features) != nil)
        #expect(weight(of: "c3:^zi", in: features) != nil)
        #expect(weight(of: "c4:zig$", in: features) != nil)
        #expect(weight(of: "w:nosuch", in: features) == nil)
    }

    @Test func executableTokenOutweighsArguments() {
        let features = CommandFeatureExtractor.features("zig build test")
        #expect(weight(of: "w:zig", in: features) == 4.0)
        #expect(weight(of: "w:build", in: features) == 3.0)
        #expect(weight(of: "w:test", in: features) == 3.0)
    }

    @Test func envPrefixDoesNotStealExecutableWeight() {
        let features = CommandFeatureExtractor.features("FOO=1 zig build")
        #expect(weight(of: "w:zig", in: features) == 4.0)
        #expect(weight(of: "w:foo=1", in: features) == 3.0)
    }

    @Test func duplicateFeaturesAccumulateWeights() {
        // "git" appears twice: once as executable (4.0), once as an
        // argument (3.0).
        let features = CommandFeatureExtractor.features("git commit git")
        #expect(weight(of: "w:git", in: features) == 7.0)
    }

    @Test func longNumericLookingTokenSkipsCharGrams() {
        let features = CommandFeatureExtractor.features("deploy a1b2c3d4")
        #expect(weight(of: "w:a1b2c3d4", in: features) != nil)
        #expect(weight(of: "c3:^a1", in: features) == nil)
        // Short numeric tokens keep their char grams.
        let short = CommandFeatureExtractor.features("deploy 1234")
        #expect(weight(of: "c3:^12", in: short) != nil)
        // Hex letters without any digit are words, not numbers.
        let words = CommandFeatureExtractor.features("deploy decade")
        #expect(weight(of: "c3:^de", in: words) != nil)
    }

    @Test func emptyAndCommentOnlyCommandsHaveNoFeatures() {
        #expect(CommandFeatureExtractor.features("   ").isEmpty)
        #expect(CommandFeatureExtractor.features("# comment").isEmpty)
        #expect(CommandFeatureExtractor.features("").isEmpty)
    }
}
