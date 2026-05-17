/// Cypher lexer (plan §8 / §14 Phase 3A).
///
/// Hand-rolled — no regex, no codegen. Tokenizes the v1 read subset:
/// keywords, identifiers, numeric / string / bool / null literals,
/// arithmetic + comparison operators, and the punctuation needed for
/// patterns and projections. Line + column on every token so the
/// parser can produce §8-spec error messages.
library;

enum TokenKind {
  // Keywords
  match,
  where,
  returnKw,
  distinct,
  as,
  trueKw,
  falseKw,
  nullKw,
  and,
  or,
  not,
  in_,
  orderKw,
  byKw,
  asc,
  desc,
  skipKw,
  limitKw,
  createKw,
  deleteKw,
  setKw,
  mergeKw,
  // Identifiers
  ident,
  // Literals
  intLit,
  doubleLit,
  stringLit,
  // Operators
  eq, // =
  neq, // <>  also accepts !=
  lt, // <
  lte, // <=
  gt, // >
  gte, // >=
  plus,
  minus,
  star,
  slash,
  percent,
  // Punctuation
  lparen,
  rparen,
  lbrace,
  rbrace,
  lbracket,
  rbracket,
  colon,
  comma,
  dot,
  dollar,
  pipe,
  // Path arrows + dash (used by relationship patterns)
  arrowLeft, // <-
  arrowRight, // ->
  dash, // - (relationship spine or unary-minus)
  // Sentinel
  eof,
}

class Token {
  final TokenKind kind;
  final String lexeme;
  final int line;
  final int column;

  /// For [intLit] this is `int`; for [doubleLit] `double`; for
  /// [stringLit] the un-escaped Dart `String`; otherwise `null`.
  final Object? literal;

  const Token({
    required this.kind,
    required this.lexeme,
    required this.line,
    required this.column,
    this.literal,
  });

  @override
  String toString() =>
      'Token(${kind.name}, ${literal ?? lexeme}, $line:$column)';
}

class GqlLexException implements Exception {
  final String message;
  final int line;
  final int column;
  final String contextLine;

  GqlLexException(this.message, this.line, this.column, this.contextLine);

  @override
  String toString() => 'GqlLexException at $line:$column — $message\n'
      '  $contextLine\n'
      '  ${' ' * (column - 1)}^';
}

const Map<String, TokenKind> _keywords = {
  'MATCH': TokenKind.match,
  'WHERE': TokenKind.where,
  'RETURN': TokenKind.returnKw,
  'DISTINCT': TokenKind.distinct,
  'AS': TokenKind.as,
  'TRUE': TokenKind.trueKw,
  'FALSE': TokenKind.falseKw,
  'NULL': TokenKind.nullKw,
  'AND': TokenKind.and,
  'OR': TokenKind.or,
  'NOT': TokenKind.not,
  'IN': TokenKind.in_,
  'ORDER': TokenKind.orderKw,
  'BY': TokenKind.byKw,
  'ASC': TokenKind.asc,
  'DESC': TokenKind.desc,
  'SKIP': TokenKind.skipKw,
  'LIMIT': TokenKind.limitKw,
  'CREATE': TokenKind.createKw,
  'DELETE': TokenKind.deleteKw,
  'SET': TokenKind.setKw,
  'MERGE': TokenKind.mergeKw,
};

class GqlLexer {
  final String source;
  int _pos = 0;
  int _line = 1;
  int _col = 1;

  GqlLexer(this.source);

  /// Tokenizes [source] end-to-end. Always terminates with an [eof]
  /// token at the final source position.
  List<Token> tokenize() {
    final tokens = <Token>[];
    while (true) {
      _skipWhitespaceAndComments();
      if (_pos >= source.length) {
        tokens.add(Token(
          kind: TokenKind.eof,
          lexeme: '',
          line: _line,
          column: _col,
        ));
        return tokens;
      }
      tokens.add(_scanToken());
    }
  }

  void _skipWhitespaceAndComments() {
    while (_pos < source.length) {
      final c = source.codeUnitAt(_pos);
      if (c == 0x20 || c == 0x09) {
        _pos++;
        _col++;
      } else if (c == 0x0A) {
        _pos++;
        _line++;
        _col = 1;
      } else if (c == 0x0D) {
        _pos++;
        // Treat \r\n as a single newline
        if (_pos < source.length && source.codeUnitAt(_pos) == 0x0A) {
          _pos++;
        }
        _line++;
        _col = 1;
      } else if (c == 0x2F && // '/'
          _pos + 1 < source.length &&
          source.codeUnitAt(_pos + 1) == 0x2F) {
        // line comment
        while (_pos < source.length && source.codeUnitAt(_pos) != 0x0A) {
          _pos++;
        }
      } else {
        break;
      }
    }
  }

