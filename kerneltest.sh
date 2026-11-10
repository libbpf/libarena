#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1 OR BSD-2-Clause
# Copyright (c) 2026 Meta Platforms, Inc. and affiliates.

set -euo pipefail

usage()
{
	cat <<'EOF'
Usage: ./test.sh <linux-directory> [-- <selftest arguments>]

Build/cache the guest kernel, generate vmlinux.h from its BTF, build
standalone libarena selftests with vendored libbpf, and run them in vmtest.

Environment:
  LIBARENA_TEST_CACHE  Cache directory (default: ~/.cache/libarena-selftests/<id>)
  O / KBUILD_OUTPUT   Kernel build directory (default: <cache>/kernel)
  JOBS                Parallel build jobs (default: nproc)
  CLANG / CC          BPF/selftest and libbpf compilers (default: clang / cc)
  BPFTOOL             Installed bpftool used for BTF and skeleton generation
  ASAN=1              Also build and run the arena ASAN selftests
  REQUIRE_ALL_SELFTESTS=1  Require every ordinary/ASAN test to pass (CI mode)
  VMTEST_ROOTFS       Optional local rootfs archive for vmtest's -l option

This starting point supports native architecture builds only. QEMU, KVM,
sudo image mounts, and the usual kernel/libelf/zlib build dependencies are
required. No kernel selftest sources or kernel-tree libbpf are built.
EOF
}

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
	usage
	exit 0
