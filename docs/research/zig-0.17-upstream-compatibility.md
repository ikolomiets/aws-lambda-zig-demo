# Upstream dependency compatibility with Zig 0.17.0

Checked 2026-11-02 against the baseline revisions in the inventory below,
using the Zig 0.17.0 release compiler
and its bundled standard library on Apple Silicon macOS. The installed default
compiler remains Zig 0.16.0. `.tigerbeetle_c_artifacts` is excluded.

The current pins are maintained in [`build.zig.zon`](../../build.zig.zon).
The PASETO assessment here covers the earlier `ikolomiets/zig-paseto` 1.1.6
revision; it does not assess the current `deatil/zig-paseto` 1.2.3 pin or its
transitive `zig-rsa` dependency on Zig 0.17.0.

**The baseline dependency pins are not compatible with Zig 0.17.0 unchanged.**
The direct dependencies all have reproducible compilation or build-configuration
failures. The SDK's transitive test runner also needs an update.

The [official release notes][release-notes] supply the migration checklist:
array repetition is removed, reflection metadata changes, build configuration
APIs change, optimization tags become lowercase, and testing uses a new
allocator. The findings below come from inspecting the pinned source and running
the compiler; they are not inferred solely from minimum-version declarations.

## Dependency inventory

| Dependency | Assessed baseline revision | Zig 0.17.0 assessment |
| --- | --- | --- |
| `aws_sdk` | [`778dcfe1423c`][sdk-pin], fork branch `agent/parse-modeled-aws-json-errors` | Incompatible: build APIs, repetition syntax, JSON reflection, and CRC names. |
| `aws_lambda` | [`e3b15bf9b820`][lambda-pin], fork branch `agent/fix-sqs-review-findings` | Incompatible build configuration; 28 source-level tests pass separately. |
| `zig_paseto` | [`35b4ae94c88b`][paseto-pin], fork branch `main`, package 1.1.6 | Incompatible: repetition syntax, integer type construction, and a debug-mode comparison. |
| `zest` (SDK test dependency) | [`2ec1ae484888`][zest-pin], package 0.1.0 | Unit tests pass, but the custom runner does not compile. A newer upstream commit supports 0.17. |

All four pinned package manifests declare minimum Zig 0.16.0. This is a lower
bound, not a promise of compatibility with later breaking releases. The Lambda
and PASETO manifests have no further dependencies; the SDK declares `zest`, whose
manifest declares no dependencies.

The named SDK and Lambda branch heads and PASETO `main` still resolve to their
respective pinned commits at the time of this check. Advancing those same refs
does not supply a migration. This statement concerns the repositories and refs
actually named by the project, not every branch or ancestor repository.

## AWS SDK

The SDK is the largest migration item and affects both Lambda functions and host
CLI tools. The project imports its runtime plus DynamoDB and SQS modules.

| Location in pinned SDK | Observed blocker | Required adaptation |
| --- | --- | --- |
| [`build.zig:20`][sdk-build] and other directory reads | `Build` has no `build_root` field. | Use the new `b.root` path operations, preserving package-relative paths. |
| [`build.zig:53`][sdk-build] | After adapting directory reads in a temporary copy, configuration fails because `Build` has no `args` field. | Use `run_docgen.addPassthruArgs()`. |
| [`src/signing.zig:787`][sdk-signing], 793, 799 | The parser rejects string repetition with `**`, even though these expressions are in test bodies. | Construct repeated byte arrays with `@splat` and pass pointers/slices where required. |
| [`src/json.zig:86`][sdk-json] and other reflection loops | `std.meta.fields` produces a compile error. | Rewrite loops using the appropriate `@typeInfo` field names, types, and attributes; preserve defaults and JSON field mapping. |
| [`src/checksum.zig:18`][sdk-checksum], 22 | `Crc32IsoHdlc` and `Crc32Iscsi` are absent. | Use `std.hash.crc.@"CRC-32/ISO-HDLC"` and `std.hash.crc.@"CRC-32/ISCSI"`. |

Reflection changes extend into generated services: 43 DynamoDB files and three
SQS files call `std.meta.fields`, including
[`service/sqs/queue_attribute_name.zig`][sdk-sqs-enum]. Across all packaged service
modules, 10,417 files contain that call. These counts identify source requiring
inspection, not 10,417 independently reproduced failures. Update the upstream
generator/templates and regenerate affected services rather than treating this
as a runtime-only JSON edit.

