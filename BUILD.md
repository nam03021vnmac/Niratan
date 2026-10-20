# Building Niratan

Niratan is a macOS 26+ app with a single `Niratan` Xcode scheme that always contains Reader, Video and Manga. There are no build variants. Every build script lives in [script/](script/) and is run from anywhere (each resolves the repository root itself).

## Which script do I want?

| I want to… | Run |
| --- | --- |
| Build and launch a Debug app to try a change | `./script/build_and_run.sh` |
| Build, launch and confirm the process started | `./script/build_and_run.sh --verify` |
| Try the app against throw-away data | `./script/build_and_run.sh --data-root /tmp/niratan-data` |
| Build a local DMG to test installing/running | `./script/package_mac_local.sh` |
| Run the unit/contract tests | `bash script/run_tests.sh [filter]` |
| Free disk used by build output | `./script/build_and_run.sh --clean` |
| Cut a public release | `script/release_mac.sh <version>` (CI does the build) |

## Prerequisites

- macOS 26+ with Xcode (command line tools selected) and `git`.
- `cmake` (only the first time, to build SVT-AV1).
- Network access on the first build: the video dependencies are downloaded and built once into `Vendor/libmpv/` (git-ignored) and reused afterwards.

## Run scripts (Debug)

### `build_and_run.sh`

A thin wrapper that `exec`s `build_and_run_native.sh` with the same arguments.

### `build_and_run_native.sh`

Builds the Debug app with `xcodebuild` (no code signing), re-signs it locally, and launches it. It never launches `/Applications/Niratan.app`; it only operates on the bundle it just built at `<derived-data>/Build/Products/Debug/Niratan.app`.

```
build_and_run_native.sh [--instance <id>] [--data-root <dir>] [--appearance dark|light] [mode] [arguments]
```

Modes:

| Mode | Effect |
| --- | --- |
| `run` (default) | Stop any running copy of this bundle, build, launch. |
| `--verify` | Build, launch, and print `Verified <bundle id> at <path> (pid N)`. Use this after changing app code. |
| `--open-latest` | Launch the existing build without rebuilding. |
| `--open-url <url>` | Build, launch and open a Hoshi URL. |
| `--debug` | Build and attach LLDB. |
| `--logs` / `--telemetry` | Build, launch and stream the process's logs. |
| `--clean` | Stop the app and run `cleanup_build_artifacts.sh --all`. |

Isolation options:

- `--instance <id>` (or `HOSHI_APP_INSTANCE_ID`) builds into `.build/xcode-derived-data-<id>` so parallel sessions run distinct bundles. `HOSHI_DERIVED_DATA_PATH` overrides the path. This does **not** isolate user data.
- `--data-root <dir>` (or `HOSHI_DATA_ROOT`, Debug only) moves preferences, Application Support and Keychain items under `<dir>`. Use it for any verification that writes data.
- `--appearance dark|light` stands in for the system appearance (follow-system themes only).
- `HOSHI_VIDEO_LIBRARY_CATALOG_URL` / `HOSHI_MANGA_LIBRARY_CATALOG_URL` point the app at a disposable library catalog.

Before every build it prunes old instance DerivedData (see `cleanup_build_artifacts.sh`) and runs `bootstrap_video_dependencies.sh` if `Vendor/libmpv` is missing or not universal. Swift packages are cached in `.build/xcode-source-packages`.

When verifying UI, only trust the absolute `.app` path this script prints; the bundle ID `moe.shishamo.hoshi` is the same for every build.

### `cleanup_build_artifacts.sh`

Deletes repo-local build output, only at known paths and never while a process is using them.

- `--prune [--protect <path>]` (default): keep the newest `HOSHI_BUILD_RETENTION_COUNT` (default 2) inactive `.build/xcode-derived-data-*` directories. Called automatically by the run script.
- `--all`: remove `.build/xcode-derived-data*`, `.build/xcode-source-packages`, `release/DerivedData` and `release/Niratan-Mac-*`. **This also deletes built DMGs and checksums in `release/`.**

### `verify_video_library_manual_fixture.sh`

Creates a disposable video folder and catalog in a temp directory, prints a manual test checklist for the Video bookshelf, and launches the app via `build_and_run.sh --verify` with `HOSHI_VIDEO_LIBRARY_CATALOG_URL` set. Source files are placeholders; remove the printed temp directory afterwards.

## Video dependencies

Video playback needs a universal (arm64 + x86_64) libmpv and SVT-AV1. They are fetched and verified once into `Vendor/libmpv/` and embedded into the app at build time.

- `bootstrap_video_dependencies.sh` – single idempotent entry point; runs both scripts below.
- `bootstrap_libmpv.sh` – downloads IINA 1.4.2's pinned universal dylibs and the matching headers (pinned source revision), checks them against `libmpv-1.4.2.sha256` and the expected FFmpeg major versions.
- `bootstrap_svt_av1.sh` – builds SVT-AV1 4.0.1 from a pinned revision for both architectures and merges them with `lipo`. Skips work if the universal library is already present.
- `embed_video_libraries.sh <frameworks-dir>` – copies the dylibs into the app's `Contents/Frameworks`; invoked by the Xcode build, not by hand. It fails with a pointer to the bootstrap script if a dependency is missing.

