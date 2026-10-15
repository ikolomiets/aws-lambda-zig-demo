# Local Seat Event and Operation transaction probe

The Debug [SDK harness](../tests/seat_transactions.zig) exercises the pinned
`aws_sdk` revision `778dcfe1423cf3b3a1bfe56e1e461b99b80124bd`. It composes
`finalization_update` from the Event persistence module and `seat_completion_update`
from Operation persistence in one real `TransactWriteItems` request. It reads the
pair with `TransactGetItems` and decodes both through the shared persistence modules.
No Lambda, SQS, TigerBeetle or cloud resources participate.

Provision Docker with a running local daemon, Zig 0.16.0, curl, and the repository's
pinned Zig packages. Provision the pinned test-only database image once:

```sh
docker pull amazon/dynamodb-local:3.3.0@sha256:d89f8fcc6b1a39cb35976c248ed42a28c66ae00dc043099210f5571e42648ab4
```

From the repository root, run:

```sh
./tests/seat_transactions_test.sh
```

The runner starts its own DynamoDB Local **3.3.0** container with telemetry disabled
and a randomly assigned port bound only to `127.0.0.1`. It waits up to 60 attempts,
each with a one-second HTTP deadline, runs `zig build test-seat-transactions` in Debug,
and removes only its own container. Missing tools, image or local endpoint fail
explicitly. Package fetching is disabled; `CHECK_ZIG_PACKAGE_DIR` selects an already
provisioned package directory. The SDK uses an explicit loopback endpoint, dummy
`local` credentials, an isolated environment map, one HTTP attempt and a 128 KiB
response cap. It never falls back to AWS credentials or a cloud endpoint.

For debugging, preserve the running database, fixture directory and logs:

```sh
./tests/seat_transactions_test.sh --keep
```

The output identifies the container and endpoint and prints its exact cleanup
command. Service and test output live in `service.log` and `tests.log` under the
printed temporary directory. After a failure, logs remain even without `--keep`;
the database remains only with `--keep`. Fresh runs use separate containers and
clean tables. The focused `test-seat-transactions` target requires
`SEAT_TRANSACTION_ENDPOINT=http://127.0.0.1:<port>` pointing to that isolated fixture.
Re-executing the target against an already populated fixture fails table creation;
use another runner invocation for a clean repeat. The target is separate from the
ordinary offline `zig build test` graph.

The executable evidence covers:

- Event `creating` to `ready` and Operation `SUBMITTED` to `COMPLETED` in one commit,
  including the exact Result, normal timestamps/TTL and retained identity/configuration.
- Event configuration rejection with neither record changed, and a decoded
  cancellation reason identifying the Event action.
- Operation tenant rejection with neither record changed, and a decoded cancellation
  reason identifying the Operation action.
- The Event `failed` and Operation failure variant with the same builders; replay
  cancels and coherent readback preserves the winning terminal pair.
- Diagnostic Strings surviving request/HTTP-response release, with the testing
  allocator checking cleanup. Simulated missing, empty and malformed readback JSON
  is tested separately from database execution and cannot establish a committed pair.

DynamoDB Local does not reproduce every AWS behavior. Conditional cancellation
establishes these local guard/composition paths; it does not prove live transaction
contention or `TransactionConflictException` handling. See the
[AWS local-service limitations](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/DynamoDBLocal.UsageNotes.html).
This evidence does not certify deployed IAM, queue mappings or native accounting.
