import Foundation

/// SipHash-1-3 (64-bit output) with a caller-supplied key.
///
/// Vendored so feature hashes are stable across processes and releases;
/// `Swift.Hasher` is per-process seeded and must never be used for
/// persisted features. This matches the reference construction
/// (Aumasson & Bernstein 2012) with 1 compression round per block and
/// 3 finalization rounds.
enum SipHash13 {
    static func hash(k0: UInt64, k1: UInt64, _ input: [UInt8]) -> UInt64 {
        var v0 = k0 ^ 0x736f_6d65_7073_6575
        var v1 = k1 ^ 0x646f_7261_6e64_6f6d
        var v2 = k0 ^ 0x6c79_6765_6e65_7261
        var v3 = k1 ^ 0x7465_6462_7974_6573

        func sipRound() {
            v0 &+= v1
            v1 = (v1 << 13) | (v1 >> 51)
            v1 ^= v0
            v0 = (v0 << 32) | (v0 >> 32)
            v2 &+= v3
            v3 = (v3 << 16) | (v3 >> 48)
            v3 ^= v2
            v0 &+= v3
            v3 = (v3 << 21) | (v3 >> 43)
            v3 ^= v0
            v2 &+= v1
            v1 = (v1 << 17) | (v1 >> 47)
            v1 ^= v2
            v2 = (v2 << 32) | (v2 >> 32)
        }

        // Full 8-byte blocks, little-endian.
        var i = 0
        while i + 8 <= input.count {
            var m: UInt64 = 0
            var j = i + 8
            while j > i {
                m = (m << 8) | UInt64(input[j - 1])
                j -= 1
            }
            v3 ^= m
            sipRound()
            v0 ^= m
            i += 8
        }

        // Final block: remaining bytes little-endian, total length in
        // the top byte (reference behavior; inputs here are far below
        // the 255-byte length-byte cap).
        var tail: UInt64 = 0
        var shift: UInt64 = 0
        while i < input.count {
            tail |= UInt64(input[i]) << shift
            shift += 8
            i += 1
        }
        tail |= UInt64(input.count & 0xff) << 56
        v3 ^= tail
        sipRound()
        v0 ^= tail

        v2 ^= 0xff
        sipRound()
        sipRound()
        sipRound()
        return v0 ^ v1 ^ v2 ^ v3
    }
}

