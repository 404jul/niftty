// This file contains various default word boundaries used for
// selection logic. We put it in a separate file so that different
// subsystems can import it without introducing a number of
// dependencies.

/// Default boundary characters for word selection:
/// ` \t'"│`|:;,()[]{}<>$` plus all Unicode whitespace (so prompt themes
/// that emit non-breaking or other exotic spaces still split words).
pub const default_word_boundaries = [_]u21{
    0, // null
    ' ', // space
    '\t', // tab
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

    // Unicode whitespace beyond ASCII. These are the Unicode White_Space
    // codepoints not already listed above.
    0x85, // NEL
    0xA0, // no-break space
    0x1680, // ogham space mark
    0x2000, // en quad
    0x2001, // em quad
    0x2002, // en space
    0x2003, // em space
    0x2004, // three-per-em space
    0x2005, // four-per-em space
    0x2006, // six-per-em space
    0x2007, // figure space
    0x2008, // punctuation space
    0x2009, // thin space
    0x200A, // hair space
    0x2028, // line separator
    0x2029, // paragraph separator
    0x202F, // narrow no-break space
    0x205F, // medium mathematical space
    0x3000, // ideographic space
};

/// Default whitespace characters trimmed from line selections.
pub const default_line_whitespace = [_]u21{ 0, ' ', '\t' };
