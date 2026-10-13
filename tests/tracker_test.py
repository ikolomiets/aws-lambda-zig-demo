"""Exercise the tracker command through temporary on-disk efforts."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


COMMAND = Path(__file__).resolve().parents[1] / "tracker.py"


class TrackerTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / ".scratch"
        self.issues = self.root / "effort" / "issues"
        self.issues.mkdir(parents=True)

    def issue(self, name, *, order=10, status="open", assignee="null",
              parent="map", labels="[wayfinder:task, ready-for-agent]",
              blockers="None.", criteria="- [x] Implement the command."):
        path = self.issues / f"{name}.md"
        body = f"## Acceptance criteria\n\n{criteria}\n"
        if blockers is not None:
            body += f"\n## Blocked by\n\n{blockers}\n"
        path.write_text(
            f"---\nid: {name}\ntitle: Work {name}\nstatus: {status}\n"
            f"labels: {labels}\nparent: {parent}\nassignee: {assignee}\n"
            f"mode: AFK\norder: {order}\n---\n\n{body}"
        )
        return path

    def map(self):
        return self.issue("map", parent="null", labels="[wayfinder:map]",
                          blockers=None)

    def run_command(self, *arguments):
        return subprocess.run(
            [sys.executable, str(COMMAND), "--root", str(self.root), *arguments],
            capture_output=True, text=True, check=False,
        )

    def snapshot(self):
        return {str(path.relative_to(self.root)): path.read_bytes()
                for path in self.root.rglob("*") if path.is_file()}

    def resolution(self, name, *, filename="2026-10-13-resolution.md",
                   content=None):
        path = self.root / "effort" / "comments" / name / filename
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content if content is not None else (
            "# Resolution — Reviewed work\n\nDisposition: completed\n"
            "Reviewed by: Maintainer\n\n## Acceptance evidence\n\n"
            "- The command tests pass and the reviewer checked the acceptance criteria.\n"
        ))
        return path

    def test_frontier_selects_unassigned_ready_children_in_numeric_then_id_order(self):
        self.map()
        self.issue("z", order=2)
        self.issue("a", order=2)
        self.issue("later", order=10)
        self.issue("assigned", order=1, assignee="igork")
        self.issue("done", status="closed")
        self.issue("blocked", blockers="[Work assigned](assigned.md)")
        self.issue("ready", order=3, blockers="[Work done](done.md)")
        before = self.snapshot()

        result = self.run_command("frontier", "effort", "map")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            "Work a — effort/issues/a.md",
            "Work z — effort/issues/z.md",
            "Work ready — effort/issues/ready.md",
            "Work later — effort/issues/later.md",
        ])
        self.assertEqual(self.snapshot(), before)

    def test_validation_rejects_missing_or_malformed_required_metadata(self):
        self.map()
        path = self.issue("invalid")
        valid = path.read_text()
        cases = [
            ("missing front matter", valid.removeprefix("---\n")),
            ("duplicate metadata", valid.replace("id: invalid", "id: invalid\nid: other")),
            ("malformed metadata", valid.replace("title: Work invalid", "title Work invalid")),
        ]
        for field in ("id", "title", "status", "labels", "parent", "assignee", "mode", "order"):
            line = next(line for line in valid.splitlines() if line.startswith(field + ":"))
            cases.append((f"missing {field}", valid.replace(line + "\n", "")))
            cases.append((f"empty {field}", valid.replace(line, field + ": ")))
        for field, value in (("id", "../escape"), ("status", "done"),
                             ("title", "[invalid]"), ("title", '"unterminated'),
                             ("labels", "ready-for-agent"), ("labels", "[one,,two]"),
                             ("parent", "[map]"), ("assignee", "[igork]"),
                             ("mode", "UNKNOWN"), ("order", "second")):
            line = next(line for line in valid.splitlines() if line.startswith(field + ":"))
            cases.append((f"invalid {field}", valid.replace(line, f"{field}: {value}")))
        for description, content in cases:
            with self.subTest(description=description):
                path.write_text(content)
                before = self.snapshot()
                result = self.run_command("validate")
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("invalid.md", result.stderr)
                self.assertNotIn("Traceback", result.stderr)
                self.assertEqual(self.snapshot(), before)

    def test_validation_discovers_efforts_and_accepts_compatible_metadata(self):
        self.map()
        spec = self.issue("spec", labels="[]", blockers=None)
        spec.write_text(spec.read_text() + "\n## Problem Statement\n\nA problem.\n\n## Solution\n\nA solution.\n")
        self.issue("historical", parent="spec", status="closed", assignee="igork",
                   criteria="- [ ] Historical unchecked criterion.")
        self.resolution("historical", filename="2026-09-01-resolution.md",
                        content="# Resolution\n\nThe previous reviewer recorded an answer.\n")
        path = self.issue("also-ready", order=10, labels='[ready-for-agent, "help wanted", extra]')
        path.write_text(path.read_text().replace("title: Work also-ready", "title: 'Work also-ready'"))
        other = self.root / "other" / "issues"
        other.mkdir(parents=True)
        (other / "other-map.md").write_text(
            self.map().read_text().replace("id: map", "id: other-map"))
        before = self.snapshot()
        result = self.run_command("validate")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("5 issues", result.stdout)
        self.assertEqual(self.snapshot(), before)

    def test_empty_tracker_reports_zero_issues(self):
        result = self.run_command("validate")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("0 issues", result.stdout)
        self.issues.rmdir()
        self.issues.parent.rmdir()
        self.root.rmdir()
        result = self.run_command("validate")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("0 issues", result.stdout)

    def test_structural_failures_are_diagnosed_before_frontier_output(self):
        self.map()
        first = self.issue("first")
        second = self.issue("second")
        original = {path: path.read_text() for path in (first, second)}
        cases = [
            (first, "id: first", "id: second", "duplicate ID"),
            (first, "parent: map", "parent: missing", "missing parent"),
            (first, "parent: map", "parent: second", "map or spec"),
            (first, "None.", "[Missing](missing.md)", "missing blocker"),
            (first, "None.", "[Elsewhere](../../elsewhere/issues/other.md)", "out-of-effort"),
            (first, "## Blocked by", "## Blocked-by", "missing Blocked by"),
            (first, "None.", "unlinked blocker", "invalid Blocked by"),
            (first, "None.", "None.\n[Second](second.md)", "invalid Blocked by"),
            (first, "None.", "[Self](first.md)", "blocking cycle"),
            (first, "None.", "[Second](second.md#heading)", "invalid Blocked by"),
        ]
        for path, old, new, diagnostic in cases:
            with self.subTest(diagnostic=diagnostic, replacement=new):
                path.write_text(original[path].replace(old, new))
                before = self.snapshot()
                for arguments in (("validate",), ("frontier", "effort", "map")):
                    result = self.run_command(*arguments)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn("first.md", result.stderr)
                    self.assertIn(diagnostic, result.stderr)
                    self.assertEqual(result.stdout, "")
                self.assertEqual(self.snapshot(), before)
                path.write_text(original[path])

    def test_multi_issue_blocking_and_parent_cycles_are_rejected(self):
        map_path = self.map()
        first = self.issue("first", blockers="[Second](second.md)")
        second = self.issue("second", blockers="[First](first.md)")
        result = self.run_command("validate")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("blocking cycle", result.stderr)
        self.assertIn("first.md", result.stderr)
        self.assertIn("second.md", result.stderr)
        first.unlink()
        second.unlink()
        spec = self.issue("spec", labels="[wayfinder:spec]", blockers=None)
        map_path.write_text(map_path.read_text().replace("parent: null", "parent: spec"))
        result = self.run_command("validate")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("parent cycle", result.stderr)

    def test_successfully_closed_child_cannot_have_open_blockers(self):
        self.map()
        self.issue("blocker")
        self.issue("completed", status="closed", blockers="[Blocker](blocker.md)")
        result = self.run_command("validate")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("completed.md", result.stderr)
        self.assertIn("open blocker", result.stderr)
        self.assertIn("blocker.md", result.stderr)

    def test_unknown_frontier_effort_or_parent_is_an_error(self):
        self.map()
        for effort, parent in (("absent", "map"), ("effort", "absent")):
            result = self.run_command("frontier", effort, parent)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("not found", result.stderr)

    def test_reviewed_completion_closes_only_the_issue_and_removes_it_from_frontier(self):
        self.map()
        path = self.issue("work")
        result = self.run_command("frontier", "effort", "map")
        self.assertEqual(result.stdout, "Work work — effort/issues/work.md\n")
        path.write_text(path.read_text().replace("assignee: null", "assignee: codex"))
        self.resolution("work")
        before = self.snapshot()
        result = self.run_command("complete", "effort", "work",
                                  "--resolution", "2026-10-13-resolution.md")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Work work", result.stdout)
        expected = dict(before)
        expected["effort/issues/work.md"] = before["effort/issues/work.md"].replace(
            b"status: open\n", b"status: closed\n")
        self.assertEqual(self.snapshot(), expected)
        self.assertIn("assignee: codex", path.read_text())
        self.assertIn("ready-for-agent", path.read_text())
        result = self.run_command("frontier", "effort", "map")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        result = self.run_command("validate")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_completion_refuses_unchecked_or_unreviewed_work_without_mutation(self):
        self.map()
        path = self.issue("work", assignee="codex")
        resolution = self.resolution("work")
        valid_issue = path.read_text()
        valid_resolution = resolution.read_text()
        cases = [
            ("unchecked", valid_issue.replace("[x]", "[ ]"), valid_resolution, "checked criteria"),
            ("malformed checkbox", valid_issue.replace("- [x] Implement the command.",
                "- [x] Implement the command.\n- [?] Verify completion."), valid_resolution, "checked criteria"),
            ("plus unchecked", valid_issue.replace("- [x] Implement the command.",
                "- [x] Implement the command.\n+ [ ] Verify completion."), valid_resolution, "checked criteria"),
            ("inline comment literal", valid_issue.replace("- [x] Implement the command.",
                "- [x] Render `<!--` safely.\n- [ ] Still required.\n<!-- end -->"),
             valid_resolution, "checked criteria"),
            ("missing criteria", valid_issue.replace("## Acceptance criteria", "## Notes"), valid_resolution, "criteria"),
            ("unclaimed", valid_issue.replace("assignee: codex", "assignee: null"), valid_resolution, "claim"),
            ("already closed", valid_issue.replace("status: open", "status: closed"), valid_resolution, "open"),
            ("unreviewed", valid_issue, valid_resolution.replace("Reviewed by: Maintainer", ""), "Reviewed by"),
            ("no evidence", valid_issue, valid_resolution.split("- The command")[0], "Acceptance evidence"),
            ("hidden evidence", valid_issue, valid_resolution.split("- The command")[0]
             + "<!-- Record evidence after review. -->\n", "Acceptance evidence"),
            ("wrong disposition", valid_issue, valid_resolution.replace("completed", "excluded"), "Disposition"),
            ("contradictory disposition", valid_issue, "Disposition: rejected\n" + valid_resolution, "Disposition"),
            ("duplicate reviewer", valid_issue, "Reviewed by: Another reviewer\n" + valid_resolution, "Reviewed by"),
            ("example-only review", valid_issue, "# Draft\n\n```markdown\n" + valid_resolution + "```\n", "Disposition"),
            ("wontfix", valid_issue.replace("ready-for-agent]", "ready-for-agent, wontfix]"), valid_resolution, "wontfix"),
        ]
        for description, issue_text, resolution_text, diagnostic in cases:
            with self.subTest(description=description):
                path.write_text(issue_text)
                resolution.write_text(resolution_text)
                before = self.snapshot()
                result = self.run_command("complete", "effort", "work",
                                          "--resolution", resolution.name)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(diagnostic, result.stderr)
                self.assertEqual(self.snapshot(), before)

    def test_completion_requires_existing_dated_resolution_in_the_issue_comments(self):
        self.map()
        self.issue("work", assignee="codex")
        self.resolution("other")
        for filename in ("resolution.md", "2026-02-30-resolution.md",
                         "2026-10-13-resolution.md", "../other/2026-10-13-resolution.md"):
            with self.subTest(filename=filename):
                before = self.snapshot()
                result = self.run_command("complete", "effort", "work",
                                          "--resolution", filename)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("resolution", result.stderr)
                self.assertEqual(self.snapshot(), before)

    def test_completion_refuses_open_blockers_even_with_reviewed_criteria(self):
        self.map()
        self.issue("blocker")
        self.issue("work", assignee="codex", blockers="[Blocker](blocker.md)")
        self.resolution("work")
        before = self.snapshot()
        result = self.run_command("complete", "effort", "work",
                                  "--resolution", "2026-10-13-resolution.md")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("open blocker", result.stderr)
        self.assertEqual(self.snapshot(), before)

    def test_only_explicitly_resolved_wontfix_issues_may_close_with_open_blockers(self):
        self.map()
        self.issue("blocker")
        path = self.issue("excluded", status="closed", labels="[wontfix, extra]",
                          blockers="[Blocker](blocker.md)", criteria="- [ ] Unfinished.")
        for content in ("# Resolution\n\nWork completed.\n", "# Exclusion\n",
                        "# Resolution\n\nDisposition: excluded\n\n## Exclusion reason\n",
                        "# Resolution\n\nDisposition: excluded\n\n## Exclusion reason\n\n<!-- TODO -->\n"):
            with self.subTest(content=content):
                self.resolution("excluded", content=content)
                result = self.run_command("validate")
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("exclusion resolution", result.stderr)
        for content in ("# Resolution\n\nDisposition: excluded\n\n## Exclusion reason\n\nOutside this effort.\n",
                        "# Exclusion — Historical decision\n\nOutside this effort.\n"):
            with self.subTest(content=content):
                self.resolution("excluded", content=content)
                before = self.snapshot()
                result = self.run_command("validate")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.snapshot(), before)
        path.write_text(path.read_text().replace("wontfix, ", ""))
        result = self.run_command("validate")
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_read_only_operations_preserve_bytes_and_modification_times(self):
        self.map()
        self.issue("ready")
        before = {path: (path.read_bytes() if path.is_file() else None, path.stat().st_mtime_ns)
                  for path in self.root.rglob("*")}
        for arguments in (("validate",), ("frontier", "effort", "map")):
            result = self.run_command(*arguments)
            self.assertEqual(result.returncode, 0, result.stderr)
        after = {path: (path.read_bytes() if path.is_file() else None, path.stat().st_mtime_ns)
                 for path in self.root.rglob("*")}
        self.assertEqual(after, before)

    def test_completion_preserves_line_endings_and_permissions(self):
        self.map()
        path = self.issue("work", assignee="codex")
        path.write_bytes(path.read_bytes().replace(b"\n", b"\r\n"))
        path.chmod(0o640)
        original = path.read_bytes()
        self.resolution("work")
        result = self.run_command("complete", "effort", "work",
                                  "--resolution", "2026-10-13-resolution.md")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(path.read_bytes(), original.replace(b"status: open\r\n", b"status: closed\r\n"))
        self.assertEqual(path.stat().st_mode & 0o777, 0o640)

    def test_completion_preserves_quoted_status_and_surrounding_whitespace(self):
        self.map()
        path = self.issue("work", assignee="codex")
        source = path.read_bytes()
        self.resolution("work")
        for old, new in ((b"'open'", b"'closed'"), (b'"open"', b'"closed"'),
                         (b'"o\\u0070en"', b'"closed"'), (b"open", b"closed")):
            with self.subTest(status=old):
                original = source.replace(b"status: open\n", b"status:  " + old + b"  \n")
                path.write_bytes(original)
                result = self.run_command("complete", "effort", "work",
                                          "--resolution", "2026-10-13-resolution.md")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(path.read_bytes(), original.replace(
                    b"status:  " + old + b"  \n", b"status:  " + new + b"  \n"))

    def test_review_record_ignores_comment_fences_and_accepts_recorded_code_evidence(self):
        self.map()
        self.issue("work", assignee="codex")
        self.resolution("work", content=(
            "# Resolution\n\n<!--\n```\n-->\n"
            "Disposition: completed\nReviewed by: Maintainer\n\n"
            "## Acceptance evidence\n\n```text\nCommand tests: passed.\n<!-- literal output -->\n```\n"
        ))
        result = self.run_command("complete", "effort", "work",
                                  "--resolution", "2026-10-13-resolution.md")
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
