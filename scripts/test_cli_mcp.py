#!/usr/bin/env python3
"""CLI/MCP contract tests without launching or changing a real application.

Build the helper, then run: python3 scripts/test_cli_mcp.py --binary /path/link2download
Uses an isolated, same-user Unix socket and stdlib only.
"""
import argparse
import contextlib
import json
import os
from pathlib import Path
import select
import signal
import socket
import subprocess
import tempfile
import threading
import unittest
import uuid

parser = argparse.ArgumentParser(add_help=False)
parser.add_argument("--binary", required=True)
options, unittest_args = parser.parse_known_args()
BINARY = str(Path(options.binary).resolve())
RECORD = str(uuid.uuid4())
OPERATION = str(uuid.uuid4())
VERSIONS = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]


def request(method, params=None, ident=1):
    obj = {"jsonrpc": "2.0", "method": method, "id": ident}
    if params is not None:
        obj["params"] = params
    return obj


def initialize(version="2025-11-25"):
    return request("initialize", {"protocolVersion": version, "capabilities": {},
                                  "clientInfo": {"name": "contract-tests", "version": "1"}})


def encode(messages):
    return b"".join(json.dumps(m).encode() + b"\n" for m in messages)


class FakeApp:
    def __init__(self, handler=None):
        self.temp = tempfile.TemporaryDirectory(prefix="l2d-cli-", dir="/tmp")
        os.chmod(self.temp.name, 0o700)
        self.environment = dict(os.environ, LINK2DOWNLOAD_CONTROL_DIRECTORY=self.temp.name)
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(self.temp.name + "/control.sock")
        self.listener.listen(10)
        self.listener.settimeout(0.1)
        self.calls = []
        self.errors = []
        self.stop = threading.Event()
        self.handler = handler or (lambda call: {"echo": call})
        self.thread = threading.Thread(target=self.serve, daemon=True)

    def serve(self):
        while not self.stop.is_set():
            try:
                connection, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            try:
                with connection:
                    connection.settimeout(5)
                    line = connection.makefile("rb").readline(2_000_001)
                    call = json.loads(line)
                    self.calls.append(call)
                    result = self.handler(call)
                    reply = result if "apiVersion" in result else {"apiVersion": 1, "result": result}
                    connection.sendall(json.dumps(reply).encode() + b"\n")
            except Exception as exc:
                self.errors.append(exc)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stop.set()
        self.listener.close()
        self.thread.join(timeout=6)
        self.temp.cleanup()
        if self.errors:
            raise AssertionError(self.errors)


