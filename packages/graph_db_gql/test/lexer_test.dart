import 'package:graph_db_gql/graph_db_gql.dart';
import 'package:test/test.dart';

List<Token> _tok(String s) => GqlLexer(s).tokenize();

void main() {
  test('tokenises keywords case-insensitively', () {
    final t = _tok('MATCH match Match WHERE Return');
    expect(t.map((x) => x.kind).take(5).toList(), [
      TokenKind.match,
      TokenKind.match,
      TokenKind.match,
      TokenKind.where,
      TokenKind.returnKw,
    ]);
  });

  test('numeric literals — int + double', () {
    final t = _tok('42 3.14 100');
    expect(t[0].kind, TokenKind.intLit);
    expect(t[0].literal, 42);
    expect(t[1].kind, TokenKind.doubleLit);
    expect(t[1].literal, 3.14);
    expect(t[2].kind, TokenKind.intLit);
    expect(t[2].literal, 100);
  });

  test('strings handle both quotes + escapes', () {
    // Source: single-quoted with \n escape, then double-quoted with \t
    // escape. (Outer Dart raw string so backslashes pass to the lexer.)
    final t = _tok(r"'hello\nworld' " '"a\\tb"');
    expect(t[0].kind, TokenKind.stringLit);
    expect(t[0].literal, 'hello\nworld');
    expect(t[1].kind, TokenKind.stringLit);
    expect(t[1].literal, 'a\tb');
  });

  test('arrows + dash tokens for path patterns', () {
    final t = _tok('-> <- - -[ ]->');
    expect(
      t.map((x) => x.kind).take(5).toList(),
      [
        TokenKind.arrowRight,
        TokenKind.arrowLeft,
        TokenKind.dash,
        TokenKind.dash,
        TokenKind.lbracket,
      ],
    );
  });

  test('comparison operators', () {
    final t = _tok('= != <> < <= > >=');
    expect(
      t.map((x) => x.kind).take(7).toList(),
      [
        TokenKind.eq,
        TokenKind.neq,
        TokenKind.neq,
        TokenKind.lt,
        TokenKind.lte,
        TokenKind.gt,
        TokenKind.gte,
      ],
    );
  });

  test('line + column tracking across newlines', () {
    final t = _tok('MATCH\n  (n)\nRETURN n');
    expect(t[0].line, 1);
    expect(t[0].column, 1);
    expect(t[1].line, 2);
    expect(t[1].column, 3);
    expect(t[1].kind, TokenKind.lparen);
  });

  test('line comments are skipped', () {
    final t = _tok('MATCH // this is a comment\n(n) RETURN n');
    expect(t.map((x) => x.kind).take(2).toList(),
        [TokenKind.match, TokenKind.lparen]);
  });

  test('unterminated string raises lex error w/ location', () {
    expect(
      () => _tok("'unclosed"),
      throwsA(isA<GqlLexException>()
          .having((e) => e.line, 'line', 1)
          .having((e) => e.column, 'column', 1)),
    );
  });

  test('unknown character raises lex error', () {
    expect(
      () => _tok('@'),
      throwsA(isA<GqlLexException>()),
    );
  });
}
