import 'package:graph_db_core/graph_db_core.dart';
import 'package:graph_db_wal/graph_db_wal.dart';
import 'package:test/test.dart';

/// The string-keyed convenience methods auto-intern names. This proves
/// those interns are journaled to the WAL, so the catalog + node survive
/// a recovery.
void main() {
  test('addNodeNamed auto-interns are journaled and survive recovery',
      () async {
    final store = InMemoryWalStore();
    final db = await openWalBackedGraphDb(store: store);
    await db.runTransaction((txn) => txn.addNodeNamed(
          labels: ['Person'],
          props: {'name': const PropString('Ada')},
        ));
    await db.close();

    store.reopen();
    final db2 = await openWalBackedGraphDb(store: store);
    final person = db2.labelId('Person');
    final name = db2.propKeyId('name');
    expect(person, isNotNull, reason: 'label intern was journaled');
    expect(name, isNotNull, reason: 'prop-key intern was journaled');
    expect(db2.labelScan(person!).length, 1);
    final vid = Vid(db2.labelScan(person).first);
    expect(db2.getNodeStringProp(vid, name!), 'Ada');
    await db2.close();
  });
}
