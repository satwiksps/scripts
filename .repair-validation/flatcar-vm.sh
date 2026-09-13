#!/usr/bin/env bash
# Published Flatcar image plus candidate configs; this does not build an OS image.
set -euo pipefail

repo=$(realpath "${1:?usage: flatcar-vm.sh REPO OUTPUT}")
mkdir -p "${2:?usage: flatcar-vm.sh REPO OUTPUT}"
output=$(realpath "$2")
version=${FLATCAR_VERSION:-4790.0.0}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
base="https://alpha.release.flatcar-linux.net/amd64-usr/$version"
image=flatcar_production_qemu_image.img
temp_root=$(realpath "${RUNNER_TEMP:-/tmp}")
work=$(mktemp -d "$temp_root/flatcar-pr4150.XXXXXXXX")
vm_pid=
ssh_ready=false
ssh_options=()

cleanup() {
    result=$?
    trap - EXIT
    if $ssh_ready; then
        timeout 30s ssh "${ssh_options[@]}" core@127.0.0.1 'sudo journalctl -b -u containerd -u docker --no-pager' > "$output/journal.txt" 2>&1 || true
        timeout 30s ssh "${ssh_options[@]}" core@127.0.0.1 'sudo tar -C /run/pr4150-logs -czf - .' > "$output/guest-logs.tar.gz" 2> "$output/collect-stderr.txt" || true
    fi
    if [[ -n $vm_pid ]]; then
        kill "$vm_pid" 2>/dev/null || true
        for _ in {1..10}; do
            kill -0 "$vm_pid" 2>/dev/null || break
            sleep 1
        done
        kill -KILL "$vm_pid" 2>/dev/null || true
        wait "$vm_pid" 2>/dev/null || true
    fi
    case "$work" in "$temp_root"/flatcar-pr4150.*) rm -rf -- "$work";; esac
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

curl --fail --location --retry 3 --connect-timeout 20 --max-time 600 "$base/$image.bz2" -o "$work/$image.bz2"
curl --fail --location --retry 3 --connect-timeout 20 --max-time 60 "$base/$image.bz2.DIGESTS" -o "$output/image.DIGESTS"
python3 - "$work/$image.bz2" "$output/image.DIGESTS" "$output/image-verification.json" "$base/$image.bz2" <<'PY'
import hashlib, json, pathlib, re, sys
archive, digest_file, output, url = sys.argv[1:]
matches = re.findall(r"^([0-9a-fA-F]{128})\s+\*?" + re.escape(pathlib.Path(archive).name) + r"\s*$", pathlib.Path(digest_file).read_text(), re.M)
if len(matches) != 1:
    raise SystemExit("Expected one official SHA512 digest")
h = hashlib.sha512()
with open(archive, "rb") as stream:
    while data := stream.read(1024 * 1024):
        h.update(data)
if h.hexdigest() != matches[0].lower():
    raise SystemExit("Flatcar image checksum mismatch")
pathlib.Path(output).write_text(json.dumps({"url": url, "sha512": h.hexdigest(), "verified": True}, indent=2) + "\n")
PY
timeout 600s bzip2 -dc "$work/$image.bz2" > "$work/$image"
qemu-img info --output=json "$work/$image" > "$output/image-info.json"
format=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["format"])' "$output/image-info.json")
qemu-img create -f qcow2 -F "$format" -b "$work/$image" "$work/overlay.qcow2"
ssh-keygen -q -t ed25519 -N '' -f "$work/id_ed25519"
python3 - "$repo" "$work/id_ed25519.pub" "$work/ignition.json" <<'PY'
import base64, json, pathlib, sys
repo, public_key, output = map(pathlib.Path, sys.argv[1:])
source = repo / "sdk_container/src/third_party/coreos-overlay/coreos/sysext/containerd/usr/share/containerd"
files = []
for name in ("config.toml", "config-cgroupfs.toml"):
    data = (source / name).read_bytes()
    if b'imports = ["/etc/containerd/conf.d/*.toml"]' not in data:
        raise SystemExit("Candidate config lacks expected imports")
    files.append({"path": "/etc/containerd/pr4150/" + name, "mode": 420, "contents": {"source": "data:;base64," + base64.b64encode(data).decode()}})
config = {"ignition": {"version": "3.4.0"}, "passwd": {"users": [{"name": "core", "sshAuthorizedKeys": [public_key.read_text().strip()]}]}, "storage": {"files": files}, "systemd": {"units": [{"name": "update-engine.service", "mask": True}, {"name": "locksmithd.service", "mask": True}]}}
output.write_text(json.dumps(config))
PY

port=${FLATCAR_SSH_PORT:-2222}
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    acceleration=kvm
    cpu=host
