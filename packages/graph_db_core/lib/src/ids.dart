/// Local 32-bit node id (plan §3.6).
///
/// `Vid` is an [extension type] over `int` — nominal compile-time safety,
/// zero runtime cost. The 32-bit width comes from §3.1: `Uint64List` is
/// unavailable on Dart's web targets, so the CSR is `Uint32List` and ids
/// are correspondingly capped at 2³² (~4.29 billion). [invalid] uses
/// `0xFFFFFFFF` as the sentinel.
extension type const Vid(int value) {
  static const Vid invalid = Vid(0xFFFFFFFF);
  bool get isValid => value != 0xFFFFFFFF;
}

/// Local 32-bit edge id. Same width / cap / sentinel as [Vid].
extension type const Eid(int value) {
  static const Eid invalid = Eid(0xFFFFFFFF);
  bool get isValid => value != 0xFFFFFFFF;
}
