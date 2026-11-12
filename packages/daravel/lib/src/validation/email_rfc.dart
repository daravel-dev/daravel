// A port of the RFC email parser of egulias/EmailValidator 4.0.4
// (src/EmailLexer.php, src/EmailParser.php, src/Parser.php, src/Parser/*,
// src/Validation/RFCValidation.php, NoRFCWarningsValidation.php) and of the
// lexer it extends, doctrine/lexer 3.0.1 (src/AbstractLexer.php), which
// Laravel's `email` and `email:rfc` / `email:strict` rules use.
//
// egulias/EmailValidator: Copyright (c) 2013-2023 Eduardo Gulias Davis.
// doctrine/lexer: Copyright (c) 2006-2018 Doctrine Project.
// Both under the MIT License:
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the
// "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to permit
// persons to whom the Software is furnished to do so, subject to the
// following conditions:
//
// The above copyright notice and this permission notice shall be included
// in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
// OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
// NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
// DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
// OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
// USE OR OTHER DEALINGS IN THE SOFTWARE.

import 'dart:convert';

import 'dns.dart' show punycode;

/// The result of egulias' RFC parser for one address: [valid] (its
/// `RFCValidation`) and whether it raised any [warnings] (its
/// `NoRFCWarningsValidation`, Laravel's `email:strict`, requires none).
typedef RfcEmailResult = ({bool valid, Set<String> warnings});

/// Parses [email] as egulias/EmailValidator 4's `EmailParser`.
RfcEmailResult parseRfcEmail(String email) {
  final parser = _EmailParser(_Lexer(email));
  try {
    final valid = parser.parse();
    return (valid: valid, warnings: parser.warnings);
  } on _ParseError {
    // RFCValidation catches any exception as an invalid address.
    return (valid: false, warnings: parser.warnings);
  }
}

/// `email:rfc` (and plain `email`): egulias' `RFCValidation`.
bool rfcEmailValid(String email) => parseRfcEmail(email).valid;

/// `email:strict`: egulias' `NoRFCWarningsValidation`, valid with no
/// warning.
bool strictEmailValid(String email) {
  final result = parseRfcEmail(email);
  return result.valid && result.warnings.isEmpty;
}

// ---------------------------------------------------------------------------
// Lexer (EmailLexer over doctrine's AbstractLexer)
// ---------------------------------------------------------------------------

const int _sEmpty = -1;
const int _cNul = 0;
const int _sHtab = 9;
const int _sLf = 10;
const int _sCr = 13;
const int _sSp = 32;
const int _sDquote = 34;
const int _sOpenParenthesis = 40;
const int _sCloseParenthesis = 41;
const int _sComma = 44;
const int _sHyphen = 45;
const int _sDot = 46;
const int _sSlash = 47;
const int _sColon = 58;
const int _sSemicolon = 59;
const int _sLowerThan = 60;
const int _sGreaterThan = 62;
const int _sAt = 64;
const int _sOpenBracket = 91;
const int _sBackslash = 92;
const int _sCloseBracket = 93;
const int _cDel = 127;
const int _generic = 300;
const int _sIpv6Tag = 301;
const int _invalid = 302;
const int _crlf = 1310;
const int _sDoubleColon = 5858;

const Map<String, int> _charValue = {
  '{': 123,
  '}': 125,
  '(': _sOpenParenthesis,
  ')': _sCloseParenthesis,
  '<': _sLowerThan,
  '>': _sGreaterThan,
  '[': _sOpenBracket,
  ']': _sCloseBracket,
  ':': _sColon,
  ';': _sSemicolon,
  '@': _sAt,
  r'\': _sBackslash,
  '/': _sSlash,
  ',': _sComma,
  '.': _sDot,
  "'": 39,
  '`': 96,
  '"': _sDquote,
  '-': _sHyphen,
  '::': _sDoubleColon,
  ' ': _sSp,
  '\t': _sHtab,
  '\r': _sCr,
  '\n': _sLf,
  '\r\n': _crlf,
  'IPv6': _sIpv6Tag,
  '': _sEmpty,
  // PHP's '\0' in single quotes: a backslash and a zero, not NUL.
  r'\0': _cNul,
  '*': 42,
  '!': 33,
  '&': 38,
  '^': 94,
  r'$': 36,
  '%': 37,
  '~': 126,
  '|': 124,
  '_': 95,
  '=': 61,
  '+': 43,
  '¿': 168,
  '?': 63,
  '#': 35,
  '¡': 173,
};

