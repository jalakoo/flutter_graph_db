/// Cypher recursive-descent parser.
///
/// v1 read subset:
/// ```
/// MATCH pattern [, pattern]* [WHERE expr] RETURN [DISTINCT] item [, item]*
/// ```
/// where `pattern` is a linear chain of node + relationship patterns,
/// and `item` is an expression with an optional `AS alias`. Write
/// statements (`CREATE` / `DELETE` / `SET` / `MERGE`), aggregations,
/// variable-length paths, and `ORDER BY` / `LIMIT` / `SKIP` land in
/// later sub-phases.
library;

import 'ast.dart';
import 'lexer.dart';

/// Parse-time error with a tight format: line + column + offending
/// token + 1-line context. No stack trace (caller fault, not engine bug).
class GqlParseException implements Exception {
  final String message;
  final int line;
  final int column;
  final String? token;
  final String contextLine;

  GqlParseException({
    required this.message,
    required this.line,
    required this.column,
    required this.token,
    required this.contextLine,
  });

  @override
  String toString() {
    final tokPart = token == null ? '' : ' (near "$token")';
    return 'GqlParseException at $line:$column$tokPart — $message\n'
        '  $contextLine\n'
        '  ${' ' * (column - 1)}^';
  }
}

class GqlParser {
  final String _source;
  final List<Token> _tokens;
  int _pos = 0;

  GqlParser._(this._source, this._tokens);

  /// Parses the source string end-to-end and returns the top-level
  /// statement. Throws [GqlLexException] or [GqlParseException] on
  /// bad input.
  factory GqlParser.fromSource(String source) {
    final tokens = GqlLexer(source).tokenize();
    return GqlParser._(source, tokens);
  }

  GqlStatement parse() {
    final stmt = _parseStatement();
    if (_peek().kind != TokenKind.eof) {
      throw _error('unexpected token after statement', _peek());
    }
    return stmt;
  }

  GqlStatement _parseStatement() {
    final t = _peek();
    if (t.kind == TokenKind.match) {
      return _parseMatch();
    }
    if (t.kind == TokenKind.createKw) {
      return _parseCreate();
    }
    if (t.kind == TokenKind.mergeKw) {
      return _parseMerge();
    }
    throw _error('expected MATCH or CREATE or MERGE', t);
  }

  CreateStatement _parseCreate() {
    _consume(TokenKind.createKw);
    final pattern = _parsePatternPart();
    ReturnClause? ret;
    if (_match(TokenKind.returnKw)) {
      ret = _parseReturnClause();
    }
    return CreateStatement(pattern: pattern, returnClause: ret);
  }

  MergeStatement _parseMerge() {
    _consume(TokenKind.mergeKw);
    final pattern = _parsePatternPart();
    if (pattern.relationships.isNotEmpty) {
      throw _error(
        'MERGE with relationships deferred — v1 supports single-node '
        'MERGE only',
        _peek(),
      );
    }
    ReturnClause? ret;
    if (_match(TokenKind.returnKw)) {
      ret = _parseReturnClause();
    }
    return MergeStatement(
      pattern: pattern.start,
      returnClause: ret,
    );
  }

  // ----- MATCH ... [WHERE ...] RETURN ... -----

