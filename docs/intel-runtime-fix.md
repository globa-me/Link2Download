# macOS 1.4.4 runtime and retry fix — 2026-09-11

## Report and evidence

The reported 1.4.3 Intel app started yt-dlp but remained at 1% with the URL as its title. Repeating a failed job created another history row. The supplied report alone cannot distinguish a slow Python startup from network/extractor failure: old commands implied quiet mode and warnings were suppressed.

Reproduced on the development Apple Silicon Mac, including x86_64 execution under Rosetta:

- The bundled 2026.08.19 one-file yt-dlp can take tens of seconds even for `--version`, before network activity. A sample showed Python importing libraries through `dlopen` / dyld validation. One measured warm Intel one-file launch took 27.42 seconds. The official onedir distribution took 33.29 seconds on its first launch and 1.13 seconds on its second, avoiding fresh `_MEI` extraction paths every time. This is evidence of startup latency, not proof of a permanent Intel CPU incompatibility.
- The same yt-dlp release warns that the forced `tv_embedded` client is unsupported. It falls back to supported clients and needs a JS runtime for YouTube challenges. The developer machine had Homebrew Deno; the shipped app did not include it. Previous version-only and network smoke checks did not isolate those external dependencies.
- While validating the onedir signing change, removing *all* yt-dlp entitlements reproduced an Intel ctypes/libffi executable-memory allocation loop. A controlled A/B test showed the old `disable-library-validation` entitlement also avoided it, so this is **not evidence of the original 1.4.3 root cause**. The final onedir build grants only `allow-unsigned-executable-memory` to yt-dlp for libffi trampolines; its bundled libraries remain subject to library validation.
- Control test: the old forced-client configuration with JS runtimes disabled still extracted the supplied video via fallback (with warnings). Missing Deno therefore is a real packaging dependency gap, **not proof that it alone caused this user's stall**. The exact reporter-machine hang remains unconfirmed; improved live diagnostics and startup/socket bounds expose it if it persists.
- `DownloadManager.retry()` called `enqueue()`, which always appended a row and only deduplicated active/queued records.

## Implementation

- `scripts/fetch_runtime_tools.sh` pins/verifies the official yt-dlp **onedir ZIP** and Deno 2.7.7 for the target architecture(s). Preserve the complete `_internal` directory, its relative paths and canonical Python.framework symlinks. The Python version in the layout repair is tied to the pinned yt-dlp archive; update it together with the archive/checksum.
- `scripts/build_app.sh` rejects missing tools or the onedir runtime, signs nested Python libraries/frameworks first, then the app. Deno gets JIT entitlements from `Resources/deno.entitlements`. Onedir Python is signed with the same identity and no longer needs the old one-file library-validation exception. `Resources/yt-dlp.entitlements` instead grants only executable-memory permission needed by Intel libffi. Do not omit this entitlement when signing the helper.
- `YTDLPService` uses yt-dlp's default supported clients and passes an explicit adjacent `deno` path, resetting implicit JS runtime discovery. Missing Deno is an actionable missing-tool error. Extraction progress/warnings are visible and recorded while running. All yt-dlp requests get a 20-second socket timeout.
- `RuntimeProcessRunner` drains stdout/stderr together without callbacks racing final reads; UTF-8 decoding happens on complete lines. Silent yt-dlp startup is capped at 120 seconds. Once output begins, normal long downloads/conversions have no arbitrary overall timeout. Cancellation escalates from SIGTERM to SIGKILL after 3 seconds. Inherited pipes cannot hold the caller indefinitely after parent exit.
- Retry retains the UUID, creation date and discovered metadata, resets failed state/progress, and queues the same row. Pasting a matching failed/cancelled URL reuses it. Completed history is preserved; cancellation still settling cannot reuse the active ID. Existing duplicate rows are not bulk-deleted.

## Verification commands

```bash
./scripts/test_retry_history.sh
./scripts/test_runtime_process.sh
TEST_ARCH=x86_64 YTDLP_BIN="$PWD/build/macos-x86_64/Link2Download.app/Contents/Resources/bin/yt-dlp" ./scripts/test_youtube_runtime.sh 'https://www.youtube.com/watch?v=P8e-FfBFRTQ'
TEST_ARCH=x86_64 YTDLP_BIN="$PWD/build/macos-x86_64/Link2Download.app/Contents/Resources/bin/yt-dlp" ./scripts/test_youtube_runtime.sh 'https://www.youtube.com/watch?v=JbCa_9xGHTU'
```

The retry harness uses isolated history and the process harness exercises dual-pipe pressure, split UTF-8, exit status, silent startup, long quiet work after startup, cancellation/kill escalation and descendants inheriting pipes. The network smoke test clears the environment and uses a temporary HOME, system-only PATH, explicit bundled Deno, no cache/cookies and a bounded partial download. It does not change the user's real history/settings.

## Verification results

- Both Swift regression suites passed against the final source.
- Both architecture-specific Swift applications compiled.
- Developer ID signatures on both apps and all nested libraries passed strict/deep verification.
- ARM64 bundled runtime downloaded partial video+audio and merged MP4 for `P8e-FfBFRTQ` with clean HOME/system PATH; log: `build/arm64-runtime-smoke-1.4.4.log`.

- Intel signed runtime downloaded partial video+audio and merged MP4 for **both supplied URLs** using clean HOME/system PATH and bundled Deno. Evidence: `build/intel-runtime-evidence/`. Signed Deno execution also passed.
- Final warm signed Intel `yt-dlp --version`: 0.40 seconds. This is a local measurement, not a hardware-wide guarantee.
- Intel ZIP: `build/Link2Download-1.4.4-macOS-Intel.zip`, SHA-256 `79b98053dcb57fa01ea38302417b79d679da1896d4d79eca6d4cc97a06bddf79`.

## Release status and limits

Local version: 1.4.4. Runtime binaries/build artifacts remain ignored by Git. Existing unrelated working changes in MainView and prior release documentation were preserved.

Physical Intel hardware and the reporter's exact network/OS installation are not available here. Rosetta and a clean environment are useful coverage, not a substitute for that last device check. Local signed artifacts are not automatically notarized or published. Do not label a ZIP notarized until Apple has accepted it and its app ticket is stapled.

Upstream references: [yt-dlp EJS setup](https://github.com/yt-dlp/yt-dlp/wiki/EJS), [yt-dlp options](https://github.com/yt-dlp/yt-dlp#usage-and-options), [pinned yt-dlp release](https://github.com/yt-dlp/yt-dlp/releases/tag/2026.08.19).
