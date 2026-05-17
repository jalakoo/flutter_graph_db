/// Predicate + projection expression evaluator (plan §8 / §14 Phase 3B).
///
/// Operates on **raw typed values** — `PropValue` is only constructed
/// at the public API boundary (§3.2 / Spike A). The evaluator unboxes
/// `PropValue` returned by `nodeProps.getBoxed` immediately and
/// thereafter works in Dart `int` / `double` / `String` / `bool`.
library;

import 'package:graph_db_core/graph_db_core.dart';

import '../ast.dart';
import '../plan/planner.dart' show kInternalLabelKey;
import 'result_row.dart';

class EvalException implements Exception {
  final String message;
  EvalException(this.message);
  @override
  String toString() => 'EvalException: $message';
}

class ExpressionEvaluator {
  final GraphDb _db;
  final Map<String, Object?> _params;

  ExpressionEvaluator(this._db, this._params);

  Object? eval(Expression e, ResultRow row) {
    switch (e) {
      case LiteralExpr(:final value):
        return value;
      case IdentifierExpr(:final name):
        if (!row.values.containsKey(name)) {
          throw EvalException('unknown identifier "$name"');
        }
        return row.values[name];
      case ParameterExpr(:final name):
        if (!_params.containsKey(name)) {
          throw EvalException('missing parameter \$$name');
        }
        return _params[name];
      case PropertyAccessExpr(:final target, :final key):
        final base = eval(target, row);
        return _propertyOf(base, key);
      case BinaryOpExpr(:final op, :final left, :final right):
        return _binary(op, eval(left, row), eval(right, row));
      case UnaryOpExpr(:final op, :final operand):
        final v = eval(operand, row);
        switch (op) {
          case UnaryOp.not:
            if (v is! bool) {
              throw EvalException('NOT requires a boolean, got $v');
            }
            return !v;
          case UnaryOp.neg:
            if (v is int) return -v;
            if (v is double) return -v;
            throw EvalException('unary - requires a number, got $v');
        }
      case AggregateExpr():
        throw EvalException(
            'aggregate functions must be projected — not evaluable '
            'mid-expression in v1');
      case FunctionCallExpr(:final fn, :final arguments):
        return _callBuiltin(fn, arguments, row);
    }
  }

  Object? _callBuiltin(
    BuiltinFn fn,
    List<Expression> args,
    ResultRow row,
  ) {
    switch (fn) {
      case BuiltinFn.size:
      case BuiltinFn.length:
        if (args.length != 1) {
          throw EvalException(
              '${fn.name}() expects 1 argument, got ${args.length}');
        }
        final v = eval(args.single, row);
        if (v == null) return null;
        if (v is String) return v.length;
        if (v is List<Object?>) return v.length;
        throw EvalException(
            '${fn.name}() expects string or list, got ${v.runtimeType}');
      case BuiltinFn.coalesce:
        for (final a in args) {
          final v = eval(a, row);
          if (v != null) return v;
        }
        return null;
    }
  }

  Object? _propertyOf(Object? base, String key) {
    // Special sentinel keys recognised regardless of the base type.
    if (key == kInternalLabelKey) {
      if (base is Vid) return _db.state.effectiveLabelOf(base);
      throw EvalException('label predicate on non-node value');
    }
    if (base == null) return null;
    final keyId = _db.state.strings.propKeyIdOf(key);
    if (keyId == null) return null;
    if (base is Vid) {
      final vid = base as Vid;
      if (!_db.state.nodeProps.has(vid.value, keyId)) return null;
      return _unbox(_db.state.nodeProps.getBoxed(vid.value, keyId));
    }
    if (base is Eid) {
      final eid = base as Eid;
      if (!_db.state.edgeProps.has(eid.value, keyId)) return null;
      return _unbox(_db.state.edgeProps.getBoxed(eid.value, keyId));
    }
    throw EvalException(
        'property access on ${base.runtimeType} not supported');
  }

  Object? _unbox(PropValue? v) {
    if (v == null) return null;
    switch (v) {
      case PropInt(:final value):
        return value;
      case PropDouble(:final value):
        return value;
      case PropString(:final value):
        return value;
      case PropBool(:final value):
        return value;
      case PropNull():
        return null;
      case PropList():
      case PropMap():
        throw EvalException(
            'PropList / PropMap eval not supported at boundary (§3.2)');
    }
  }

  Object? _binary(BinaryOp op, Object? a, Object? b) {
    switch (op) {
      case BinaryOp.and:
        if (a is! bool || b is! bool) {
          throw EvalException('AND requires booleans, got $a / $b');
        }
        return a && b;
      case BinaryOp.or:
        if (a is! bool || b is! bool) {
          throw EvalException('OR requires booleans, got $a / $b');
        }
        return a || b;
      case BinaryOp.eq:
        return _equals(a, b);
      case BinaryOp.neq:
        return !_equals(a, b);
      case BinaryOp.lt:
        return _compare(a, b) < 0;
      case BinaryOp.lte:
        return _compare(a, b) <= 0;
      case BinaryOp.gt:
        return _compare(a, b) > 0;
      case BinaryOp.gte:
        return _compare(a, b) >= 0;
      case BinaryOp.plus:
        if (a is String && b is String) return a + b;
        return _arith(a, b, (x, y) => x + y);
      case BinaryOp.minus:
        return _arith(a, b, (x, y) => x - y);
      case BinaryOp.mul:
        return _arith(a, b, (x, y) => x * y);
      case BinaryOp.div:
        return _arith(a, b, (x, y) => x / y);
      case BinaryOp.mod:
        if (a is int && b is int) return a % b;
        return _arith(a, b, (x, y) => x % y);
    }
  }

  bool _equals(Object? a, Object? b) {
    if (a == null || b == null) return a == b;
    if (a is num && b is num) return a == b;
    return a == b;
  }

  int _compare(Object? a, Object? b) {
    if (a == null || b == null) {
      throw EvalException('cannot compare null with $a / $b');
    }
    if (a is num && b is num) return a.compareTo(b);
    if (a is String && b is String) return a.compareTo(b);
    if (a is bool && b is bool) {
      return a == b ? 0 : (a ? 1 : -1);
    }
    throw EvalException('cannot compare ${a.runtimeType} with ${b.runtimeType}');
  }

  Object? _arith(Object? a, Object? b, num Function(num, num) op) {
    if (a is! num || b is! num) {
      throw EvalException(
          'arithmetic requires numbers, got ${a?.runtimeType} / '
          '${b?.runtimeType}');
    }
    final r = op(a, b);
    // Preserve int when both operands are int and the result is exact.
    if (a is int && b is int && r is int) return r;
    if (a is int && b is int && r == r.toInt()) return r.toInt();
    return r.toDouble();
  }
}
