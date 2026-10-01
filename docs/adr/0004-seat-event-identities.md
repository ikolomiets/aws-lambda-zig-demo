# 0004: Persist tenant-owned Seat Event identities before dispatch

Status: Accepted

## Decision

Seat Events have separate String `tenant` and `event_id` DynamoDB keys. Their
ledger, account identities, classes and timeout are durable configuration,
independent of disposable Operation tracking records. No Event TTL applies.
Native IDs use decimal Strings to preserve the complete supported u128 range.

Absent-only insertion accepts `creating` metadata. Concurrent or uncertain
insertion resolves through an authoritative tenant-scoped read and returns the
saved configuration and identities. A candidate that loses insertion cannot
supply identities for native dispatch. An unresolved insertion is an operating
error. A retry with different classes or timeout is a conflict.

The Events administrative utility inserts and reads metadata through this shared
contract. It exposes no readiness finalization, replacement, reset or deletion.
Readiness belongs to processor completion; administrative insertion provides no
native provisioning evidence.

## Consequences

Losing candidates can consume unused ledger values and native IDs; gaps are
permitted. Retaining the saved winner preserves deterministic initialization
inputs across retries. Permanent metadata requires explicit lifecycle decisions
outside Operation TTL and outside the Events utility. Tenant-scoped keys and
validation prevent foreign Event reads from revealing configuration or state.

The [Seat Reservation reference](../SEAT_RESERVATION.md) owns wire formats,
validation and size limits.
