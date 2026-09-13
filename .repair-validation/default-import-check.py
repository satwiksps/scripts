#!/usr/bin/env python3
"""Compare exact Flatcar configs using the real containerd import directory."""
import argparse
import copy
import hashlib
import json
import os
import pathlib
import platform
import subprocess
import sys
import tomllib


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("baseline", type=pathlib.Path)
parser.add_argument("candidate", type=pathlib.Path)
parser.add_argument("containerd", type=pathlib.Path)
parser.add_argument("output", type=pathlib.Path)
args = parser.parse_args()
args.output = args.output.resolve()
args.output.mkdir(parents=True, exist_ok=True)
binary = str(args.containerd.resolve())
dropins = pathlib.Path("/etc/containerd/conf.d")
snippet = dropins / "95-pr4150-check.toml"
contents = 'version = 2\n[plugins."io.containerd.grpc.v1.cri"]\nmax_container_log_line_size = 65536\n'
summary = {
    "scope": "Linux configuration parsing only; no daemon started or restarted",
    "platform": platform.platform(),
    "dropin_directory": str(dropins),
    "snippet_path": str(snippet),
    "snippet_contents": contents,
    "sources": {},
    "results": [],
}
created_dirs = []
owned_snippet = None


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def runtime(config):
    return config["plugins"]["io.containerd.cri.v1.runtime"]


def effective(config):
    result = copy.deepcopy(config)
    result.pop("imports", None)
    return result


def probe(name, path, expected=None, systemd=False):
    directory = args.output / name
    directory.mkdir(exist_ok=True)
    command = [binary, "--config", str(path), "config", "dump"]
    write_json(directory / "command.json", command)
    process = subprocess.run(command, capture_output=True, text=True, timeout=30)
    (directory / "stdout.toml").write_text(process.stdout, encoding="utf-8")
    (directory / "stderr.txt").write_text(process.stderr, encoding="utf-8")
    record = {"case": name, "returncode": process.returncode, "passed": False}
    summary["results"].append(record)
    if process.returncode != 0:
        raise RuntimeError(f"{name}: config dump failed ({process.returncode})")
    data = tomllib.loads(process.stdout)
    cri = runtime(data)
    record.update({
        "log_limit": cri["max_container_log_line_size"],
        "enable_selinux": cri["enable_selinux"],
        "systemd_cgroup": cri["containerd"]["runtimes"]["runc"]["options"]["SystemdCgroup"],
    })
    if expected is None:
        record["passed"] = (
            record["log_limit"] == 16384
            and record["enable_selinux"] == systemd
            and record["systemd_cgroup"] == systemd
            and data["root"] == "/var/lib/containerd"
            and data["state"] == "/run/containerd"
        )
    else:
        record["passed"] = effective(data) == effective(expected)
        record["comparison"] = "all effective settings except imports"
    print(f"{'PASS' if record['passed'] else 'FAIL'} {name}: {record}", flush=True)
    return data


try:
    if sys.platform != "linux" or os.geteuid() != 0:
        raise RuntimeError("Run on Linux with sudo; the test uses /etc/containerd/conf.d")
    if dropins.parent.is_symlink() or dropins.is_symlink():
        raise RuntimeError("Refusing a symlinked containerd configuration directory")
    if list(dropins.glob("*.toml")) or snippet.is_symlink():
        raise RuntimeError("Existing /etc/containerd/conf.d/*.toml entries; refusing to run")
    summary["initial_directory_exists"] = dropins.exists()
    version_command = [binary, "--version"]
    version = subprocess.run(version_command, capture_output=True, text=True, timeout=15, check=True)
    summary["version_command"] = version_command
    summary["containerd"] = version.stdout.strip()
    if " v2.3.4 " not in summary["containerd"]:
        raise RuntimeError("This check requires the official containerd v2.3.4 binary")
    paths = {}
    baseline = {}
    for filename in ("config.toml", "config-cgroupfs.toml"):
        prefix = filename.removesuffix(".toml")
        for label in ("baseline", "candidate"):
            path = (getattr(args, label) / filename).resolve(strict=True)
            payload = path.read_bytes()
            parsed = tomllib.loads(payload.decode("utf-8"))
            expected_imports = None if label == "baseline" else [str(dropins / "*.toml")]
            if parsed.get("version") != 2 or parsed.get("imports") != expected_imports:
                raise RuntimeError(f"Unexpected version or imports in {path}")
            source = args.output / f"{prefix}-{label}-source.toml"
            source.write_bytes(payload)
            summary["sources"][f"{prefix}-{label}"] = {
                "path": str(path),
                "sha256": hashlib.sha256(payload).hexdigest(),
                "git_blob": hashlib.sha1(f"blob {len(payload)}\0".encode() + payload).hexdigest(),
            }
            paths[(filename, label)] = path
        baseline[filename] = probe(prefix + "-original-no-snippet", paths[(filename, "baseline")], systemd=filename == "config.toml")
        probe(prefix + "-candidate-no-snippet", paths[(filename, "candidate")], baseline[filename])
    for directory in (dropins.parent, dropins):
        if not directory.exists():
            directory.mkdir()
            created_dirs.append(directory)
    if list(dropins.glob("*.toml")):
        raise RuntimeError("A drop-in appeared during testing; refusing to create the fixture")
    for filename in baseline:
        probe(filename.removesuffix(".toml") + "-candidate-empty-directory", paths[(filename, "candidate")], baseline[filename])
    with snippet.open("x", encoding="utf-8") as stream:
        stat = os.fstat(stream.fileno())
        owned_snippet = (stat.st_dev, stat.st_ino)
        stream.write(contents)
    for filename in baseline:
        prefix = filename.removesuffix(".toml")
        probe(prefix + "-original-with-real-dropin", paths[(filename, "baseline")], baseline[filename])
        expected = copy.deepcopy(baseline[filename])
        runtime(expected)["max_container_log_line_size"] = 65536
        probe(prefix + "-candidate-with-real-dropin", paths[(filename, "candidate")], expected)
except Exception as error:
    summary["error"] = f"{type(error).__name__}: {error}"
    print(summary["error"], file=sys.stderr, flush=True)
finally:
    try:
        if owned_snippet is not None:
            stat = snippet.lstat()
            if (stat.st_dev, stat.st_ino) != owned_snippet:
                raise RuntimeError("Fixture was replaced; refusing to remove another file")
            snippet.unlink()
        for directory in reversed(created_dirs):
            directory.rmdir()
        summary["cleanup"] = "Removed only the created snippet and empty directories"
    except Exception as error:
        summary["cleanup_error"] = f"{type(error).__name__}: {error}"
    summary["passed"] = sum(result["passed"] for result in summary["results"])
    summary["failed"] = len(summary["results"]) - summary["passed"]
    summary["success"] = (
        len(summary["results"]) == 10
        and summary["failed"] == 0
        and "error" not in summary
        and "cleanup_error" not in summary
    )
    write_json(args.output / "summary.json", summary)
sys.exit(0 if summary["success"] else 1)