final class _Token {
  const _Token(this.value, this.type);
  final String value;
  final int type;
  bool isA(int t) => type == t;
  bool isAny(List<int> types) => types.contains(type);
}

const _Token _nullToken = _Token('', _sEmpty);

/// doctrine's scan (preg_split over egulias' catchable patterns, flags
/// `iu`), the pattern the lexer below splits by hand:
/// `([a-zA-Z]+[46]?)|([^\x00-\x7F])|([0-9]+)|(\r\n)|(::)|(\s+?)|(.)`
/// `|[\xA0-\xff]+`. Every position starts a match of one capturing
/// alternative, so no text falls between tokens.
const String emailRfcScanPattern =
    r'([a-zA-Z]+[46]?)|([^\x00-\x7F])|([0-9]+)|(\r\n)|(::)|(\s+?)|(.)'
    r'|[\xA0-\xff]+';

/// The tokens the lexer splits [input] into (for the test that compares
/// them with [emailRfcScanPattern]).
List<String> emailRfcTokens(String input) => [
  for (final token in _Lexer(input)._tokens) token.value,
];

// EmailLexer::INVALID_CHARS_REGEX: a token made of symbols and controls only.
final RegExp _hasValidChar = RegExp(r'[^\p{S}\p{C}]+', unicode: true);

final class _Lexer {
  /// Splits [input] as [emailRfcScanPattern] does, by hand. A regex match
  /// per character cost 60 to 100 ms on 100 000 characters; this is the
  /// same split in one pass.
  _Lexer(String input) {
    final n = input.length;
    var i = 0;
    while (i < n) {
      final start = i;
      final c = input.codeUnitAt(i);
      if (_letter(input, i)) {
        // ([a-zA-Z]+[46]?) under /iu: letters, ſ and the Kelvin sign.
        while (i < n && _letter(input, i)) {
          i++;
        }
        if (i < n &&
            (input.codeUnitAt(i) == 0x34 || input.codeUnitAt(i) == 0x36)) {
          i++;
        }
        _add(input.substring(start, i), alphanumeric: true);
      } else if (c >= 0x80) {
        // ([^\x00-\x7F]): one code point, a surrogate pair included.
        i +=
            c >= 0xD800 &&
                c <= 0xDBFF &&
                i + 1 < n &&
                input.codeUnitAt(i + 1) >= 0xDC00 &&
                input.codeUnitAt(i + 1) <= 0xDFFF
            ? 2
            : 1;
        _add(input.substring(start, i));
      } else if (c >= 0x30 && c <= 0x39) {
        // ([0-9]+)
        while (i < n &&
            input.codeUnitAt(i) >= 0x30 &&
            input.codeUnitAt(i) <= 0x39) {
          i++;
        }
        _add(input.substring(start, i), alphanumeric: true);
      } else if (c == 0x0D && i + 1 < n && input.codeUnitAt(i + 1) == 0x0A) {
        // (\r\n)
        i += 2;
        _add('\r\n');
      } else if (c == 0x3A && i + 1 < n && input.codeUnitAt(i + 1) == 0x3A) {
        // (::)
        i += 2;
        _add('::');
      } else {
        // (\s+?) takes one ASCII space, (.) any other character: one each.
        i++;
        _add(input.substring(start, i));
      }
    }
  }

