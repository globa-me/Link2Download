#!/usr/bin/env python3
"""Offline integration test: real app/CLI/MCP, bundled yt-dlp/ffmpeg, isolated state.

Requires a built .app and a logged-in macOS GUI session. No browser access,
external website, or production settings/history are used.
"""
import argparse
import concurrent.futures
import functools
import http.server
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path("build/Link2Download.app"))
    parser.add_argument("--sdk-check", type=Path, help="Optional external Node MCP SDK integration script")
    parser.add_argument("--arch", choices=["arm64", "x86_64"], help="Force app/helper architecture (Intel requires Rosetta on Apple Silicon)")
    args = parser.parse_args()
    app = args.app.resolve()
    helper = app / "Contents/MacOS/link2download-cli"
    runtime = app / "Contents/Resources/bin"
    prefix = ["/usr/bin/arch", "-" + args.arch] if args.arch else []
    with tempfile.TemporaryDirectory(prefix="l2d-live-", dir="/tmp") as temp:
        root = Path(temp)
        state = root / ("state-" + root.name)
        state.mkdir()
        socket_dir = root / "socket"
        env = dict(os.environ, LINK2DOWNLOAD_TEST_HOME=str(state), LINK2DOWNLOAD_CONTROL_DIRECTORY=str(socket_dir))
        fixture = root / "fixture.mp4"
        subprocess.run(prefix + [str(runtime / "ffmpeg"), "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=blue:s=160x90:r=15",
                        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-t", "1", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                        "-c:a", "aac", "-movflags", "+faststart", str(fixture)], check=True, timeout=30)
        # Generic direct MP4 lacks codec metadata in yt-dlp. Use a local HLS
        # master with explicit codecs so it exercises the app's normal A/V selector.
        subprocess.run(prefix + [str(runtime / "ffmpeg"), "-hide_banner", "-loglevel", "error", "-i", str(fixture),
                        "-c", "copy", "-f", "hls", "-hls_time", "1", "-hls_list_size", "0", str(root / "media.m3u8")], check=True, timeout=30)
        (root / "master.m3u8").write_text('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=200000,RESOLUTION=160x90,CODECS="avc1.64000a,mp4a.40.2"\nmedia.m3u8\n')
        class QuietHandler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *_):
                pass
            def do_GET(self):
                if "slow=1" in self.path:
                    time.sleep(3)
                try:
                    super().do_GET()
                except (BrokenPipeError, ConnectionResetError):
                    pass  # A cancelled runtime request can close its fixture connection.
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(QuietHandler, directory=str(root)))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        url = f"http://127.0.0.1:{server.server_port}/master.m3u8?token=integration-secret#private"
        log = open(root / "app-stderr.log", "w+")
        process = None

        def cli(*parts, ok=True):
            result = subprocess.run(prefix + [str(helper), "--no-launch", "--json", *parts], env=env, capture_output=True, text=True, timeout=25)
            if ok and result.returncode:
                raise AssertionError(f"CLI {parts} failed: {result.stderr}")
            return json.loads(result.stdout if result.returncode == 0 else result.stderr)

        def launch():
            nonlocal process
            process = subprocess.Popen(prefix + [str(app / "Contents/MacOS/Link2Download"), "--background-control"], env=env, stdout=log, stderr=log)
            for _ in range(150):
                if process.poll() is not None:
                    log.seek(0)
                    raise AssertionError(f"App exited {process.returncode}: {log.read()}")
                if (socket_dir / "control.sock").exists():
                    return
                time.sleep(0.1)
            raise AssertionError("App control startup timed out")

        def wait(operation):
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                result = cli("download", "get", "--operation-id", operation)
                if result["terminal"]:
                    assert not result["failed"], result
                    return result["records"][0]
                time.sleep(0.2)
            raise AssertionError("Download/transcode did not become terminal")

        try:
            launch()
            status = cli("app", "status")
            assert status["minimumMacOS"] == "12.0" and not status["visible"], status
            if args.arch:
                assert status["architecture"] == args.arch, status
            before = cli("settings", "get")["settings"]
            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                replies = list(pool.map(lambda _: cli("app", "status"), range(12)))
            assert all(item["appPath"] == str(app) for item in replies)
            # A duplicate executable launch must exit without loading/reconciling the owner's state.
            duplicate = subprocess.run(prefix + [str(app / "Contents/MacOS/Link2Download"), "--background-control"], env=env, capture_output=True, timeout=10)
            assert duplicate.returncode == 0 and process.poll() is None
            print("PASS: background app, single owner, simultaneous clients", flush=True)

            params = {"url": url, "requestId": "live-video", "mode": "manual", "options": {"cookieSource": "none", "saveDirectory": str(state / "video")}}
            enqueued = cli("call", "downloads.enqueue", "--params", json.dumps(params))
            operation = enqueued["operationId"]
            # Enqueue's helper has exited; the app must finish the work itself.
            video = wait(operation)
            assert Path(video["filePath"]).is_file() and video["outputFormat"] == "MP4", video
            assert cli("call", "downloads.enqueue", "--params", json.dumps(params))["operationId"] == operation
            assert cli("settings", "get")["settings"] == before
            print("PASS: real bundled download, durable request ID, job-only options, helper disconnect", flush=True)

            transcode = cli("transcode", "add", video["id"], "--request-id", "live-mov")
            mov = wait(transcode["operationId"])
            assert Path(mov["filePath"]).is_file() and mov["outputFormat"] == "MOV", mov
            assert Path(video["filePath"]).is_file(), "Transcode copy must preserve source"
            audio = cli("download", "add", url, "--kind", "audio", "--audio-format", "m4a", "--cookie-source", "none",
                        "--save-directory", str(state / "audio"), "--request-id", "live-audio")
            audio_record = wait(audio["operationId"])
            assert audio_record["kind"] == "audio" and audio_record["outputFormat"] == "M4A", audio_record
            print("PASS: real Apple MOV copy and M4A extraction", flush=True)

            # Make the isolated downloaded source long enough to cancel after
            # VideoToolbox emits actual progress, rather than only while queued.
            vp9 = root / "vp9.webm"
            subprocess.run(prefix + [str(runtime / "ffmpeg"), "-hide_banner", "-loglevel", "error",
                            "-f", "lavfi", "-i", "color=c=blue:s=640x360:r=30", "-t", "1",
                            "-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8", str(vp9)],
                           check=True, timeout=30)
            source = Path(video["filePath"])
            subprocess.run(prefix + [str(runtime / "ffmpeg"), "-hide_banner", "-loglevel", "error",
                            "-y", "-stream_loop", "-1", "-i", str(vp9), "-t", "900", "-c", "copy", str(source)],
                           check=True, timeout=30)
            original_bytes = source.read_bytes()
            cancelling = cli("transcode", "add", video["id"], "--request-id", "live-cancel-transcode")
            cancel_id = cancelling["operationId"]
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                snapshot = cli("download", "get", "--operation-id", cancel_id)
                active = snapshot["records"][0]
                if active.get("processingStage") == "hardwareTranscode" and active.get("processingProgress", 0) > 0.01:
                    break
                assert not snapshot["terminal"], snapshot
                time.sleep(0.05)
            else:
                raise AssertionError("Hardware transcode did not emit progress")
            cancel_started = time.monotonic()
            cli("download", "cancel", "--operation-id", cancel_id)
            while time.monotonic() - cancel_started < 10:
                snapshot = cli("download", "get", "--operation-id", cancel_id)
                if snapshot["terminal"]:
                    break
                time.sleep(0.1)
            assert snapshot["terminal"] and not snapshot["stopping"], snapshot
            cancelled = snapshot["records"][0]
            assert cancelled["status"] == "cancelled" and cancelled.get("processingStage") is None, cancelled
            assert source.read_bytes() == original_bytes, "Cancellation changed the downloaded source"
            assert not list(source.parent.glob(".*.tmp.mov")), "Cancelled MOV was retained"
            print("PASS: running VideoToolbox cancellation, bounded stop, source retained, temporary MOV removed", flush=True)

            # Real stdio connection through the app; keep stdin open to catch buffering hangs.
            mcp = subprocess.Popen(prefix + [str(helper), "--no-launch", "mcp", "serve"], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            def rpc(message):
                mcp.stdin.write((json.dumps(message) + "\n").encode())
                mcp.stdin.flush()
                assert select.select([mcp.stdout], [], [], 10)[0], "MCP response stalled with open stdin"
                return json.loads(mcp.stdout.readline())
            init = rpc({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "live-test", "version": "1"}}})
            assert init["result"]["capabilities"]["tools"] is not None
            mcp.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
            mcp.stdin.flush()
            listed = rpc({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
            assert len(listed["result"]["tools"]) == 29
            result = rpc({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "downloads_get", "arguments": {"operationId": operation}}})
            assert result["result"]["structuredContent"]["terminal"] and not result["result"]["isError"]
            mcp.stdin.close()
            assert mcp.wait(timeout=10) == 0 and process.poll() is None
            if args.sdk_check:
                subprocess.run(["node", str(args.sdk_check.resolve()), str(helper)], env=env, check=True, timeout=30)
            report = cli("diagnostics", "report")["report"]
            assert "integration-secret" not in report and "#private" not in report, report
            assert cli("source", "get", video["id"])["url"] == url
            print("PASS: live MCP tools and redacted diagnostics", flush=True)

            cli("settings", "set", "--language", "russian", "--cookie-source", "none")
            cli("app", "quit")
            assert process.wait(timeout=15) == 0
            launch()
            restored = cli("download", "get", "--operation-id", operation)
            assert restored["terminal"] and restored["records"][0]["id"] == video["id"]
            assert cli("settings", "get")["settings"]["cookieSource"] == "none"
            assert cli("call", "downloads.enqueue", "--params", json.dumps(params))["operationId"] == operation
            cli("history", "remove", video["id"])
            assert Path(video["filePath"]).is_file()
            cli("file", "delete", mov["id"])
            assert not Path(mov["filePath"]).exists()
            slow_url = url.replace("?token=", "?slow=1&token=")
            slow = cli("download", "add", slow_url, "--mode", "manual", "--cookie-source", "none")
            assert cli("app", "quit", ok=False)["error"]["code"] == "TASKS_ACTIVE"
            cli("app", "quit", "--force")
            assert process.wait(timeout=15) == 0
            launch()
            cancelled = cli("download", "get", "--operation-id", slow["operationId"])
            assert cancelled["terminal"] and cancelled["records"][0]["status"] == "cancelled", cancelled
            cli("app", "quit")
            assert process.wait(timeout=15) == 0
            print("PASS: idle/active graceful quit, restart persistence, replay after settings change, history/file separation", flush=True)
        except Exception:
            log.flush()
            log.seek(0)
            print("App stderr:", log.read(), flush=True)
            diagnostics = state / "logs/app.log"
            if diagnostics.exists():
                print("App diagnostics:", diagnostics.read_text()[-6000:], flush=True)
            raise
        finally:
            if process and process.poll() is None:
                try:
                    cli("app", "quit", "--force")
                    process.wait(timeout=15)
                except Exception:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
            server.shutdown()
            log.close()
            # A private defaults suite is used by the app; remove only that test suite.
            subprocess.run(["/usr/bin/defaults", "delete", "com.gzakharov.link2download.test." + state.name], capture_output=True)


if __name__ == "__main__":
    main()