  Token _scanToken() {
    final startLine = _line;
    final startCol = _col;
    final c = source.codeUnitAt(_pos);

    // Identifier / keyword: [A-Za-z_][A-Za-z0-9_]*
    if (_isAlpha(c)) {
      final start = _pos;
      while (_pos < source.length && _isAlphaNum(source.codeUnitAt(_pos))) {
        _pos++;
        _col++;
      }
      final lex = source.substring(start, _pos);
      final kind = _keywords[lex.toUpperCase()] ?? TokenKind.ident;
      return Token(
        kind: kind,
        lexeme: lex,
        line: startLine,
        column: startCol,
      );
    }

    // Number: digit run, optional `.digit`
    if (_isDigit(c)) {
      final start = _pos;
      while (_pos < source.length && _isDigit(source.codeUnitAt(_pos))) {
        _pos++;
        _col++;
      }
      var isDouble = false;
      if (_pos < source.length && source.codeUnitAt(_pos) == 0x2E) {
        // '.' followed by digit (otherwise leave it for property access)
        if (_pos + 1 < source.length &&
            _isDigit(source.codeUnitAt(_pos + 1))) {
          isDouble = true;
          _pos++;
          _col++;
          while (_pos < source.length && _isDigit(source.codeUnitAt(_pos))) {
            _pos++;
            _col++;
          }
        }
      }
      final lex = source.substring(start, _pos);
      return Token(
        kind: isDouble ? TokenKind.doubleLit : TokenKind.intLit,
        lexeme: lex,
        line: startLine,
        column: startCol,
        literal: isDouble ? double.parse(lex) : int.parse(lex),
      );
    }

    // String: single- or double-quoted; escapes \n \t \\ \' \"
    if (c == 0x27 || c == 0x22) {
      return _scanString(c, startLine, startCol);
    }

    // Punctuation + operators
    _pos++;
    _col++;
    final next = _pos < source.length ? source.codeUnitAt(_pos) : -1;
    switch (c) {
      case 0x28: // (
        return Token(
          kind: TokenKind.lparen,
          lexeme: '(',
          line: startLine,
          column: startCol,
        );
      case 0x29: // )
        return Token(
          kind: TokenKind.rparen,
          lexeme: ')',
          line: startLine,
          column: startCol,
        );
      case 0x7B: // {
        return Token(
          kind: TokenKind.lbrace,
          lexeme: '{',
          line: startLine,
          column: startCol,
        );
      case 0x7D: // }
        return Token(
          kind: TokenKind.rbrace,
          lexeme: '}',
          line: startLine,
          column: startCol,
        );
      case 0x5B: // [
        return Token(
          kind: TokenKind.lbracket,
          lexeme: '[',
          line: startLine,
          column: startCol,
        );
      case 0x5D: // ]
        return Token(
          kind: TokenKind.rbracket,
          lexeme: ']',
          line: startLine,
          column: startCol,
        );
      case 0x3A: // :
        return Token(
          kind: TokenKind.colon,
          lexeme: ':',
          line: startLine,
          column: startCol,
        );
      case 0x2C: // ,
        return Token(
          kind: TokenKind.comma,
          lexeme: ',',
          line: startLine,
          column: startCol,
        );
      case 0x2E: // .
        return Token(
          kind: TokenKind.dot,
          lexeme: '.',
          line: startLine,
          column: startCol,
        );
      case 0x24: // $
        return Token(
          kind: TokenKind.dollar,
          lexeme: r'$',
          line: startLine,
          column: startCol,
        );
      case 0x7C: // |
        return Token(
          kind: TokenKind.pipe,
          lexeme: '|',
          line: startLine,
          column: startCol,
        );
      case 0x2B: // +
        return Token(
          kind: TokenKind.plus,
          lexeme: '+',
          line: startLine,
          column: startCol,
        );
      case 0x2A: // *
        return Token(
          kind: TokenKind.star,
          lexeme: '*',
          line: startLine,
          column: startCol,
        );
      case 0x2F: // /
        return Token(
          kind: TokenKind.slash,
          lexeme: '/',
          line: startLine,
          column: startCol,
        );
      case 0x25: // %
        return Token(
          kind: TokenKind.percent,
          lexeme: '%',
          line: startLine,
          column: startCol,
        );
      case 0x3D: // =
        return Token(
          kind: TokenKind.eq,
          lexeme: '=',
          line: startLine,
          column: startCol,
        );
      case 0x21: // !
        if (next == 0x3D) {
          _pos++;
          _col++;
          return Token(
            kind: TokenKind.neq,
            lexeme: '!=',
            line: startLine,
            column: startCol,
          );
        }
        throw _lexError('unexpected !', startLine, startCol);
      case 0x3C: // <
        if (next == 0x3D) {
          _pos++;
          _col++;
          return Token(
            kind: TokenKind.lte,
            lexeme: '<=',
            line: startLine,
            column: startCol,
          );
        }
        if (next == 0x3E) {
          _pos++;
          _col++;
          return Token(
            kind: TokenKind.neq,
            lexeme: '<>',
            line: startLine,
            column: startCol,
          );
        }
        if (next == 0x2D) {
          _pos++;
          _col++;
          return Token(
            kind: TokenKind.arrowLeft,
            lexeme: '<-',
            line: startLine,
            column: startCol,
          );
        }
        return Token(
          kind: TokenKind.lt,
          lexeme: '<',
          line: startLine,
          column: startCol,
        );
      case 0x3E: // >
        if (next == 0x3D) {
          _pos++;
          _col++;
          return Token(
            kind: TokenKind.gte,
            lexeme: '>=',
            line: startLine,
            column: startCol,
          );
        }
        return Token(
          kind: TokenKind.gt,
          lexeme: '>',
          line: startLine,
          column: startCol,
        );
      case 0x2D: // -
        if (next == 0x3E) {
          _pos++;
          _col++;
          return Token(
            kind: TokenKind.arrowRight,
            lexeme: '->',
            line: startLine,
            column: startCol,
          );
        }
        return Token(
          kind: TokenKind.dash,
          lexeme: '-',
          line: startLine,
          column: startCol,
        );
      default:
        throw _lexError(
          'unexpected character "${String.fromCharCode(c)}"',
          startLine,
          startCol,
        );
    }
  }