  /// Whether a letter of `[a-zA-Z]` under `/iu` starts at [i]: an ASCII
  /// letter, `ſ` (U+017F, folds to s) or the Kelvin sign (U+212A, to k).
  static bool _letter(String input, int i) {
    final c = input.codeUnitAt(i);
    return (c >= 0x41 && c <= 0x5A) ||
        (c >= 0x61 && c <= 0x7A) ||
        c == 0x017F ||
        c == 0x212A;
  }

  /// A lexer at the same place as [other], to look ahead without moving
  /// it. It records nothing: what it reads is never kept.
  _Lexer._copy(_Lexer other)
    : _tokens = other._tokens,
      _position = other._position,
      _lookahead = other._lookahead,
      hasInvalidTokens = other.hasInvalidTokens,
      current = other.current,
      previous = other.previous;

  List<_Token> _tokens = [];
  int _position = 0;
  _Token? _lookahead;
  bool hasInvalidTokens = false;
  _Token current = _nullToken;
  _Token previous = _nullToken;

  /// What is recorded, appended token by token: a buffer, as appending to
  /// a String copies it whole each time (quadratic in the input's length;
  /// PHP appends in place).
  final StringBuffer _accumulator = StringBuffer();
  bool _recording = false;

  void _add(String value, {bool alphanumeric = false}) =>
      _tokens.add(_Token(value, _typeOf(value, alphanumeric: alphanumeric)));

  int _typeOf(String value, {bool alphanumeric = false}) {
    final known = _charValue[value];
    if (known != null) {
      return known;
    }
    if (value == '\u0000') {
      return _cNul;
    }
    // Letters and digits are neither symbols nor controls.
    if (alphanumeric) {
      return _generic;
    }
    if (!_hasValidChar.hasMatch(value)) {
      hasInvalidTokens = true;
      return _invalid;
    }
    return _generic;
  }

  bool moveNext() {
    if (_recording && identical(previous, _nullToken)) {
      _accumulator.write(current.value);
    }
    previous = current;
    _lookahead ??= _nullToken;
    // doctrine's moveNext.
    final token = _lookahead;
    _lookahead = _position < _tokens.length ? _tokens[_position++] : null;
    final hasNext = _lookahead != null;
    current = token ?? _nullToken;
    if (_recording) {
      _accumulator.write(current.value);
    }
    return hasNext;
  }

  bool isNextToken(int type) => _lookahead != null && _lookahead!.isA(type);

  bool isNextTokenAny(List<int> types) =>
      _lookahead != null && _lookahead!.isAny(types);

  /// egulias' `find`: whether a [type] token comes, searched on a copy.
  void find(int type) {
    final search = _Lexer._copy(this);
    while (search._lookahead != null && !search._lookahead!.isA(type)) {
      search.moveNext();
    }
    if (search._lookahead == null) {
      throw const _ParseError();
    }
  }

  void startRecording() => _recording = true;
  void stopRecording() => _recording = false;
  void clearRecorded() => _accumulator.clear();
  String get accumulated => _accumulator.toString();
}

/// An exception the PHP parser lets reach RFCValidation (which catches it).
final class _ParseError implements Exception {
  const _ParseError();
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

int _bytes(String s) => utf8.encode(s).length;

final class _EmailParser {
  _EmailParser(this.lexer);
  final _Lexer lexer;
  final Set<String> warnings = {};
  String _localPart = '';
  String _domainPart = '';

  bool parse() {
    final valid = _parse();
    if (_bytes('$_localPart@$_domainPart') > 254) {
      warnings.add('EmailTooLong');
    }
    return valid;
  }