The original `zig build test` fails during configuration. Running the runtime
tests directly first exposes the repetition syntax error; replacing only those
three repetitions in a temporary copy exposes the JSON reflection and CRC
errors. The SDK suite does not pass, and later errors can remain hidden behind
these blockers. No service integration tests or AWS calls are run.

## AWS Lambda runtime

The pinned [target helper][lambda-target] sets Linux, architecture, and glibc
2.34 but leaves the ABI unspecified. With the Zig 0.17.0 release compiler,
`zig build test` aborts in `Target.Query.zigTriple` while creating the demo
compile steps, because the query ABI is null. Explicitly setting `.abi = .gnu`
in both Lambda target queries avoids the observed panic and expresses the
existing glibc requirement.

After that temporary adaptation, a second configuration failure appears:
[`build.zig`][lambda-build] registers the exported module `"lambda"` twice,
once for demos and once for unit tests. Zig 0.17 rejects the duplicate name.
Keeping one exported module and creating the test-only module with
`b.createModule` avoids that failure.

Evidence distinguishes the build script from the runtime source:

- Bypassing the original build script, all 28 runtime source tests pass with
  unmodified sources, including Function URL and SQS parsing tests.
- With only the two build adaptations above in a temporary copy,
  `zig build test demo:sqs -Darch=arm` passes all 28 tests and compiles the SQS
  demo for `aarch64-linux-gnu.2.34`.

This establishes a small, demonstrated build migration for the tested paths.
It does not validate deployed Lambda behavior, DNS scheduling, or every demo.

## PASETO

The original package test build fails parsing
[`src/rsa/rsa.zig:779`][paseto-rsa] (also 921) and
[`src/rsa/der.zig:261`][paseto-der] because of `**`. A separate executable probe
that uses only `v4_public` through the package root hits the same parsing
failures, so these are not limited to running the upstream RSA tests.

Replacing those three repetitions with appropriately typed `@splat` arrays in
a temporary copy exposes another compiler error at
[`src/rsa/der.zig:115`][paseto-der]: `std.meta.Int` is absent. Its replacement
here is `@Int(.unsigned, info.int.bits)`.

After those syntax and integer-type adaptations, all 95 upstream tests pass.
However, a focused probe that instantiates `Parser.expectEnum` exposes an
additional error at [`src/rsa/der.zig:97`][paseto-der]:
`builtin.mode == .Debug` must use `.debug`. The existing suite does not
instantiate that path. Passing the 95 tests alone therefore does not establish
compatibility of every exposed parser method.

## Zest test runner

The SDK pins [`2ec1ae484888`][zest-pin]. Its four unit tests pass on Zig 0.17,
but `zig build demo` fails compiling the custom runner at
[`src/root.zig:135`][zest-root] and 275. The runner initializes
`testing.allocator_instance` with `.{};` this is invalid for the new
`SafeAllocator`. The old comparison of allocator `deinit()` with `.leak` also
needs adaptation to the new leak-count result. This dependency affects SDK
testing rather than the application's runtime module imports.

Upstream commit [`420846a238e8`][zest-update], dated 2026-10-04, explicitly ports
the runner to Zig 0.17. It updates allocator initialization and leak reporting,
uses `std.lang.TestFn` and `@backingInt`, raises the minimum Zig version, and
adds runner integration tests. An isolated copy of that exact commit passes
`zig build test`: 14 build steps succeed, including the four unit tests and
checks of hooks, skips, expected failures, and test/hook leaks.

The SDK must update its transitive `zest` URL/hash; changing this project's
direct dependency declarations alone does not update that pin.

## Validation and boundaries

The audit uses isolated dependency copies under `/private/tmp`, without changing
the project pins, cached dependency sources, sibling checkouts, or existing
hostname-workaround work. Temporary edits only uncover subsequent blockers;
they are not patches applied to the project.

These are the meaningful checks against the original pinned sources:

| Check, run from the indicated package | Result on Zig 0.17.0 |
| --- | --- |
| SDK: `zig build test` | Fails: `b.build_root`. |
| SDK: `zig test src/root.zig` | Fails: string repetition syntax. |
| Lambda: `zig build test` | Configurer aborts: null ABI in demo target query. |
| Lambda: `zig test --dep build-meta -Mroot=src/root.zig -Mbuild-meta=build.zig.zon` | 28/28 pass. |
| PASETO: `zig build test` | Fails: array repetition syntax. |
| PASETO: executable importing root and using `v4_public` | Fails: same RSA/DER syntax. |
| Zest: `zig build test` | 4/4 pass. |
| Zest: `zig build demo` | Compilation fails in allocator initialization, before its deliberate demo test failure. |

