"""Command-boundary fake; fixture values contain no real AWS identities."""

import json
import os
from pathlib import Path
import sys
import time


tool = Path(sys.argv[0]).name
args = sys.argv[1:]
state_path = Path(os.environ["MOCK_STATE"])
state = json.loads(state_path.read_text()) if state_path.exists() else {"operations": {}}
mode = os.environ.get("MOCK_MODE", "")
counter_id = os.environ.get("MOCK_COUNTER_ID", "global")
counter_table = os.environ.get("MOCK_COUNTER_TABLE", "owned-counter")
with open(os.environ["MOCK_CALLS"], "a") as log:
    log.write(json.dumps({"tool": tool, "args": args}) + "\n")

if mode == "aws-failure" and tool == "aws":
    print("upstream-sensitive-marker", file=sys.stderr)
    sys.exit(42)
if mode == "command-timeout" and tool == "aws":
    time.sleep(5)


def emit(value):
    print(json.dumps(value))


if tool == "aws":
    assert "--profile" in args and args[args.index("--profile") + 1] == "chosen-profile"
    if mode == "profile-endpoint":
        assert os.environ["AWS_CONFIG_FILE"] == os.environ["MOCK_PROFILE_CONFIG"]
    if args[:2] == ["configure", "export-credentials"]:
        assert args[args.index("--format") + 1] == "process"
        emit({"Version": 1, "AccessKeyId": "mock-access", "SecretAccessKey": "mock-secret",
              "SessionToken": "mock-session"})
    elif args[:2] == ["cloudformation", "describe-stack-resource"]:
        assert args[args.index("--logical-resource-id") + 1] == "OperationsTable"
        assert args[args.index("--region") + 1] == "chosen-region"
        emit({"StackResourceDetail": {"PhysicalResourceId": "operations-table"}})
    else:
        assert args[:2] == ["cloudformation", "describe-stacks"]
        assert args[args.index("--region") + 1] == "chosen-region"
        assert args[args.index("--stack-name") + 1] == "chosen-stack"
        outputs = {"IntakeFunctionUrl": "https://intake.example.invalid/",
                   "QueryFunctionUrl": "https://query.example.invalid/",
                   "SeatEventsTableName": "events-table",
                   "LedgerCounterTableName": counter_table, "LedgerCounterId": counter_id}
        if mode == "missing-counter-id":
            outputs.pop("LedgerCounterId")
        if mode == "invalid-counter-id":
            outputs["LedgerCounterId"] = "bad/id"
        if mode == "missing-counter-table":
            outputs.pop("LedgerCounterTableName")
        if mode == "invalid-url":
            outputs["IntakeFunctionUrl"] = "http://unsafe.example.invalid/"
        if mode == "malformed-discovery":
            print("not-json upstream-sensitive-marker")
            sys.exit(0)
        emit({"Stacks": [{"Outputs": [{"OutputKey": k, "OutputValue": v}
                                     for k, v in outputs.items()]}]})
elif tool == "paseto":
    assert args[0] == "issue" and os.environ["PASETO_PRIVATE_KEY"] == "test-private-key"
    print("v4.public." + args[args.index("--subject") + 1])