  bool _parse() {
    if (lexer.hasInvalidTokens) {
      return false;
    }
    // preLeftParsing: hasAtToken, a local part before the first `@`.
    lexer
      ..moveNext()
      ..moveNext();
    if (lexer.current.isA(_sAt)) {
      return false;
    }
    final local = _LocalPart(lexer);
    final localValid = local.parse();
    _localPart = local.localPart;
    warnings.addAll(local.warnings);
    if (!localValid) {
      return false;
    }
    final domain = _DomainPart(lexer);
    final domainValid = domain.parse();
    _domainPart = domain.domainPart;
    warnings.addAll(domain.warnings);
    return domainValid;
  }
}

abstract base class _PartParser {
  _PartParser(this.lexer);
  final _Lexer lexer;
  final Set<String> warnings = {};

  bool parseFws() {
    // _FoldingWhiteSpace.parse's first test, before building one: most
    // tokens are not white space, and this runs for every token.
    if (escaped() ||
        !_FoldingWhiteSpace._fwsTypes.contains(lexer.current.type)) {
      return true;
    }
    final fws = _FoldingWhiteSpace(lexer);
    final valid = fws.parse();
    warnings.addAll(fws.warnings);
    return valid;
  }

  bool consecutiveDots() =>
      lexer.current.isA(_sDot) && lexer.isNextToken(_sDot);

  bool escaped() =>
      lexer.previous.isA(_sBackslash) && !lexer.current.isA(_generic);
}

final class _LocalPart extends _PartParser {
  _LocalPart(super.lexer);

  static const List<int> _invalidTokens = [
    _sComma,
    _sCloseBracket,
    _sOpenBracket,
    _sGreaterThan,
    _sLowerThan,
    _sColon,
    _sSemicolon,
    _invalid,
  ];

  String localPart = '';

  bool parse() {
    lexer
      ..clearRecorded()
      ..startRecording();
    while (!lexer.current.isA(_sAt) && !lexer.current.isA(_sEmpty)) {
      if (lexer.current.isA(_sDot) && lexer.previous.isA(_sEmpty)) {
        return false; // DotAtStart
      }
      if (lexer.current.isA(_sDquote)) {
        final quoted = _DoubleQuote(lexer);
        final valid = quoted.parse();
        warnings.addAll(quoted.warnings);
        if (!valid) {
          return false;
        }
      }
      if (lexer.current.isA(_sOpenParenthesis) ||
          lexer.current.isA(_sCloseParenthesis)) {
        final comment = _Comment(lexer, local: true);
        final valid = comment.parse();
        warnings.addAll(comment.warnings);
        if (!valid) {
          return false;
        }
      }
      if (lexer.current.isA(_sDot) && lexer.isNextToken(_sDot)) {
        return false; // ConsecutiveDot
      }
      if (lexer.current.isA(_sDot) && lexer.isNextToken(_sAt)) {
        return false; // DotAtEnd
      }
      if (lexer.current.isA(_sBackslash) && lexer.isNextToken(_generic)) {
        return false; // Found ATOM after escaping
      }
      if (_invalidTokens.contains(lexer.current.type)) {
        return false; // Invalid token found
      }
      final fws = _FoldingWhiteSpace(lexer);
      if (!fws.parse()) {
        return false;
      }
      warnings.addAll(fws.warnings);
      lexer.moveNext();
    }
    lexer.stopRecording();
    var recorded = lexer.accumulated;
    while (recorded.endsWith('@')) {
      recorded = recorded.substring(0, recorded.length - 1);
    }
    localPart = recorded;
    if (_bytes(localPart) > 64) {
      warnings.add('LocalTooLong');
    }
    return true;
  }
}

final class _DoubleQuote extends _PartParser {
  _DoubleQuote(super.lexer);

  static const List<int> _special = [_sCr, _sHtab, _sLf];
  static const List<int> _invalidTypes = [_cNul, _sHtab, _sCr, _sLf];

  bool parse() {
    if (!_checkDquote()) {
      return false;
    }
    var setSpecialsWarning = true;
    lexer.moveNext();
    while (!lexer.current.isA(_sDquote) && !lexer.current.isA(_sEmpty)) {
      if (_special.contains(lexer.current.type) && setSpecialsWarning) {
        warnings.add('CFWSWithFWS');
        setSpecialsWarning = false;
      }
      if (lexer.current.isA(_sBackslash) && lexer.isNextToken(_sDquote)) {
        lexer.moveNext();
      }
      lexer.moveNext();
      if (!escaped() && _invalidTypes.contains(lexer.current.type)) {
        return false;
      }
    }
    final prev = lexer.previous;
    if (prev.isA(_sBackslash) && !_checkDquote()) {
      return false;
    }
    if (!lexer.isNextToken(_sAt) && !prev.isA(_sBackslash)) {
      return false;
    }
    return true;
  }

