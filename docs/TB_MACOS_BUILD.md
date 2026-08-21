# Building TigerBeetle on macOS 26.6 with Zig 0.14.1

This runbook records the workaround used to build TigerBeetle from source on an
Apple Silicon Mac running macOS 26.6.1. The checkout was at commit
`97c7a8ef385270ebe0e1b75959d3d21d134629df`.

The normal source-build command is:

```sh
./zig/download.ps1
./zig/zig build -Drelease
```

Two local toolchain problems prevented that command from working as-is:

1. The existing repo-local compiler was Zig 0.13.0, while this TigerBeetle
   checkout requires Zig 0.14.1.
2. After installing Zig 0.14.1, Zig selected Xcode's macOS 26.5 SDK. That SDK's
   `libSystem.tbd` did not expose the plain `arm64-macos` target needed by this
   version of Zig. Linking the Zig build runner therefore failed with unresolved
   symbols such as `_abort`, `_clock_gettime`, and
   `__availability_version_check`.

The successful workaround was to install the repository-pinned Zig 0.14.1 and
temporarily intercept Zig's `xcrun` SDK lookup so that it selected an already
installed macOS 15.4 SDK. No system SDK, global developer setting, or
TigerBeetle source file was modified.

## Environment used

```text
Architecture:       arm64
macOS:              26.6.1 (build 25G76)
TigerBeetle commit: 97c7a8ef385270ebe0e1b75959d3d21d134629df
Required Zig:       0.14.1
Default SDK:        MacOSX26.5.sdk
Fallback SDK:       /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
```

This procedure assumes that the macOS 15.4 SDK exists at the fallback path
shown above. If it is installed elsewhere, substitute its absolute path in the
commands below.

## 1. Inspect the toolchain

Run these commands from the TigerBeetle repository root:

```sh
./zig/zig version
./zig/zig env
xcrun --sdk macosx --show-sdk-path
xcrun --sdk macosx --show-sdk-version
ls -ld /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
```

The initial build failed immediately because the existing compiler was too old:

```text
error: unsupported zig version: expected 0.14.1, found 0.13.0
```

## 2. Download the repository-pinned Zig compiler

TigerBeetle includes a bootstrap script. Despite its `.ps1` suffix, it is also
an executable POSIX shell wrapper on macOS:

```sh
./zig/download.ps1
./zig/zig version
```

The expected version for this checkout is:

```text
0.14.1
```

The download requires network access to `ziglang.org`.

## 3. Diagnose the SDK linker failure

With Zig 0.14.1 installed, the ordinary release build still failed:

```sh
./zig/zig build -Drelease
```

The most useful diagnostic was Zig's verbose linker output:

```sh
ZIG_VERBOSE_LINK=1 ./zig/zig build -Drelease
```

It showed the Zig build runner being linked against the default Xcode SDK:

```text
-platform_version macos 26.6.1 26.5
-syslibroot /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk
-lSystem
```

The resulting errors included:

```text
error: undefined symbol: __availability_version_check
error: undefined symbol: _abort
error: undefined symbol: _arc4random_buf
error: undefined symbol: _clock_gettime
error: undefined symbol: _fork
error: undefined symbol: _malloc_size
error: undefined symbol: _sigaction
```

Inspection of the SDK stubs showed the key difference:

- The macOS 26.5 `libSystem.tbd` selected by Xcode omitted the plain
  `arm64-macos` target.
- The installed macOS 15.4 SDK included `arm64-macos`.

In this environment, setting `SDKROOT` or `MACOSX_DEPLOYMENT_TARGET` was not
enough. Zig still discovered the SDK by invoking:

```sh
xcrun --sdk macosx --show-sdk-path
xcrun --sdk macosx --show-sdk-version
```

## 4. Add a temporary `xcrun` shim

Create a temporary command directory inside the repository:

```sh
mkdir -p .tmp-bin
```

Create `.tmp-bin/xcrun` with the following contents:

```sh
#!/bin/sh

if [ "$1" = "--sdk" ] && [ "$2" = "macosx" ] && [ "$3" = "--show-sdk-path" ]; then
    echo /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
    exit 0
fi

if [ "$1" = "--sdk" ] && [ "$2" = "macosx" ] && [ "$3" = "--show-sdk-version" ]; then
    echo 15.4
    exit 0
fi

exec /usr/bin/xcrun "$@"
```

Make it executable and verify that it selects the older SDK when it is first on
`PATH`:

```sh
chmod +x .tmp-bin/xcrun

PATH="$(pwd)/.tmp-bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    xcrun --sdk macosx --show-sdk-path

PATH="$(pwd)/.tmp-bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    xcrun --sdk macosx --show-sdk-version
```

Expected output:

```text
/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
15.4
```

The shim forwards every other `xcrun` invocation to `/usr/bin/xcrun`, so only
the macOS SDK path and version queries are overridden.

## 5. Build the release binary

Prepend the shim directory to `PATH` only for the build command:

```sh
PATH="$(pwd)/.tmp-bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    ./zig/zig build -Drelease
```

For linker diagnostics during the build, add `ZIG_VERBOSE_LINK=1`:

```sh
PATH="$(pwd)/.tmp-bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    ZIG_VERBOSE_LINK=1 \
    ./zig/zig build -Drelease
```

The build installs the executable in both locations below:

```text
./tigerbeetle
./zig-out/bin/tigerbeetle
```

## 6. Verify the artifact

```sh
file ./tigerbeetle
./tigerbeetle version
shasum -a 256 ./tigerbeetle ./zig-out/bin/tigerbeetle
```

For the checkout recorded here, verification produced:

```text
./tigerbeetle: Mach-O 64-bit executable arm64
TigerBeetle version 65535.0.0+97c7a8e
```

The two SHA-256 values should match, confirming that the root executable and
the installed build artifact are identical.

## 7. Remove the temporary shim

After the build succeeds, remove only the two temporary objects created by this
procedure:

```sh
rm .tmp-bin/xcrun
rmdir .tmp-bin
```

The finished binary does not depend on the shim. Future rebuilds on the same
macOS/Xcode combination will need the shim again unless the Zig or SDK
compatibility issue has been resolved.

## Notes

- Do not change the global `xcode-select` setting for this workaround. Scoping
  the SDK override to the build command avoids affecting unrelated builds.
- The `65535.0.0` release number identifies a development source build; the
  commit suffix identifies the source revision.
- TigerBeetle's own documentation supports macOS for development, but states
  that source builds require extra compatibility care and are not the
  recommended production deployment path.
- The SDK issue affected the native Zig build runner before TigerBeetle's own
  target options could take effect. That is why passing a TigerBeetle build
  target alone did not solve it.

## Optional development smoke test

For a new, disposable single-replica development database only:

```sh
./tigerbeetle format \
    --cluster=0 \
    --replica=0 \
    --replica-count=1 \
    --development \
    ./0_0.tigerbeetle

./tigerbeetle start \
    --addresses=0.0.0.0:3000 \
    --development \
    ./0_0.tigerbeetle
```

Do not run `format` over an existing TigerBeetle data file.