fi
if [[ $# -eq 0 ]]; then
	usage >&2
	exit 1
fi

LIBARENA_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
LINUXDIR=$(realpath -- "$1")
shift
if [[ ${1:-} == -- ]]; then
	shift
fi
selftest_args=("$@")

VMTEST_SCRIPT="$LINUXDIR/tools/testing/selftests/bpf/vmtest.sh"
if [[ ! -f "$VMTEST_SCRIPT" || ! -f "$LIBARENA_ROOT/vendor/libbpf/src/Makefile" ]]; then
	printf '%s\n' 'Need a Linux checkout with vmtest.sh and an initialized vendor/libbpf submodule.' >&2
	exit 1
fi
if [[ ${PLATFORM:-$(uname -m)} != "$(uname -m)" || -n ${CROSS_COMPILE:-} ]]; then
	printf '%s\n' 'Cross compilation is not supported by this starter script.' >&2
	exit 1
fi

cache_id=$(printf '%s\n' "$LIBARENA_ROOT" "$LINUXDIR" | sha256sum)
CACHE_DIR=$(realpath -m -- "${LIBARENA_TEST_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/libarena-selftests/${cache_id:0:12}}")
O=$(realpath -m -- "${O:-${KBUILD_OUTPUT:-$CACHE_DIR/kernel}}")
export O
export CROSS_COMPILE=""
JOBS=${JOBS:-$(nproc)}
CLANG=${CLANG:-clang}
CC=${CC:-cc}
BPFTOOL=$(command -v "${BPFTOOL:-bpftool}")
ASAN=${ASAN:-0}
REQUIRE_ALL_SELFTESTS=${REQUIRE_ALL_SELFTESTS:-0}
if [[ "$REQUIRE_ALL_SELFTESTS" == 1 && "$ASAN" != 1 ]]; then
	printf '%s\n' 'REQUIRE_ALL_SELFTESTS=1 requires ASAN=1.' >&2
	exit 1
fi
BUILD_DIR="$CACHE_DIR/selftests"
HEADER_DIR="$CACHE_DIR/include"
libbpf_revision=$(git -C "$LIBARENA_ROOT/vendor/libbpf" rev-parse HEAD)
LIBBPF_BUILD="$CACHE_DIR/libbpf/$libbpf_revision"

mkdir -p "$CACHE_DIR" "$O" "$BUILD_DIR" "$HEADER_DIR" "$LIBBPF_BUILD"
# Serialize changes to this cache's kernel build and writable VM image.
exec 9>"$CACHE_DIR/lock"
flock 9

# Reuse upstream VM provisioning, kernel building, and result collection.
# Parameterize its checkout path and defer main() so we can replace the
# kernel-selftest build/staging function. Keep the Linux checkout untouched.
VMTEST_HELPER="$CACHE_DIR/vmtest.sh"
python3 - "$VMTEST_SCRIPT" "$VMTEST_HELPER" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text()
source, checkout_count = re.subn(
    r'^[ \t]*local kernel_checkout=\$\(realpath [^\n]*\)$',
    '\tlocal kernel_checkout="$LINUXDIR"',
    source,
    flags=re.MULTILINE,
)
source, main_count = re.subn(r'^main "\$@"\s*$', '', source, flags=re.MULTILINE)
# Older kernels flatten argv, losing the quoting needed by guest commands.
source, _ = re.subn(
    r'^[ \t]*command="\$@"$',
    '\t\tcommand=$(printf \'%q \' "$@")',
    source,
    flags=re.MULTILINE,
)
if checkout_count != 1 or main_count != 1:
    sys.exit('vmtest.sh layout changed; update the adapter in test.sh.')
pathlib.Path(sys.argv[2]).write_text(source)
PY
# shellcheck source=/dev/null
source "$VMTEST_HELPER"

update_selftests()
{
	# OUTPUT_DIR and MOUNT_DIR are set by the sourced vmtest.sh.
	# shellcheck disable=SC2153
	local mount_dir="$OUTPUT_DIR/$MOUNT_DIR"
	local targets=(selftests)

	# vmtest has now built the kernel, so its vmlinux describes the guest.
	"$BPFTOOL" btf dump file "$O/vmlinux" format c > "$HEADER_DIR/vmlinux.h.tmp"
	mv "$HEADER_DIR/vmlinux.h.tmp" "$HEADER_DIR/vmlinux.h"

	make -C "$LIBARENA_ROOT/vendor/libbpf/src" -j "$JOBS" \
		CC="$CC" BUILD_STATIC_ONLY=1 OBJDIR="$LIBBPF_BUILD" \
		INCLUDEDIR="$HEADER_DIR" UAPIDIR="$HEADER_DIR" \
		all install_headers install_uapi_headers

	if [[ "$ASAN" == 1 ]]; then
		targets+=(test_libarena_asan)
	fi
	# Build outside the checkout. Force BPF/skeleton regeneration because the
	# standalone Makefile does not yet track all header and flag dependencies.
	make -B -C "$BUILD_DIR" -f "$LIBARENA_ROOT/Makefile" -j "$JOBS" \
		LIBARENA="$LIBARENA_ROOT" BPFDIR="$LIBARENA_ROOT" \
		CC="$CC" CLANG="$CLANG" BPFTOOL="$BPFTOOL" \
		INCLUDE_DIR="$HEADER_DIR" LIBBPF_INCLUDE="$HEADER_DIR" \
		BPFOBJ="$LIBBPF_BUILD/libbpf.a" \
		LDLIBS="-lelf -lz -lrt -lpthread -lzstd" \
		BPF_CFLAGS="${BPF_CFLAGS:-} -D__TARGET_ARCH_$ARCH" \
		"${targets[@]}"
	if [[ "$REQUIRE_ALL_SELFTESTS" == 1 ]]; then
		python3 "$LIBARENA_ROOT/.github/vmtest/selftest-programs.py" \
			"$BUILD_DIR/libarena.bpf.o" > "$BUILD_DIR/test_libarena.tests"
		python3 "$LIBARENA_ROOT/.github/vmtest/selftest-programs.py" \
			"$BUILD_DIR/libarena_asan.bpf.o" > "$BUILD_DIR/test_libarena_asan.tests"
	fi

	# Skeletons embed the BPF objects; only the executables need staging.
	mount_image
	sudo install -d "$mount_dir/root/bpf"
	sudo install -m 755 "$BUILD_DIR/test_libarena" "$mount_dir/root/bpf/test_libarena"
	if [[ "$ASAN" == 1 ]]; then
		sudo install -m 755 "$BUILD_DIR/test_libarena_asan" "$mount_dir/root/bpf/test_libarena_asan"
	fi
	if [[ "$REQUIRE_ALL_SELFTESTS" == 1 ]]; then
		sudo install -m 755 "$LIBARENA_ROOT/.github/vmtest/run-selftests.sh" "$mount_dir/root/bpf/run-selftests.sh"
		sudo install -m 644 "$BUILD_DIR/"*.tests "$mount_dir/root/bpf/"
	fi
	unmount_image
}

vmtest_args=(-d "$CACHE_DIR/vmtest" -j "$JOBS")
if [[ -n ${VMTEST_ROOTFS:-} ]]; then
	vmtest_args+=(-l "$(realpath -- "$VMTEST_ROOTFS")")
fi
guest_command=(./test_libarena "${selftest_args[@]}")
if [[ "$ASAN" == 1 ]]; then
	guest_command=(bash -c './test_libarena "$@" && ./test_libarena_asan "$@"' \
		libarena-selftests "${selftest_args[@]}")
fi
if [[ "$REQUIRE_ALL_SELFTESTS" == 1 ]]; then
	guest_command=(./run-selftests.sh "${selftest_args[@]}")
fi

main "${vmtest_args[@]}" -- "${guest_command[@]}"