## Packaging a DMG

### `package_mac_local.sh` – local test DMG

```
./script/package_mac_local.sh [version]
```

Builds a Release app and an ad-hoc signed DMG for testing on your own machine. With no argument the version is `<MARKETING_VERSION>-local` (for example `2.0.2-local`). Output:

- `release/Niratan-Mac-<version>.dmg`
- `release/Niratan-Mac-<version>.sha256`

It needs no secrets: it skips the Google sign-in credential check and ignores `HOSHI_RELEASE_SIGNING_IDENTITY`. As a result **Google Drive sign-in and sync do not work in this build**, and the DMG must not be distributed. It overwrites a previous DMG of the same name.

### `package_mac.sh` – release DMG

```
./script/package_mac.sh <version>        # e.g. 2.0.3, 2.0.3-rc.1, 0.6.0beta1
```

What it does, in order: bootstrap video dependencies → Release `xcodebuild` into `release/DerivedData` → check that the bundle version and bundle ID match → verify the Google sign-in settings baked into `Info.plist` → verify the full bundle (libmpv, SVT-AV1 and YouTubeKit present; every dylib universal and free of Homebrew paths; no nested `.app`/`.xpc`/`.appex`; no helper executables; no Java/Shinsou/AidokuRunner payloads) → sign (ad-hoc, or `HOSHI_RELEASE_SIGNING_IDENTITY`) → re-verify and check for JIT entitlements → create the DMG with `hdiutil`, verify it and write the SHA-256.

Google sign-in credentials come from the build environment: `HOSHI_READER_GOOGLE_CLIENT_ID` and `HOSHI_READER_GOOGLE_CLIENT_SECRET`, passed to Xcode through an xcconfig. Without them the Google check fails. `package_mac_local.sh` bypasses this through `HOSHI_SKIP_GOOGLE_SIGNIN_VERIFY=1`, which is only honoured for local builds; do not set it in CI.

### `configure_hoshi_google_signin.py`

- `--output <file>` writes a private (mode 600) xcconfig from the two environment variables above, after validating their format. CI exports its path as `XCODE_XCCONFIG_FILE`.
- `--verify-bundle <app>` checks the built `Info.plist` contains a valid client ID/secret and, if the variables are set, that they match. It never prints the values.

## Releasing

### `release_mac.sh`

```
script/release_mac.sh <version> [release-notes-file]
```

Requires a clean working tree on `main` (override with `ALLOW_NON_MAIN_RELEASE=1`) and a tag that doesn't exist locally or on `origin`. It sets `MARKETING_VERSION`, commits the bump if needed, **pushes the branch**, creates an annotated `v<version>` tag and **pushes the tag**. The tag triggers `.github/workflows/release-mac.yml`, which runs the validation scripts below, builds the DMG with `package_mac.sh` using the repository's signing and Google secrets, and publishes the GitHub Release. A release only counts once all three jobs succeed.

## Tests and contract checks

### `run_tests.sh`

```
bash script/run_tests.sh [name-filter]
```

Runs every `script/test_*.swift` and `script/test_*.sh` and prints PASS/FAIL/SKIP per test (failure logs go to `.build/test-logs/`). `bash script/run_tests.sh pdf` runs only tests whose file name contains `pdf`.

Each Swift test declares how it is built through a header comment:

- no directive: a source contract executed by the Swift interpreter;
- `// test-sources: <files>`: compiled together with the listed repository sources;
- `// test-modules: <modules>`: linked against an existing Xcode build. These use `HOSHI_TEST_PRODUCTS` or the newest `.build/xcode-derived-data*` Debug products, and are skipped when no build exists (run the app build first);
- `// test-skip: <reason>`: manual tool or needs the full app target.

Shell tests may declare `# test-requires-path: <path>` and are skipped, not failed, when that bootstrap output is missing. Note that contract tests cannot prove Reader, Manga or Video visuals; verify those in a built app with disposable data.

### Release contract scripts

These run in CI before packaging and are cheap to run locally:

- `verify_native_release_contract.sh` – project, scheme, run script, changelog and Info.plist rules for the native macOS release.
- `verify_full_build_contract.sh` – the single full-feature build stays intact: one scheme, no retired variants, packaging checks present, libmpv/SVT-AV1/YouTubeKit/Aidoku requirements.
- `verify_native_upgrade_contract.sh` – storage, token and Keychain keys stay compatible across upgrades.
- `audit_native_upgrade_data.sh [--root DIR] [--skip-defaults] [--skip-keychain]` – read-only audit of an installed user's data; prints only counts and presence, never values.

### Manual smoke test

`smoke_test_manga_google_lens.swift` is a manual network tool (it uploads a generated image to Google Lens); `run_tests.sh` never runs it (it only picks up `test_*` files), and it is not part of CI.

## Generated paths

All git-ignored: `.build/` (Debug DerivedData, source packages, test logs), `release/` (Release DerivedData, DMGs, checksums), and `Vendor/libmpv/{include/mpv,lib}` (video dependencies).
