#!/usr/bin/env python3
"""macOS C ABI/Git integration: isolated config, local HTTP auth, and remote outcomes.

Requires a built rust/target/debug/liblithe_core.dylib, Git, and a C compiler.
Every child has a local deadline and an owned process group. No user config,
credential store, external service, or application UI is used.
"""
import argparse
import base64
import functools
import http.server
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import socket
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / ".artifacts/test-stability/git-execution-integration.json"
DRIVER = r'''
#include "lithe_core.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static const char *operation;
static void event(const char *json, void *context) {
    (void)context;
    printf("E%s\n", json); fflush(stdout);
    if (strstr(json, "\"type\":\"authentication\"")) {
        char *reply = NULL; size_t size = 0;
        if (getline(&reply, &size, stdin) < 0) { lithe_core_cancel(operation); free(reply); return; }
        if (!strcmp(reply, "cancel\n")) lithe_core_cancel(operation);
        else { char *result = lithe_core_execute_json(reply); lithe_core_free_string(result); }
        memset(reply, 0, size); free(reply);
    }
}
int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "--lithe-git-askpass"))
        return lithe_core_git_askpass(argc > 2 ? argv[2] : "");
    if (getenv("LITHE_GIT_ASKPASS_MODE") && argc == 2) return lithe_core_git_askpass(argv[1]);
    operation = argc > 1 ? argv[1] : "fixture";
    char *request = NULL; size_t size = 0;
    if (getline(&request, &size, stdin) < 0) return 2;
    char *result = lithe_core_execute_json_with_events(request, event, NULL);
    if (!result) { free(request); return 3; }
    printf("R%s\n", result); fflush(stdout);
    lithe_core_free_string(result); free(request); return 0;
}
'''


def run(args, env, cwd=None):
    process = subprocess.Popen(args, cwd=cwd, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True)
    try:
        output, error = process.communicate(timeout=10)
        if process.returncode:
            raise AssertionError(f"Fixture command failed ({process.returncode}): {error.decode(errors='replace')}")
        return output.decode()
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=3)


