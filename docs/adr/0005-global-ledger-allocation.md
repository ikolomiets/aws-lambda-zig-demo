# 0005: Allocate ledgers through one global counter binding

Status: Superseded by [0006: Select independent ledger counters within one table](0006-selectable-ledger-counters.md).

The decision below records the historical fixed-global contract. The replacement
shared API and host tooling are implemented by the
[Support selectable independent ledger counters](../../.scratch/seat-reservation/issues/05-selectable-ledger-counters.md)
ticket.

## Decision

Seat creation shares one sequence to prevent ordinary ledger reuse across
participating deployments without introducing tenant or native cluster ranges.
The selected counter table and fixed String key `counter_id = "global"` define
one bounded u32 ledger sequence. Participating tenants and deployments share this
binding independently of native cluster selection. Native cluster identity is
absent from allocator storage, API and configuration. Separate tables define
separate allocators.

First-time setup inserts 1000 absent-only. Allocation increments validated state
conditionally and uses only the returned updated value. Existing data is preserved;
missing established state is an error. Uncertain allocations are never inferred
from subsequent reads. Lost responses and losing Event inserts may consume gaps.

## Consequences

An owned or referenced physical table can serve many deployments. Native cluster
changes do not justify resetting or selecting a fresh sequence. Counter retention
is independent of Operation TTL; only the table owner may clean it up. Tooling
exposes setup, read and allocation without lifecycle or repair commands. Restore
reconciliation, ledger reuse and exhaustion migration remain outside this contract.

The [Seat Reservation reference](../SEAT_RESERVATION.md#global-ledger-allocator)
owns the counter schema, bounds, errors and memory lifetimes. The
[deployment guide](../DEPLOY_AWS_LAMBDA_WITH_SAM.md#global-ledger-counter-utility)
owns explicit setup and resource discovery.
