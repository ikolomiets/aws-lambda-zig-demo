#!/usr/bin/env python3
"""Explicitly authorized deployed Seat Reservation scenarios; never builds or deploys."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from urllib.parse import urlsplit
import uuid


class ScenarioError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise ScenarioError(message)


def decode(text):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "duplicate JSON field")
            result[key] = value
        return result

    try:
        return json.loads(text, object_pairs_hook=unique,
                          parse_constant=lambda _: require(False, "invalid JSON constant"))
    except (ValueError, TypeError):
        raise ScenarioError("invalid JSON output") from None


def exact(actual, expected):
    require(json.dumps(actual, sort_keys=True) == json.dumps(expected, sort_keys=True),
            "unexpected public Result")


def native_id(value):
    return (isinstance(value, str) and re.fullmatch(r"[1-9][0-9]{0,38}", value)
            and int(value) <= 2**128 - 2)


def arguments():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--authorize-cloud", action="store_true", required=True,
                        help="authorize scenario effects on the selected development stack")
    parser.add_argument("--profile", required=True)
    parser.add_argument("--region", required=True)
    parser.add_argument("--stack-name", required=True)
    parser.add_argument("--output-dir", required=True,
                        help="new directory for sanitized evidence (no URLs or credentials)")
    parser.add_argument("--poll-attempts", type=int, default=30, help="1-60, per Operation")
    parser.add_argument("--poll-seconds", type=float, default=2, help="0-5, between reads")
    parser.add_argument("--timeout-seconds", type=float, default=300, help="1-300, entire run")
    args = parser.parse_args()
    if not (1 <= args.poll_attempts <= 60 and 0 <= args.poll_seconds <= 5):
        parser.error("poll bounds: attempts 1-60, seconds 0-5")
    if not 1 <= args.timeout_seconds <= 300:
        parser.error("timeout bound: seconds 1-300")
    if not all(value.strip() for value in (args.profile, args.region, args.stack_name)):
        parser.error("profile, region and stack name must be explicit and nonempty")
    return args


class Scenarios:
    def __init__(self, args):
        self.args = args
        self.root = Path(__file__).resolve().parent
        self.output = Path(args.output_dir)
        self.env = dict(os.environ)
        self.deadline = time.monotonic() + args.timeout_seconds
        self.stage = "prerequisites"
        self.manifest = {"evidence": "deployed", "status": "running", "operations": {}}

    def save(self, name, value):
        (self.output / (name + ".json")).write_text(json.dumps(value, indent=2) + "\n")

    def command(self, tool, *args, input_text=None):
        remaining = self.deadline - time.monotonic()
        require(remaining > 0, "scenario deadline exceeded")
        executable = str(self.root / "zig-out/bin" / tool) if tool in (
            "paseto", "events", "dynamodb", "ledger-counter") else tool
        child_env = self.env
        if tool in ("events", "dynamodb", "ledger-counter"):
            # The pinned SDK prioritizes profile endpoint_url over its ignore flag.
            # Exported credentials and explicit Region/table bindings are sufficient.
            child_env = dict(self.env, AWS_CONFIG_FILE=os.devnull,
                             AWS_SHARED_CREDENTIALS_FILE=os.devnull)
        try:
            result = subprocess.run([executable, *args], input=input_text, env=child_env,
                                    capture_output=True, text=True, timeout=min(30, remaining))
        except subprocess.TimeoutExpired:
            raise ScenarioError(f"{tool} timed out") from None
        except (OSError, UnicodeError):
            raise ScenarioError(f"{tool} could not execute or decode output") from None
        require(result.returncode == 0, f"{tool} failed (exit {result.returncode})")
        require(len(result.stdout) <= 131072, f"{tool} output exceeds bound")
        return result.stdout.strip()

    def aws(self, *args):
        return self.command("aws", *args, "--profile", self.args.profile,
                            "--no-cli-pager", "--cli-connect-timeout", "5",
                            "--cli-read-timeout", "10")

    def setup(self):
        require(bool(self.env.get("PASETO_PRIVATE_KEY")), "PASETO_PRIVATE_KEY is required")
        for tool in ("aws", "curl"):
            require(shutil.which(tool) is not None, f"missing command: {tool}")
        for tool in ("paseto", "events", "dynamodb", "ledger-counter"):
            require(os.access(self.root / "zig-out/bin" / tool, os.X_OK),
                    f"missing prebuilt host utility: {tool}")
        require(not any(key.startswith("AWS_ENDPOINT_URL") and value
                        for key, value in self.env.items()), "AWS endpoint overrides are not allowed")
        for key in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
                    "AWS_SECURITY_TOKEN"):
            self.env.pop(key, None)
        self.env.update(AWS_PROFILE=self.args.profile, AWS_REGION=self.args.region,
                        AWS_DEFAULT_REGION=self.args.region, AWS_EC2_METADATA_DISABLED="true",
                        AWS_IGNORE_CONFIGURED_ENDPOINT_URLS="true", AWS_MAX_ATTEMPTS="1")
        self.stage = "credential export"
        credentials = decode(self.aws("configure", "export-credentials", "--format", "process"))
        for field, key in (("AccessKeyId", "AWS_ACCESS_KEY_ID"),
                           ("SecretAccessKey", "AWS_SECRET_ACCESS_KEY"),
                           ("SessionToken", "AWS_SESSION_TOKEN")):
            require(isinstance(credentials.get(field), str) and bool(credentials[field]),
                    "credential export omitted temporary credentials")
            self.env[key] = credentials[field]
        self.stage = "stack discovery"
        response = decode(self.aws("cloudformation", "describe-stacks", "--stack-name",
                                   self.args.stack_name, "--region", self.args.region, "--output", "json"))
        require(isinstance(response, dict) and isinstance(response.get("Stacks"), list)
                and len(response["Stacks"]) == 1, "expected one deployed stack")
        outputs = response["Stacks"][0].get("Outputs", [])
        require(isinstance(outputs, list), "invalid stack outputs")
        self.binding = {}
        for entry in outputs:
            require(isinstance(entry, dict) and isinstance(entry.get("OutputKey"), str)
                    and isinstance(entry.get("OutputValue"), str), "invalid stack output")
            key = entry["OutputKey"]
            require(key not in self.binding, "duplicate stack output")
            self.binding[key] = entry["OutputValue"]
        for key in ("IntakeFunctionUrl", "QueryFunctionUrl"):
            url = urlsplit(self.binding.get(key, ""))
            require(url.scheme == "https" and url.hostname and not url.username
                    and not url.password and not url.query and not url.fragment
                    and url.path in ("", "/"), f"missing or invalid {key} output")
        for output, env_key in (("SeatEventsTableName", "EVENTS_TABLE_NAME"),
                                ("LedgerCounterTableName", "LEDGER_COUNTER_TABLE_NAME")):
            value = self.binding.get(output, "")
            require(re.fullmatch(r"[A-Za-z0-9_.-]{3,255}", value), f"missing or invalid {output} output")
            self.env[env_key] = value
        self.counter_id = self.binding.get("LedgerCounterId", "")
        require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", self.counter_id),
                "missing or invalid LedgerCounterId output; deploy the six-function baseline")
        resource = decode(self.aws("cloudformation", "describe-stack-resource", "--stack-name",
                                   self.args.stack_name, "--region", self.args.region,
                                   "--logical-resource-id", "OperationsTable", "--output", "json"))
        table = resource.get("StackResourceDetail", {}).get("PhysicalResourceId", "")
        require(isinstance(table, str) and re.fullmatch(r"[A-Za-z0-9_.-]{3,255}", table),
                "missing or invalid OperationsTable physical resource")
        self.env["OPERATIONS_TABLE_NAME"] = table

    def http(self, method, url, token=None, body=None, status=200):
        config = {"url": url, "request": method, "silent": "", "show-error": "",
                  "connect-timeout": "5", "max-time": "10", "max-filesize": "65536",
                  "proto": "=https", "write-out": "\n%{http_code}"}
        if token:
            config["header"] = "Authorization: Bearer " + token
        lines = [f"{key} = {json.dumps(value)}" for key, value in config.items()]
        if body is not None:
            lines += ['header = "Content-Type: application/json"',
                      "data = " + json.dumps(json.dumps(body, separators=(",", ":")))]
        raw = self.command("curl", "--disable", "--config", "-", input_text="\n".join(lines) + "\n")
        response, separator, code = raw.rpartition("\n")
        require(separator and re.fullmatch(r"[0-9]{3}", code), "invalid HTTP status output")
        require(code == str(status), f"unexpected HTTP status {code} (expected {status})")
        return response

    def operation(self, value, operation_id, tenant):
        require(isinstance(value, dict), "invalid Operation output")
        required = {"id", "tenant", "name", "state", "hash", "last_updated", "expires_at"}
        require(value.get("state") in ("SUBMITTED", "COMPLETED"), "invalid Operation State")
        if value["state"] == "COMPLETED":
            required.add("result")
        require(set(value) == required and value["id"] == operation_id
                and value["tenant"] == tenant and value["name"] == "SeatReservation",
                "Operation identity or fields mismatch")
        require(isinstance(value["hash"], str) and re.fullmatch(r"[a-f0-9]{64}", value["hash"])
                and all(type(value[key]) is int and value[key] >= 0
                        for key in ("last_updated", "expires_at")), "invalid Operation metadata")
        return value

    def submit(self, label, body, tenant, token, payload=None, result_type="SUCCESS"):
        operation_id = str(uuid.uuid4())
        self.manifest["operations"][label] = operation_id
        self.save("manifest", self.manifest)
        self.stage = f"{label} intake (Operation {operation_id})"
        request = {"id": operation_id, "name": "SeatReservation", "body": body}
        self.operation(decode(self.http("POST", self.binding["IntakeFunctionUrl"], token, request)),
                       operation_id, tenant)
        self.stage = f"{label} query (Operation {operation_id})"
        for attempt in range(self.args.poll_attempts):
            result = self.operation(decode(self.http("GET", self.query_url(operation_id), token)),
                                    operation_id, tenant)
            if result["state"] == "COMPLETED":
                if label == "create":
                    payload = {"event_id": operation_id}
                if label == "reserve":
                    reservation = result.get("result", {}).get("payload", {}).get("reservation_id")
                    require(native_id(reservation), "invalid reservation ID")
                    payload = dict(payload, reservation_id=reservation)
                exact(result["result"], {"type": result_type, "payload": payload})
                self.save(label, result)
                self.stage = f"{label} persistent Operation inspection"
                persisted = decode(self.command("dynamodb", "read", "--id", operation_id))
                exact(persisted, result)
                return result
            if attempt + 1 < self.args.poll_attempts:
                time.sleep(min(self.args.poll_seconds, max(0, self.deadline - time.monotonic())))
        raise ScenarioError(f"Operation polling timed out after {self.args.poll_attempts} attempts")

    def query_url(self, operation_id):
        return self.binding["QueryFunctionUrl"].rstrip("/") + "/" + operation_id

    def counter(self, label):
        self.stage = label + " counter inspection"
        value = decode(self.command("ledger-counter", "--counter-id", self.counter_id, "read"))
        require(isinstance(value, dict) and set(value) == {"counter_id", "high_water"}
                and value["counter_id"] == self.counter_id and type(value["high_water"]) is int
                and 1000 <= value["high_water"] <= 2**32 - 1, "invalid selected counter output")
        self.save(label + "_counter", value)
        return value["high_water"]

    def run(self):
        self.setup()
        tenants = ["seat-" + str(uuid.uuid4()) for _ in range(2)]
        self.manifest["tenants"] = tenants
        self.save("manifest", self.manifest)
        self.stage = "token issuance"
        tokens = [self.command("paseto", "issue", "--subject", tenant, "--ttl-seconds", "900")
                  for tenant in tenants]
        require(all(re.fullmatch(r"v4\.public\.[A-Za-z0-9_.-]+", token) for token in tokens)
                and tokens[0] != tokens[1], "invalid or identical tenant tokens")
        # Child processes that do not issue tokens never need the signing key.
        self.env.pop("PASETO_PRIVATE_KEY", None)
        self.stage = "unauthenticated public requests"
        self.http("POST", self.binding["IntakeFunctionUrl"], body={}, status=401)
        self.http("GET", self.query_url(str(uuid.uuid4())), status=401)
        before = self.counter("before")
        create = self.submit("create", {"command": "create_event", "classes": {"general": 3,
                             "premium": 2}, "timeout_seconds": 300}, tenants[0], tokens[0])
        event_id = create["id"]
        self.stage = "persistent Event inspection"
        event = decode(self.command("events", "read", "--tenant", tenants[0], "--event-id", event_id))
        require(isinstance(event, dict) and set(event) == {"tenant", "event_id", "ledger",
                "timeout_seconds", "capacity_account_id", "allocation_account_id", "state", "classes"},
                "invalid Event fields")
        require(event["tenant"] == tenants[0] and event["event_id"] == event_id
                and event["state"] == "ready" and event["timeout_seconds"] == 300
                and type(event["ledger"]) is int and before < event["ledger"] <= 2**32 - 1
                and native_id(event["capacity_account_id"]) and native_id(event["allocation_account_id"]),
                "Event identity, readiness or ledger mismatch")
        require(isinstance(event["classes"], dict) and set(event["classes"]) == {"general", "premium"},
                "Event classes mismatch")
        for tag, total in (("general", 3), ("premium", 2)):
            entry = event["classes"][tag]
            require(isinstance(entry, dict) and set(entry) == {"total", "tb_account_id"}
                    and type(entry["total"]) is int and entry["total"] == total
                    and native_id(entry["tb_account_id"]), "Event class configuration mismatch")
        self.save("event", event)
        require(self.counter("after") >= event["ledger"], "counter does not cover Event ledger")
        check_body = {"command": "check_seats", "event_id": event_id}
        check_payload = {"event_id": event_id, "classes": {
            "general": {"total": 3, "available": 3}, "premium": {"total": 2, "available": 2}}}
        self.submit("initial_check", check_body, tenants[0], tokens[0], check_payload)
        reserve_body = {"command": "reserve_seats", "event_id": event_id, "class": "general", "quantity": 2}
        reserve = self.submit("reserve", reserve_body, tenants[0], tokens[0],
                              {"event_id": event_id, "class": "general", "quantity": 2})
        pending_id = reserve["result"]["payload"]["reservation_id"]
        check_payload["classes"]["general"]["available"] = 1
        self.submit("held_check", check_body, tenants[0], tokens[0], check_payload)
        confirm_body = {"command": "confirm_seats", "event_id": event_id, "class": "general",
                        "pending_id": pending_id}
        self.submit("confirm", confirm_body, tenants[0], tokens[0],
                    {"event_id": event_id, "class": "general", "reservation_id": pending_id})
        self.submit("final_check", check_body, tenants[0], tokens[0], check_payload)
        self.stage = "tenant isolation through public query and intake"
        foreign = self.http("GET", self.query_url(event_id), tokens[1], status=404)
        missing = self.http("GET", self.query_url(str(uuid.uuid4())), tokens[1], status=404)
        require(foreign == missing == "Not Found\n", "cross-tenant query disclosed Operation data")
        self.http("POST", self.binding["IntakeFunctionUrl"], tokens[1],
                  {"id": event_id, "name": "SeatReservation", "body": check_body}, status=409)
        for label, body in (("foreign_check", check_body), ("foreign_reserve", reserve_body),
                            ("foreign_confirm", confirm_body)):
            self.submit(label, body, tenants[1], tokens[1], {"code": "event_unavailable"}, "FAILURE")


def main():
    args = arguments()
    os.umask(0o077)
    scenarios = Scenarios(args)
    try:
        scenarios.output.mkdir(mode=0o700)
    except OSError:
        print("seat scenarios: output directory must be new and have an existing parent", file=sys.stderr)
        return 2
    try:
        scenarios.save("manifest", scenarios.manifest)
        scenarios.run()
        scenarios.manifest["status"] = "passed"
        scenarios.save("manifest", scenarios.manifest)
    except (ScenarioError, OSError, ValueError, TypeError, KeyError, AttributeError) as error:
        # Foreign command output and exception text can contain account details or credentials.
        reason = str(error) if isinstance(error, ScenarioError) else "invalid output or local I/O failure"
        scenarios.manifest.update(status="failed", stage=scenarios.stage, reason=reason)
        try:
            scenarios.save("manifest", scenarios.manifest)
        except OSError:
            pass
        print(f"seat scenarios: {scenarios.stage}: {reason}", file=sys.stderr)
        return 1
    print("Deployed seat scenarios passed; sanitized evidence retained in the selected output directory.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