  bool _checkDquote() {
    final previous = lexer.previous;
    if (lexer.isNextToken(_generic) && previous.isA(_generic)) {
      return false; // quoted string should be a unit
    }
    try {
      lexer.find(_sDquote);
    } on _ParseError {
      return false; // UnclosedQuotedString
    }
    warnings.add('QuotedString');
    return true;
  }
}

final class _FoldingWhiteSpace extends _PartParser {
  _FoldingWhiteSpace(super.lexer);

  static const List<int> _fwsTypes = [_sSp, _sHtab, _sCr, _sLf, _crlf];

  bool parse() {
    if (escaped() || !_fwsTypes.contains(lexer.current.type)) {
      return true;
    }
    final previous = lexer.previous;
    if (lexer.current.isA(_crlf) &&
        !lexer.isNextTokenAny(const [_sSp, _sHtab])) {
      return false; // CRLFX2
    }
    if (lexer.current.isA(_sCr)) {
      return false; // CRNoLF
    }
    if (lexer.isNextToken(_generic) && !previous.isA(_sAt)) {
      return false; // AtextAfterCFWS
    }
    if (lexer.current.isA(_sLf) || lexer.current.isA(_cNul)) {
      return false; // ExpectingCTEXT
    }
    if (lexer.isNextToken(_sAt) || previous.isA(_sAt)) {
      warnings.add('CFWSNearAt');
    } else {
      warnings.add('CFWSWithFWS');
    }
    return true;
  }
}

final class _Comment extends _PartParser {
  _Comment(super.lexer, {required this.local});

  /// LocalComment (true) or DomainComment.
  final bool local;
  int _opened = 0;

  bool _exitCondition() => local
      ? !lexer.isNextToken(_sAt)
      : !(_opened == 0 && lexer.isNextToken(_sDot));

  bool parse() {
    if (lexer.current.isA(_sOpenParenthesis)) {
      _opened++;
      try {
        lexer.find(_sCloseParenthesis);
      } on _ParseError {
        return false; // UnclosedComment
      }
    }
    if (lexer.current.isA(_sCloseParenthesis)) {
      return false; // UnOpenedComment
    }
    warnings.add('Comment');
    var moreTokens = true;
    while (_exitCondition() && moreTokens) {
      if (lexer.isNextToken(_sOpenParenthesis)) {
        _opened++;
      }
      if (lexer.current.isA(_sBackslash) &&
          lexer.isNextTokenAny(const [_sSp, _sHtab, _cDel])) {
        warnings.add('QuotedPart');
      }
      if (lexer.isNextToken(_sCloseParenthesis)) {
        _opened--;
      }
      moreTokens = lexer.moveNext();
    }
    if (_opened >= 1 || _opened < 0) {
      return false;
    }
    if (local) {
      if (!lexer.isNextToken(_sAt)) {
        return false;
      }
      warnings.add('CFWSNearAt');
      return true;
    }
    return lexer.isNextToken(_sDot);
  }
}

final class _DomainPart extends _PartParser {
  _DomainPart(super.lexer);

  String domainPart = '';
  // Buffers: appending to a String copies it whole (see _Lexer).
  final StringBuffer _label = StringBuffer();

