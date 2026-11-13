#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1 OR BSD-2-Clause
# Copyright (c) 2026 Meta Platforms, Inc. and affiliates.

set -euo pipefail

## Argument parsing

usage()
{
	echo 'Usage: ./kerneltest.sh <linux-directory> [-- <selftest arguments>]'
}

if [[ ${1:-} == -h || ${1:-} == --help || $# -eq 0 ]]; then
	usage >&2
	exit 0
fi

# Only native x86_64/aarch64 testing supported
case $(uname -m) in
	x86_64) target_arch=x86 ;;
	aarch64) target_arch=arm64 ;;
	*) printf 'Unsupported architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
esac

LIBARENA_ROOT=$PWD
LINUXDIR=$1
shift
if [[ ${1:-} == -- ]]; then
	shift
fi
selftest_args=("$@")
test_targets=(selftests)
if [[ ${ASAN:-1} == 1 ]]; then
	test_targets+=(test_libarena_asan)
fi

## Identifying working and source directories

KERNEL_SELFTESTS="$LINUXDIR/tools/testing/selftests/bpf"
KERNEL_BUILD_DIR=${O:-${KBUILD_OUTPUT:-$LINUXDIR}}
if [[ -n ${O:-} ]]; then
	KERNEL_SELFTEST_OUTPUT=$KERNEL_BUILD_DIR
else
	KERNEL_SELFTEST_OUTPUT=$KERNEL_SELFTESTS
fi
BPFTOOL="$KERNEL_SELFTEST_OUTPUT/tools/sbin/bpftool"
LIBBPF_INCLUDE="$KERNEL_SELFTEST_OUTPUT/tools/include"
BPFOBJ="$KERNEL_SELFTEST_OUTPUT/tools/build/libbpf/libbpf.a"

# Generic scratch space
WORK_DIR=$(mktemp -d)
BUILD_DIR="$WORK_DIR/selftests"
HEADER_DIR="$WORK_DIR/include"

# Where we put the selftests for vmtest.sh to copy into test VM
STAGE_DIR=
cleanup()
{
	if [[ -n "$STAGE_DIR" ]]; then
		rm -rf -- "$STAGE_DIR"
	fi
	rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT
mkdir -p "$BUILD_DIR" "$HEADER_DIR"

# Hack to avoid having to build the kernel selftests. Write a Makefile
# fragment that overrides the target in the kernel selftests Makefile,
# and only builds libbpf/bpftool instead of all the selftests. Extra
# important when using Clang 23, because some of them fail to compile.
MKOVERRIDE="$WORK_DIR"/override.mk
VMTEST=(env MAKEFILES="$MKOVERRIDE" "$KERNEL_SELFTESTS/vmtest.sh")

printf '%s\n' 'ifneq ($(filter %/tools/testing/selftests/bpf,$(CURDIR)),)' \
	'override TRUNNER_TEST_OBJS :=' '.DEFAULT_GOAL = $(DEFAULT_BPFTOOL)' \
	'endif' > "$MKOVERRIDE"

## Generating vmlinux.h

# Trigger a kernel build. "-- true" is a dummy cmdline because
# vmtest.sh always runs the compiled kernel after building and
# the default is ./test_progs that we don't care about.
"${VMTEST[@]}" -- true

"$BPFTOOL" btf dump file "$KERNEL_BUILD_DIR/vmlinux" format c > "$HEADER_DIR/vmlinux.h"

# Build outside the checkout. Force BPF/skeleton regeneration because the
# standalone Makefile does not yet track all header and flag dependencies.
make -B -C "$BUILD_DIR" -f "$LIBARENA_ROOT/Makefile" -j "$(nproc)" \
	LIBARENA="$LIBARENA_ROOT" BPFDIR="$LIBARENA_ROOT" \
	BPFTOOL="$BPFTOOL" \
	INCLUDE_DIR="$HEADER_DIR" LIBBPF_INCLUDE="$LIBBPF_INCLUDE" \
	BPFOBJ="$BPFOBJ" \
	LDLIBS="-lelf -lz -lrt -lpthread -lzstd" \
	BPF_CFLAGS="${BPF_CFLAGS:-} -D__TARGET_ARCH_$target_arch" \
	EXTRA_CFLAGS=-Werror \
	"${test_targets[@]}"

# vmtest copies this tree into the guest. Use a temporary hidden directory so
# the kernel checkout is restored after the run.
STAGE_DIR=$(mktemp -d "$KERNEL_SELFTESTS/.libarena-standalone.XXXXXX")
cp "$BUILD_DIR"/test_libarena* \
	"$LIBARENA_ROOT/selftests/run-selftests.sh" "$STAGE_DIR"

guest_stage="./$(basename "$STAGE_DIR")"
"${VMTEST[@]}" -- \
	bash "$guest_stage/run-selftests.sh" "${selftest_args[@]}"