  MatchStatement _parseMatch() {
    _consume(TokenKind.match);
    final patterns = [_parsePatternPart()];
    while (_match(TokenKind.comma)) {
      patterns.add(_parsePatternPart());
    }
    Expression? where;
    if (_match(TokenKind.where)) {
      where = _parseExpression();
    }
    // Optional mutating clauses (SET / DELETE) before RETURN. A
    // write-only MATCH has no RETURN at all.
    final mutations = <MutatingClause>[];
    while (_peek().kind == TokenKind.setKw ||
        _peek().kind == TokenKind.deleteKw) {
      if (_match(TokenKind.setKw)) {
        // SET ident.key = expr [, ident.key = expr]*
        mutations.add(_parseSetAssignment());
        while (_match(TokenKind.comma)) {
          mutations.add(_parseSetAssignment());
        }
      } else if (_match(TokenKind.deleteKw)) {
        final aliases = <String>[];
        aliases.add(
          _consume(TokenKind.ident, msg: 'expected identifier after DELETE')
              .lexeme,
        );
        while (_match(TokenKind.comma)) {
          aliases.add(
            _consume(TokenKind.ident, msg: 'expected identifier')
                .lexeme,
          );
        }
        mutations.add(DeleteClause(aliases));
      }
    }
    ReturnClause? returnClause;
    if (_match(TokenKind.returnKw)) {
      returnClause = _parseReturnClause();
    } else if (mutations.isEmpty) {
      throw _error('expected RETURN, SET, or DELETE after MATCH/WHERE',
          _peek());
    }

    // Optional trailing clauses: ORDER BY ... [SKIP n] [LIMIT n]
    List<OrderByItem>? orderBy;
    if (_match(TokenKind.orderKw)) {
      _consume(TokenKind.byKw, msg: 'expected BY after ORDER');
      orderBy = [_parseOrderByItem()];
      while (_match(TokenKind.comma)) {
        orderBy.add(_parseOrderByItem());
      }
    }
    int? skipN;
    int? limitN;
    // SKIP and LIMIT can appear in either order, but typically SKIP
    // first. Accept both orderings.
    for (var i = 0; i < 2; i++) {
      if (_match(TokenKind.skipKw)) {
        if (skipN != null) {
          throw _error('SKIP specified twice', _peek());
        }
        final t = _consume(TokenKind.intLit, msg: 'expected integer after SKIP');
        skipN = t.literal as int;
      } else if (_match(TokenKind.limitKw)) {
        if (limitN != null) {
          throw _error('LIMIT specified twice', _peek());
        }
        final t = _consume(TokenKind.intLit, msg: 'expected integer after LIMIT');
        limitN = t.literal as int;
      } else {
        break;
      }
    }

    return MatchStatement(
      patterns: patterns,
      where: where,
      returnClause: returnClause,
      mutations: mutations.isEmpty ? null : mutations,
      orderBy: orderBy,
      skip: skipN,
      limit: limitN,
    );
  }

  SetPropertyClause _parseSetAssignment() {
    final ident = _consume(TokenKind.ident,
        msg: 'expected identifier in SET');
    _consume(TokenKind.dot, msg: 'expected . after identifier in SET');
    final key = _consume(TokenKind.ident,
        msg: 'expected property key in SET');
    _consume(TokenKind.eq, msg: 'expected = in SET assignment');
    final value = _parseExpression();
    return SetPropertyClause(
      alias: ident.lexeme,
      key: key.lexeme,
      value: value,
    );
  }

  OrderByItem _parseOrderByItem() {
    final expr = _parseExpression();
    var ascending = true;
    if (_match(TokenKind.asc)) {
      ascending = true;
    } else if (_match(TokenKind.desc)) {
      ascending = false;
    }
    return OrderByItem(expr: expr, ascending: ascending);
  }

  // ----- Patterns -----

  PatternPart _parsePatternPart() {
    final start = _parseNodePattern();
    final relationships = <RelationshipPattern>[];
    final nodes = <NodePattern>[];
    while (_peek().kind == TokenKind.arrowLeft ||
        _peek().kind == TokenKind.dash) {
      relationships.add(_parseRelationshipPattern());
      nodes.add(_parseNodePattern());
    }
    return PatternPart(
      start: start,
      relationships: relationships,
      nodes: nodes,
    );
  }

  NodePattern _parseNodePattern() {
    _consume(TokenKind.lparen, msg: 'expected node pattern starting with (');
    String? alias;
    if (_peek().kind == TokenKind.ident) {
      alias = _advance().lexeme;
    }
    final labels = <String>[];
    while (_match(TokenKind.colon)) {
      final t = _consume(TokenKind.ident, msg: 'expected label name after :');
      labels.add(t.lexeme);
    }
    final props = <String, Expression>{};
    if (_peek().kind == TokenKind.lbrace) {
      _parseInlineProperties(props);
    }
    _consume(TokenKind.rparen, msg: 'expected ) to close node pattern');
    return NodePattern(alias: alias, labels: labels, properties: props);
  }