  Token _scanString(int quote, int startLine, int startCol) {
    _pos++; // skip opening quote
    _col++;
    final buf = StringBuffer();
    while (_pos < source.length) {
      final c = source.codeUnitAt(_pos);
      if (c == quote) {
        _pos++;
        _col++;
        return Token(
          kind: TokenKind.stringLit,
          lexeme: buf.toString(),
          line: startLine,
          column: startCol,
          literal: buf.toString(),
        );
      }
      if (c == 0x5C) {
        // backslash escape
        _pos++;
        _col++;
        if (_pos >= source.length) {
          throw _lexError(
            'unterminated string escape',
            startLine,
            startCol,
          );
        }
        final esc = source.codeUnitAt(_pos);
        switch (esc) {
          case 0x6E: // n
            buf.write('\n');
          case 0x74: // t
            buf.write('\t');
          case 0x5C: // \
            buf.write('\\');
          case 0x27: // '
            buf.write("'");
          case 0x22: // "
            buf.write('"');
          default:
            throw _lexError(
              'invalid escape \\${String.fromCharCode(esc)}',
              _line,
              _col,
            );
        }
        _pos++;
        _col++;
      } else if (c == 0x0A) {
        throw _lexError('unterminated string', startLine, startCol);
      } else {
        buf.writeCharCode(c);
        _pos++;
        _col++;
      }
    }
    throw _lexError('unterminated string', startLine, startCol);
  }

  GqlLexException _lexError(String msg, int line, int col) =>
      GqlLexException(msg, line, col, _contextLine(line));

  String _contextLine(int targetLine) {
    var lineStart = 0;
    var l = 1;
    for (var i = 0; i < source.length; i++) {
      if (l == targetLine) {
        lineStart = i;
        break;
      }
      if (source.codeUnitAt(i) == 0x0A) l++;
    }
    var lineEnd = source.length;
    for (var i = lineStart; i < source.length; i++) {
      if (source.codeUnitAt(i) == 0x0A) {
        lineEnd = i;
        break;
      }
    }
    return source.substring(lineStart, lineEnd);
  }

  static bool _isAlpha(int c) =>
      (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F;

  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

  static bool _isAlphaNum(int c) => _isAlpha(c) || _isDigit(c);
}
