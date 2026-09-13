#!/usr/bin/env python3
"""Configuration checks only; does not start containerd or modify the checkout."""
import argparse
import copy
import json
import pathlib
import platform
import subprocess
import sys
import tempfile
import tomllib


parser = argparse.ArgumentParser()
parser.add_argument("repo", type=pathlib.Path)
parser.add_argument("containerd", type=pathlib.Path)
parser.add_argument("output", type=pathlib.Path)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
binary = str(args.containerd.resolve())
source_dir = args.repo / "sdk_container/src/third_party/coreos-overlay/coreos/sysext/containerd/usr/share/containerd"
version = subprocess.run([binary, "--version"], capture_output=True, text=True, timeout=15, check=True).stdout.strip()
results = []


def runtime(config):
    plugins = config["plugins"]
    return plugins.get("io.containerd.cri.v1.runtime", plugins.get("io.containerd.grpc.v1.cri"))


def clean(config):
    result = copy.deepcopy(config)
    result.pop("imports", None)
    return result


def probe(name, source, snippets, create_directory=True):
    with tempfile.TemporaryDirectory(prefix="containerd-pr4150-") as tmp:
        tmp = pathlib.Path(tmp)
        dropins = tmp / "conf.d"
        if create_directory:
            dropins.mkdir()
        for filename, text in snippets.items():
            (dropins / filename).write_text(text)
        rewritten = source.replace('"/etc/containerd/conf.d/*.toml"', json.dumps((dropins / "*.toml").as_posix()))
        config_file = tmp / "config.toml"
        config_file.write_text(rewritten)
        case_dir = args.output / name
        case_dir.mkdir()
        (case_dir / "input.toml").write_text(rewritten)
        (case_dir / "snippets.json").write_text(json.dumps(snippets, indent=2))
        command = [binary, "--config", str(config_file), "config", "dump"]
        process = subprocess.run(command, capture_output=True, text=True, timeout=30)
        (case_dir / "stdout.toml").write_text(process.stdout)
        (case_dir / "stderr.txt").write_text(process.stderr)
        (case_dir / "command.json").write_text(json.dumps(command))
        data = tomllib.loads(process.stdout) if process.returncode == 0 else None
        return process.returncode, data


def record(name, passed, reason=""):
    results.append({"case": name, "passed": bool(passed), "reason": reason})
    print(f"{'PASS' if passed else 'FAIL'} {name} {reason}", flush=True)


log_snippet = 'version = 2\n[plugins."io.containerd.grpc.v1.cri"]\nmax_container_log_line_size = 65536\n'
for filename in ("config.toml", "config-cgroupfs.toml"):
    source = (source_dir / filename).read_text()
    if source.count('imports = ["/etc/containerd/conf.d/*.toml"]') != 1:
        raise SystemExit(f"Expected the repaired import directive in {filename}")
    prefix = filename.removesuffix(".toml")
    code, baseline = probe(prefix + "-absent", source, {}, False)
    record(prefix + "-absent", code == 0)
    if baseline is None:
        continue
    expected_systemd = filename == "config.toml"
    base_runtime = runtime(baseline)
    record(prefix + "-shipped-defaults", baseline["root"] == "/var/lib/containerd" and baseline["state"] == "/run/containerd" and base_runtime["containerd"]["runtimes"]["runc"]["options"]["SystemdCgroup"] == expected_systemd and base_runtime["enable_selinux"] == expected_systemd)
    code, empty = probe(prefix + "-empty", source, {})
    record(prefix + "-empty", code == 0 and clean(empty) == clean(baseline))
    unpatched = source.replace('imports = ["/etc/containerd/conf.d/*.toml"]', '')
    code, ignored = probe(prefix + "-without-import", unpatched, {"50-log.toml": log_snippet})
    record(prefix + "-without-import", code == 0 and clean(ignored) == clean(baseline))
    for label, snippets in (
        ("log", {"50-log.toml": log_snippet}),
        ("ordered", {"10-log.toml": log_snippet.replace("65536", "32768"), "50-log.toml": log_snippet}),
    ):
        code, data = probe(prefix + "-" + label, source, snippets)
        expected = copy.deepcopy(baseline)
        runtime(expected)["max_container_log_line_size"] = 65536
        record(prefix + "-" + label, code == 0 and clean(data) == clean(expected), "all other effective settings preserved")
    code, data = probe(prefix + "-zero", source, {"50-zero.toml": "version = 2\noom_score = 0\n"})
    record(prefix + "-zero", code == 0 and clean(data) == clean(baseline), "native merge keeps existing nonzero OOM score")
    false_snippet = 'version = 2\n[plugins."io.containerd.grpc.v1.cri"]\nenable_selinux = false\n[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]\nSystemdCgroup = false\n'
    code, data = probe(prefix + "-false", source, {"50-false.toml": false_snippet})
    expected = copy.deepcopy(baseline)
    runtime(expected)["enable_selinux"] = False
    runtime(expected)["containerd"]["runtimes"]["runc"]["options"]["SystemdCgroup"] = False
    record(prefix + "-false", code == 0 and clean(data) == clean(expected))
    for label, contents in (("version3", "version = 3\n"), ("version4", "version = 4\n"), ("malformed", "version = 2\n[broken\n")):
        code, data = probe(prefix + "-" + label, source, {"50-invalid.toml": contents})
        record(prefix + "-" + label, code != 0, "unsupported import rejected")

summary = {"containerd": version, "platform": platform.platform(), "scope": "configuration parsing only", "results": results}
(args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
sys.exit(0 if all(item["passed"] for item in results) else 1)