  RelationshipPattern _parseRelationshipPattern() {
    // Supported shapes:
    //   ->
    //   -[]->
    //   -[r]->
    //   -[r:TYPE]->
    //   -[r:TYPE {p: v}]->
    //   <-[...]-
    //   -[...]-     (undirected)
    Direction direction;
    var leftIncoming = false;
    if (_match(TokenKind.arrowLeft)) {
      // <- ... must be followed by an optional [..] then a dash.
      leftIncoming = true;
    } else {
      _consume(TokenKind.dash, msg: 'expected -[ or <-[ in relationship');
    }

    String? alias;
    final types = <String>[];
    final props = <String, Expression>{};

    int? minHops;
    int? maxHops;
    if (_match(TokenKind.lbracket)) {
      if (_peek().kind == TokenKind.ident) {
        alias = _advance().lexeme;
      }
      while (_match(TokenKind.colon)) {
        final t = _consume(TokenKind.ident,
            msg: 'expected type name after :');
        types.add(t.lexeme);
        // Multi-type (`:A|B`) deferred — error if seen.
        if (_peek().kind == TokenKind.pipe) {
          throw _error(
            'multi-type relationship (TYPE1|TYPE2) is not yet supported',
            _peek(),
          );
        }
      }
      // Optional variable-length quantifier: *  *N  *..M  *N..  *N..M
      if (_match(TokenKind.star)) {
        minHops = 1;
        maxHops = null; // unbounded by default for `*`
        if (_peek().kind == TokenKind.intLit) {
          minHops = _advance().literal as int;
          // After a number we may see `..` or end.
          if (_peek().kind == TokenKind.dot &&
              _peek(1).kind == TokenKind.dot) {
            _advance();
            _advance(); // consume `.` `.`
            if (_peek().kind == TokenKind.intLit) {
              maxHops = _advance().literal as int;
            } else {
              maxHops = null; // *N.. unbounded above
            }
          } else {
            maxHops = minHops; // *N exact
          }
        } else if (_peek().kind == TokenKind.dot &&
            _peek(1).kind == TokenKind.dot) {
          _advance();
          _advance();
          if (_peek().kind == TokenKind.intLit) {
            maxHops = _advance().literal as int;
          }
          // minHops stays 1
        }
      }
      if (_peek().kind == TokenKind.lbrace) {
        _parseInlineProperties(props);
      }
      _consume(TokenKind.rbracket,
          msg: 'expected ] to close relationship pattern');
    }

    if (leftIncoming) {
      _consume(TokenKind.dash, msg: 'expected - after relationship body');
      direction = Direction.incoming;
    } else {
      // After the optional [...] we either see `->` (outgoing) or `-`
      // / `-...-` (undirected).
      if (_match(TokenKind.arrowRight)) {
        direction = Direction.outgoing;
      } else if (_match(TokenKind.dash)) {
        direction = Direction.undirected;
      } else {
        throw _error(
          'expected -> or - after relationship body',
          _peek(),
        );
      }
    }

    return RelationshipPattern(
      alias: alias,
      types: types,
      direction: direction,
      properties: props,
      minHops: minHops,
      maxHops: maxHops,
    );
  }

  void _parseInlineProperties(Map<String, Expression> into) {
    _consume(TokenKind.lbrace);
    if (_peek().kind == TokenKind.rbrace) {
      _advance();
      return;
    }
    while (true) {
      final key = _consume(TokenKind.ident,
          msg: 'expected property key inside { }');
      _consume(TokenKind.colon,
          msg: 'expected : after property key "${key.lexeme}"');
      final value = _parseExpression();
      into[key.lexeme] = value;
      if (_match(TokenKind.comma)) continue;
      break;
    }
    _consume(TokenKind.rbrace,
        msg: 'expected } to close inline properties');
  }

  // ----- RETURN -----

  ReturnClause _parseReturnClause() {
    final distinct = _match(TokenKind.distinct);
    final items = [_parseReturnItem()];
    while (_match(TokenKind.comma)) {
      items.add(_parseReturnItem());
    }
    return ReturnClause(distinct: distinct, items: items);
  }

  ReturnItem _parseReturnItem() {
    final expr = _parseExpression();
    String? alias;
    if (_match(TokenKind.as)) {
      final t = _consume(TokenKind.ident, msg: 'expected alias after AS');
      alias = t.lexeme;
    }
    return ReturnItem(expr: expr, alias: alias);
  }