else
    acceleration=tcg
    cpu=max
fi
printf 'image=%s\nacceleration=%s\ncheckout=%s\nscope=published-image-plus-candidate-configs\n' "$version" "$acceleration" "$(git -C "$repo" rev-parse HEAD)" > "$output/scope.txt"
qemu-system-x86_64 -machine "q35,accel=$acceleration" -cpu "$cpu" -smp 2 -m 4096 \
    -drive "if=none,id=os,file=$work/overlay.qcow2,format=qcow2" -device virtio-blk-pci,drive=os,bootindex=1 \
    -netdev "user,id=eth0,hostfwd=tcp:127.0.0.1:$port-:22" -device virtio-net-pci,netdev=eth0 \
    -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0 \
    -fw_cfg "name=opt/org.flatcar-linux/config,file=$work/ignition.json" \
    -display none -monitor none -serial "file:$output/serial.log" -no-reboot \
    > "$output/qemu.log" 2>&1 &
vm_pid=$!
ssh_options=(-i "$work/id_ed25519" -p "$port" -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=no -o "UserKnownHostsFile=$work/known_hosts" -o IdentitiesOnly=yes)
deadline=$((SECONDS + ${FLATCAR_BOOT_TIMEOUT:-900}))
until timeout 8s ssh "${ssh_options[@]}" core@127.0.0.1 true > /dev/null 2>&1; do
    if ! kill -0 "$vm_pid" 2>/dev/null; then
        cat "$output/qemu.log"
        exit 1
    fi
    if (( SECONDS >= deadline )); then
        echo "Flatcar SSH did not become ready before the boot timeout" >&2
        tail -n 80 "$output/serial.log"
        exit 1
    fi
    sleep 5
done
ssh_ready=true

cat > "$work/guest-probes.sh" <<'GUEST'
#!/usr/bin/env bash
set -euxo pipefail
logs=/run/pr4150-logs
mkdir -p "$logs"
cat /etc/os-release > "$logs/os-release.txt"
uname -a > "$logs/uname.txt"
containerd --version > "$logs/containerd-version.txt"
docker --version > "$logs/docker-version.txt"
crictl --version > "$logs/crictl-version.txt"
getenforce > "$logs/selinux.txt" || true
stat -f -c %T /sys/fs/cgroup > "$logs/cgroup-filesystem.txt"
systemctl cat containerd > "$logs/original-unit.txt"
timeout 90s systemctl start containerd
systemctl is-active containerd
containerd --config /usr/share/containerd/config.toml config dump > "$logs/published-config.toml"
systemctl stop docker.service docker.socket || true
[[ ! -e /etc/containerd/conf.d ]]
mkdir -p /run/systemd/system/containerd.service.d

select_config() {
    config="/etc/containerd/pr4150/$1"
    printf '[Service]\nEnvironment=CONTAINERD_CONFIG=%s\nRestart=no\nTimeoutStartSec=60\n' "$config" > /run/systemd/system/containerd.service.d/99-pr4150.conf
    systemctl daemon-reload
    systemctl reset-failed containerd
    timeout 75s systemctl restart containerd
    systemctl is-active --quiet containerd
    pid=$(systemctl show -p MainPID --value containerd)
    tr '\0' ' ' < "/proc/$pid/cmdline" | tee "$logs/selected-command.txt" | grep -F -- "--config $config"
}

check_defaults() {
    grep -Eq "^[[:space:]]*SystemdCgroup = $2$" "$1"
    grep -Eq "^[[:space:]]*enable_selinux = $2$" "$1"
    grep -F 'io.containerd.runc.v2' "$1"
    grep -F '/run/containerd/containerd.sock' "$1"
    grep -F '/var/lib/containerd' "$1"
}

