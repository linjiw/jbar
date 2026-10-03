#!/usr/bin/env python3
"""Measure real-file indexing, process startup and persistent stdio search separately."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import select
import subprocess
import time


def distribution(values):
    ordered = sorted(values)
    return {name: ordered[max(0, math.ceil(len(ordered) * percentile) - 1)]
            for name, percentile in [("p50", .5), ("p95", .95), ("p99", .99), ("max", 1)]}


def signature(response):
    return (response["results"], response["totalMatches"],
            response["totalMatchesIsComplete"], response["hasMoreResults"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path,
                        help="New temporary directory; never replaces existing files")
    parser.add_argument("--items", type=int, default=10000)
    parser.add_argument("--samples", type=int, default=100)
    parser.add_argument("--serve-timeout", type=float, default=30,
                        help="Maximum seconds to wait for each stdio response (default: 30)")
    args = parser.parse_args()
    if not 4 <= args.items <= 100000 or not 1 <= args.samples <= 1000:
        parser.error("items must be 4...100000; samples must be 1...1000")
    if not math.isfinite(args.serve_timeout) or not .1 <= args.serve_timeout <= 180:
        parser.error("serve-timeout must be .1...180 seconds")
    binary = args.binary.resolve(strict=True)
    output = args.output_dir.absolute()
    output.mkdir(mode=0o700)
    root = output / "files"
    root.mkdir(mode=0o700)
    for group in range(100):
        (root / f"group-{group:03}").mkdir(mode=0o700)
    for item in range(args.items):
        name = f"report-{item:06}.pdf" if item % 4 == 0 else f"module-{item:06}.swift"
        (root / f"group-{item % 100:03}" / name).touch(mode=0o600)
    config = output / "config.json"
    config.write_text(json.dumps({"fileRoots": [str(root)], "excludeNames": [],
                                  "excludePaths": [], "downrankNames": []}))
    config.chmod(0o600)
    common = ["--root", str(root), "--config", str(config), "--cache-dir", str(output / "cache")]

    def run(command):
        start = time.perf_counter_ns()
        completed = subprocess.run([str(binary), *command, *common, "--format", "json"],
                                   capture_output=True, text=True, check=True, timeout=180)
        return json.loads(completed.stdout), (time.perf_counter_ns() - start) / 1e6

    indexed, index_wall = run(["index"])
    if not indexed["index"]["complete"] or not indexed["index"]["persisted"]:
        raise RuntimeError("fixture crawl did not produce a complete persisted index")
    query = "report pdf"
    reference, first_wall = run(["search", query])
    expected = (args.items + 3) // 4
    if reference["totalMatches"] != expected or not reference["totalMatchesIsComplete"]:
        raise RuntimeError("fixture search lost expected matches")
    large, _ = run(["search", query, "--limit", "500"])
    if large["returnedCount"] != min(500, expected) or large["totalMatches"] != expected:
        raise RuntimeError("large result limit lost rows or exact matches")
    directory_query = str(root / "group-000") + "/rep"
    directory_reference, _ = run(["search", directory_query])
    directory_expected = (args.items + 99) // 100
    if directory_reference["totalMatches"] != directory_expected or directory_reference["mode"] != "directory":
        raise RuntimeError("snapshot directory search lost expected children")
    one_shot = []
    one_shot_engine = []
    for _ in range(args.samples):
        response, wall = run(["search", query])
        if signature(response) != signature(reference):
            raise RuntimeError("one-shot search result drift")
        one_shot.append(wall)
        one_shot_engine.append(response["elapsedSeconds"] * 1000)

    ready_start = time.perf_counter_ns()
    serve = subprocess.Popen([str(binary), "serve", *common], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    reply_buffer = bytearray()

    def read_reply():
        deadline = time.monotonic() + args.serve_timeout
        while True:
            newline = reply_buffer.find(b"\n")
            if newline >= 0:
                line = bytes(reply_buffer[:newline])
                del reply_buffer[:newline + 1]
                return json.loads(line)
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([serve.stdout], [], [], remaining)[0]:
                raise TimeoutError("CLI stdio response exceeded serve-timeout")
            chunk = os.read(serve.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError("CLI stdio closed before a complete response")
            reply_buffer.extend(chunk)
            if len(reply_buffer) > 8 * 1024 * 1024:
                raise RuntimeError("CLI stdio response exceeded 8 MiB")

    try:
        ready = read_reply()
        if ready["type"] != "ready" or not ready["index"]["complete"]:
            raise RuntimeError("serve did not become ready with a complete index")
        ready_ms = (time.perf_counter_ns() - ready_start) / 1e6

        def request(identifier, text=query, expected_response=reference):
            start = time.perf_counter_ns()
            serve.stdin.write((json.dumps({"id": str(identifier), "query": text, "limit": 40}) + "\n").encode())
            serve.stdin.flush()
            response = read_reply()
            wall = (time.perf_counter_ns() - start) / 1e6
            if response.get("id") != str(identifier) or signature(response) != signature(expected_response):
                raise RuntimeError("stdio search result drift or request ID mismatch")
            return response, wall

        _, serve_first = request("warmup")
        persistent, persistent_engine = [], []
        for sample in range(args.samples):
            response, wall = request(sample)
            persistent.append(wall)
            persistent_engine.append(response["elapsedSeconds"] * 1000)
        _, directory_first = request("directory-first", directory_query, directory_reference)
        directory = []
        for sample in range(args.samples):
            _, wall = request(f"directory-{sample}", directory_query, directory_reference)
            directory.append(wall)
        serve.stdin.write(b'{"id":"done","command":"quit"}\n')
        serve.stdin.flush()
        serve.communicate(timeout=10)
        if serve.returncode != 0:
            raise RuntimeError("serve exited unsuccessfully")
    finally:
        if serve.poll() is None:
            serve.kill()
            serve.communicate()

    snapshot = Path(indexed["index"]["snapshotPath"])
    result = {
        "schemaVersion": 1, "fixtureVersion": 1, "files": args.items,
        "samples": args.samples, "query": query, "exactMatches": expected,
        "correctness": "all one-shot and stdio requests returned identical ordered rows and exact totals",
        "environment": {"machine": platform.machine(), "system": platform.platform(),
                        "binary": str(binary), "binarySha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                        "version": subprocess.check_output([str(binary), "--version"], text=True).strip()},
        "index": {"itemsIncludingDirectories": indexed["index"]["itemCount"],
                  "wallMilliseconds": index_wall, "engineMilliseconds": indexed["startupSeconds"] * 1000,
                  "filesPerSecond": args.items / (index_wall / 1000),
                  "snapshotBytes": snapshot.stat().st_size},
        "oneShotFirstWallMilliseconds": first_wall,
        "oneShotWallMilliseconds": distribution(one_shot),
        "oneShotEngineMilliseconds": distribution(one_shot_engine),
        "serveReadyWallMilliseconds": ready_ms, "serveFirstQueryWallMilliseconds": serve_first,
        "serveWallMilliseconds": distribution(persistent),
        "serveEngineMilliseconds": distribution(persistent_engine),
        "directoryQuery": directory_query, "directoryExactMatches": directory_expected,
        "directoryFirstWallMilliseconds": directory_first,
        "directoryWallMilliseconds": distribution(directory),
        "rawSamples": {"oneShotWallMilliseconds": one_shot, "serveWallMilliseconds": persistent,
                       "directoryWallMilliseconds": directory},
        "notes": ["Empty regular files; filename search only; filesystem and CPU caches may be warm.",
                  "One process per one-shot sample; one long-lived serve process with one unmeasured warm-up.",
                  "No Spotlight comparison; no UI key-to-paint, content indexing, energy or cold-VM measurement."],
    }
    report = output / "report.json"
    report.write_text(json.dumps(result, indent=2) + "\n")
    report.chmod(0o600)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    os.umask(0o077)
    main()
