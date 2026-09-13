#!/bin/bash
set -euo pipefail

repo=$(realpath "$1")
output=$(realpath -m "$2")
mkdir -p "$output/fixture/rootfs"
cd "$repo"
source ci-automation/ci_automation_common.sh
sudo podman version >"$output/podman-version.txt"

name=sdk-repair-podman
version=1
short="$name:$version"
full="$CONTAINER_REGISTRY/$short"
fixture="$output/fixture"
archive="$name-$version.tar.zst"
cp "$(command -v busybox)" "$fixture/rootfs/busybox"
printf 'podman-produced\n' >"$fixture/rootfs/marker"
tar -C "$fixture/rootfs" -cf "$fixture/rootfs.tar" .
sudo podman import --change 'CMD ["/busybox", "cat", "/marker"]' \
    "$fixture/rootfs.tar" "$short"
sudo podman save "$short" >"$fixture/image.tar"
tar -xOf "$fixture/image.tar" manifest.json >"$output/manifest.json"
jq -e --arg tag "localhost/$short" \
    'any(.[].RepoTags[]?; . == $tag)' "$output/manifest.json"
zstd -q -f "$fixture/image.tar" -o "$fixture/$archive"
(cd "$fixture"; sha512sum "$archive" >"$archive.DIGESTS")

# Archive production and consumption use real engines; only transport is local.
curl() {
    local destination='' url='' arg
    while (($#)); do
        arg=$1
        shift
        case "$arg" in
            --output) destination=$1; shift ;;
            --retry-delay|--retry|--retry-max-time|--connect-timeout) shift ;;
            https://*) url=$arg ;;
        esac
    done
    printf '%s\n' "$url" >>"$requests"
    local file="$fixture/${url##*/}"
    [[ -f $file ]] || return 22
    if [[ -n $destination ]]; then
        cp "$file" "$destination"
    else
        cat "$file"
    fi
}

consumer_docker() {
    [[ ${1:-} != pull ]] || return 1
    [[ ${1:-} != load ]] || printf 'load\n' >>"$loads"
    command docker --context "$consumer" "$@"
}

for consumer in classic containerd; do
    mkdir -p "$output/$consumer/work"
    cd "$output/$consumer/work"
    requests="$output/$consumer/requests.txt"
    loads="$output/$consumer/loads.txt"
    : >"$requests"
    : >"$loads"
    docker=consumer_docker
    docker_image_from_registry_or_buildcache "$name" "$version"
    id=$(consumer_docker image inspect --format '{{.Id}}' "$short")
    [[ $(consumer_docker image inspect --format '{{.Id}}' "$full") = "$id" ]]
    [[ $(docker_image_fullname "$name" "$version") = "$full" ]]
    for tag in "$short" "$full"; do
        [[ $(consumer_docker run --rm "$tag") = podman-produced ]]
    done
    docker_image_from_registry_or_buildcache "$name" "$version"
    [[ $(wc -l <"$loads") -eq 1 ]]
    [[ $(grep -Ec '\.tar\.zst$' "$requests") -eq 1 ]]
    [[ -s "__build__/container-images/$archive.local" ]]
    printf 'Podman -> %s: localhost archive, both aliases, marker and warm skip passed (ID %s)\n' \
        "$consumer" "$id" | tee -a "$output/results.txt"
done
