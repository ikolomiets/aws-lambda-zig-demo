"""Exercise the offline check command and hooks through temporary repositories."""

from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1]


class LocalCheckTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / "checkout with spaces"
        self.root.mkdir()
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.log = self.base / "commands.jsonl"
        self.env = os.environ.copy()
        self.env["PATH"] = str(self.bin) + os.pathsep + self.env["PATH"]
        self.env["CHECK_TEST_LOG"] = str(self.log)
        self.env["CHECK_TEST_REAL_ZIG"] = shutil.which("zig") or ""
        # Keep fixture packages and nested Git independent of caller configuration.
        for key in ("CHECK_ZIG_PACKAGE_DIR", "GIT_DIR", "GIT_WORK_TREE",
                    "GIT_INDEX_FILE", "GIT_COMMON_DIR",
                    "GIT_PREFIX", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
                    "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT"):
            self.env.pop(key, None)
        self.env["GIT_CONFIG_GLOBAL"] = os.devnull
        self.env["GIT_CONFIG_NOSYSTEM"] = "1"
        self.write(".gitignore", ".scratch/\nzig-pkg/\n")
        self.write("build.zig", (
            'pub fn build(b: *std.Build) void {\n'
            '    b.step("fmt-check", "Check formatting");\n'
            '    b.step("test", "Offline tests");\n}\n'
        ))
        self.write("build.zig.zon", '.{ .name = .fixture, .version = "0.0.0" }\n')
        self.write("src/example.zig", "const value = 1;\n")
        self.write("tests/live_harness.sh", "#!/bin/bash\nexit 98\n")
        self.write("README.md", "# Fixture\nUse `zig build test` or `./tests/live_harness.sh`.\n")
        (self.root / "zig-pkg").mkdir()
        for name in ("check.sh", "setup-hooks.sh", ".githooks/pre-commit",
                     "check_docs.py", "tracker.py"):
            source = SOURCE / name
            if source.exists():
                target = self.root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
        self.command("uname", 'print("Darwin" if "-s" in sys.argv else "arm64")')
        self.command("jq", 'print("jq-1.7")')
        self.command("zig", '''
args = sys.argv[1:]
if args == ["version"]:
    print(os.environ.get("CHECK_TEST_ZIG_VERSION", "0.16.0"))
    sys.exit(0)
with open(os.environ["CHECK_TEST_LOG"], "a") as log:
    log.write(json.dumps(args) + "\\n")
if "--system" not in args:
    sys.exit("package fetching must be disabled")
if os.environ.get("CHECK_TEST_FAIL_TARGET") in args:
    sys.exit(17)
if "fmt-check" in args:
    sys.exit(subprocess.call([os.environ["CHECK_TEST_REAL_ZIG"], "fmt", "--check",
                             "build.zig", "build.zig.zon", "src", "tests"]))
''')
        self.git("init", "-q")

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def command(self, name, body):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\nimport json, os, subprocess, sys\n" + body + "\n")
        path.chmod(0o755)

    def run_command(self, *args, cwd=None):
        return subprocess.run(args, cwd=cwd or self.root, env=self.env,
                              capture_output=True, text=True, check=False)

    def git(self, *args):
        result = self.run_command("git", *args)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def checks(self):
        return self.run_command("bash", str(self.root / "check.sh"), cwd=self.base)

    def effects(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def hook(self):
        return self.run_command("bash", str(self.root / ".githooks/pre-commit"))

    def setup_hooks(self):
        return self.run_command("bash", str(self.root / "setup-hooks.sh"), cwd=self.base)

    def test_standalone_checks_uncommitted_development_and_empty_tracker_offline(self):
        result = self.checks()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Validated 0 issues.", result.stdout)
        self.assertIn("0 errors", result.stdout)
        targets = [args[1] for args in self.effects() if args[1] in ("fmt-check", "test")]
        self.assertEqual(targets, ["fmt-check", "test"])
        self.assertTrue(all("--system" in args for args in self.effects()))

    def test_hook_rejects_working_tree_index_difference_before_checks(self):
        self.git("add", ".")
        self.write("README.md", "# An unstaged fix\n")

        result = self.hook()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("working tree differs from the index", result.stderr)
        self.assertFalse(self.log.exists(), "The guard must precede checks.")

    def test_hook_requires_relevant_untracked_inputs_to_be_staged(self):
        self.git("add", ".")
        self.write("src/unstaged.zig", "const value = 1;\n")

        result = self.hook()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("src/unstaged.zig", result.stderr)
        self.assertIn("untracked check input", result.stderr)
        self.assertFalse(self.log.exists())

    def test_setup_activates_hook_and_is_idempotent_without_creating_commits(self):
        self.git("add", ".")

        result = self.setup_hooks()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git("config", "--local", "--get", "core.hooksPath").stdout.strip(),
                         ".githooks")
        self.assertEqual(self.setup_hooks().returncode, 0)
        hooked = self.git("hook", "run", "pre-commit")
        self.assertIn("Local offline checks passed", hooked.stdout + hooked.stderr)
        self.assertNotEqual(self.run_command("git", "rev-parse", "--verify", "HEAD").returncode, 0)

    def test_setup_preserves_existing_default_hook(self):
        hook = self.write(".git/hooks/pre-commit", "#!/bin/bash\nexit 37\n")
        hook.chmod(0o755)
        before = hook.read_bytes(), hook.stat().st_mtime_ns

        result = self.setup_hooks()

        self.assertEqual(result.returncode, 2)
        self.assertIn("Existing hook entry", result.stderr)
        self.assertEqual((hook.read_bytes(), hook.stat().st_mtime_ns), before)
        self.assertEqual(self.run_command("git", "config", "--get", "core.hooksPath").returncode, 1)

    def test_setup_preserves_configured_local_and_global_hook_paths(self):
        for scope, value in (("--local", "other-hooks"), ("--global", "/existing/hooks"),
                             ("--local", "")):
            with self.subTest(scope=scope, value=value):
                self.env["GIT_CONFIG_GLOBAL"] = str(self.base / "global-config")
                self.git("config", scope, "core.hooksPath", value)

                result = self.setup_hooks()

                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("already configured", result.stderr)
                self.assertEqual(self.git("config", scope, "--get", "core.hooksPath").stdout,
                                 value + "\n")
                self.git("config", scope, "--unset", "core.hooksPath")

    def test_hook_rejects_deleted_or_partially_staged_files_before_checks(self):
        self.git("add", ".")
        for name in ("src/example.zig", "README.md"):
            with self.subTest(name=name):
                path = self.root / name
                original = path.read_bytes()
                path.unlink()
                result = self.hook()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("working tree differs from the index", result.stderr)
                path.write_bytes(original)
        self.assertFalse(self.log.exists())

    def test_hook_rejects_ignored_code_docs_and_new_check_inputs(self):
        self.write(".gitignore", ".scratch/\nzig-pkg/\nsrc/ignored.zig\n")
        self.git("add", ".")
        for name, content in (("src/ignored.zig", "const value = 1;\n"),
                              ("tests/new harness.sh", "#!/bin/bash\nexit 0\n"),
                              ("docs/new\nreference.md", "# Reference\n"),
                              ("new_check.py", "raise SystemExit(0)\n"),
                              (".githooks/new-hook", "#!/bin/bash\nexit 0\n")):
            with self.subTest(name=name):
                path = self.write(name, content)
                result = self.hook()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("untracked check input", result.stderr)
                path.unlink()
        self.assertFalse(self.log.exists())

    def test_hook_accepts_staged_inputs_and_ignored_local_tracker(self):
        self.git("add", ".")
        self.write("notes.txt", "Unrelated local notes.\n")
        self.write(".scratch/local/issues/01-map.md", (
            "---\nid: local-map\ntitle: Local map\nstatus: open\n"
            "labels: [wayfinder:map]\nparent: null\nassignee: null\nmode: AFK\n"
            "order: 1\n---\n# Local map\n"
        ))

        result = self.hook()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Validated 1 issues.", result.stdout)

    def test_index_flags_cannot_hide_different_staged_inputs(self):
        self.write("README.md", "# Fixture\n[Broken](missing.md)\n")
        self.git("add", ".")
        for flag in ("assume-unchanged", "skip-worktree"):
            with self.subTest(flag=flag):
                self.log.unlink(missing_ok=True)
                self.git("update-index", "--" + flag, "README.md")
                self.write("README.md", "# Fixture\nAn unstaged fix.\n")
                try:
                    result = self.hook()
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("index flags", result.stderr)
                    self.assertFalse(self.log.exists())
                finally:
                    self.git("update-index", "--no-" + flag, "README.md")
                    self.write("README.md", "# Fixture\n[Broken](missing.md)\n")

    def test_check_failures_propagate_through_standalone_and_hook(self):
        self.git("add", ".")
        for target in ("fmt-check", "test"):
            with self.subTest(target=target):
                self.env["CHECK_TEST_FAIL_TARGET"] = target
                self.assertEqual(self.checks().returncode, 17)
                self.assertEqual(self.hook().returncode, 17)

    def test_setup_errors_do_not_silently_skip_checks(self):
        self.env["CHECK_TEST_ZIG_VERSION"] = "0.15.2"
        result = self.checks()
        self.assertEqual(result.returncode, 2)
        self.assertIn("Zig 0.16.0", result.stderr)
        self.env.pop("CHECK_TEST_ZIG_VERSION")
        (self.root / "zig-pkg").rmdir()
        result = self.checks()
        self.assertEqual(result.returncode, 2)
        self.assertIn("Provision pinned packages", result.stderr)
        self.assertFalse(self.log.exists())
        (self.root / "zig-pkg").mkdir()
        self.env["CHECK_TEST_FAIL_TARGET"] = "--help"
        result = self.checks()
        self.assertEqual(result.returncode, 2)
        self.assertIn("provisioned pinned packages", result.stderr)

    def test_deliberate_defects_prevent_standalone_and_hook_success(self):
        cases = (
            ("src/example.zig", "const value=1;\n", "src/example.zig"),
            ("broken.sh", "#!/bin/bash\nif then\n", "broken.sh"),
            ("tests/nested/broken.sh", "#!/bin/bash\nif then\n", "broken.sh"),
            ("README.md", "# Fixture\n[Missing](absent.md)\n", "absent.md"),
            ("README.md", "# Fixture\n[Missing](#absent)\n", "missing anchor"),
            ("README.md", "# Fixture\nUse `zig build nonexistent-target`.\n",
             "unknown Zig build target"),
            (".scratch/local/issues/01-bad.md", "# Missing metadata\n", "01-bad.md"),
        )
        for name, content, diagnostic in cases:
            with self.subTest(name=name, diagnostic=diagnostic):
                path = self.root / name
                original = path.read_bytes() if path.exists() else None
                self.write(name, content)
                self.git("add", "-A")
                self.log.unlink(missing_ok=True)

                for result in (self.checks(), self.hook()):
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(diagnostic, result.stdout + result.stderr)
                self.assertFalse(any("test" in args for args in self.effects()),
                                 "Failing fast must not run the aggregate suite.")
                if original is None:
                    path.unlink()
                else:
                    path.write_bytes(original)

    def test_unsupported_hosts_and_missing_tools_are_setup_errors(self):
        self.command("uname", 'print("Darwin" if "-s" in sys.argv else "x86_64")')
        result = self.checks()
        self.assertEqual(result.returncode, 2)
        self.assertIn("ARM64", result.stderr)
        self.command("uname", 'print("Darwin" if "-s" in sys.argv else "arm64")')
        self.env["PATH"] = str(self.bin)
        for name in ("bash", "dirname", "python3"):
            (self.bin / name).symlink_to(shutil.which(name))
        (self.bin / "jq").unlink()
        result = self.checks()
        self.assertEqual(result.returncode, 2)
        self.assertIn("Install jq", result.stderr)
        self.assertFalse(self.log.exists())

    def test_arm64_linux_requires_glibc(self):
        self.command("uname", 'print("Linux" if "-s" in sys.argv else "aarch64")')
        self.command("getconf", 'print("glibc 2.31")')
        result = self.checks()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.command("getconf", 'print("glibc 2.26")')
        result = self.checks()
        self.assertEqual(result.returncode, 2)
        self.assertIn("2.27", result.stderr)
        self.command("getconf", 'print("musl")')
        result = self.checks()
        self.assertEqual(result.returncode, 2)
        self.assertIn("must use glibc", result.stderr)

    def test_unavailable_nested_bash_reports_executable_and_runner_version(self):
        real_bash = shutil.which("bash")
        version = subprocess.check_output(
            [real_bash, "-c", 'printf "%s" "$BASH_VERSION"'], text=True)
        self.command("bash", f'''
if sys.argv[1:] == ["--version"]:
    sys.exit(19)
os.execv({real_bash!r}, [{real_bash!r}] + sys.argv[1:])
''')

        result = self.checks()

        self.assertEqual(result.returncode, 2)
        self.assertIn(f"Bash at {self.bin / 'bash'} is unavailable", result.stderr)
        self.assertIn(f"runner Bash {version}", result.stderr)
        self.assertFalse(self.log.exists())

    def test_missing_shell_utilities_fail_as_setup_errors_before_checks(self):
        self.env["PATH"] = str(self.bin)
        for name in ("bash", "dirname", "python3"):
            (self.bin / name).symlink_to(shutil.which(name))

        result = self.checks()

        self.assertEqual(result.returncode, 2)
        self.assertIn("Install find", result.stderr)
        self.assertFalse(self.log.exists())
        (self.bin / "find").symlink_to(shutil.which("find"))
        (self.bin / "dirname").unlink()
        result = self.checks()
        self.assertEqual(result.returncode, 2)
        self.assertIn("Install dirname", result.stderr)
        self.assertFalse(self.log.exists())

    def test_package_directory_override_remains_offline(self):
        packages = self.base / "provisioned packages"
        packages.mkdir()
        (self.root / "zig-pkg").rmdir()
        self.env["CHECK_ZIG_PACKAGE_DIR"] = str(packages)

        result = self.checks()

        self.assertEqual(result.returncode, 0, result.stderr)
        for args in self.effects():
            self.assertIn("--system", args)
            self.assertEqual(args[args.index("--system") + 1], str(packages))

    def test_inherited_package_override_preserves_missing_fixture_package_failure(self):
        packages = self.base / "inherited packages with spaces"
        packages.mkdir()
        env = os.environ.copy()
        env["CHECK_ZIG_PACKAGE_DIR"] = str(packages)

        result = subprocess.run(
            [sys.executable, str(SOURCE / "tests/local_check_test.py"),
             "LocalCheckTest.test_setup_errors_do_not_silently_skip_checks"],
            cwd=SOURCE, env=env, capture_output=True, text=True, check=False)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
