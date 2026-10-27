# 0006: Select independent ledger counters within one table

Status: Accepted.

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

The [Seat Reservation specification](../SEAT_RESERVATION.md#global-ledger-allocator)
owns selection, validation, compatibility and the shared allocator API. The
[deployment guide](../DEPLOY_AWS_LAMBDA_WITH_SAM.md#global-ledger-counter-utility)
owns host tooling and operational procedures. Seat submission uses the trusted
configured binding; SAM exposes the actual owned or referenced counter table
and configured ID.
