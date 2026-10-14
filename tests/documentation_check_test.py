"""Exercise documentation checking through its CLI and temporary repositories."""

from pathlib import Path
import hashlib
import json
import subprocess
import sys
import tempfile
import unittest


COMMAND = Path(__file__).resolve().parents[1] / "check_docs.py"


class DocumentationCheckTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def run_command(self, *paths):
        return subprocess.run(
            [sys.executable, str(COMMAND), "--root", str(self.root), *paths],
            capture_output=True, text=True, check=False,
        )

    def test_local_links_and_heading_anchors_pass_without_changing_files(self):
        self.write("README.md", "[Guide](docs/guide.md#seat-events)\n[Again](#local)\n# Local\n")
        self.write("docs/guide.md", "# Seat Events\n[Source](../src/example.zig)\n")
        self.write("src/example.zig", "// Example.\n")
        before = {path: (path.read_bytes(), path.stat().st_mtime_ns)
                  for path in self.root.rglob("*") if path.is_file()}

        result = self.run_command()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Checked 2 Markdown files", result.stdout)
        after = {path: (path.read_bytes(), path.stat().st_mtime_ns)
                 for path in self.root.rglob("*") if path.is_file()}
        self.assertEqual(after, before)

    def test_broken_inline_reference_image_and_anchor_links_report_source_and_destination(self):
        self.write("README.md", (
            "[Missing](docs/missing.md)\n[Section](docs/guide.md#absent)\n"
            "![Image](missing.png)\n[Reference][bad]\n\n[bad]: absent.md\n"
        ))
        self.write("docs/guide.md", "# Present\n")

        result = self.run_command()

        self.assertEqual(result.returncode, 1, result.stderr)
        for source, destination in (("README.md:1", "docs/missing.md"),
                                    ("README.md:2", "docs/guide.md#absent"),
                                    ("README.md:3", "missing.png"),
                                    ("README.md:4", "absent.md")):
            self.assertIn(source, result.stderr)
            self.assertIn(destination, result.stderr)
        self.assertIn("missing anchor", result.stderr)

    def test_current_commands_follow_build_declarations_and_existing_scripts(self):
        build = self.write("build.zig", (
            'pub fn build(b: *std.Build) void {\n'
            '    b.step("test-new", "New test");\n'
            '    b.addExecutable(.{ .name = "new-tool", .root_module = module });\n}\n'
        ))
        self.write("run.sh", "#!/bin/sh\nexit 99\n")
        self.write("tests/check.py", "raise RuntimeError('must never run')\n")
        self.write("README.md", (
            "Use `zig build test-new` and `./run.sh`.\n```sh\n"
            "MODE=test ./run.sh\npython3 tests/check.py\n"
            "zig build --cache-dir cache --system packages --release -Darch=arm \\\n  test-new\n"
            "./zig-out/bin/new-tool --help\n```\n"
        ))

        result = self.run_command()
        self.assertEqual(result.returncode, 0, result.stderr)

        build.write_text(build.read_text().replace("test-new", "test-replaced")
                              .replace("new-tool", "replacement"))
        (self.root / "run.sh").unlink()
        (self.root / "tests/check.py").unlink()
        result = self.run_command()
        self.assertEqual(result.returncode, 1, result.stderr)
        for name in ("test-new", "run.sh", "tests/check.py", "zig-out/bin/new-tool"):
            self.assertIn(name, result.stderr)
        self.assertIn("README.md:", result.stderr)
        self.assertIn("unknown Zig build target", result.stderr)
        self.assertIn("missing repository entry point", result.stderr)

    def test_labelled_planning_and_historical_commands_still_check_ordinary_links(self):
        self.write("README.md", (
            "Planned commands:\n```sh planning\nzig build future\n./future.sh\n```\n"
            "<!-- doc-check: commands=historical -->\n"
            "Historical commands in a separate checkout: `./old.sh`.\n"
            "[Ordinary link](missing.md)\n"
            "<!-- doc-check: commands=current -->\n`./current-missing.sh`\n"
            "Literal syntax: `[a-z][0-9]`, `[example](fake.md)`.\n"
        ))

        result = self.run_command()

        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("missing.md", result.stderr)
        self.assertIn("current-missing.sh", result.stderr)
        for ignored in ("future", "old.sh", "fake.md", "undefined reference"):
            self.assertNotIn(ignored, result.stderr)

    def test_archived_machine_local_evidence_is_explicit_and_limited_to_preserved_bytes(self):
        archive = self.write("docs/audit.md", (
            "Historical evidence: [Session](/unavailable/session.jsonl:9).\n"
            "[Ordinary link](guide.md)\nHistorical command: `./obsolete.sh`.\n"
        ))
        self.write("docs/guide.md", "# Guide\n")
        self.write("docs/agents/documentation-archives.json", json.dumps({
            "docs/audit.md": {"sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
                              "reason": "Preserved audit with machine-local historical evidence."},
        }))
        result = self.run_command()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("docs/audit.md", result.stdout)
        self.assertIn("archival machine-local evidence", result.stdout)

        self.write("README.md", "[Not archived](/unavailable/session.jsonl:9)\n")
        (self.root / "docs/guide.md").unlink()
        result = self.run_command()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("README.md:1", result.stderr)
        self.assertIn("docs/audit.md:2", result.stderr)
        self.assertIn("guide.md", result.stderr)

        archive.write_text(archive.read_text() + "[New absolute link](/new/evidence)\n")
        result = self.run_command()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("archive checksum mismatch", result.stderr)

    def test_absent_optional_archive_does_not_break_checkout_but_links_to_it_fail(self):
        archive = self.write("docs/audit.md", "Historical local research.\n")
        self.write("docs/agents/documentation-archives.json", json.dumps({
            "docs/audit.md": {"sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
                              "reason": "Optional preserved local research."},
        }))
        archive.unlink()
        self.write("README.md", "# Portable checkout\n")

        result = self.run_command()
        self.assertEqual(result.returncode, 0, result.stderr)

        self.write("README.md", "[Missing archive](docs/audit.md)\n")
        result = self.run_command()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("README.md:1", result.stderr)
        self.assertIn("docs/audit.md", result.stderr)

    def test_markdown_variants_and_source_line_anchors_follow_rendered_destinations(self):
        self.write("README.md", (
            '[Guide](<docs/guide (one).md#heading-with-code>)\n'
            '[Again](docs/guide%20%28one%29.md#heading-with-code-1)\n'
            '[Setext][section]\n[Short]\n[Collapsed][]\n'
            '[HTML](docs/guide%20%28one%29.md#custom-id)\n'
            '[Lines](src/example.zig#L1-L2)\n'
            '[section]: <docs/guide (one).md#setext-heading> "Title"\n'
            '[Short]: src/example.zig\n[Collapsed]: src/example.zig\n'
            '<!-- [Comment](missing.md) -->\n'
            '```markdown\n[Example](missing.md)\n# Fake Heading\n```\n'
        ))
        guide = self.write("docs/guide (one).md", (
            "# Heading with `code`\n# Heading with `code`\n"
            "Setext **Heading**\n---\n<a id=\"custom-id\"></a>\n"
        ))
        source = self.write("src/example.zig", "// First.\n// Second.\n")
        result = self.run_command()
        self.assertEqual(result.returncode, 0, result.stderr)

        guide.write_text("# Different\n")
        source.write_text("// First.\n")
        result = self.run_command()
        self.assertEqual(result.returncode, 1, result.stderr)
        for destination in ("#heading-with-code", "#setext-heading", "#custom-id", "#L1-L2"):
            self.assertIn(destination, result.stderr)

    def test_missing_setup_and_explicit_missing_documents_fail_usefully(self):
        result = self.run_command("docs/missing.md")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("docs/missing.md", result.stderr)

        result = subprocess.run(
            [sys.executable, str(COMMAND), "--root", str(self.root / "missing")],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("repository root", result.stderr)

    def test_multiline_destinations_and_nested_labels_cannot_hide_broken_links(self):
        document = self.write("README.md", (
            "[Missing](\n  docs/absent.md\n)\n"
            "[A [nested [label]] label](docs/absent.md#missing)\n"
            '[Named](\n <docs/absent.md>\n "Title"\n)\n'
            "[Reference [label]][target]\n[target]:\n  docs/absent.md\n"
        ))
        result = self.run_command()
        self.assertEqual(result.returncode, 1, result.stderr)
        for number in (1, 4, 5, 9):
            self.assertIn(f"README.md:{number}", result.stderr)
        self.assertIn("docs/absent.md#missing", result.stderr)

        self.write("docs/present.md", "# Present\n")
        document.write_text(document.read_text().replace("absent", "present")
                           .replace("#missing", "#present"))
        result = self.run_command()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_literal_parentheses_in_titles_and_angle_destinations_do_not_hide_targets(self):
        self.write("README.md", (
            '[Missing](absent.md "A (title")\n'
            '[Missing](<absent(one.md>)\n'
            "[Missing](absent.md 'A ) title')\n"
            '[Missing](absent.md "A \\\"quoted\\\" ) title")\n'
        ))
        result = self.run_command()
        self.assertEqual(result.returncode, 1, result.stderr)
        for number in (1, 2, 3, 4):
            self.assertIn(f"README.md:{number}", result.stderr)
        self.assertIn("absent(one.md", result.stderr)

        self.write("absent.md", "# Exists\n")
        self.write("absent(one.md", "# Exists\n")
        result = self.run_command()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_literal_comment_openers_do_not_hide_following_links_or_commands(self):
        examples = (
            ("inline", "Literal `<!--` and `[Example](example-only.md)`.\n", 3),
            ("fenced", "```sh\nprintf '<!-- [Example](example-only.md)'\n```\n", 5),
        )
        for name, example, link_line in examples:
            with self.subTest(name=name):
                self.write("README.md", example + (
                    "\n[Broken](missing.md)\nUse `zig build missing-target`.\n\n"
                    "<!-- [Hidden](comment-only.md) `zig build comment-only` -->\n"
                ))
                result = self.run_command()
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(f"README.md:{link_line}:", result.stderr)
                self.assertIn("missing repository target: missing.md", result.stderr)
                self.assertIn(f"README.md:{link_line + 1}:", result.stderr)
                self.assertIn("unknown Zig build target: missing-target", result.stderr)
                self.assertNotIn("example-only", result.stderr)
                self.assertNotIn("comment-only", result.stderr)

    def test_fence_markers_with_trailing_text_do_not_hide_following_links_or_commands(self):
        examples = (
            ("```", "```literal marker inside example", "```  \t"),
            ("~~~", "~~~literal marker inside example", "~~~~"),
            ("```", "````literal marker inside example", "````"),
        )
        for opening, literal, closing in examples:
            with self.subTest(literal=literal):
                self.write("README.md", (
                    f"{opening}markdown\n{literal}\n"
                    "[Example](example-only.md)\nUse `zig build example-only`.\n"
                    f"{closing}\n[Broken](missing.md)\nUse `zig build missing-target`.\n"
                ))
                result = self.run_command()
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("README.md:6: missing repository target: missing.md", result.stderr)
                self.assertIn("README.md:7: unknown Zig build target: missing-target", result.stderr)
                self.assertNotIn("example-only", result.stderr)

    def test_current_commands_do_not_accept_names_from_comments_or_literal_examples(self):
        self.write("build.zig", (
            'pub fn build(b: *std.Build) void {\n'
            '    // b.step("old", "Removed");\n'
            '    /* b.addExecutable(.{ .name = "removed" }); */\n'
            '    b.step("current", "Current // target");\n}\n'
        ))
        self.write("run.sh", "#!/bin/sh\nexit 99\n")
        self.write("README.md", (
            "<!-- `./comment.sh` -->\n<!--\n`./another-comment.sh`\n-->\n"
            "```json\n{\"command\": \"./literal.sh\"}\n```\n"
            "```sh\nzig build current && ./run.sh\n"
            "zig build old | ./zig-out/bin/removed\n"
            "bash missing.sh\npython3 missing.py\n```\n"
        ))
        result = self.run_command()
        self.assertEqual(result.returncode, 1, result.stderr)
        for name in ("old", "removed", "missing.sh", "missing.py"):
            self.assertIn(name, result.stderr)
        for name in ("comment.sh", "literal.sh", "current", "run.sh"):
            self.assertNotIn(name, result.stderr)


if __name__ == "__main__":
    unittest.main()
