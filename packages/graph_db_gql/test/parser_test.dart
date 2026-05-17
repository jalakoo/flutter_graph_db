import 'package:graph_db_gql/graph_db_gql.dart';
import 'package:test/test.dart';

MatchStatement _parseMatch(String s) =>
    GqlParser.fromSource(s).parse() as MatchStatement;

void main() {
  group('node patterns', () {
    test('bare anonymous (n)', () {
      final m = _parseMatch('MATCH (n) RETURN n');
      expect(m.patterns.single.start.alias, 'n');
      expect(m.patterns.single.start.labels, isEmpty);
    });

    test('label filter (n:Person)', () {
      final m = _parseMatch('MATCH (n:Person) RETURN n');
      expect(m.patterns.single.start.labels, ['Person']);
    });

    test('multi-label (n:Person:Employee) parses to a list', () {
      final m = _parseMatch('MATCH (n:Person:Employee) RETURN n');
      expect(m.patterns.single.start.labels, ['Person', 'Employee']);
    });

    test('anonymous label-only (:Person)', () {
      final m = _parseMatch('MATCH (:Person) RETURN 1');
      expect(m.patterns.single.start.alias, isNull);
      expect(m.patterns.single.start.labels, ['Person']);
    });

    test('inline properties {name: "x", age: 30}', () {
      final m =
          _parseMatch('MATCH (n {name: \'Ada\', age: 30}) RETURN n');
      final props = m.patterns.single.start.properties;
      expect(props.keys, ['name', 'age']);
      expect((props['name'] as LiteralExpr).value, 'Ada');
      expect((props['age'] as LiteralExpr).value, 30);
    });
  });

  group('relationship patterns', () {
    test('plain --> outgoing', () {
      final m = _parseMatch('MATCH (a)-->(b) RETURN a, b');
      final rel = m.patterns.single.relationships.single;
      expect(rel.direction, Direction.outgoing);
      expect(rel.alias, isNull);
      expect(rel.types, isEmpty);
    });

    test('-[r:KNOWS]-> typed + aliased', () {
      final m = _parseMatch('MATCH (a)-[r:KNOWS]->(b) RETURN r');
      final rel = m.patterns.single.relationships.single;
      expect(rel.alias, 'r');
      expect(rel.types, ['KNOWS']);
      expect(rel.direction, Direction.outgoing);
    });

    test('<-[r:KNOWS]- incoming', () {
      final m = _parseMatch('MATCH (a)<-[r:KNOWS]-(b) RETURN r');
      final rel = m.patterns.single.relationships.single;
      expect(rel.direction, Direction.incoming);
    });

    test('-[r]- undirected', () {
      final m = _parseMatch('MATCH (a)-[r]-(b) RETURN r');
      expect(m.patterns.single.relationships.single.direction,
          Direction.undirected);
    });

    test('multi-type (:A|B) rejected in 3A', () {
      expect(
        () => _parseMatch('MATCH (a)-[:A|B]->(b) RETURN a'),
        throwsA(isA<GqlParseException>()),
      );
    });
  });

  group('WHERE expressions', () {
    test('comparison + property access', () {
      final m = _parseMatch('MATCH (n:Person) WHERE n.age > 30 RETURN n');
      final w = m.where! as BinaryOpExpr;
      expect(w.op, BinaryOp.gt);
      final left = w.left as PropertyAccessExpr;
      expect((left.target as IdentifierExpr).name, 'n');
      expect(left.key, 'age');
      expect((w.right as LiteralExpr).value, 30);
    });

    test('AND / OR / NOT with precedence', () {
      final m = _parseMatch(
          'MATCH (n) WHERE NOT n.x = 1 AND n.y < 2 OR n.z > 3 RETURN n');
      final w = m.where! as BinaryOpExpr;
      expect(w.op, BinaryOp.or); // OR has lowest precedence → top
      final lhs = w.left as BinaryOpExpr;
      expect(lhs.op, BinaryOp.and);
      final notExpr = lhs.left as UnaryOpExpr;
      expect(notExpr.op, UnaryOp.not);
    });

    test('parameter \$name', () {
      final m = _parseMatch(r'MATCH (n) WHERE n.id = $userId RETURN n');
      final w = m.where! as BinaryOpExpr;
      expect((w.right as ParameterExpr).name, 'userId');
    });

    test('arithmetic with proper precedence', () {
      final m = _parseMatch(
          'MATCH (n) WHERE n.age = 30 + 5 * 2 RETURN n');
      final w = m.where! as BinaryOpExpr;
      expect(w.op, BinaryOp.eq);
      final rhs = w.right as BinaryOpExpr;
      expect(rhs.op, BinaryOp.plus);
      final mul = rhs.right as BinaryOpExpr;
      expect(mul.op, BinaryOp.mul);
    });

    test('unary negation', () {
      final m = _parseMatch('MATCH (n) WHERE n.x = -5 RETURN n');
      final w = m.where! as BinaryOpExpr;
      final neg = w.right as UnaryOpExpr;
      expect(neg.op, UnaryOp.neg);
      expect((neg.operand as LiteralExpr).value, 5);
    });
  });

  group('RETURN clause', () {
    test('bare alias + aliased + DISTINCT', () {
      final m = _parseMatch(
          'MATCH (n:Person) RETURN DISTINCT n, n.name AS userName');
      expect(m.returnClause!.distinct, isTrue);
      expect(m.returnClause!.items.length, 2);
      expect(m.returnClause!.items[1].alias, 'userName');
    });
  });

  group('error reporting (plan §8)', () {
    test('missing RETURN raises parse exception w/ line + column', () {
      try {
        _parseMatch('MATCH (n)');
        fail('expected GqlParseException');
      } on GqlParseException catch (e) {
        expect(e.line, 1);
        expect(e.column, greaterThan(0));
        expect(e.message, contains('RETURN'));
      }
    });

    test('error message includes the offending token + context line', () {
      try {
        _parseMatch('MATCH (n)\nRETURN');
        fail('expected GqlParseException');
      } on GqlParseException catch (e) {
        expect(e.line, 2);
        expect(e.contextLine, 'RETURN');
        final s = e.toString();
        expect(s, contains('RETURN'));
        expect(s, contains('^'));
      }
    });

    test('unknown leading statement names the issue', () {
      expect(
        () => GqlParser.fromSource('FOO bar').parse(),
        throwsA(isA<GqlParseException>()
            .having((e) => e.message, 'message', contains('MATCH'))),
      );
    });
  });

  group('multi-pattern + complex shape', () {
    test('comma-separated patterns each parse', () {
      final m = _parseMatch(
          'MATCH (a:Person), (b:Company) WHERE a.name = b.name RETURN a, b');
      expect(m.patterns.length, 2);
    });

    test('chained pattern (a)-[r1]->(b)-[r2]->(c)', () {
      final m =
          _parseMatch('MATCH (a)-[r1]->(b)-[r2]->(c) RETURN a, b, c');
      final p = m.patterns.single;
      expect(p.relationships.length, 2);
      expect(p.nodes.length, 2);
      expect(p.relationships[0].alias, 'r1');
      expect(p.nodes[1].alias, 'c');
    });
  });
}