Run these with an actual Zig 0.17.0 binary and its bundled library. The table's
`zig` means that binary, not the repository's default Zig 0.16.0. The additional
temporary-copy probes and the tested newer Zest commit are described above;
their successes do not change the original-pin results.

Dependency upgrades alone do not complete this project's migration. A source
inspection of [`build.zig`](../../build.zig) also finds formatting paths passed
as strings, a `.ReleaseSafe` comparison, old Run file-argument methods, C
translation via `addTranslateC`, and a processor-specific Zig 0.16 library
override. Project test bodies also contain `**`; a direct compile of
`src/paseto_cli.zig` stops at one such expression. These local migration items
are separate from the dependency findings; the excluded TigerBeetle artifacts
and their ABI are not assessed. No full project 0.17 build or deployable package
is produced.

The release-note checks also look for direct `Uri.getHost`/`getHostAlloc` calls,
`containsAtLeastScalar`, `errdefer` captures, and `@cImport` in the four pinned
dependencies; no uses are found. PASETO's two `@bitCast` calls operate on integer
and packed-identifier representations, rather than the array/vector cases
changed in 0.17. These source checks do not replace runtime validation.

## Suggested migration order

1. Port the SDK build script, JSON reflection, generated services, signing test
   literals, and CRC names. Update its Zest pin to the tested 0.17 commit.
2. Apply the two demonstrated Lambda build adaptations.
3. Port PASETO's repetition expressions, integer type helper, and debug-mode
   comparison, including a probe of the enum-decoding path.
4. Pin the reviewed upstream revisions, migrate the project's own build and
   source APIs, then validate the host tools and ARM64 Lambda targets with a
   matching standard library. Evaluate the hostname workaround separately.

[release-notes]: https://ziglang.org/download/0.17.0/release-notes.html
[sdk-pin]: https://github.com/ikolomiets/aws-sdk-zig/commit/778dcfe1423cf3b3a1bfe56e1e461b99b80124bd
[sdk-build]: https://github.com/ikolomiets/aws-sdk-zig/blob/778dcfe1423cf3b3a1bfe56e1e461b99b80124bd/build.zig#L20
[sdk-signing]: https://github.com/ikolomiets/aws-sdk-zig/blob/778dcfe1423cf3b3a1bfe56e1e461b99b80124bd/src/signing.zig#L787
[sdk-json]: https://github.com/ikolomiets/aws-sdk-zig/blob/778dcfe1423cf3b3a1bfe56e1e461b99b80124bd/src/json.zig#L86
[sdk-checksum]: https://github.com/ikolomiets/aws-sdk-zig/blob/778dcfe1423cf3b3a1bfe56e1e461b99b80124bd/src/checksum.zig#L18
[sdk-sqs-enum]: https://github.com/ikolomiets/aws-sdk-zig/blob/778dcfe1423cf3b3a1bfe56e1e461b99b80124bd/service/sqs/queue_attribute_name.zig#L80
[lambda-pin]: https://github.com/ikolomiets/aws-lambda-zig/commit/e3b15bf9b820ba0ad16be50e7d988bb114800c72
[lambda-target]: https://github.com/ikolomiets/aws-lambda-zig/blob/e3b15bf9b820ba0ad16be50e7d988bb114800c72/build/target.zig#L37
[lambda-build]: https://github.com/ikolomiets/aws-lambda-zig/blob/e3b15bf9b820ba0ad16be50e7d988bb114800c72/build.zig#L19
[paseto-pin]: https://github.com/ikolomiets/zig-paseto/commit/35b4ae94c88bbdad3c0f634e48e0a4f1c5bc4f28
[paseto-rsa]: https://github.com/ikolomiets/zig-paseto/blob/35b4ae94c88bbdad3c0f634e48e0a4f1c5bc4f28/src/rsa/rsa.zig#L779
[paseto-der]: https://github.com/ikolomiets/zig-paseto/blob/35b4ae94c88bbdad3c0f634e48e0a4f1c5bc4f28/src/rsa/der.zig#L97
[zest-pin]: https://github.com/cloudboss/zest/commit/2ec1ae4848887223e585e105a92ca57d7612d332
[zest-root]: https://github.com/cloudboss/zest/blob/2ec1ae4848887223e585e105a92ca57d7612d332/src/root.zig#L135
[zest-update]: https://github.com/cloudboss/zest/commit/420846a238e832b42c05bd857773c5a96d8cd586