  // ----- Expressions (precedence-climbing) -----
  //
  // Precedence (low → high):
  //   OR
  //   AND
  //   NOT
  //   comparison: = <> < <= > >=
  //   additive: + -
  //   multiplicative: * / %
  //   unary: - (negation)
  //   primary: literals, ident, ident.prop, $param, (expr)

  Expression _parseExpression() => _parseOr();

  Expression _parseOr() {
    var left = _parseAnd();
    while (_match(TokenKind.or)) {
      final right = _parseAnd();
      left = BinaryOpExpr(BinaryOp.or, left, right);
    }
    return left;
  }

  Expression _parseAnd() {
    var left = _parseNot();
    while (_match(TokenKind.and)) {
      final right = _parseNot();
      left = BinaryOpExpr(BinaryOp.and, left, right);
    }
    return left;
  }

  Expression _parseNot() {
    if (_match(TokenKind.not)) {
      return UnaryOpExpr(UnaryOp.not, _parseNot());
    }
    return _parseComparison();
  }

  Expression _parseComparison() {
    var left = _parseAdditive();
    while (true) {
      final t = _peek();
      BinaryOp? op;
      switch (t.kind) {
        case TokenKind.eq:
          op = BinaryOp.eq;
        case TokenKind.neq:
          op = BinaryOp.neq;
        case TokenKind.lt:
          op = BinaryOp.lt;
        case TokenKind.lte:
          op = BinaryOp.lte;
        case TokenKind.gt:
          op = BinaryOp.gt;
        case TokenKind.gte:
          op = BinaryOp.gte;
        default:
          op = null;
      }
      if (op == null) break;
      _advance();
      final right = _parseAdditive();
      left = BinaryOpExpr(op, left, right);
    }
    return left;
  }

  Expression _parseAdditive() {
    var left = _parseMultiplicative();
    while (true) {
      final t = _peek();
      if (t.kind == TokenKind.plus) {
        _advance();
        left = BinaryOpExpr(BinaryOp.plus, left, _parseMultiplicative());
      } else if (t.kind == TokenKind.dash || t.kind == TokenKind.minus) {
        _advance();
        left = BinaryOpExpr(BinaryOp.minus, left, _parseMultiplicative());
      } else {
        break;
      }
    }
    return left;
  }

  Expression _parseMultiplicative() {
    var left = _parseUnary();
    while (true) {
      final t = _peek();
      if (t.kind == TokenKind.star) {
        _advance();
        left = BinaryOpExpr(BinaryOp.mul, left, _parseUnary());
      } else if (t.kind == TokenKind.slash) {
        _advance();
        left = BinaryOpExpr(BinaryOp.div, left, _parseUnary());
      } else if (t.kind == TokenKind.percent) {
        _advance();
        left = BinaryOpExpr(BinaryOp.mod, left, _parseUnary());
      } else {
        break;
      }
    }
    return left;
  }

  Expression _parseUnary() {
    if (_match(TokenKind.dash) || _match(TokenKind.minus)) {
      return UnaryOpExpr(UnaryOp.neg, _parseUnary());
    }
    return _parsePrimary();
  }

  Expression _parsePrimary() {
    final t = _peek();
    switch (t.kind) {
      case TokenKind.intLit:
      case TokenKind.doubleLit:
      case TokenKind.stringLit:
        _advance();
        return LiteralExpr(t.literal);
      case TokenKind.trueKw:
        _advance();
        return const LiteralExpr(true);
      case TokenKind.falseKw:
        _advance();
        return const LiteralExpr(false);
      case TokenKind.nullKw:
        _advance();
        return const LiteralExpr(null);
      case TokenKind.dollar:
        _advance();
        final name = _consume(TokenKind.ident,
            msg: r'expected parameter name after $');
        return ParameterExpr(name.lexeme);
      case TokenKind.ident:
        final ident = _advance();
        // Function-call shape: IDENT(...). v1 recognises only the six
        // aggregates; other function calls (e.g. `size()`,
        // `coalesce()`) land with Cypher-compat mode.
        if (_peek().kind == TokenKind.lparen) {
          return _parseFunctionCall(ident.lexeme);
        }
        Expression expr = IdentifierExpr(ident.lexeme);
        while (_match(TokenKind.dot)) {
          final key = _consume(TokenKind.ident,
              msg: 'expected property key after .');
          expr = PropertyAccessExpr(expr, key.lexeme);
        }
        return expr;
      case TokenKind.lparen:
        _advance();
        final inner = _parseExpression();
        _consume(TokenKind.rparen,
            msg: 'expected ) to close parenthesised expression');
        return inner;
      default:
        throw _error('expected expression', t);
    }
  }

