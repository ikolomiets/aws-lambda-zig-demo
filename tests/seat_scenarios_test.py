"""Offline CLI tests: external AWS, HTTP and host utility effects are mocked."""

import os
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class SeatScenariosTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        shutil.copy2(ROOT / "seat_scenarios.py", self.work)
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("AWS_")}
        self.env["PASETO_PRIVATE_KEY"] = "test-private-key"
        self.bin = self.work / "bin"
        self.bin.mkdir()
        utilities = self.work / "zig-out/bin"
        utilities.mkdir(parents=True)
        fixture = (ROOT / "tests/fixtures/seat_scenarios_mock.py").read_text()
        for tool in ("aws", "curl", "paseto", "events", "dynamodb", "ledger-counter"):
            path = (self.bin if tool in ("aws", "curl") else utilities) / tool
            path.write_text(f"#!{sys.executable}\n" + fixture)
            path.chmod(0o700)
        self.env.update(PATH=str(self.bin), MOCK_STATE=str(self.work / "state.json"),
                        MOCK_CALLS=str(self.work / "calls.jsonl"))
        self.output = self.work / "evidence"

    def run_cli(self, *args):
        return subprocess.run(
            [sys.executable, str(self.work / "seat_scenarios.py"), *args],
            env=self.env, capture_output=True, text=True, timeout=15,
        )

    def test_help_needs_no_tools_credentials_or_discovery(self):
        self.env.pop("PASETO_PRIVATE_KEY")
        self.env["PATH"] = str(self.work)
        result = self.run_cli("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--authorize-cloud", result.stdout)
        self.assertIn("--stack-name", result.stdout)

    def authorized(self, *args):
        return self.run_cli("--authorize-cloud", "--profile", "chosen-profile", "--region",
                            "chosen-region", "--stack-name", "chosen-stack", "--output-dir",
                            str(self.output), *args)

    def test_workflow_inspects_runtime_binding_and_exact_public_results(self):
        self.env.update(LEDGER_COUNTER_ID="inherited-wrong-id", MOCK_COUNTER_ID="selected-id",
                        MOCK_COUNTER_TABLE="referenced-counter", EVENTS_TABLE_NAME="wrong-events",
                        LEDGER_COUNTER_TABLE_NAME="wrong-counter", OPERATIONS_TABLE_NAME="wrong-operations")
        result = self.authorized()
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((self.output / "manifest.json").read_text())
        self.assertEqual(manifest["status"], "passed")
        self.assertEqual(manifest["evidence"], "deployed")
        state = json.loads((self.work / "state.json").read_text())
        self.assertEqual(len(state["operations"]), 9)
        self.assertEqual(len({op["tenant"] for op in state["operations"].values()}), 2)
        evidence = "".join(p.read_text() for p in self.output.iterdir())
        for private in ("example.invalid", "referenced-counter", "test-private-key", "mock-secret",
                        "v4.public."):
            self.assertNotIn(private, evidence + result.stdout + result.stderr)

    def test_default_binding_ignores_even_invalid_inherited_counter_selection(self):
        self.env["LEDGER_COUNTER_ID"] = "invalid/inherited/id"
        result = self.authorized()
        self.assertEqual(result.returncode, 0, result.stderr)
        before = json.loads((self.output / "before_counter.json").read_text())
        self.assertEqual(before, {"counter_id": "global", "high_water": 1000})

    def test_authorization_and_explicit_selectors_are_required_before_discovery(self):
        cases = [[], ["--profile", "chosen-profile"],
                 ["--authorize-cloud", "--profile", "", "--region", "chosen-region",
                  "--stack-name", "chosen-stack", "--output-dir", str(self.output)]]
        for args in cases:
            with self.subTest(args=args):
                self.assertNotEqual(self.run_cli(*args).returncode, 0)
                self.assertFalse((self.work / "calls.jsonl").exists())

    def test_failures_stop_and_retain_sanitized_inspectable_evidence(self):
        modes = ["aws-failure", "missing-counter-id", "invalid-counter-id", "missing-counter-table",
                 "invalid-url", "malformed-discovery", "unauthenticated-accepted", "http-failure",
                 "malformed-http", "duplicate-http-field", "extra-result-field", "wrong-result",
                 "wrong-tenant", "boolean-availability", "tenant-query-leak", "tenant-collision-accepted",
                 "ledger-counter-failure", "wrong-counter-output", "events-failure", "dynamodb-failure"]
        for mode in modes:
            with self.subTest(mode=mode):
                self.env["MOCK_MODE"] = mode
                self.output = self.work / mode
                (self.work / "state.json").unlink(missing_ok=True)
                result = self.authorized()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                manifest = json.loads((self.output / "manifest.json").read_text())
                self.assertEqual(manifest["status"], "failed")
                self.assertTrue(manifest["stage"])
                self.assertTrue(manifest["reason"])
                captured = result.stdout + result.stderr
                captured += "".join(p.read_text() for p in self.output.iterdir())
                self.assertNotIn("upstream-sensitive-marker", captured)
                self.assertNotIn("v4.public.", captured)

    def test_polling_stops_at_the_selected_attempt_limit(self):
        self.env["MOCK_MODE"] = "poll-timeout"
        result = self.authorized("--poll-attempts", "2", "--poll-seconds", "0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("timed out after 2 attempts", result.stderr)
        calls = [json.loads(line) for line in (self.work / "calls.jsonl").read_text().splitlines()]
        self.assertFalse(any(call["tool"] in ("events", "dynamodb") for call in calls))

    def test_repeat_runs_use_new_tenants_events_and_operations_without_cleanup(self):
        first = self.authorized()
        self.assertEqual(first.returncode, 0, first.stderr)
        first_manifest = json.loads((self.output / "manifest.json").read_text())
        self.output = self.work / "second"
        second = self.authorized()
        self.assertEqual(second.returncode, 0, second.stderr)
        second_manifest = json.loads((self.output / "manifest.json").read_text())
        self.assertTrue(set(first_manifest["tenants"]).isdisjoint(second_manifest["tenants"]))
        self.assertTrue(set(first_manifest["operations"].values()).isdisjoint(
            second_manifest["operations"].values()))

    def test_existing_output_directory_is_never_overwritten(self):
        self.output.mkdir()
        (self.output / "manifest.json").write_text("existing evidence")
        result = self.authorized()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.output / "manifest.json").read_text(), "existing evidence")
        self.assertFalse((self.work / "calls.jsonl").exists())

    def test_total_deadline_terminates_a_stalled_external_command(self):
        self.env["MOCK_MODE"] = "command-timeout"
        result = self.authorized("--timeout-seconds", "1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("aws timed out", result.stderr)
        manifest = json.loads((self.output / "manifest.json").read_text())
        self.assertEqual(manifest["status"], "failed")

    def test_invalid_bounds_and_cloud_endpoint_overrides_fail_before_discovery(self):
        for args in (("--poll-attempts", "0"), ("--poll-seconds", "nan"),
                     ("--timeout-seconds", "301")):
            with self.subTest(args=args):
                self.assertNotEqual(self.authorized(*args).returncode, 0)
                self.assertFalse((self.work / "calls.jsonl").exists())
        self.env["AWS_ENDPOINT_URL_DYNAMODB"] = "http://local.example.invalid"
        result = self.authorized()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("endpoint overrides", result.stderr)
        self.assertFalse((self.work / "calls.jsonl").exists())

    def test_profile_endpoint_configuration_cannot_redirect_utility_inspection(self):
        config = self.work / "config"
        config.write_text("[profile chosen-profile]\nendpoint_url = http://local.example.invalid\n")
        self.env.update(MOCK_MODE="profile-endpoint", MOCK_PROFILE_CONFIG=str(config),
                        AWS_CONFIG_FILE=str(config), AWS_SHARED_CREDENTIALS_FILE=str(config))
        result = self.authorized()
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