elif tool == "curl":
    assert args == ["--disable", "--config", "-"]
    entries = [line.split(" = ", 1) for line in sys.stdin.read().splitlines()]
    config = {k: json.loads(v) for k, v in entries if k != "header"}
    assert config["max-time"] == "10" and config["proto"] == "=https"
    header = next((json.loads(v) for k, v in entries
                   if k == "header" and json.loads(v).startswith("Authorization:")), "")
    tenant = header.removeprefix("Authorization: Bearer v4.public.")
    url = config["url"]
    code, response = 200, ""
    if not header:
        code, response = (200, "upstream-sensitive-marker") if mode == "unauthenticated-accepted" else (
            401, "Unauthorized")
    elif config["request"] == "POST":
        operation = json.loads(config["data"])
        assert operation["name"] == "SeatReservation" and set(operation) == {"id", "name", "body"}
        operation_id = operation["id"]
        body = operation["body"]
        command = body["command"]
        if operation_id in state["operations"]:
            code, response = 409, "Conflict"
            if mode == "tenant-collision-accepted":
                code = 200
        else:
            result_type = "SUCCESS"
            if command == "create_event":
                assert body == {"command": "create_event", "classes": {"general": 3, "premium": 2},
                                "timeout_seconds": 300}
                state.update(event_id=operation_id, owner=tenant)
                state["high_water"] = state.get("high_water", 1000) + 1
                state.pop("reserved", None)
                payload = {"event_id": operation_id}
            elif tenant != state["owner"]:
                result_type, payload = "FAILURE", {"code": "event_unavailable"}
            elif command == "reserve_seats":
                assert body["class"] == "general" and body["quantity"] == 2
                state["reserved"] = True
                payload = {"event_id": state["event_id"], "class": "general", "quantity": 2,
                           "reservation_id": "123456789"}
            elif command == "confirm_seats":
                assert body["pending_id"] == "123456789" and body["class"] == "general"
                payload = {"event_id": state["event_id"], "class": "general",
                           "reservation_id": "123456789"}
            else:
                assert command == "check_seats"
                payload = {"event_id": state["event_id"], "classes": {
                    "general": {"total": 3, "available": 1 if state.get("reserved") else 3},
                    "premium": {"total": 2, "available": 2}}}
            response = dict(id=operation_id, tenant=tenant, name="SeatReservation", state="SUBMITTED",
                            hash="a" * 64, last_updated=100, expires_at=86500)
            completed = dict(response, state="COMPLETED",
                             result={"type": result_type, "payload": payload})
            state["operations"][operation_id] = completed
            if mode == "http-failure":
                code, response = 503, "upstream-sensitive-marker"
    else:
        operation_id = url.rsplit("/", 1)[1]
        response = state["operations"].get(operation_id)
        if not response or response["tenant"] != tenant:
            code, response = 404, "Not Found\n"
            if response and mode == "tenant-query-leak":
                code, response = 200, response
        elif mode == "poll-timeout":
            response = dict(response, state="SUBMITTED")
            response.pop("result")
        elif mode == "extra-result-field":
            response["result"]["internal"] = "upstream-sensitive-marker"
        elif mode == "wrong-result":
            response["result"] = {"type": "FAILURE", "payload": {"code": "invalid_request"}}
        elif mode == "wrong-tenant":
            response["tenant"] = "unexpected-tenant"
        elif mode == "boolean-availability" and "classes" in response["result"]["payload"]:
            response["result"]["payload"]["classes"]["general"]["available"] = True
    if mode == "malformed-http" and header:
        print("upstream-sensitive-marker\n200")
        sys.exit(0)
    if mode == "duplicate-http-field" and isinstance(response, dict):
        print('{"id":"first","id":"second"}\n200')
        sys.exit(0)
    print(json.dumps(response) if isinstance(response, dict) else response)
    print(code)
else:
    if mode == "profile-endpoint":
        assert os.environ["AWS_CONFIG_FILE"] == os.devnull
        assert os.environ["AWS_SHARED_CREDENTIALS_FILE"] == os.devnull
    assert os.environ["AWS_ACCESS_KEY_ID"] == "mock-access"
    assert os.environ["AWS_SECRET_ACCESS_KEY"] == "mock-secret"
    assert os.environ["AWS_SESSION_TOKEN"] == "mock-session"
    assert os.environ["AWS_PROFILE"] == "chosen-profile"
    assert os.environ["AWS_REGION"] == "chosen-region"
    if mode == tool + "-failure":
        print("upstream-sensitive-marker", file=sys.stderr)
        sys.exit(43)
    if tool == "ledger-counter":
        assert args == ["--counter-id", counter_id, "read"]
        assert os.environ["LEDGER_COUNTER_TABLE_NAME"] == counter_table
        emit({"counter_id": "wrong-id" if mode == "wrong-counter-output" else counter_id,
              "high_water": state.get("high_water", 1000)})
    elif tool == "events":
        assert args[0] == "read" and os.environ["EVENTS_TABLE_NAME"] == "events-table"
        assert args[args.index("--event-id") + 1] == state["event_id"]
        assert args[args.index("--tenant") + 1] == state["owner"]
        emit({"tenant": state["owner"], "event_id": state["event_id"], "state": "ready",
              "ledger": state["high_water"], "timeout_seconds": 300, "capacity_account_id": "101",
              "allocation_account_id": "102", "classes": {
                  "general": {"total": 3, "tb_account_id": "103"},
                  "premium": {"total": 2, "tb_account_id": "104"}}})
    else:
        assert tool == "dynamodb" and args[0] == "read"
        assert os.environ["OPERATIONS_TABLE_NAME"] == "operations-table"
        emit(state["operations"][args[args.index("--id") + 1]])
state_path.write_text(json.dumps(state))
