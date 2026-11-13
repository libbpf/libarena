#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1 OR BSD-2-Clause
# Copyright (c) 2026 Meta Platforms, Inc. and affiliates.

set -euo pipefail

llvm_version=${1:-}
export DEBIAN_FRONTEND=noninteractive

# Common apt commands
apt_update=(apt-get -o Acquire::Retries=3 update)
apt_install=(apt-get -o Acquire::Retries=3 -y --no-install-recommends install)

# Basic dependencies
"${apt_update[@]}"
"${apt_install[@]}" bc binutils bison build-essential ca-certificates cpio curl e2fsprogs \
	flex git gnupg libcap-dev libdw1 libelf-dev libssl-dev libzstd-dev \
	make pkg-config python3 python3-docutils qemu-system-x86 zlib1g-dev zstd

# Kernel builds don't need LLVM.
if [[ -z "$llvm_version" ]]; then
	exit 0
fi

curl -fsSL --retry 3 https://apt.llvm.org/llvm-snapshot.gpg.key |
	gpg --batch --yes --dearmor -o /usr/share/keyrings/apt.llvm.org.gpg
printf 'deb [signed-by=/usr/share/keyrings/apt.llvm.org.gpg] https://apt.llvm.org/noble/ llvm-toolchain-noble-%s main\n' \
	"$llvm_version" > /etc/apt/sources.list.d/apt.llvm.org.list

"${apt_update[@]}"
"${apt_install[@]}" "clang-$llvm_version" "lld-$llvm_version" "llvm-$llvm_version"

"/usr/lib/llvm-$llvm_version/bin/clang" --version
