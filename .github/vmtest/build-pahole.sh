#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1 OR BSD-2-Clause
# Copyright (c) 2026 Meta Platforms, Inc. and affiliates.

set -euo pipefail

archive=$(realpath -m "${1:?usage: build-pahole.sh <archive>}")
export DEBIAN_FRONTEND=noninteractive

apt_update=(apt-get -o Acquire::Retries=3 update)
apt_install=(apt-get -o Acquire::Retries=3 -y --no-install-recommends install)

"${apt_update[@]}"
"${apt_install[@]}" build-essential cmake elfutils git libdw-dev libelf-dev zlib1g-dev

work_dir=$(mktemp -d)
trap 'rm -rf -- "$work_dir"' EXIT
pahole_dir="$work_dir/pahole"
stage_dir="$work_dir/stage"
mkdir -p "$pahole_dir" "$stage_dir" "$(dirname "$archive")"

git -C "$pahole_dir" init
git -C "$pahole_dir" remote add origin https://git.kernel.org/pub/scm/devel/pahole/pahole.git
git -C "$pahole_dir" fetch --depth=1 origin master
git -C "$pahole_dir" checkout FETCH_HEAD

cmake -S "$pahole_dir" -B "$pahole_dir/build" -DCMAKE_INSTALL_PREFIX=/usr
make -C "$pahole_dir/build" -j "$(nproc)"
DESTDIR="$stage_dir" make -C "$pahole_dir/build" install
tar -C "$stage_dir" -czf "$archive" usr