  bool parse() {
    lexer
      ..clearRecorded()
      ..startRecording()
      ..moveNext();
    // performDomainStartChecks.
    if (lexer.current.isA(_sDot) || lexer.current.isA(_sHyphen)) {
      return false;
    }
    if (lexer.current.isA(_sEmpty) ||
        (lexer.current.isA(_sSp) && !lexer.isNextToken(_generic))) {
      return false; // NoDomainPart
    }
    if (lexer.current.isA(_sOpenParenthesis)) {
      warnings.add('DeprecatedComment');
    }
    if (lexer.current.isA(_sAt)) {
      return false; // ConsecutiveAt
    }
    if (!_doParseDomainPart()) {
      return false;
    }
    // checkEndOfDomain.
    final prev = lexer.previous;
    if (prev.isA(_sDot) || prev.isA(_sHyphen) || lexer.current.isA(_sSp)) {
      return false;
    }
    lexer.stopRecording();
    domainPart = lexer.accumulated;
    if (_bytes(domainPart) > 253) {
      return false; // DomainTooLong
    }
    return true;
  }

  bool _doParseDomainPart() {
    var tldMissing = true;
    var hasComments = false;
    final domain = StringBuffer();
    do {
      final prev = lexer.previous;
      if (lexer.current.isA(_sBackslash) || lexer.current.isA(_sSlash)) {
        return false; // CharNotAllowed
      }
      if (lexer.current.isA(_sOpenParenthesis) ||
          lexer.current.isA(_sCloseParenthesis)) {
        hasComments = true;
        final comment = _Comment(lexer, local: false);
        final valid = comment.parse();
        warnings.addAll(comment.warnings);
        if (!valid) {
          return false;
        }
      }
      if (consecutiveDots()) {
        return false;
      }
      if (lexer.current.isA(_sOpenBracket)) {
        bool literal;
        try {
          lexer.find(_sCloseBracket);
          final parser = _DomainLiteral(lexer);
          literal = parser.parse();
          warnings.addAll(parser.warnings);
        } on _ParseError {
          literal = false; // ExpectingDomainLiteralClose
        }
        if (tldMissing) {
          warnings.add('TLD');
        }
        return literal;
      }
      if (!_checkLabelLength()) {
        return false;
      }
      if (!parseFws()) {
        return false;
      }
      domain.write(lexer.current.value);
      if (lexer.current.isA(_sDot) && lexer.isNextToken(_generic)) {
        tldMissing = false;
      }
      // checkDomainPartExceptions.
      if (lexer.current.isA(_sOpenBracket) && prev.type != _sAt) {
        return false;
      }
      if (lexer.current.isA(_sHyphen) && lexer.isNextToken(_sDot)) {
        return false;
      }
      if (lexer.current.isA(_sBackslash) && lexer.isNextToken(_generic)) {
        return false;
      }
      final type = lexer.current.type;
      final valid =
          type == _generic ||
          type == _sHyphen ||
          type == _sDot ||
          (hasComments &&
              (type == _sOpenParenthesis || type == _sCloseParenthesis));
      if (!valid) {
        return false; // Invalid token in domain
      }
      lexer.moveNext();
    } while (!lexer.current.isA(_sEmpty));
    if (!_checkLabelLength(endOfDomain: true)) {
      return false;
    }
    if (tldMissing) {
      warnings.add('TLD');
    }
    domainPart = domain.toString();
    return true;
  }

  bool _checkLabelLength({bool endOfDomain = false}) {
    if (lexer.current.isA(_sDot) || endOfDomain) {
      if (_labelTooLong(_label.toString())) {
        return false; // LabelTooLong
      }
      _label.clear();
    }
    _label.write(lexer.current.value);
    return true;
  }

  static bool _labelTooLong(String label) {
    // Checked once per label: no regex built, no bytes encoded, for the
    // usual ASCII label (its octets are its length).
    if (label.codeUnits.any((c) => c > 0x7F)) {
      // idn_to_ascii's IDNA_ERROR_LABEL_TOO_LONG: the ASCII form of the
      // label is longer than 63 octets. Punycode writes at least one
      // character per code point, so a label of more than 59 is too long
      // without encoding it (punycode's time grows with the square of the
      // distinct code points, as in `toAsciiHost`).
      final lower = label.toLowerCase();
      if (lower.runes.length > 63 - 'xn--'.length) {
        return true;
      }
      return 'xn--${punycode(lower)}'.length > 63;
    }
    return label.length > 63;
  }
}

final class _DomainLiteral extends _PartParser {
  _DomainLiteral(super.lexer);

