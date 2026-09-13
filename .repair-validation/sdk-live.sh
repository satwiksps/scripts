#!/bin/bash
set -euo pipefail

repo=$(realpath "$1")
output=$(realpath -m "$2")
mkdir -p "$output"
cd "$repo"
source ci-automation/ci_automation_common.sh
docker version >"$output/docker-version.txt"
for context in classic containerd; do
    docker --context "$context" info >"$output/$context-info.txt"
done

# Only transport is replaced; archive creation, checksums and both daemons are real.
curl() {
    local output_file='' url='' arg
    while (($#)); do
        arg=$1
        shift
        case "$arg" in
            --output) output_file=$1; shift ;;
            --retry-delay|--retry|--retry-max-time|--connect-timeout) shift ;;
            https://*) url=$arg ;;
        esac
    done
    printf '%s\n' "$url" >>"$requests"
    local file="$fixture/${url##*/}"
    [[ -f $file ]] || return 22
    if [[ -n $output_file ]]; then
        cp "$file" "$output_file"
    else
        cat "$file"
    fi
}

consumer_docker() {
    [[ ${1:-} != pull ]] || return 1
    if [[ ${1:-} = load && ${fail_load:-0} = 1 ]]; then
        cat >/dev/null
        return 1
    fi
    command docker --context "$consumer" "$@"
}

publish_fixture() {
    local marker=$1 compression=${2:-zst}
    printf '%s\n' "$marker" >"$fixture/rootfs/marker"
    tar -C "$fixture/rootfs" -cf "$fixture/rootfs.tar" .
    command docker --context "$producer" import \
        --change 'CMD ["/busybox", "cat", "/marker"]' \
        "$fixture/rootfs.tar" "$full"
    producer_id=$(command docker --context "$producer" image inspect --format '{{.Id}}' "$full")
    command docker --context "$producer" save "$full" >"$fixture/image.tar"
    if [[ $compression = zst ]]; then
        zstd -q -f "$fixture/image.tar" -o "$fixture/$name-$version.tar.zst"
    else
        gzip -c "$fixture/image.tar" >"$fixture/$name-$version.tar.gz"
    fi
    (cd "$fixture"; sha512sum "$name-$version.tar.$compression" >"$name-$version.tar.$compression.DIGESTS")
}

assert_image() {
    local expected=$1 short_id full_id actual
    short_id=$(consumer_docker image inspect --format '{{.Id}}' "$short")
    full_id=$(consumer_docker image inspect --format '{{.Id}}' "$full")
    [[ $short_id = "$full_id" ]]
    actual=$(consumer_docker run --rm "$short")
    [[ $actual = "$expected" ]]
    actual=$(consumer_docker run --rm "$full")
    [[ $actual = "$expected" ]]
    [[ $(docker_image_fullname "$name" "$version") = "$full" ]]
}

archive_requests() {
    grep -Ec '\.tar\.(zst|gz)$' "$requests" || true
}

for direction in classic-to-containerd containerd-to-classic; do
    producer=${direction%-to-*}
    consumer=${direction#*-to-}
    fixture="$output/$direction/fixture"
    mkdir -p "$fixture/rootfs" "$output/$direction/work"
    cp /bin/busybox "$fixture/rootfs/busybox"
    requests="$output/$direction/requests.txt"
    : >"$requests"
    cd "$output/$direction/work"
    name="sdk-repair-$direction"
    version=1
    short="$name:$version"
    full="$CONTAINER_REGISTRY/$short"
    docker=consumer_docker
    stamp="__build__/container-images/$name-$version.tar.zst.local"

    publish_fixture first
    docker_image_from_registry_or_buildcache "$name" "$version"
    assert_image first
    consumer_id=$(consumer_docker image inspect --format '{{.Id}}' "$full")
    printf '%s producer=%s consumer=%s\n' "$direction" "$producer_id" "$consumer_id" | tee -a "$output/results.txt"
    [[ $producer_id != "$consumer_id" ]]
    [[ $(archive_requests) = 1 ]]
    docker_image_from_registry_or_buildcache "$name" "$version"
    [[ $(archive_requests) = 1 ]]

    consumer_docker image rm "$short"
    docker_image_from_registry_or_buildcache "$name" "$version"
    assert_image first
    [[ $(archive_requests) = 2 ]]

    printf 'stale\n' >"$fixture/rootfs/marker"
    tar -C "$fixture/rootfs" -cf "$fixture/stale.tar" .
    consumer_docker import --change 'CMD ["/busybox", "cat", "/marker"]' "$fixture/stale.tar" "$short"
    docker_image_from_registry_or_buildcache "$name" "$version"
    assert_image first
    [[ $(archive_requests) = 3 ]]

    publish_fixture second
    docker_image_from_registry_or_buildcache "$name" "$version"
    assert_image second
    [[ $(archive_requests) = 4 ]]

    publish_fixture corrupt-candidate
    printf 'corruption' >>"$fixture/$name-$version.tar.zst"
    if docker_image_from_registry_or_buildcache "$name" "$version"; then
        echo 'Corrupt archive unexpectedly succeeded' >&2
        exit 1
    fi
    [[ ! -e $stamp ]]
    [[ $(archive_requests) = 5 ]]

    publish_fixture third
    fail_load=1
    if docker_image_from_registry_or_buildcache "$name" "$version"; then
        echo 'Injected load failure unexpectedly succeeded' >&2
        exit 1
    fi
    fail_load=0
    [[ ! -e $stamp ]]
    assert_image second
    docker_image_from_registry_or_buildcache "$name" "$version"
    assert_image third

    rm "$fixture/$name-$version.tar.zst" "$fixture/$name-$version.tar.zst.DIGESTS"
    publish_fixture gzip-fallback gz
    docker_image_from_registry_or_buildcache "$name" "$version"
    assert_image gzip-fallback
    [[ -s __build__/container-images/$name-$version.tar.gz.local ]]
    before=$(archive_requests)
    docker_image_from_registry_or_buildcache "$name" "$version"
    [[ $(archive_requests) = "$before" ]]
    rm "__build__/container-images/$name-$version.tar.gz.local"
    docker_image_from_registry_or_buildcache "$name" "$version" & first=$!
    docker_image_from_registry_or_buildcache "$name" "$version" & second=$!
    wait "$first"
    wait "$second"
    [[ $(archive_requests) = $((before + 1)) ]]
    assert_image gzip-fallback
    printf '%s: cold/warm, missing tag, stale tag, changed digest, corrupt archive, failed load, retry, gzip fallback and concurrent loads passed\n' "$direction" | tee -a "$output/results.txt"
done