class Fixture:
    def __init__(self, directory):
        self.directory = directory
        self.env = {**os.environ, "HOME": str(directory), "GIT_CONFIG_GLOBAL": str(directory / "global.conf"),
                    "GIT_CONFIG_NOSYSTEM": "1", "XDG_CONFIG_HOME": str(directory / "xdg"),
                    "GIT_TERMINAL_PROMPT": "0", "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost"}
        for key in list(self.env):
            if key.startswith(("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_", "LITHE_GIT_ASKPASS_")) or key in ["GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS", "GIT_DIR", "GIT_WORK_TREE", "GIT_ASKPASS", "SSH_ASKPASS"]:
                del self.env[key]
        source = directory / "driver.c"
        source.write_text(DRIVER)
        self.driver = directory / "fixture driver"
        library = ROOT / "rust/target/debug"
        run(["xcrun", "--sdk", "macosx", "clang", "-isysroot", run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], self.env).strip(), str(source), "-I", str(ROOT / "rust/lithe-core/include"), "-L", str(library),
             "-llithe_core", f"-Wl,-rpath,{library}", "-o", str(self.driver)], self.env)
        self.repo = directory / "repo"
        self.git("init", str(self.repo))
        self.git("config", "user.name", "Fixture", root=self.repo)
        self.git("config", "user.email", "fixture@example.invalid", root=self.repo)
        self.git("commit", "--allow-empty", "-m", "fixture", root=self.repo)
        self.bare = directory / "remote.git"
        self.git("clone", "--bare", str(self.repo), str(self.bare))
        self.git("branch", "old", root=self.bare)
        self.git("update-server-info", root=self.bare)

    def git(self, *args, root=None):
        return run(["git", *args], self.env, root)

    def call(self, command, payload, preferences=None, answer=None):
        operation = "execution-integration"
        request = {"id": operation, "operationId": operation, "timeoutMilliseconds": 10000,
                   "command": command, "payload": payload,
                   "gitExecution": {"interactive": answer is not None, "detailedFetch": True, **(preferences or {})}}
        process = subprocess.Popen([str(self.driver), operation], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, env=self.env, start_new_session=True)
        events, response, buffer = [], None, b""
        deadline = time.monotonic() + 14
        try:
            process.stdin.write((json.dumps(request) + "\n").encode()); process.stdin.flush()
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                while response is None:
                    remaining = deadline - time.monotonic()
                    assert remaining > 0, "Git execution fixture deadline exceeded"
                    assert selector.select(remaining), "Git execution produced no result before deadline"
                    chunk = os.read(process.stdout.fileno(), 65536)
                    assert chunk, "Git execution ended without a response"
                    buffer += chunk
                    while b"\n" in buffer:
                        line, buffer = buffer.split(b"\n", 1)
                        value = json.loads(line[1:])
                        if line.startswith(b"R"):
                            response = value
                        else:
                            events.append(value)
                            if value["type"] == "authentication":
                                reply = answer(value)
                                data = "cancel" if reply is None else json.dumps({"command": "git.authRespond", "payload": {"requestId": value["requestId"], "answer": reply}})
                                process.stdin.write((data + "\n").encode()); process.stdin.flush()
            _, error = process.communicate(timeout=3)
            assert process.returncode == 0, error.decode()
            assert events[0]["type"] == "requestStarted" and events[-1]["type"] == "requestFinished"
            return response, events
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate(timeout=3)

    def configuration(self):
        payload = {"root": str(self.repo), "scope": "local"}
        before = (self.repo / ".git/config").read_bytes()
        response, _ = self.call("git.executionInspect", payload)
        assert response["ok"], response
        assert response["data"]["fetchSources"]["prune"]["scope"] == "application"
        assert (self.repo / ".git/config").read_bytes() == before
        edit = {**payload, "key": "lithe.fetch.prune", "value": "false", "expectedValues": []}
        response, events = self.call("git.executionConfigure", edit)
        assert response["ok"], response
        assert response["data"]["fetchOptions"]["prune"] is False
        assert response["data"]["fetchSources"]["prune"]["scope"] == "local"
        assert any(event["type"] == "started" and "--replace-all" in event["arguments"] for event in events)
        stale, _ = self.call("git.executionConfigure", {**edit, "value": "true"})
        assert stale["error"]["code"] == "invalid_request"
        assert self.git("config", "--get", "lithe.fetch.prune", root=self.repo).strip() == "false"
        rejected, _ = self.call("git.executionConfigure", {**edit, "key": "credential.helper", "value": "bad"})
        assert rejected["error"]["code"] == "invalid_request"
        cleared, _ = self.call("git.executionConfigure", {**edit, "value": None, "expectedValues": ["false"]})
        assert cleared["ok"] and cleared["data"]["fetchOptions"]["prune"] is True
        global_edit, _ = self.call("git.executionConfigure", {**payload, "scope": "global", "key": "pull.ff", "value": "only", "expectedValues": []})
        assert global_edit["ok"], global_edit
        assert "ff = only" in (self.directory / "global.conf").read_text()
        assert b"log.showSignature" not in (self.repo / ".git/config").read_bytes()
        included = self.directory / "repository-preferences.conf"
        included.write_text('[lithe "fetch"]\nprune = false\n')
        self.git("config", "include.path", str(included), root=self.repo)
        inherited, _ = self.call("git.executionInspect", payload)
        assert inherited["data"]["fetchOptions"]["prune"] is False
        assert inherited["data"]["fetchSources"]["prune"]["origin"].endswith(str(included))
        field = next(field for field in inherited["data"]["fields"] if field["key"] == "lithe.fetch.prune")
        assert field["configuredValues"] == []
        self.git("config", "--unset-all", "include.path", root=self.repo)

    def executable_and_temporary_policy(self):
        selected = shutil.which("git")
        response, events = self.call("git.command", {"root": str(self.repo), "arguments": ["-c", "alias.policyfixture=!git config --get log.showSignature", "policyfixture"]}, {"executable": selected})
        assert response["data"]["stdout"].strip() == "false", response
        started = next(event for event in events if event["type"] == "started")
        assert started["executable"] == selected
        assert ["log.showSignature", "false"] in started["temporaryConfig"]
        old = self.directory / "old-git"
        old.write_text("#!/bin/sh\nprintf 'git version 2.30.0\\n'\n")
        old.chmod(0o700)
        rejected, events = self.call("git.command", {"root": str(self.repo), "arguments": ["status"]}, {"executable": str(old)})
        assert rejected["error"]["code"] == "invalid_request", rejected
        assert not any(event["type"] == "started" for event in events)
        assert b"showSignature" not in (self.repo / ".git/config").read_bytes()

    def ordinary_operations(self):
        repo = self.directory / "ordinary-operations"
        self.git("clone", str(self.bare), str(repo))
        self.git("config", "user.name", "Fixture", root=repo)
        self.git("config", "user.email", "fixture@example.invalid", root=repo)
        path = repo / "notes with spaces.txt"
        path.write_text("initial notes\n")

        def mutation(operation, subcommand, **fields):
            result, events = self.call("git.write", {"root": str(repo), "operation": operation, **fields})
            assert result["ok"] and result["data"]["exitCode"] == 0 and not result["data"].get("operationError"), result
            starts = [event for event in events if event["type"] == "started"]
            commands = [event for event in starts if event["displayArguments"][0] == subcommand]
            assert commands, (operation, starts)
            assert all(Path(event["workingDirectory"]).resolve() == repo.resolve() for event in starts), starts
            assert all(event["globalArguments"] and "--no-pager" not in event["displayArguments"] for event in commands)
            for event in commands:
                finish = next(item for item in events if item["type"] == "finished" and item["invocationId"] == event["invocationId"])
                assert finish["exitCode"] == 0, finish
            return starts

        mutation("stage", "add", paths=[path.name])
        mutation("unstage", "restore", paths=[path.name])
        mutation("stage", "add", paths=[path.name])
        mutation("commit", "commit", message="record ordinary operations")
        mutation("createBranch", "switch", name="console-fixture", reference="HEAD", checkout=True)
        path.write_text("changed notes\n")
        mutation("stashPush", "stash", message="console stash")
        mutation("stashPop", "stash", reference="stash@{0}")
        mutation("discard", "restore", paths=[path.name])
        mutation("publishBranch", "push", name="console-fixture")
        mutation("createWorktree", "worktree", name="console-worktree",
                 gitReference={"kind": "local", "fullName": "refs/heads/console-fixture", "shortName": "console-fixture"},
                 destination=str(self.directory / "console-worktree"))
        # All calls used the same native event path as Fetch; there was no UI
        # action callback or command-specific event producer in this test.

    def remotes(self):
        self.git("remote", "add", "origin", str(self.bare), root=self.repo)
        self.git("remote", "add", "upstream", str(self.bare), root=self.repo)
        self.git("remote", "add", "skip", str(self.directory / "missing.git"), root=self.repo)
        self.git("config", "remote.skip.skipFetchAll", "true", root=self.repo)
        payload = {"root": str(self.repo), "operation": "fetch"}
        plan, _ = self.call("git.fetchPlan", {"root": str(self.repo), "options": {}})
        sample = json.loads((ROOT / "shared/fixtures/git/execution-policy-v1.json").read_text())["repositoryPlan"]
        assert plan["data"]["commands"] == sample["commands"], plan
        response, events = self.call("git.write", payload)
        assert response["ok"] and response["data"]["exitCode"] == 0, response
        # An unset skipFetchAll is a normal internal lookup, not a failed user
        # operation. Verify actual event delivery, not just the final Fetch result.
        starts = [event for event in events if event["type"] == "started"]
        assert len(starts) == 2 and all(event["displayArguments"][0] == "fetch" for event in starts), starts
        assert all(event["exitCode"] == 0 for event in events if event["type"] == "finished"), events
        assert [event["arguments"] for event in starts] == sample["commands"]
        assert all("-c" not in event["displayArguments"] and "--no-pager" not in event["displayArguments"] for event in starts)
        assert all("--no-pager" in event["globalArguments"] for event in starts)
        results = [event for event in events if event["type"] == "remoteResult"]
        assert [event["remote"] for event in results] == ["origin", "upstream"]
        assert all(event["succeeded"] and event["updatedReferenceCount"] > 0 for event in results)
        self.git("branch", "-D", "old", root=self.bare)
        self.git("remote", "add", "broken", str(self.directory / "missing.git"), root=self.repo)
        response, events = self.call("git.write", payload)
        assert response["data"]["operationError"]["code"] == "process_failed", response
        results = [event for event in events if event["type"] == "remoteResult"]
        assert [event["succeeded"] for event in results] == [False, True, True]
        assert results[1]["deletedReferences"] == ["refs/remotes/origin/old"]
        assert results[2]["deletedReferences"] == ["refs/remotes/upstream/old"]
        starts = [event["arguments"] for event in events if event["type"] == "started" and "fetch" in event["arguments"]]
        assert [args[-1] for args in starts] == ["broken", "origin", "upstream"]
        # Suppressing successful/absent configuration lookups must not suppress
        # a real preflight error when inspecting the selected remote.
        self.git("config", "remote.origin.url", "invalid\nremote", root=self.repo)
        invalid, events = self.call("git.write", {**payload, "fetchOptions": {"remote": "origin"}})
        assert not invalid["ok"], invalid
        assert events[-1]["type"] == "requestFinished" and events[-1]["error"], events
        self.git("config", "remote.origin.url", str(self.bare), root=self.repo)

    def authentication(self, retry=False, cancel=False, ssh=False):
        password = "fixture-password"
        if ssh:
            response, events = self.call("git.command", {"root": str(self.repo), "arguments": ["-c", 'alias.askfixture=!"$SSH_ASKPASS" "Enter passphrase for fixture:" >/dev/null', "askfixture"]}, answer=lambda _: password)
            assert response["data"]["exitCode"] == 0, response
            assert any(event["type"] == "authentication" and event["secret"] for event in events)
            assert password not in json.dumps(events)
            return
        authorized = "Basic " + base64.b64encode(f"fixture-user:{password}".encode()).decode()
        class Handler(http.server.SimpleHTTPRequestHandler):
            def do_GET(self):
                if self.headers.get("Authorization") != authorized:
                    self.send_response(401); self.send_header("WWW-Authenticate", 'Basic realm="fixture"'); self.end_headers()
                else:
                    super().do_GET()
            def log_message(self, *args):
                pass
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=str(self.directory)))
        worker = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        worker.start()
        retried = False
        def answer(event):
            nonlocal retried
            if cancel: return None
            if event.get("retry"):
                retried = True
                return "retry"
            if not event["secret"]: return "fixture-user"
            return "fixture-wrong-password" if retry and not retried else password
        try:
            if retry:
                self.git("config", "--global", "credential.helper", "!printf 'username=fixture-user\\npassword=fixture-wrong-password\\n'")
            destination = self.directory / ("clone-retry" if retry else "clone-cancel" if cancel else "clone")
            response, events = self.call("git.write", {"root": str(self.directory), "operation": "clone", "remote": f"http://127.0.0.1:{server.server_port}/remote.git", "destination": str(destination)}, {"useCredentialHelper": retry}, answer)
            if cancel:
                assert response["error"]["code"] == "cancelled", response
            else:
                assert response["ok"] and response["data"]["exitCode"] == 0, response
                assert (destination / ".git").is_dir()
                assert retried == retry
                if retry:
                    assert next(event for event in events if event["type"] == "authentication").get("retry") is True
                    assert "fixture-wrong-password" in self.git("config", "--global", "--get", "credential.helper")
                assert len([e for e in events if e["type"] == "started"]) == (2 if retry else 1)
            assert password not in json.dumps(events) and "fixture-wrong-password" not in json.dumps(events)
        finally:
            server.shutdown(); server.server_close(); worker.join(timeout=2)
            assert not worker.is_alive(), "Local authentication server did not stop"
            if retry: self.git("config", "--global", "--unset-all", "credential.helper")

    def application_helper(self, executable):
        for explicit in [False, True]:
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0)); listener.listen(1); listener.settimeout(5)
                env = {**self.env, "LITHE_GIT_ASKPASS_MODE": "1", "LITHE_GIT_ASKPASS_TOKEN": "fixture-application-token",
                       "LITHE_GIT_ASKPASS_ADDRESS": "127.0.0.1:" + str(listener.getsockname()[1])}
                arguments = [str(executable), *(["--lithe-git-askpass"] if explicit else []), "Password for app fixture:"]
                child = subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, start_new_session=True)
                try:
                    peer, _ = listener.accept()
                    with peer:
                        peer.settimeout(2)
                        frame = b""
                        while not frame.endswith(b"\n"):
                            chunk = peer.recv(1024)
                            assert chunk and len(frame) < 16384
                            frame += chunk
                        request = json.loads(frame)
                        assert request["token"] == "fixture-application-token"
                        assert request["prompt"] == "Password for app fixture:"
                        peer.sendall(b"fixture-app-answer\n")
                    output, error = child.communicate(timeout=5)
                    assert child.returncode == 0 and output == b"fixture-app-answer\n", error.decode()
                finally:
                    if child.poll() is None:
                        os.killpg(child.pid, signal.SIGKILL); child.communicate(timeout=3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--application", type=Path, help="Also verify the built macOS app exits through AskPass before UI startup")
    arguments = parser.parse_args()
    tests = []
    try:
        with tempfile.TemporaryDirectory(prefix="lithe-execution-integration-") as directory:
            fixture = Fixture(Path(directory))
            cases = [("configuration_scope_precedence_and_stale_save", fixture.configuration),
                     ("executable_capabilities_and_temporary_policy", fixture.executable_and_temporary_policy),
                     ("per_remote_preview_partial_success_and_pruning", fixture.remotes),
                     ("ordinary_git_operations_emit_commands_and_folded_options", fixture.ordinary_operations),
                     ("http_askpass_credentials", lambda: fixture.authentication()),
                     ("http_explicit_authentication_retry", lambda: fixture.authentication(retry=True)),
                     ("authentication_cancellation", lambda: fixture.authentication(cancel=True)),
                     ("ssh_askpass_executes_path_with_spaces", lambda: fixture.authentication(ssh=True))]
            if arguments.application:
                cases.append(("built_application_early_askpass_modes", lambda: fixture.application_helper(arguments.application.resolve())))
            for name, case in cases:
                started = time.monotonic()
                record = {"target": "git-execution-integration", "name": name, "status": "failed"}
                try:
                    case()
                    assert time.monotonic() - started < 15, "Integration case exceeded its 15-second budget"
                    record["status"] = "passed"
                finally:
                    record["durationMs"] = round((time.monotonic() - started) * 1000)
                    tests.append(record)
                    print(f'{record["status"]}: {name} ({record["durationMs"]}ms)', flush=True)
    finally:
        REPORT.parent.mkdir(parents=True, exist_ok=True)
        REPORT.write_text(json.dumps({"schemaVersion": 1, "runner": "macOS · Git C ABI integration", "package": "git-execution-c-abi-integration", "warnMs": 5000, "maxMs": 15000, "tests": tests}, indent=2) + "\n")


if __name__ == "__main__":
    main()
