# macOS CLI and MCP automation

The macOS app includes a native `link2download` helper. CLI commands and MCP tools control the same queue, history and preferences as the window. No Python, Node.js, Homebrew or separate MCP runtime is required by users. This is source functionality under **Unreleased**; an older installed release does not include the helper.

## Start with the CLI

For an app installed in Applications:

```bash
/Applications/Link2Download.app/Contents/MacOS/link2download-cli --help
/Applications/Link2Download.app/Contents/MacOS/link2download-cli app status --json
```

Optionally add a symlink in your own directory, then put that directory on your shell's PATH:

```bash
mkdir -p "$HOME/.local/bin"
ln -s /Applications/Link2Download.app/Contents/MacOS/link2download-cli "$HOME/.local/bin/link2download"
export PATH="$HOME/.local/bin:$PATH"
```

The examples below use `link2download`. Using the absolute bundled path works equally well. Do not copy the helper out of the app: keeping the bundled helper and app together avoids version mismatches. A standalone development helper can use `--app /absolute/path/Link2Download.app`.

The helper connects to the running app or starts it with `--background-control` without showing a window. `--no-launch` makes a missing app connection an error. MCP initialization and tool discovery do not launch the app; the first tool call can. A normal logged-in macOS session is required; browser/Keychain permissions may still display system prompts.

Quit older running copies before installing/starting an automation-enabled build. The published 1.4.5 installer predates the helper; use a new source build or the separately verified local automation preview.

Closing a terminal, interrupting a waiting CLI, or disconnecting an MCP client leaves accepted jobs running. Closing the app window also keeps the app running. `app quit` refuses while work is pending; `app quit --force` cancels pending work and quits after workers stop. A process crash or restart does not resume jobs: interrupted records are marked failed and can be retried.

## Connect Codex and Claude Code

Run these yourself after installing a build containing the helper. They register a local stdio server; the implementation does not alter either client's configuration automatically.

Codex uses its user configuration by default (`~/.codex/config.toml`, unless its configuration location is overridden):

```bash
codex mcp add link2download -- \
  /Applications/Link2Download.app/Contents/MacOS/link2download-cli mcp serve
codex mcp list
```

Claude Code has an explicit user scope:

```bash
claude mcp add --scope user --transport stdio link2download -- \
  /Applications/Link2Download.app/Contents/MacOS/link2download-cli mcp serve
claude mcp list
```

