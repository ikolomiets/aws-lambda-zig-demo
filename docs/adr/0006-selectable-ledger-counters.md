# 0006: Select independent ledger counters within one table

Status: Accepted.

Supersedes [0005: Allocate ledgers through one global counter binding](0005-global-ledger-allocation.md).

One LedgerCounter table supports multiple independent Ledger Counters identified
by unique String `counter_id` values. The physical table and selected ID define
an allocator binding; omitted selection uses `"global"`, preserving the existing
record and default behavior without a key-schema change or data conversion.
Callers select IDs through the shared API, operator tooling, or trusted deployment
configuration. Public SeatReservation Bodies retain their existing fields, and
native cluster identity never derives a counter ID.

Independent bindings may allocate equal numeric ledger values. Consumers that
require one shared ledger sequence must use the same binding. Each counter retains
absent-only setup at 1000, bounded u32 conditional atomic increments returning the
updated value, explicit uncertainty, permitted gaps, and independent retention
from Operations. Existing allocator bindings remain durable deployment identity;
choosing another ID is not a repair or reset of an established sequence.

The [selectable-counter amendment](../../.scratch/seat-reservation/comments/seat-spec/2026-10-14-selectable-ledger-counters.md)
records selection, validation, compatibility and affected work.
[Support selectable independent ledger counters](../../.scratch/seat-reservation/issues/05-selectable-ledger-counters.md)
implements the shared allocator API and host tooling. The
[Seat Reservation reference](../SEAT_RESERVATION.md#global-ledger-allocator) and
[deployment guide](../DEPLOY_AWS_LAMBDA_WITH_SAM.md#global-ledger-counter-utility)
own the current contracts. Seat submission uses the trusted configured binding;
SAM exposes the actual owned or referenced counter table and configured ID.