for name in config.toml config-cgroupfs.toml; do
    label=${name%.toml}
    wanted=false
    [[ $name != config.toml ]] || wanted=true
    select_config "$name"
    containerd --config "$config" config dump > "$logs/$label-missing.toml"
    check_defaults "$logs/$label-missing.toml" "$wanted"
    mkdir /etc/containerd/conf.d
    timeout 75s systemctl restart containerd
    containerd --config "$config" config dump > "$logs/$label-empty.toml"
    diff -u <(sed '/^imports =/d' "$logs/$label-missing.toml") <(sed '/^imports =/d' "$logs/$label-empty.toml")
    printf 'version = 2\n[plugins."io.containerd.grpc.v1.cri"]\nmax_container_log_line_size = 65536\n' > /etc/containerd/conf.d/50-log.toml
    restorecon -R /etc/containerd || true
    timeout 75s systemctl restart containerd
    systemctl is-active --quiet containerd
    containerd --config "$config" config dump > "$logs/$label-override.toml"
    grep -Eq '^[[:space:]]*max_container_log_line_size = 65536$' "$logs/$label-override.toml"
    check_defaults "$logs/$label-override.toml" "$wanted"
    rm /etc/containerd/conf.d/50-log.toml
    printf 'version = 2\n[broken\n' > /etc/containerd/conf.d/50-invalid.toml
    if containerd --config "$config" config dump > "$logs/$label-invalid.stdout" 2> "$logs/$label-invalid.stderr"; then
        echo 'Malformed TOML unexpectedly parsed' >&2
        exit 1
    fi
    if timeout 75s systemctl restart containerd; then
        echo 'Containerd unexpectedly started with malformed TOML' >&2
        exit 1
    fi
    ! systemctl is-active --quiet containerd
    rm /etc/containerd/conf.d/50-invalid.toml
    systemctl reset-failed containerd
    timeout 75s systemctl restart containerd
    systemctl is-active --quiet containerd
    containerd --config "$config" config dump > "$logs/$label-recovered.toml"
    diff -u <(sed '/^imports =/d' "$logs/$label-missing.toml") <(sed '/^imports =/d' "$logs/$label-recovered.toml")
    rmdir /etc/containerd/conf.d
done

select_config config.toml
mkdir /etc/containerd/conf.d
printf 'version = 2\n[plugins."io.containerd.grpc.v1.cri"]\nmax_container_log_line_size = 65536\n' > /etc/containerd/conf.d/50-log.toml
restorecon -R /etc/containerd || true
timeout 75s systemctl restart containerd
timeout 90s systemctl start docker
image=docker.io/library/busybox:1.37.0
timeout 180s docker pull "$image"
docker image inspect "$image" > "$logs/docker-image.json"
timeout 90s docker run --rm "$image" echo pr4150-docker-ok | tee "$logs/docker-smoke.txt"
grep -Fx pr4150-docker-ok "$logs/docker-smoke.txt"
cri=(crictl --runtime-endpoint unix:///run/containerd/containerd.sock --image-endpoint unix:///run/containerd/containerd.sock)
timeout 30s "${cri[@]}" info > "$logs/cri-info.json"
timeout 180s "${cri[@]}" pull "$image"
"${cri[@]}" inspecti "$image" > "$logs/cri-image.json"
mkdir -p /var/log/pr4150-cri
printf '%s\n' '{"metadata":{"name":"pr4150","namespace":"validation","uid":"pr4150","attempt":0},"log_directory":"/var/log/pr4150-cri","linux":{"security_context":{"namespace_options":{"network":2}}}}' > /run/pr4150-pod.json
printf '%s\n' '{"metadata":{"name":"smoke","attempt":0},"image":{"image":"docker.io/library/busybox:1.37.0"},"command":["/bin/sh","-c","echo pr4150-cri-ok"],"log_path":"container.log","linux":{}}' > /run/pr4150-container.json
pod=
container=
cleanup_cri() {
    [[ -z $container ]] || "${cri[@]}" rm -f "$container" || true
    [[ -z $pod ]] || "${cri[@]}" stopp "$pod" || true
    [[ -z $pod ]] || "${cri[@]}" rmp -f "$pod" || true
}
trap cleanup_cri EXIT
pod=$(timeout 180s "${cri[@]}" runp /run/pr4150-pod.json)
container=$(timeout 90s "${cri[@]}" create "$pod" /run/pr4150-container.json /run/pr4150-pod.json)
timeout 90s "${cri[@]}" start "$container"
for _ in {1..30}; do
    "${cri[@]}" logs "$container" > "$logs/cri-smoke.txt" 2>&1 || true
    grep -Fxq pr4150-cri-ok "$logs/cri-smoke.txt" && break
    sleep 1
done
grep -Fx pr4150-cri-ok "$logs/cri-smoke.txt"
"${cri[@]}" inspect "$container" > "$logs/cri-container.json"
systemctl cat containerd > "$logs/test-unit.txt"
containerd --config /etc/containerd/pr4150/config.toml config dump > "$logs/final-config.toml"
printf '%s\n' 'PASS: both configs, missing/empty directory, override, malformed failure/recovery, Docker and CRI workloads.' > "$logs/result.txt"
GUEST

timeout 30s ssh "${ssh_options[@]}" core@127.0.0.1 'cat > /home/core/pr4150-probes.sh' < "$work/guest-probes.sh"
timeout 1200s ssh "${ssh_options[@]}" core@127.0.0.1 'sudo bash /home/core/pr4150-probes.sh' 2>&1 | tee "$output/guest-validation.log"