Keep MCP input schemas as root objects without `oneOf`, `anyOf` or `allOf`. Claude Code can exclude tools with root-level unions when its optional schema rewrite is unavailable. Commands accepting a record or operation describe the exclusive choice and enforce exactly one of `id` or `operationId` in the shared server-side validator. This preserves all 29 tools across clients, including `downloads_get`, `downloads_cancel` and `history_remove`. See [Claude Code schema compatibility](https://code.claude.com/docs/en/mcp#tool-input-schemas-with-a-root-level-combinator).

For a different installation location, replace the absolute helper path. Use the client's MCP status view to check discovery. Configuration syntax follows the [Codex MCP documentation](https://developers.openai.com/codex/mcp/) and [Claude Code MCP documentation](https://code.claude.com/docs/en/mcp). The Codex command was also checked against the installed CLI's `mcp add --help`; Claude Code was not installed on the development Mac at implementation time.

An example instruction for either agent: “Download these links as M4A to `/Users/me/Music/Clips`, without changing my app preferences. Wait for processing to finish, then list the saved files.” The agent should enqueue, retain the operation IDs and poll `downloads_get`.

## Downloads, playlists and progress

```bash
link2download download add 'https://example.com/video' \
  --mode manual --kind audio --audio-format m4a \
  --save-directory "$HOME/Music/Clips" --request-id audio-example-1 --json

link2download download get --operation-id OPERATION_UUID --limit 100 --offset 0 --json
link2download download wait OPERATION_UUID --timeout 1800 --json
link2download download watch OPERATION_UUID --interval 1 --timeout 1800

link2download download list --status failed --query example --limit 50 --offset 0 --json
link2download download cancel --operation-id OPERATION_UUID --json
link2download download retry RECORD_UUID --preferences original --json
link2download download retry-errors --preferences current --json
```

`OPERATION_UUID` and `RECORD_UUID` above are placeholders. `download add` immediately returns an `operationId`, current `records`, `effectivePreferences` and `resolvedProfile`. Snapshots include `terminal`, `stopping` and `failed`. Snapshots also return `recordCount`, `offset`, `limit` and `nextOffset`; use the latter to fetch subsequent record pages (default 100, maximum 500). `terminal`, `stopping` and `failed` summarize **all** operation records, including records outside the current page. Completion means `terminal=true` and `stopping=false`; it includes any remux/transcode stage, not just transfer completion. One download and one transcode can run concurrently. Errors during a job appear in its record; accepting a job does not guarantee a successful download.

`download get RECORD_UUID` returns that record's operation snapshot. `download cancel RECORD_UUID` cancels one record; `--operation-id` cancels the operation's records. `wait`/`watch` positional IDs are operation IDs; use `--id RECORD_UUID` to resolve via a record. `watch` emits one compact JSON object per changed snapshot (NDJSON). Wait defaults: 600-second timeout, 1-second interval; interval range 0.1–60 seconds. Timeout does not cancel anything.

For URLs containing a `list` query parameter, explicitly choose:

```bash
link2download download add 'https://www.youtube.com/watch?v=VIDEO&list=PLAYLIST' --playlist single --json
link2download download add 'https://www.youtube.com/playlist?list=PLAYLIST' --playlist all --json
```

A playlist has a root operation ID and may produce several child records. Continue polling the operation rather than only its first record. The `single` choice requires a URL identifying a video, not just a playlist.

`--request-id KEY` is optional but recommended for enqueue commands. Repeating the same request and options returns the existing operation; reusing the key for different work returns `REQUEST_CONFLICT`. The operation's saved preference baseline is used when repeating omitted options, even if global settings have changed. This protection persists only while the corresponding history record is retained. Clearing/removing its history releases the key. The helper never automatically replays a request after an ambiguous connection failure.

Retry defaults to **current** preferences, matching the GUI. `--preferences original` uses the saved original settings; legacy records without a saved profile cannot use that option.

## Preferences and file actions

Download options apply only to that job. `settings set` atomically changes persistent preferences:

```bash
link2download settings get --json
link2download settings set --save-directory "$HOME/Downloads/Media" --json
link2download settings set --smart-mode-enabled true --json
link2download settings set --changes '{"kind":"audio","audioFormat":"m4a"}' --json
link2download settings reset --json

link2download transcode add RECORD_UUID --transcode-bitrate 24 --json
link2download file reveal RECORD_UUID
link2download source get RECORD_UUID --json
link2download history remove --operation-id OPERATION_UUID --json
```

Supported options:

| CLI flag | Values | Raw API preference |
| --- | --- | --- |
| `--language` | `system`, `english`, `russian`, `hindi`, `chinese` | `language` |
| `--smart-mode-enabled` | boolean | `smartModeEnabled` |
| `--apple-transcode-enabled` | boolean | `appleTranscodeEnabled` |
| `--kind` | `video`, `audio` | `kind` |
| `--quality` | `best`, `720`, `1080`, `4k`, `8k` | `quality`: `best`, `p720`, `p1080`, `p4k`, `p8k`; legacy `smart` also accepted |
| `--video-format` | `mp4`, `mkv` | `videoFormat` |
| `--audio-format` | `mp3`, `m4a`, `ogg` | `audioFormat` |
| `--save-directory` | absolute path; CLI expands relative paths and `~` | `saveDirectory` |
| `--speed-limit` | `unlimited`, `50`, `25`, `10`, `4` Mbit/s | `speedLimit`: `unlimited`, `mbps50`, `mbps25`, `mbps10`, `mbps4` |
| `--transcode-bitrate` | `auto`, `6`, `10`, `16`, `24`, `35`, `50`, `80` Mbit/s | `transcodeBitrate`: `autoHigh` or `mbpsN` |
| `--cookie-source` | `auto`, `none`, `safari`, `chrome`, `comet`, `chromium`, `firefox`, `edge` | `cookieSource` |
| `--include-subtitles` | boolean | `includeSubtitles` |
| `--include-additional-audio-tracks` | boolean | `includeAdditionalAudioTracks` |

Boolean flags accept `true`/`false`, omitted `true`, or `--no-FLAG`. Raw enums are also accepted by CLI flags. JSON `--options`, `--changes`, MCP arguments and raw API calls use raw preference keys/values. Unknown fields and wrong types are rejected.

`--mode smart` enables Smart Mode; `--mode manual` disables it for the job. Explicit Smart Mode together with manual overrides of kind, quality, formats, speed, cookies, subtitles or additional audio tracks returns `SMART_MODE_CONFLICT`. Supplying those fields without explicitly enabling Smart Mode disables it. Enabling Smart Mode resets its managed fields to smart defaults; save directory and language are retained. A single settings request avoids the side effects of sequential GUI property assignments.

`file delete` deletes the saved output while retaining history, and refuses files still used by a queued/running job. `history remove` cancels/removes selected records while retaining downloaded files. `history clear` cancels/removes all records; `history clear-errors` removes failed/cancelled records. History clear operations return removal counts and `filesDeleted=false`.

## Complete command and tool map

All commands accept global `--json`, `--app PATH` and `--no-launch`. `call METHOD --params JSON` exposes the same wire API. `capabilities` returns its current schemas.

| CLI | Wire method | MCP tool |
| --- | --- | --- |
| `app status` | `app.status` | `app_status` |
| `app quit [--force]` | `app.quit` | `app_quit` |
| `capabilities` | `capabilities.get` | `capabilities_get` |
| `download add URL` | `downloads.enqueue` | `downloads_enqueue` |
| `download get ID` | `downloads.get` | `downloads_get` |
| `download list` | `downloads.list` | `downloads_list` |
| `download cancel ID` | `downloads.cancel` | `downloads_cancel` |
| `download retry ID` | `downloads.retry` | `downloads_retry` |
| `download retry-errors` | `downloads.retry_errors` | `downloads_retry_errors` |
| `transcode add ID` | `transcodes.enqueue` | `transcodes_enqueue` |
| `settings get` | `settings.get` | `settings_get` |
| `settings set` | `settings.update` | `settings_update` |
| `settings reset` | `settings.reset` | `settings_reset` |
| `history remove ID` | `history.remove` | `history_remove` |
| `history clear` | `history.clear` | `history_clear` |
| `history clear-errors` | `history.clear_errors` | `history_clear_errors` |
| `file open ID` | `files.open` | `files_open` |
| `file reveal ID` | `files.reveal` | `files_reveal` |
| `file delete ID` | `files.delete` | `files_delete` |
| `source get ID` | `sources.get` | `sources_get` |
| `source copy ID` | `sources.copy` | `sources_copy` |
| `source open ID` | `sources.open` | `sources_open` |
| `diagnostics report` | `diagnostics.report` | `diagnostics_report` |
| `diagnostics logs [--max-bytes N]` | `diagnostics.logs` | `diagnostics_logs` |
| `ui show` | `ui.show` | `ui_show` |
| `ui settings` | `ui.settings` | `ui_settings` |
| `ui about` | `ui.about` | `ui_about` |
| `ui hide` | `ui.hide` | `ui_hide` |
| `ui filter [--kind all\|video\|audio] [--query TEXT]` | `ui.set_filter` | `ui_set_filter` |

`downloads.get`, `downloads.cancel` and `history.remove` accept exactly one UUID field: `id` or `operationId`. Other record actions require `id`. `settings.update` requires `changes`; enqueue accepts `options`, optional `requestId`, and downloads additionally accept `mode` and `playlist`. `download wait`/`watch` are CLI polling helpers using `downloads.get`; no long-running MCP tool call is needed.

## Output, limits and errors

CLI success uses stdout; `--json` produces compact JSON. Errors use stderr (`{"error":{"code":"…","message":"…"}}` with `--json`). Exit codes: **0** success, **1** operation/connection failure or failed/cancelled wait result, **2** invalid command/parameters, **3** wait timeout. Batch retry reports per-record errors in its successful result; inspect `errors` as well as `retried`.

MCP stdout contains only newline-delimited JSON-RPC. Tools declare `outputSchema` with typed common success fields and a structured-error alternative, and return both `structuredContent` and equivalent JSON in text content. Additional success fields remain allowed for compatible extensions. Tool execution/argument failures set `isError=true`; malformed protocol requests use JSON-RPC errors. Notifications, including `notifications/cancelled`, receive no response. Cancelling an MCP request does not undo an accepted app operation; explicitly call `downloads_cancel`.

| Codes | Meaning / recovery |
| --- | --- |
| `USAGE`, `INVALID_PARAMS`, `INVALID_URL`, `INVALID_DIRECTORY` | Correct the command, type, URL or writable absolute folder. |
| `PLAYLIST_CHOICE_REQUIRED`, `SMART_MODE_CONFLICT` | Supply an explicit playlist choice or use compatible mode/options. |
| `RECORD_NOT_FOUND`, `FILE_MISSING`, `INVALID_STATE` | Refresh history and check the selected record/file. |
| `TASK_STOPPING`, `TASKS_ACTIVE`, `FILE_IN_USE`, `ALREADY_QUEUED` | Wait for work to stop or address the active task before continuing. |
| `REQUEST_CONFLICT` | Use the original request parameters or a new key for new work. |
| `APP_NOT_RUNNING`, `APP_NOT_FOUND`, `APP_START_FAILED`, `APP_START_TIMEOUT` | Check app/helper location and launch behavior. |
| `IPC_UNSAFE`, `IPC_UNAUTHORIZED`, `IPC_UNAVAILABLE`, `IPC_DISCONNECTED` | Check local endpoint ownership/permissions; after an ambiguous disconnect query existing work before resubmitting. |
| `API_VERSION_MISMATCH` | Use helper and app from the same build. |
| `MESSAGE_TOO_LARGE` | Reduce page/log size. |
| `WAIT_TIMEOUT` | Job still runs; query/wait again or explicitly cancel. |
| `APP_STOPPING`, `OPEN_FAILED`, `CLIPBOARD_FAILED`, `FILE_DELETE_FAILED`, `INTERNAL_ERROR` | Inspect the message and redacted diagnostic report. |

History listing defaults to 50 records; operation snapshots default to 100. Both accept `limit` 1–500 and nonnegative `offset`. Input limits: request IDs 1–200 Unicode characters, URL 1–8,192, query at most 1,000, save directory 1–4,096. Diagnostics `maxBytes` is 1,000–180,000 (default 50,000). Wire messages and MCP input frames are bounded to about 2 MB; use pagination. The app accepts up to eight simultaneous socket connections. Socket reads/writes have 15-second timeouts. Media jobs themselves have their own runtime limits and can take much longer.

Diagnostics redact URL queries/fragments and embedded username/password URL credentials. Source URLs and record paths remain available as intentional application data; cookies and Keychain secret values are not API results. Access to the control socket grants the user's app operations, including file deletion. MCP annotations identify destructive tools; individual clients control their approval policies.

## Architecture and macOS 12 compatibility

```text
CLI / MCP stdio → ControlClient → per-user Unix socket
                                             ↓
                                   AutomationController
                                             ↓
GUI ───────────────────→ DownloadManager + SettingsStore
                                 ↓
                         yt-dlp / ffmpeg / ffprobe
```

There is one app-owned manager and settings store. The ownership lease is acquired before history is loaded, so starting a second app process cannot rewrite the active queue. Control mutations execute on the main actor; socket reading/writing runs off the main thread. The control channel has no network listener. Download tools still connect to media sites normally.

The endpoint is `/tmp/link2download-UID/control.sock`, with a real, same-user directory restricted to `0700`, a `0600` socket, an owner lease and peer-UID verification on both sides. No browser cookie database or Keychain material is exposed through the socket.

The helper uses Foundation/Darwin and a small native MCP adapter. The official Swift MCP SDK [package manifest](https://github.com/modelcontextprotocol/swift-sdk/blob/main/Package.swift), checked on **2026-10-23**, declares macOS 13 and Swift 6.1; it was not added because this project retains macOS 12. Both app/helper targets remain `*-apple-macos12.0` by default.

The adapter supports `initialize`, initialization notification, `ping`, `tools/list`, `tools/call` and cancellation notifications. Negotiated versions: `2024-11-05`, `2025-03-26`, `2025-06-18`, `2025-11-25`; an unsupported proposed version receives the newest supported version. Only tools capability is advertised. Resources, prompts, subscriptions, HTTP/SSE, MCP task extension and JSON-RPC batches are not implemented. Async work is represented by app operation IDs and polling.

Compilation for the macOS 12 deployment target and execution on the development Mac do **not** substitute for running on macOS 12. A physical/VM macOS 12 runtime check has not yet been performed. Actual client/runtime checks are recorded below. Claude Code connection and tool discovery were checked on 2026-10-24; an authenticated Claude model session was not exercised and is outside the acceptance scope agreed on 2026-10-25.

### File map for continued development

| File | Responsibility |
| --- | --- |
| `Control/ControlWire.swift` | API version, stable errors, JSON encoding and size limit. |
| `Control/ControlCatalog.swift` | Canonical 29 commands, MCP schemas, strict argument validation and option enums. |
| `Control/ControlTransport.swift` | Secure Unix socket, ownership lease, app discovery/launch, request/response client. |
| `Sources/ControlServer.swift` | Bounded app listener; main-actor dispatch and off-main response writes. |
| `Sources/AutomationController.swift` | App command routing, atomic preferences and operation snapshots. |
| `Sources/Link2DownloadApp.swift` | AppKit lifecycle, background launch, shared manager, windows and orderly shutdown. |
| `Sources/DownloadManager.swift`, `Sources/Models.swift` | Queues, persisted operation/request IDs, requested preferences and resolved profiles. |
| `CLI/Main.swift` | Strict CLI parser, exit codes and wait/watch. |
| `CLI/MCPServer.swift` | Dependency-free stdio MCP protocol; injectable handler for tests. |
| `scripts/build_cli.sh`, `scripts/build_app.sh` | Architecture/deployment target and bundled helper build/signing. |
| `scripts/test_cli_mcp.py`, `scripts/test_automation.swift` | Transport/parser/protocol tests and domain integration tests. |

Update the catalog, routing, tests and this guide together when extending the API. Keep old history decoding compatible. Runtime errors remain on records even after a client disconnects.

## Build and regression checks

```bash
./scripts/build_cli.sh
python3 scripts/test_cli_mcp.py --binary "$PWD/build/link2download" -v
./scripts/test_automation.sh
./scripts/test_retry_history.sh
./scripts/test_runtime_process.sh
./scripts/test_transcode_cancellation.sh
./scripts/test_process_error_message.sh
./scripts/build_app.sh
python3 scripts/check_macos_compatibility.py build/Link2Download.app
python3 scripts/test_automation_live.py --app build/Link2Download.app --arch arm64
python3 scripts/test_automation_live.py --app build/Link2Download.app --arch x86_64
```

`build_cli.sh` defaults to Universal 2 and macOS 12; `TARGET_ARCH=arm64` or `TARGET_ARCH=x86_64` selects a single architecture. Python 3 is used by development tests only. The 12 protocol/CLI tests use an isolated fake same-user Unix server and do not launch or mutate a real app. They cover all command mappings, version negotiation, structured results/errors, invalid types/UTF-8/oversized input, notifications, open-stdin response liveness, SIGINT, wait/watch/timeouts and no automatic replay. In particular, use POSIX stdin reads: Foundation's buffered read previously held a response until the pipe filled or closed.

`test_automation_live.py` requires a built app and a logged-in GUI session. It generates a one-second A/V fixture and serves it over local HTTP/HLS, exercising the actual bundled runtime without visiting external media sites or accessing browser cookies. State, diagnostics, settings suites and Unix endpoints are isolated. The optional `--sdk-check /path/to/check.mjs` hook runs an external official-SDK smoke script; Node is not needed for the default test or end-user app.

### Transcode cancellation — 2026-10-24

The row action changes to **Cancel transcoding** during queued/running Apple MOV processing (including hardware encoding). The existing `downloads.cancel` command/MCP tool also cancels this phase. The record becomes cancelled; poll until `terminal=true` and `stopping=false` before retrying. The downloaded source remains available through Open File/Show in Finder for automatic in-place conversions; a cancelled copy retains its separate source record. Retry reuses the local `transcodeSourcePath` without downloading again. No preference/history format or wire contract changed.

Cancellation is latched for the entire worker, including optional `ffprobe` calls, encoder startup/fallback and output probing. `runProcess` must never clear it: only `DownloadManager.runDownload`/`runTranscode` release the latch with `finishTask` when their worker exits. The runner owns SIGTERM and escalates to SIGKILL after three seconds. MOV output is probed while temporary; commit is serialized with cancellation, so an accepted cancellation before commit preserves the source and removes the temporary `.tmp.mov`. Once the output is committed, the conversion has succeeded. Late progress callbacks ignore terminal records.

`test_transcode_cancellation.sh` uses deterministic subprocess fixtures for cancellation before launch, during a probe, between probes and encoding, during a running encoder that ignores SIGTERM, before commit and during output probing. Every case verifies unchanged source bytes, no leftover MOV, stopped encoder, no software fallback and successful retry with the same task ID. `TEST_ARCH=x86_64` runs the fixture checks under Rosetta on Apple Silicon. The live integration test additionally cancels actual VideoToolbox encoding after progress exceeds 1%, and checks terminal/stopping flags, source bytes and temporary cleanup. It uses only isolated local media/state.

The fixture checks passed on ARM64 and Intel under Rosetta, alongside automation, retry/history, process runner, 12 CLI/MCP protocol tests and eight compatibility-checker fixtures. CI now includes the deterministic cancellation regression. A Universal 2 app was built with macOS 12 targets; all 109 bundled Mach-O images passed the minimum-OS checker. The final Developer ID signed build passed the offline live test on ARM64 and Intel under Rosetta, including actual hardware cancellation. Nine UI snapshots include active/cancelled processing and the longer Russian action at narrow and wide window widths. Actual macOS 12 and physical Intel runtime verification remain outstanding; release/install results are recorded separately in [macos-release.md](macos-release.md).

### Verification on 2026-10-23

- Both app and helper compile for `arm64-apple-macos12.0` and `x86_64-apple-macos12.0`; all **109** bundled Mach-O images, including Python extensions/libraries, declare minimum macOS versions no higher than 12.0. The checker has eight binary-format regression fixtures.
- Twelve CLI/MCP protocol tests passed, including both architecture-specific helpers. Domain automation tests passed on ARM64 and Intel under Rosetta; existing retry/history, process runner and process-error checks passed.
- The signed app passed the offline live test on **ARM64** and **x86_64 under Rosetta**: background startup, duplicate-instance ownership, simultaneous clients, real video download, Apple MOV copy, M4A extraction, immutable job-only settings, persisted request replay, paged state, idle quit, forced active cancellation/quit and restart persistence.
- The official TypeScript MCP SDK **1.32.1** successfully negotiated the protocol, discovered all 29 output schemas, read live app/settings results and received typed tool errors. This SDK was installed in a temporary test directory only.
- A real **Codex CLI 0.163.0-alpha.11.2** ephemeral session successfully invoked `app_status` and `settings_get`, with client configuration supplied as command overrides. User MCP configurations were not modified. Claude Code was not installed at that stage, so no Claude client session was performed in this initial verification.
- Six responsive UI snapshots rendered; the actual native window, settings/About switching and Settings menu action were inspected. Programmatic quit is scheduled through a run-loop selector so AppKit's nested termination loop can drain pending main-actor work.
- Host: macOS **26.7.1** on Apple Silicon. These checks do not establish physical Intel or actual macOS 12 runtime compatibility, authenticated browser-cookie behavior, external-site availability or a newly published binary release.

Async failures include stable optional record `errorCode` values such as `TOOLS_MISSING`, `AUTH_REQUIRED`, `METADATA_FAILED`, `PROCESS_FAILED` and `SESSION_INTERRUPTED`; legacy history without the field remains readable. Original request preferences, latest attempt preferences and transcode input record identity are persisted separately to keep retries and request replay consistent.

For real app integration tests, isolate **both** data and endpoint before directly launching the executable. `open -a` may reuse an existing process and is not suitable for environment-isolation tests:

```bash
TEST_HOME="$(mktemp -d /tmp/link2download-test.XXXXXX)"
mkdir -m 700 "$TEST_HOME/control"
LINK2DOWNLOAD_TEST_HOME="$TEST_HOME" \
LINK2DOWNLOAD_CONTROL_DIRECTORY="$TEST_HOME/control" \
  ./build/Link2Download.app/Contents/MacOS/Link2Download --background-control &

LINK2DOWNLOAD_CONTROL_DIRECTORY="$TEST_HOME/control" \
  ./build/Link2Download.app/Contents/MacOS/link2download-cli --no-launch app status --json

LINK2DOWNLOAD_CONTROL_DIRECTORY="$TEST_HOME/control" \
  ./build/Link2Download.app/Contents/MacOS/link2download-cli --no-launch app quit --json
```

`LINK2DOWNLOAD_TEST_HOME` selects isolated history/logs, a namespaced preferences suite and a downloads directory. `LINK2DOWNLOAD_CONTROL_DIRECTORY` changes the socket/lease directory for both client and app; keep the socket path within the Unix path length limit and do not reuse production endpoints. Test homes/endpoints must be unique for concurrent test runs. Only remove a test directory after its app has exited. Test preferences use the suite name `com.gzakharov.link2download.test.<test-home-basename>`; clear that suite when cleaning up persistent test preferences.

## Packaging and release status

The helper ships at `Link2Download.app/Contents/MacOS/link2download-cli` and is signed before the outer app. Architecture checks include it. Public Developer ID builds need the normal hardened-runtime/timestamp signing, notarization, stapling and final archive verification described in [macos-release.md](macos-release.md). Modifying either executable after notarization requires a new submission.

The `-cli` suffix is intentional: on default case-insensitive APFS, a helper named `link2download` overwrites the app executable `Link2Download`. A PATH symlink may still be named `link2download` outside the bundle.

This implementation does not itself constitute a new signed/notarized public release. Keep actual build, runtime, client-session and release verification results in the release/handoff documentation when those checks are completed.

A local Universal 2 preview was Developer ID signed, accepted by Apple notarization and stapled on 2026-10-23. Its checksum, verification limits and reproduction commands are recorded in the [release runbook](macos-release.md#local-automation-preview--2026-10-23). No new public GitHub binary release was published.


## Installed client verification — 2026-10-24

The user requested replacing the installed app and enabling both clients. The notarized preview was installed at `/Applications/Link2Download.app`; both user-level MCP entries launch `/Applications/Link2Download.app/Contents/MacOS/link2download-cli mcp serve`. Codex uses `~/.codex/config.toml` (shared with the desktop app on this host); Claude Code uses the user scope in `~/.claude.json`. Unrelated server configurations were preserved. Existing desktop conversations may need a new conversation or MCP reconnect to load a newly added server.

Claude Code was absent and installed using the official native installer, stable version 2.1.308. Its first discovery exposed 26 tools: `downloads_get`, `downloads_cancel` and `history_remove` were skipped because of root-level `oneOf`. The compatibility fix above keeps exclusive-target validation while exposing plain object input schemas. Regression coverage checks discovery-compatible schemas and rejects missing/ambiguous targets before transport.

A real Codex CLI 0.163.0-alpha.11.2 session used the persisted server entry (no replacement MCP config): `app_status`, `ui_show`, `ui_set_filter` to a temporary audio/search filter, restoration of the original filter, and final `app_status` succeeded. All 56 original record IDs and every history record field were retained; startup applies the existing history ordering. Persistent download preferences were semantically unchanged. Private test transcripts, configuration/state snapshots and the previous installed app are kept only under ignored `build/installation-20261024/` (mode 0700); do not commit them.

After the fix, the installed build 1.4.5 (241026) passes the same five Codex calls. Claude Code's server health check connects successfully, and its real print-mode initialization lists all 29 tools (including the previously excluded three). An authenticated Claude model session was not performed: `claude auth status` reported `loggedIn: false` and a real print-mode run stopped with `Not logged in · Please run /login`. On **2026-10-25**, the user accepted the completed checks as sufficient and explicitly waived further Claude model verification. No Claude login or additional client check is required to complete this task. Preserve the distinction between successful MCP connection/discovery and an unperformed authenticated model session. [Current Claude Code requires macOS 13+](https://code.claude.com/docs/en/setup#system-requirements) independently of Link2Download; the app, CLI and native MCP adapter retain macOS 12 support.
