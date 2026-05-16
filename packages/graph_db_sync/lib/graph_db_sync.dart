/// Sync engine — consumes the WAL `WalOp` stream and ships
/// transactions to configured `RemoteGraphClient`s (plan §10).
///
/// **Skeleton.** Implementation lands in Phase 7 per plan §14. v1 is
/// push-only with HLC + LWW-per-property conflict resolution and
/// quarantine-on-rejection; bi-directional sync (data model
/// already anticipates it via the `originId` carried on every WAL
/// entry — §6.3 / §10.1) is deferred to v1.1.
library;