/// A minimal generic shell lexer. It knows shell *structure* — quoting,
/// escapes, operators, substitution boundaries — but no command names.
/// Command and process substitutions (`$(...)`, backticks, `<(...)`,
/// `>(...)`) are flattened: their contents are lexed and inlined, so
/// `echo $(date)` and `echo \`date\`` produce identical token streams.
/// Heredoc bodies are consumed rather than lexed as commands. Quoted
/// substitutions (`"...$(x)..."`) remain literal.
enum ShellLexer {
    struct Token: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// A word (possibly quoted or escaped, with `A=B` env
            /// prefixes kept whole).
            case word
            /// A control operator: `| & ; ( ) && || ;; ;& ;;& |&`
            case op
            /// A redirection: `< > >> << <<- <<< &> >& <& 2> 2>> 2>&1`
            case redirect
        }

        var text: String
        var kind: Kind
    }

    /// A token plus its raw position in the lexed line, so callers can
    /// slice the original text instead of the flattened token stream.
    /// `start`/`end` are character offsets into the line (half-open,
    /// `end` exclusive) covering exactly the raw characters that
    /// produced the token, quotes and escapes included. `nested` is
    /// true when the token came from inside a `$(...)`, backtick, or
    /// process substitution rather than the top-level line.
    struct LocatedToken: Sendable {
        var token: Token
        var start: Int
        var end: Int
        var nested: Bool
    }

    /// Three-character operators merged into single tokens.
    private static let threeCharOperators: Set<String> = [";;&", "<<<", "<<-"]

    /// Two-character operators merged into single tokens.
    private static let twoCharOperators: Set<String> = [
        "&&", "||", ";;", ";&", "|&", "&>", ">>", "<<", ">&", "<&",
    ]

    /// Split a command line into tokens. Unquoted `#` at the start of
    /// a token comments out the rest of the line. Unterminated quotes
    /// simply end at end-of-input.
    static func tokens(_ line: String) -> [Token] {
        locatedTokens(line).map(\.token)
    }

    /// `tokens(_:)` with each token's raw range and substitution
    /// nesting recorded.
    static func locatedTokens(_ line: String) -> [LocatedToken] {
        var lexer = Scanner(chars: Array(line))
        return lexer.scan()
    }

    /// Normalized form of a command line for deduplication: trimmed,
    /// quoting flattened, substitution contents inlined, and whitespace
    /// runs collapsed by re-joining the token stream with single
    /// spaces. Comments and heredoc bodies disappear.
    static func normalize(_ line: String) -> String {
        tokens(line).map(\.text).joined(separator: " ")
    }

    /// Single-pass scanner over one command line. `substitutionDepth`
    /// is non-nil while inside `$(...)`, backticks, or process
    /// substitution: nested `(` increments it, `)` at depth 0 closes.
    private struct Scanner {
        let chars: [Character]
        private var tokens: [LocatedToken] = []
        private var word: [Character] = []
        private var wordOpen = false
        /// Char offset of the first raw character of the open word.
        private var wordStart = 0
        private var i = 0
        private var substitutionDepth: Int?
        /// Heredoc bodies (oldest first) not yet consumed.
        private var pendingHeredocs: [(delimiter: String, stripTabs: Bool)] = []
        /// Set right after `<<`/`<<-`; the next word is its delimiter.
        private var awaitingHeredocDelimiter: Bool?

        /// Explicit init: the implicit memberwise initializer inherits
        /// the private access of the stored properties, which older
        /// Swift compilers (Xcode 26.6 / Swift 6.2) reject at the
        /// call site in `tokens(_:)`.
        init(chars: [Character]) {
            self.chars = chars
        }

        /// True while lexing substitution contents rather than the
        /// top-level line.
        private var nested: Bool { substitutionDepth != nil }

        mutating func scan() -> [LocatedToken] {
            while i < chars.count {
                if step(closer: nil) { break }
            }
            flushWord()
            return tokens
        }

        /// Record one token whose raw characters ended just before the
        /// read cursor.
        private mutating func appendToken(
            _ text: String, _ kind: Token.Kind, start: Int
        ) {
            tokens.append(LocatedToken(
                token: Token(text: text, kind: kind),
                start: start,
                end: i,
                nested: nested))
        }

        /// Advance one character. Returns true when a substitution
        /// closer (`)` at depth 0, or the closing backtick) has been
        /// consumed and the caller's scan should stop.
        private mutating func step(closer: Character?) -> Bool {
            let c = chars[i]

            if c == closer {
                flushWord()
                i += 1
                return true
            }

            // Newlines separate commands; with heredoc bodies pending
            // they start body consumption instead.
            if c == "\n" {
                newline()
                return false
            }

            // Whitespace separates tokens.
            if c.isWhitespace {
                flushWord()
                i += 1
                return false
            }

            // Backslash escape outside quotes: `\<newline>` is a line
            // continuation, `\x` is a literal x.
            if c == "\\" {
                if !wordOpen { wordStart = i }
                wordOpen = true
                if i + 1 < chars.count {
                    let n = chars[i + 1]
                    if n.isNewline {
                        i += 2
                    } else {
                        word.append(n)
                        i += 2
                    }
                } else {
                    i += 1
                }
                return false
            }

            // Single quotes: everything literal until the closing quote.
            if c == "'" {
                if !wordOpen { wordStart = i }
                wordOpen = true
                i += 1
                while i < chars.count, chars[i] != "'" {
                    word.append(chars[i])
                    i += 1
                }
                i += 1
                return false
            }

            // Double quotes: `$ ` " \ newline` are escapes; a backslash
            // before anything else stays literal.
            if c == "\"" {
                if !wordOpen { wordStart = i }
                wordOpen = true
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count {
                        let n = chars[i + 1]
                        switch n {
                        case "$", "`", "\"", "\\":
                            word.append(n)
                        case "\n":
                            break
                        default:
                            word.append(chars[i])
                            word.append(n)
                        }
                        i += 2
                    } else {
                        word.append(chars[i])
                        i += 1
                    }
                }
                i += 1
                return false
            }

            // Unquoted `#` at the start of a token comments out the
            // rest of the line.
            if c == "#", !wordOpen {
                i = chars.count
                return false
            }

            // Command substitution `$(...)`: inline the lexed contents.
            if c == "$", i + 1 < chars.count, chars[i + 1] == "(" {
                flushWord()
                i += 2
                substitution(closer: nil)
                return false
            }

            // Backtick substitution: inline the lexed contents.
            if c == "`" {
                flushWord()
                i += 1
                substitution(closer: "`")
                return false
            }

            // Process substitution `<(...)`/`>(...)`: drop the syntax,
            // inline the lexed contents.
            if (c == "<" || c == ">"), i + 1 < chars.count, chars[i + 1] == "(" {
                flushWord()
                i += 2
                substitution(closer: nil)
                return false
            }

            // `)` closes a nested `(` inside a substitution, closes
            // the substitution itself at depth 0, or is a plain operator.
            if c == ")" {
                flushWord()
                if substitutionDepth != nil {
                    if substitutionDepth! > 0 {
                        substitutionDepth! -= 1
                        appendToken(")", .op, start: i)
                        i += 1
                        return false
                    }
                    substitutionDepth = nil
                    i += 1
                    return true
                }
                appendToken(")", .op, start: i)
                i += 1
                return false
            }

            // `(` groups subshells; inside substitutions it nests.
            if c == "(" {
                flushWord()
                if substitutionDepth != nil {
                    substitutionDepth! += 1
                }
                appendToken("(", .op, start: i)
                i += 1
                return false
            }

            // FD redirection: a digit starting a token immediately
            // followed by `>` (e.g. `2>`, `2>>`, `2>&1`).
            if !wordOpen, c.isASCII, c.isNumber,
               i + 1 < chars.count, chars[i + 1] == ">" {
                var text = String(c) + ">"
                let start = i
                i += 2
                if i < chars.count, chars[i] == ">" {
                    text.append(">")
                    i += 1
                } else if i < chars.count, chars[i] == "&" {
                    text.append("&")
                    i += 1
                    if i < chars.count, chars[i].isASCII, chars[i].isNumber {
                        text.append(chars[i])
                        i += 1
                    }
                }
                appendToken(text, .redirect, start: start)
                return false
            }

            // Operators and redirects.
            if "|&;<>".contains(c) {
                flushWord()
                let start = i
                // Three-character operators first.
                if i + 2 < chars.count {
                    let triple = String(chars[i]) + String(chars[i + 1])
                        + String(chars[i + 2])
                    if threeCharOperators.contains(triple) {
                        appendToken(
                            triple, triple == ";;&" ? .op : .redirect, start: start)
                        // `<<-` is a tab-stripping heredoc whose delimiter
                        // arrives as the next word; `<<<` is a herestring
                        // and consumes the rest of the line instead, so it
                        // must not arm delimiter collection. Plain `<<` is
                        // two characters and is handled below.
                        if triple == "<<-" {
                            awaitingHeredocDelimiter = true
                        }
                        i += 3
                        return false
                    }
                }
                if i + 1 < chars.count {
                    let pair = String(c) + String(chars[i + 1])
                    if twoCharOperators.contains(pair) {
                        let kind: Token.Kind = (pair.contains("<") || pair.contains(">"))
                            ? .redirect : .op
                        appendToken(pair, kind, start: start)
                        if pair == "<<" {
                            awaitingHeredocDelimiter = false
                        }
                        i += 2
                        return false
                    }
                }
                let kind: Token.Kind = (c == "<" || c == ">") ? .redirect : .op
                appendToken(String(c), kind, start: start)
                i += 1
                return false
            }

            if !wordOpen { wordStart = i }
            word.append(c)
            wordOpen = true
            i += 1
            return false
        }

        /// Lex until the substitution closes, restoring the entry depth
        /// so enclosing contexts are unaffected.
        private mutating func substitution(closer: Character?) {
            let base = substitutionDepth
            substitutionDepth = 0
            while i < chars.count {
                if step(closer: closer) { break }
            }
            substitutionDepth = base
        }

        /// Consume a newline: plain whitespace at top level, but the
        /// trigger for heredoc body consumption when bodies are pending.
        private mutating func newline() {
            flushWord()
            i += 1
            guard !pendingHeredocs.isEmpty else { return }
            // Skip lines until one matches the oldest pending delimiter
            // (leading tabs stripped for `<<-`).
            while i < chars.count {
                let start = i
                while i < chars.count, chars[i] != "\n" { i += 1 }
                var line = String(chars[start..<i])
                if i < chars.count { i += 1 }
                if pendingHeredocs[0].stripTabs {
                    while line.first == "\t" { line.removeFirst() }
                }
                if line == pendingHeredocs[0].delimiter {
                    pendingHeredocs.removeFirst()
                    if pendingHeredocs.isEmpty { break }
                }
            }
        }

        private mutating func flushWord() {
            guard wordOpen else { return }
            wordOpen = false
            if let stripTabs = awaitingHeredocDelimiter {
                awaitingHeredocDelimiter = nil
                pendingHeredocs.append((String(word), stripTabs))
            } else {
                appendToken(String(word), .word, start: wordStart)
            }
            word = []
        }
    }
}