  static final RegExp _ipv4 = RegExp(
    r'\b(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}'
    r'(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$',
  );
  static const List<int> _obsolete = [_invalid, _cDel, _sLf, _sBackslash];

  bool parse() {
    // addTagWarnings.
    if (lexer.isNextToken(_sColon)) {
      warnings.add('IPV6ColonStart');
    }
    if (lexer.isNextToken(_sIpv6Tag)) {
      final copy = _Lexer._copy(lexer)..moveNext();
      if (copy.isNextToken(_sDoubleColon)) {
        warnings.add('IPV6ColonStart');
      }
    }
    var ipv6Tag = false;
    final literal = StringBuffer();
    do {
      if (lexer.current.isA(_cNul)) {
        return false;
      }
      if (_obsolete.contains(lexer.current.type)) {
        warnings.add('ObsoleteDTEXT');
      }
      if (lexer.isNextTokenAny(const [_sOpenBracket, _sOpenBracket])) {
        return false;
      }
      if (lexer.isNextTokenAny(const [_sHtab, _sSp, _crlf])) {
        warnings.add('CFWSWithFWS');
        parseFws();
      }
      if (lexer.isNextToken(_sCr)) {
        return false;
      }
      if (lexer.current.isA(_sBackslash)) {
        return false;
      }
      if (lexer.current.isA(_sIpv6Tag)) {
        ipv6Tag = true;
      }
      if (lexer.current.isA(_sCloseBracket)) {
        break;
      }
      literal.write(lexer.current.value);
    } while (lexer.moveNext());
    var addressLiteral = literal.toString().replaceAll('[', '');
    if (!_checkIpv4Tag(addressLiteral)) {
      return true;
    }
    addressLiteral = _convertIpv4ToIpv6(addressLiteral);
    if (!ipv6Tag) {
      warnings.add('DomainLiteral');
      return true;
    }
    warnings.add('AddressLiteral');
    _checkIpv6Tag(addressLiteral);
    return true;
  }

  void _checkIpv6Tag(String addressLiteral, [int maxGroups = 8]) {
    if (lexer.previous.isA(_sColon)) {
      warnings.add('IPV6ColonEnd');
    }
    final ipv6 = addressLiteral.length > 5 ? addressLiteral.substring(5) : '';
    final groups = ipv6.split(':');
    final colons = ipv6.indexOf('::');
    if (groups.any((g) => !RegExp(r'^[0-9A-Fa-f]{0,4}$').hasMatch(g))) {
      warnings.add('IPV6BadChar');
    }
    if (colons == -1) {
      if (groups.length != maxGroups) {
        warnings.add('IPV6GroupCount');
      }
      return;
    }
    if (colons != ipv6.lastIndexOf('::')) {
      warnings.add('IPV6DoubleColon');
      return;
    }
    var max = maxGroups;
    if (colons == 0 || colons == ipv6.length - 2) {
      max++;
    }
    if (groups.length > max) {
      warnings.add('IPV6MaxGroups');
    } else if (groups.length == max) {
      warnings.add('IPV6Deprecated');
    }
  }

  String _convertIpv4ToIpv6(String literal) {
    final match = _ipv4.firstMatch(literal);
    if (match != null) {
      final index = literal.lastIndexOf(match.group(0)!);
      if (index > 0) {
        return '${literal.substring(0, index)}0:0';
      }
    }
    return literal;
  }

  bool _checkIpv4Tag(String literal) {
    final match = _ipv4.firstMatch(literal);
    if (match != null && literal.lastIndexOf(match.group(0)!) == 0) {
      warnings.add('AddressLiteral');
      return false;
    }
    return true;
  }
}