class HelperTests(unittest.TestCase):
    def invoke(self, args, app=None, input=None):
        with contextlib.ExitStack() as stack:
            if app is None:
                directory = stack.enter_context(tempfile.TemporaryDirectory(prefix="l2d-cli-", dir="/tmp"))
                env = dict(os.environ, LINK2DOWNLOAD_CONTROL_DIRECTORY=directory)
            else:
                env = app.environment
            return subprocess.run([BINARY, "--no-launch"] + args, input=input,
                                  capture_output=True, env=env, timeout=10)

    def mcp(self, messages, app=None):
        data = messages if isinstance(messages, bytes) else encode(messages)
        result = self.invoke(["mcp", "serve"], app=app, input=data)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, b"")
        return [json.loads(line) for line in result.stdout.splitlines()]

    def test_protocol_negotiation(self):
        for version in VERSIONS + ["unsupported-future-version"]:
            with self.subTest(version=version):
                result = self.mcp([initialize(version)])[0]["result"]
                self.assertEqual(result["protocolVersion"], version if version in VERSIONS else VERSIONS[-1])
                self.assertEqual(set(result["capabilities"]), {"tools"})

    def test_lifecycle_ping_notifications_and_reinitialize(self):
        replies = self.mcp([request("tools/list"), request("ping", ident="ping"), initialize(),
                            {"jsonrpc": "2.0", "method": "notifications/initialized"},
                            {"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 1}},
                            {"jsonrpc": "2.0", "method": "unknown/notification"}, initialize(),
                            request("unknown/method")])
        self.assertEqual(len(replies), 5)
        self.assertEqual(replies[0]["error"]["code"], -32002)
        self.assertEqual(replies[1]["result"], {})
        self.assertEqual(replies[3]["error"]["code"], -32600)
        self.assertEqual(replies[4]["error"]["code"], -32601)

    def test_invalid_json_utf8_batches_ids_and_params(self):
        invalid = [b'{\n', b'\xff\n', b'[]\n', b'null\n',
                   encode([request("ping", ident=None)]), encode([request("ping", ident=True)]),
                   encode([request("ping", params=[])]), b'{"id":1,"method":"ping"}\n']
        expected = [-32700, -32700, -32600, -32600, -32600, -32600, -32602, -32600]
        for data, code in zip(invalid, expected):
            with self.subTest(data=data[:100]):
                self.assertEqual(self.mcp(data)[0]["error"]["code"], code)

    def test_oversized_frame_recovers(self):
        replies = self.mcp(b"x" * 2_000_001 + b"\n" + encode([request("ping", ident="after")]))
        self.assertEqual(replies[0]["error"]["code"], -32700)
        self.assertEqual(replies[1]["id"], "after")
        self.assertEqual(replies[1]["result"], {})

    def test_open_stdin_liveness_and_sigint(self):
        with tempfile.TemporaryDirectory(prefix="l2d-cli-", dir="/tmp") as directory:
            env = dict(os.environ, LINK2DOWNLOAD_CONTROL_DIRECTORY=directory)
            process = subprocess.Popen([BINARY, "--no-launch", "mcp", "serve"], stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            try:
                process.stdin.write(encode([initialize()]))
                process.stdin.flush()
                ready, _, _ = select.select([process.stdout], [], [], 3)
                self.assertTrue(ready, "MCP must reply before stdin closes or fills a buffer")
                self.assertIn("result", json.loads(process.stdout.readline()))
                process.send_signal(signal.SIGINT)
                process.wait(timeout=3)
                self.assertNotEqual(process.returncode, 0)
                self.assertFalse(Path(directory, "control.sock").exists())
            finally:
                if process.poll() is None:
                    process.kill()
                process.communicate(timeout=3)

    def test_tool_discovery_and_schema(self):
        replies = self.mcp([initialize(), request("tools/list"), request("tools/list", {"cursor": "bad"})])
        tools = {tool["name"]: tool for tool in replies[1]["result"]["tools"]}
        self.assertEqual(len(tools), 29)
        for tool in tools.values():
            self.assertEqual(tool["inputSchema"]["type"], "object")
            self.assertFalse(tool["inputSchema"]["additionalProperties"])
            for keyword in ("oneOf", "anyOf", "allOf"):
                self.assertNotIn(keyword, tool["inputSchema"], "Claude Code must discover every tool")
            self.assertEqual(tool["outputSchema"]["type"], "object")
            success, failure = tool["outputSchema"]["anyOf"]
            self.assertTrue(success["additionalProperties"])
            self.assertEqual(failure["required"], ["error"])
        self.assertIn("options", tools["transcodes_enqueue"]["inputSchema"]["properties"])
        self.assertIn("maxBytes", tools["diagnostics_logs"]["inputSchema"]["properties"])
        for name in ("downloads_get", "downloads_cancel", "history_remove"):
            self.assertIn("exactly one of id or operationId", tools[name]["description"])
        self.assertTrue(tools["files_delete"]["annotations"]["destructiveHint"])
        self.assertEqual(replies[2]["error"]["code"], -32602)

    def test_tool_validation_prevents_transport(self):
        calls = [
            ("downloads_enqueue", {"url": "https://example.test", "options": {"alien": True}}),
            ("settings_update", {"changes": {"includeSubtitles": 1}}),
            ("settings_update", {"changes": {"quality": "1080"}}),
            ("downloads_get", {}),
            ("downloads_get", {"id": RECORD, "operationId": OPERATION}),
            ("downloads_get", {"id": "bad"}),
            ("downloads_cancel", {}),
            ("downloads_cancel", {"id": RECORD, "operationId": OPERATION}),
            ("history_remove", {}),
            ("history_remove", {"id": RECORD, "operationId": OPERATION}),
            ("downloads_list", {"limit": True}),
            ("downloads_list", {"limit": 1.5}),
            ("downloads_list", {"limit": 501}),
            ("diagnostics_logs", {"maxBytes": 999}),
            ("downloads_enqueue", {"url": "", "requestId": "ok"}),
            ("downloads_enqueue", {"url": "x" * 8193}),
            ("downloads_enqueue", {"url": "https://example.test", "requestId": ""}),
            ("downloads_enqueue", {"url": "https://example.test", "requestId": "x" * 201}),
            ("downloads_list", {"query": "x" * 1001}),
            ("settings_update", {"changes": {"saveDirectory": "x" * 4097}}),
            ("downloads_get", {"operationId": OPERATION, "limit": 501}),
        ]
        with FakeApp() as app:
            replies = self.mcp([initialize()] + [request("tools/call", {"name": name, "arguments": args}, i + 2)
                                              for i, (name, args) in enumerate(calls)], app=app)
            for reply in replies[1:]:
                self.assertTrue(reply["result"]["isError"])
                self.assertEqual(reply["result"]["structuredContent"]["error"]["code"], "INVALID_PARAMS")
            self.assertEqual(app.calls, [])

    def test_tool_success_and_app_error(self):
        result = {"operationId": OPERATION, "records": [], "terminal": False, "stopping": False, "failed": False, "recordCount": 0, "offset": 0, "limit": 100, "nextOffset": None}
        with FakeApp(lambda _: result) as app:
            reply = self.mcp([initialize(), request("tools/call", {"name": "downloads_enqueue",
                             "arguments": {"url": "https://example.test/a", "requestId": "stable"}})], app=app)[1]["result"]
            self.assertFalse(reply["isError"])
            self.assertEqual(reply["structuredContent"], result)
            self.assertEqual(json.loads(reply["content"][0]["text"]), result)
            self.assertEqual(app.calls[0]["method"], "downloads.enqueue")
        with FakeApp(lambda _: {"apiVersion": 1, "error": {"code": "AUTH_REQUIRED", "message": "Sign in"}}) as app:
            reply = self.mcp([initialize(), request("tools/call", {"name": "app_status"})], app=app)[1]["result"]
            self.assertTrue(reply["isError"])
            self.assertEqual(reply["structuredContent"]["error"]["code"], "AUTH_REQUIRED")

    def test_cli_command_mapping(self):
        cases = [
            (["app", "status"], "app.status", {}), (["app", "quit", "--force"], "app.quit", {"force": True}),
            (["capabilities"], "capabilities.get", {}),
            (["download", "add", "https://example.test/a", "--mode", "manual", "--quality", "1080", "--speed-limit", "25", "--include-subtitles", "--no-apple-transcode-enabled"],
             "downloads.enqueue", {"url": "https://example.test/a", "mode": "manual", "options": {"quality": "p1080", "speedLimit": "mbps25", "includeSubtitles": True, "appleTranscodeEnabled": False}}),
            (["download", "get", RECORD], "downloads.get", {"id": RECORD}),
            (["download", "get", "--operation-id", OPERATION, "--limit", "5", "--offset", "10"], "downloads.get", {"operationId": OPERATION, "limit": 5, "offset": 10}),
            (["download", "list", "--query", "hello", "--limit", "3", "--offset", "2"], "downloads.list", {"query": "hello", "limit": 3, "offset": 2}),
            (["download", "cancel", "--operation-id", OPERATION], "downloads.cancel", {"operationId": OPERATION}),
            (["download", "retry", RECORD, "--preferences", "original"], "downloads.retry", {"id": RECORD, "preferences": "original"}),
            (["download", "retry-errors", "--preferences", "current"], "downloads.retry_errors", {"preferences": "current"}),
            (["transcode", "add", RECORD, "--transcode-bitrate", "35"], "transcodes.enqueue", {"id": RECORD, "options": {"transcodeBitrate": "mbps35"}}),
            (["settings", "get"], "settings.get", {}),
            (["settings", "set", "--changes", '{"language":"russian"}', "--include-subtitles", "false"], "settings.update", {"changes": {"language": "russian", "includeSubtitles": False}}),
            (["settings", "reset"], "settings.reset", {}),
            (["history", "remove", "--operation-id", OPERATION], "history.remove", {"operationId": OPERATION}),
            (["history", "clear"], "history.clear", {}), (["history", "clear-errors"], "history.clear_errors", {}),
            (["diagnostics", "report"], "diagnostics.report", {}),
            (["diagnostics", "logs", "--max-bytes", "2000"], "diagnostics.logs", {"maxBytes": 2000}),
            (["ui", "filter", "--kind", "audio", "--query", "test"], "ui.set_filter", {"kind": "audio", "query": "test"}),
            (["call", "downloads.get", "--params", json.dumps({"id": RECORD})], "downloads.get", {"id": RECORD}),
        ]
        cases += [([group, action, RECORD], method + "." + action, {"id": RECORD})
                  for group, method, actions in [("file", "files", ["open", "reveal", "delete"]),
                                                 ("source", "sources", ["get", "copy", "open"])] for action in actions]
        cases += [(["ui", action], "ui." + action, {}) for action in ["show", "settings", "about", "hide"]]
        with FakeApp() as app:
            for args, method, params in cases:
                with self.subTest(args=args):
                    process = self.invoke(args + ["--json"], app=app)
                    self.assertEqual(process.returncode, 0, process.stderr)
                    echo = json.loads(process.stdout)["echo"]
                    self.assertEqual(echo, {"apiVersion": 1, "method": method, "params": params})

    def test_cli_invalid_input_and_help_without_app(self):
        cases = [["download", "get"], ["download", "get", "bad"], ["download", "list", "--limit", "true"],
                 ["download", "get", RECORD, "extra"], ["settings", "set", "--kind", "other"],
                 ["settings", "set", "--include-subtitles", "yes"], ["app", "quit", "--force=maybe"],
                 ["download", "list", "--limit", "1", "--limit", "2"], ["call", "settings.get", "--params", "[]"],
                 ["download", "wait", OPERATION, "--interval", "0"], ["settings", "get", "--unknown", "x"]]
        for args in cases:
            with self.subTest(args=args):
                process = self.invoke(args + ["--json"])
                self.assertEqual(process.returncode, 2)
                self.assertEqual(process.stdout, b"")
                self.assertIn(json.loads(process.stderr)["error"]["code"], ["USAGE", "INVALID_PARAMS"])
        process = self.invoke(["--help"])
        self.assertEqual(process.returncode, 0)
        self.assertIn(b"macOS 12+", process.stdout)

    def test_wait_watch_timeout_failure_and_no_cancellation(self):
        def job(terminal, failed=False):
            return {"operationId": OPERATION, "records": [{"id": RECORD, "status": "failed" if failed else "completed" if terminal else "downloading"}],
                    "terminal": terminal, "stopping": False, "failed": failed}
        with FakeApp(lambda _: job(True)) as app:
            p = self.invoke(["download", "wait", OPERATION, "--json"], app=app)
            self.assertEqual(p.returncode, 0, p.stderr)
        with FakeApp(lambda _: job(False)) as app:
            p = self.invoke(["download", "wait", OPERATION, "--timeout", "0", "--json"], app=app)
            self.assertEqual(p.returncode, 3)
            self.assertEqual(json.loads(p.stderr)["error"]["code"], "WAIT_TIMEOUT")
            self.assertEqual([call["method"] for call in app.calls], ["downloads.get"])
        with FakeApp(lambda _: job(True, True)) as app:
            p = self.invoke(["download", "wait", OPERATION, "--json"], app=app)
            self.assertEqual(p.returncode, 1)
        with FakeApp() as app:
            app.handler = lambda _: job(len(app.calls) >= 2)
            p = self.invoke(["download", "watch", OPERATION, "--interval", "0.1"], app=app)
            self.assertEqual(p.returncode, 0, p.stderr)
            snapshots = [json.loads(line) for line in p.stdout.splitlines()]
            self.assertEqual(len(snapshots), 2)
            self.assertFalse(snapshots[0]["terminal"])
            self.assertTrue(snapshots[1]["terminal"])

    def test_transport_errors_do_not_replay(self):
        with FakeApp(lambda _: {"apiVersion": 999, "result": {}}) as app:
            p = self.invoke(["app", "status", "--json"], app=app)
            self.assertEqual(p.returncode, 1)
            self.assertEqual(json.loads(p.stderr)["error"]["code"], "API_VERSION_MISMATCH")
            self.assertEqual(len(app.calls), 1)


if __name__ == "__main__":
    unittest.main(argv=[__file__] + unittest_args)
