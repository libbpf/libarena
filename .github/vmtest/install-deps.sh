#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1 OR BSD-2-Clause
# Copyright (c) 2026 Meta Platforms, Inc. and affiliates.

set -euo pipefail

prefix=${1:?usage: install-deps.sh PREFIX}
llvm_version=22
bpftool_commit=83f764e01d7f0cefe1fe3b3405594ed931ed2d37
export DEBIAN_FRONTEND=noninteractive

apt-get -o Acquire::Retries=3 update
apt-get -o Acquire::Retries=3 install -y --no-install-recommends ca-certificates curl gnupg
curl -fsSL --retry 3 https://apt.llvm.org/llvm-snapshot.gpg.key |
	gpg --batch --yes --dearmor -o /usr/share/keyrings/apt.llvm.org.gpg
printf 'deb [signed-by=/usr/share/keyrings/apt.llvm.org.gpg] https://apt.llvm.org/noble/ llvm-toolchain-noble-%s main\n' \
	"$llvm_version" > /etc/apt/sources.list.d/apt.llvm.org.list
apt-get -o Acquire::Retries=3 update
apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
	bc binutils bison build-essential "clang-$llvm_version" cpio dwarves \
	e2fsprogs flex git libcap-dev libelf-dev libssl-dev libzstd-dev \
	"llvm-$llvm_version" make pkg-config python3 qemu-system-x86 \
	zlib1g-dev zstd

mkdir -p "$prefix/bin" "$prefix/src"
ln -sf "/usr/bin/clang-$llvm_version" "$prefix/bin/clang"
ln -sf "/usr/bin/llvm-strip-$llvm_version" "$prefix/bin/llvm-strip"

# Selftests link this repository's vendored libbpf; bpftool builds separately.
git init -q "$prefix/src/bpftool"
git -C "$prefix/src/bpftool" fetch -q --depth 1 https://github.com/libbpf/bpftool.git "$bpftool_commit"
git -C "$prefix/src/bpftool" checkout -q FETCH_HEAD
git -C "$prefix/src/bpftool" submodule update -q --init --depth 1
make -C "$prefix/src/bpftool/src" -j "$(nproc)"
install -m 755 "$prefix/src/bpftool/src/bpftool" "$prefix/bin/bpftool"
"$prefix/bin/bpftool" version
"$prefix/bin/clang" --version
