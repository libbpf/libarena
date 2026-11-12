#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1 OR BSD-2-Clause
# Copyright (c) 2026 Meta Platforms, Inc. and affiliates.

set -euo pipefail

linux_dir="$RUNNER_TEMP/linux"
git init -q "$linux_dir"
git -C "$linux_dir" fetch --depth 1 "$KERNEL_REPOSITORY" "$KERNEL_REVISION"
git -C "$linux_dir" checkout --detach FETCH_HEAD

WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

# Hack to avoid building kernel selftests, see kerneltest.sh for details.
MKOVERRIDE="$WORK_DIR"/override.mk
VMTEST=(env MAKEFILES="$MKOVERRIDE" "$linux_dir/tools/testing/selftests/bpf/vmtest.sh")

printf '%s\n' 'ifneq ($(filter %/tools/testing/selftests/bpf,$(CURDIR)),)' \
	'override TRUNNER_TEST_OBJS :=' '.DEFAULT_GOAL = $(DEFAULT_BPFTOOL)' \
	'endif' > "$MKOVERRIDE"

"${VMTEST[@]}" -- true

tar --zstd -cf "$RUNNER_TEMP/kernel.tar.zst" \
	-C "$RUNNER_TEMP" linux kernel-build \
	-C "$HOME/.bpf_selftests" latest.config
