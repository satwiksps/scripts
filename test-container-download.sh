#!/bin/bash
# Copyright (c) 2026 The Flatcar Maintainers.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

set -euo pipefail

source ci-automation/ci_automation_common.sh

mkdir -p __build__
test_dir=$(realpath "$(mktemp -d __build__/test-container-download.XXXXXXXX)")
[[ ${test_dir} = "$(pwd -P)/__build__/test-container-download."* ]]
trap 'rm -rf "${test_dir}"' EXIT

function fail() {
    echo "FAIL: ${*}" >&2
    exit 1
}

function assert_equal() {
    [[ ${1} = "${2}" ]] || fail "expected '${1}', got '${2}'"
}

function image_file() {
    local image=${1//\//_}
    echo "${state}/images/${image//:/_}"
}

function mock_docker() {
    local image id
    case ${1} in
        pull) return 1;;
        images)
            [[ ! -f $(image_file "${2}") ]] || echo "${2}"
            ;;
        image)
            cat "$(image_file "${@: -1}")"
            ;;
        load)
            echo load >>"${state}/loads"
            cat >"${state}/loaded.tar"
            [[ ${fail_load} = false ]] || return 1
            image=$(tar -xOf "${state}/loaded.tar" manifest.json | jq -r '.[0].RepoTags[0]')
            id=$(tar -xOf "${state}/loaded.tar" config.json | sha256sum)
            printf 'sha256:%s\n' "${id%% *}" >"$(image_file "${image}")"
            echo "Loaded image: ${image}"
            ;;
        tag)
            [[ ${fail_tag} = false ]] || return 1
            printf '%s\n' "${2}" >"$(image_file "${3}")"
            ;;
        *) fail "unexpected Docker command: ${*}";;
    esac
}

function curl() {
    local url=${!#} output='' server
    while [[ $# -gt 0 ]]; do
        if [[ ${1} = --output ]]; then
            output=${2}
            shift
        fi
        shift
    done
    echo "${url}" >>"${state}/requests"
    case ${url} in
        "https://${BUILDCACHE_SERVER}/"*) server=bincache;;
        'https://mirror.release.flatcar-linux.net/'*) server=release;;
        *) fail "unexpected URL: ${url}";;
    esac
    local file="${state}/${server}/${url##*/}"
    [[ -f ${file} ]] || return 22
    if [[ -n ${output} ]]; then
        cp "${file}" "${output}"
    else
        cat "${file}"
    fi
}

function make_archive() {
    local server=${1} tag=${2} content=${3} compr=${4:-zst}
    local dir="${state}/${server}" tgz="sdk-1.tar.${compr}"
    printf '%s\n' "${content}" >"${dir}/config.json"
    jq -n --arg tag "${tag}" '[{Config: "config.json", RepoTags: [$tag], Layers: []}]' >"${dir}/manifest.json"
    tar -C "${dir}" -cf "${dir}/image.tar" manifest.json config.json
    case ${compr} in
        zst) zstd -q -f "${dir}/image.tar" -o "${dir}/${tgz}";;
        gz) gzip -c "${dir}/image.tar" >"${dir}/${tgz}";;
    esac
    local digest
    digest=$(sha512sum "${dir}/${tgz}")
    printf '%s  %s\n' "${digest%% *}" "${tgz}" >"${dir}/${tgz}.DIGESTS"
}

function download() {
    docker_image_from_registry_or_buildcache sdk 1
}

function assert_loads() {
    assert_equal "${1}" "$(wc -l <"${state}/loads" | tr -d ' ')"
}

function assert_uncached() {
    [[ ! -f __build__/container-images/sdk-1.tar.zst.local ]] || fail 'cached a failed load'
    if grep -q 'sdk-1.tar.gz' "${state}/requests"; then
        fail 'retried an invalid archive as gzip'
    fi
}

function repeat() {
    download
    download
    assert_loads 1
    assert_equal "$(cat "$(image_file "${full_image}")")" "$(cat "$(image_file sdk:1)")"
    assert_equal "${full_image}" "$(docker_image_fullname sdk 1)"
}

function rebuild() {
    download
    local previous
    previous=$(cat "$(image_file "${full_image}")")
    make_archive bincache "${full_image}" rebuilt
    download
    download
    assert_loads 2
    [[ $(cat "$(image_file "${full_image}")") != "${previous}" ]] || fail 'kept old image'
}

function retag() {
    download
    local image expected
    expected=$(cat "$(image_file "${full_image}")")
    for image in sdk:1 "${full_image}"; do
        echo replaced >"$(image_file "${image}")"
        download
        assert_equal "${expected}" "$(cat "$(image_file "${image}")")"
    done
    download
    assert_loads 3
}

function bad_archive() {
    echo damaged >>"${state}/bincache/sdk-1.tar.zst"
    download && fail 'accepted incorrect digest'
    assert_loads 0
    assert_uncached
}

function failed_load() {
    echo stale >"$(image_file sdk:1)"
    echo stale >"$(image_file "${full_image}")"
    fail_load=true
    download && fail 'ignored load failure'
    assert_equal stale "$(cat "$(image_file "${full_image}")")"
    assert_uncached
    fail_load=false
    download
    download
    assert_loads 2
    [[ $(cat "$(image_file "${full_image}")") != stale ]] || fail 'kept stale image'
}

function failed_tag() {
    fail_tag=true
    download && fail 'ignored tag failure'
    assert_uncached
}

function short_tag() {
    make_archive bincache sdk:1 original
    echo stale >"$(image_file "${full_image}")"
    repeat
}

function localhost_tag() {
    make_archive bincache localhost/sdk:1 original
    repeat
}

function mirror_pair() {
    rm "${state}/bincache/sdk-1.tar.zst"
    make_archive release "${full_image}" mirrored
    download
    assert_loads 1
    assert_equal mirrored "$(tar -xOf "${state}/loaded.tar" config.json)"
}

function gzip_fallback() {
    rm "${state}/bincache/sdk-1.tar.zst.DIGESTS"
    make_archive bincache "${full_image}" original gz
    download
    download
    assert_loads 1
    [[ -f __build__/container-images/sdk-1.tar.gz.local ]] || fail 'missing gzip stamp'
}

function wrong_tag() {
    make_archive bincache unrelated:1 original
    download && fail 'accepted unrelated tag'
    assert_loads 0
    assert_uncached
}

function bad_metadata() {
    echo invalid >"${state}/bincache/sdk-1.tar.zst.DIGESTS"
    download && fail 'accepted invalid digest metadata'
    assert_loads 0
    assert_uncached
}

for testcase in repeat rebuild retag bad_archive failed_load failed_tag short_tag localhost_tag mirror_pair gzip_fallback wrong_tag bad_metadata; do
    (
        state="${test_dir}/${testcase}"
        mkdir -p "${state}"/{images,bincache,release}
        : >"${state}/loads"
        : >"${state}/requests"
        cd "${state}"
        docker=mock_docker
        fail_load=false fail_tag=false
        full_image="${CONTAINER_REGISTRY}/sdk:1"
        make_archive bincache "${full_image}" original
        "${testcase}"
        echo "PASS: ${testcase}"
    )
done