  // ----- Function call (aggregates in 3C; other built-ins later) -----

  Expression _parseFunctionCall(String name) {
    _consume(TokenKind.lparen);
    final upper = name.toUpperCase();
    AggregateFn? fn;
    switch (upper) {
      case 'COUNT':
        fn = AggregateFn.count;
      case 'SUM':
        fn = AggregateFn.sum;
      case 'AVG':
        fn = AggregateFn.avg;
      case 'MIN':
        fn = AggregateFn.min;
      case 'MAX':
        fn = AggregateFn.max;
      case 'COLLECT':
        fn = AggregateFn.collect;
    }
    if (fn != null) {
      Expression? arg;
      // COUNT(*) — argument is the star token.
      if (fn == AggregateFn.count && _peek().kind == TokenKind.star) {
        _advance();
        arg = null;
      } else {
        arg = _parseExpression();
      }
      _consume(TokenKind.rparen,
          msg: 'expected ) to close $upper(...)');
      return AggregateExpr(fn: fn, argument: arg);
    }
    // Cypher-compat scalar functions.
    BuiltinFn? scalar;
    switch (upper) {
      case 'SIZE':
        scalar = BuiltinFn.size;
      case 'LENGTH':
        scalar = BuiltinFn.length;
      case 'COALESCE':
        scalar = BuiltinFn.coalesce;
      case 'LABELS':
        scalar = BuiltinFn.labels;
    }
    if (scalar != null) {
      final args = <Expression>[];
      if (_peek().kind != TokenKind.rparen) {
        args.add(_parseExpression());
        while (_match(TokenKind.comma)) {
          args.add(_parseExpression());
        }
      }
      _consume(TokenKind.rparen,
          msg: 'expected ) to close $upper(...)');
      return FunctionCallExpr(fn: scalar, arguments: args);
    }
    throw _error(
      'unknown function "$name" — v1 recognises COUNT / SUM / AVG / '
      'MIN / MAX / COLLECT / SIZE / LENGTH / COALESCE / LABELS',
      _peek(),
    );
  }

  // ----- Token plumbing -----

  Token _peek([int lookahead = 0]) =>
      _pos + lookahead < _tokens.length
          ? _tokens[_pos + lookahead]
          : _tokens.last;

  Token _advance() {
    final t = _tokens[_pos];
    if (t.kind != TokenKind.eof) _pos++;
    return t;
  }

  bool _match(TokenKind kind) {
    if (_peek().kind == kind) {
      _advance();
      return true;
    }
    return false;
  }

  Token _consume(TokenKind kind, {String? msg}) {
    if (_peek().kind == kind) return _advance();
    throw _error(
      msg ?? 'expected ${kind.name}',
      _peek(),
    );
  }

  GqlParseException _error(String msg, Token at) => GqlParseException(
        message: msg,
        line: at.line,
        column: at.column,
        token: at.kind == TokenKind.eof ? null : at.lexeme,
        contextLine: _contextLine(at.line),
      );

  String _contextLine(int targetLine) {
    var lineStart = 0;
    var l = 1;
    for (var i = 0; i < _source.length; i++) {
      if (l == targetLine) {
        lineStart = i;
        break;
      }
      if (_source.codeUnitAt(i) == 0x0A) l++;
    }
    var lineEnd = _source.length;
    for (var i = lineStart; i < _source.length; i++) {
      if (_source.codeUnitAt(i) == 0x0A) {
        lineEnd = i;
        break;
      }
    }
    return _source.substring(lineStart, lineEnd);
  }
}
