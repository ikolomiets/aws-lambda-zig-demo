# Local checks and pre-commit setup

From the repository root, run the standalone offline gate:

```sh
./check.sh
```

[check.sh](../../check.sh) uses the current working tree, including uncommitted
development files. It runs the existing complete `zig build fmt-check`, Bash syntax
checks for every root shell entry point, tracked hook and recursively discovered
shell harness under `tests/`, [documentation checking](documentation-checks.md),
structural [tracker validation](issue-tracker.md), and the existing `zig build test`.
It stops at the first required failure. The existing aggregate target owns the
offline test graph; this command does not maintain a second list of tests.

Tracker validation discovers actual ignored `.scratch/*/issues/*.md` efforts.
A fresh clone without local issues reports `Validated 0 issues.` No registry or
access to another developer's ignored tickets is required.

## Host and package prerequisites

Use an ARM64 macOS or ARM64 glibc Linux host, Zig **0.16.0**, Bash, `jq`, Python
**3.9 or newer**, and the ordinary host tools `dirname`, `find` and `uname`.
Linux also requires `getconf` to identify glibc. The native TigerBeetle archive in
the pinned packages targets glibc 2.27 or newer. Hook setup and invocation require
Git; `git hook run` for activation verification requires Git 2.36 or newer.

Provision every pinned dependency from [build.zig.zon](../../build.zig.zon),
including transitive packages, before checking. Provisioning is a separate step
that requires network access:

```sh
zig build --fetch
```

The gate passes `--system zig-pkg` to Zig to disable package fetching. A missing
tool, wrong Zig/Python version, unsupported host, missing package directory or
build graph that cannot configure with provisioned packages fails as a setup
error (exit 2). Required check failures also return a nonzero exit status.
It never silently skips a check. To use another already provisioned package
directory, set `CHECK_ZIG_PACKAGE_DIR`; relative paths resolve from the checkout:

```sh
CHECK_ZIG_PACKAGE_DIR=/path/to/provisioned-packages ./check.sh
```

Build-cache environment settings such as `ZIG_LOCAL_CACHE_DIR` and
`ZIG_GLOBAL_CACHE_DIR` still apply. Provisioning does not upgrade dependency pins.
The patched sibling Zig standard library is a separate Lambda-build prerequisite;
this gate does not build deployable Lambdas or refresh zip packages.

## Hook activation and staged inputs

The selected tracked hook is [.githooks/pre-commit](../../.githooks/pre-commit).
Configure this checkout and inspect the effective path:

```sh
./setup-hooks.sh
git config --show-origin --get core.hooksPath
```

[setup-hooks.sh](../../setup-hooks.sh) sets repository-local
`core.hooksPath=.githooks`. It requires the hook and check command to be executable.
Repeated setup with that same effective path is safe. A different or empty
configured path (including inherited configuration), or any non-sample entry in
the default hooks directory, stops setup without changing that arrangement.
There is no force option. Review and integrate an existing workflow manually;
this setup does not chain or overwrite other hooks.

Before invoking the shared command, the hook rejects any tracked working-tree/index
difference, including unstaged deletions and partially staged edits. It
rejects `assume-unchanged` and `skip-worktree` index flags, which can hide those
differences from Git. Clear such flags on affected paths before committing;
the hook does not modify the index.

The hook also rejects untracked inputs under `src/`, `tests/`, `docs/` and `.githooks/`, plus root
Zig, manifest, shell, Python, Markdown, JSON and YAML files. This includes ignored
files in those input locations because checks read them. Stage intended inputs or
move incidental files out of those locations before committing. Generated caches
and packages and unrelated local notes are outside that guard. Ignored tracker
efforts are validated as local state and do not have to be staged.

The hook checks the working tree only after these guards pass. It creates no staged
snapshot and does not stage files. On a checkout whose tracked files match the index
and whose relevant new files are staged, verify activation without creating a commit:

```sh
git hook run pre-commit
```

A successful invocation runs the gate and prints `Local offline checks passed.`
An invocation during unstaged development rejects the inputs before running checks;
use `./check.sh` for development validation.

## Validation scope

Temporary-repository regression tests control external command effects and exercise
the command, configured hook, staged-input guards, prerequisites and existing-hook
setup. They create no commits and include deliberate formatting, shell syntax,
link/anchor, command-target and tracker failures:

```sh
python3 tests/local_check_test.py
zig build test-local-checks --system zig-pkg
```

These tests are also in the existing full offline suite. The gate executes no live
replica tests, AWS/cloud commands, deployment or packaging steps, or documentation
examples. Syntax-checking a live shell harness does not execute it. The deployment
tests use mocked AWS commands. Separate ABI and live integration targets retain
their existing explicit validation paths.

Passing checks establishes formatting, tested behavior, names, destinations and
structural tracker validity. Review command options, integration prerequisites and
Processor Message schemas manually against the [documentation review scope](documentation-checks.md#manual-review).