/// Generic n-gram feature extraction over shell commands. Produces
/// stable SipHash-1-3 feature hashes with fixed weights; nothing here
/// knows any command name, so the feature space grows with whatever the
/// user actually runs.
enum CommandFeatureExtractor {
    /// Bump when the extraction logic changes; features are stored per
    /// extractor version and old versions stop matching. v2 flattens
    /// command/process substitutions into the token stream, so v1 rows
    /// for substitution-containing commands no longer match.
    static let version = 2

    /// SipHash key: the first 16 ASCII bytes of "niftty-prediction-v1"
    /// ("niftty-p" / "redictio"). Fixed forever; changing it
    /// invalidates every stored feature.
    private static let keyBytes = Array("niftty-prediction-v1".utf8.prefix(16))
    private static let k0 = littleEndian(keyBytes[0..<8])
    private static let k1 = littleEndian(keyBytes[8..<16])

    /// Stable hash of one feature string (namespace prefix included).
    static func hash(_ feature: String) -> UInt64 {
        SipHash13.hash(k0: k0, k1: k1, Array(feature.utf8))
    }

    /// Features for one command line: word/bigram/trigram unigrams over
    /// the lexer's word tokens plus bounded character n-grams. Duplicate
    /// features accumulate their weights.
    static func features(_ command: String) -> [(hash: UInt64, weight: Double)] {
        let words = ShellLexer.tokens(command)
            .filter { $0.kind == .word }
            .map { $0.text.lowercased() }
        guard !words.isEmpty else { return [] }

        var acc: [UInt64: Double] = [:]
        func add(_ feature: String, _ weight: Double) {
            acc[hash(feature), default: 0] += weight
        }

        // The executable is the first word that is not an env
        // assignment (`FOO=1 cmd...`); assignments are plain words.
        let execIndex = words.firstIndex { !isEnvAssignment($0) } ?? words.startIndex
        for (index, word) in words.enumerated() {
            add("w:\(word)", index == execIndex ? 4.0 : 3.0)
        }
        // `words.count - 1`/`- 2` underflow the Range for short word
        // lists, so gate each loop on its minimum length.
        if words.count >= 2 {
            for i in 0..<(words.count - 1) {
                add("b:\(words[i]) \(words[i + 1])", 2.0)
            }
        }
        if words.count >= 3 {
            for i in 0..<(words.count - 2) {
                add("t:\(words[i]) \(words[i + 1]) \(words[i + 2])", 1.5)
            }
        }

        // Character 3-/4-grams with boundary markers, only for short
        // tokens; long numeric-looking tokens (hashes, ids) are skipped
        // because their grams are pure noise.
        for word in words {
            guard word.count <= 24, !isNumericLooking(word) else { continue }
            let marked = Array("^" + word + "$")
            for n in 3...4 where marked.count >= n {
                for start in 0...(marked.count - n) {
                    let gram = String(marked[start..<(start + n)])
                    add("c\(n):\(gram)", 0.5)
                }
            }
        }

        return acc.map { (hash: $0.key, weight: $0.value) }
    }

    /// `NAME=value` where NAME is a shell identifier.
    private static func isEnvAssignment(_ word: String) -> Bool {
        guard let eq = word.firstIndex(of: "="), eq != word.startIndex else { return false }
        let name = word[word.startIndex..<eq]
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Longer than 4 characters, entirely hex, and containing at least
    /// one digit: commit hashes and ids.
    private static func isNumericLooking(_ word: String) -> Bool {
        word.count > 4
            && word.allSatisfy(\.isHexDigit)
            && word.contains(where: \.isNumber)
    }

    private static func littleEndian(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        var value: UInt64 = 0
        for (i, b) in bytes.enumerated() {
            value |= UInt64(b) << (8 * UInt64(i))
        }
        return value
    }
}
