// This file contains various default word boundaries used for
// selection logic. We put it in a separate file so that different
// subsystems can import it without introducing a number of
// dependencies.

/// Punctuation that delimits words, on top of Unicode whitespace which
/// always splits (see `isWhitespace`). Kept free of exotic spaces so the
/// config/Settings default stays a readable `"\t '\"│`|:;,()[]{}<>$"` instead
/// of a blob of NBSP/line-separator glyphs.
pub const default_word_boundaries = [_]u21{
    0, // null
    '\t', // tab
    ' ', // space
    '\'', // single quote
    '"', // double quote
    '│', // U+2502 box drawing
    '`', // backtick
    '|', // pipe
    ':', // colon
    ';', // semicolon
    ',', // comma
    '(', // left paren
    ')', // right paren
    '[', // left bracket
    ']', // right bracket
    '{', // left brace
    '}', // right brace
    '<', // less than
    '>', // greater than
    '$', // dollar
};

/// Unicode White_Space (and ASCII space/tab). Always a word boundary so
/// prompt themes that emit NBSP still split, without putting those glyphs
/// in the user-facing default string.
pub fn isWhitespace(cp: u21) bool {
    return switch (cp) {
        ' ',
        '\t',
        '\n',
        '\r',
        0x85, // NEL
        0xA0, // no-break space
        0x1680, // ogham space mark
        0x2000...0x200A, // en quad .. hair space
        0x2028, // line separator
        0x2029, // paragraph separator
        0x202F, // narrow no-break space
        0x205F, // medium mathematical space
        0x3000, // ideographic space
        => true,
        else => false,
    };
}

/// Default whitespace characters trimmed from line selections.
pub const default_line_whitespace = [_]u21{ 0, ' ', '\t' };
