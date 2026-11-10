#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1 OR BSD-2-Clause
# Copyright (c) 2026 Meta Platforms, Inc. and affiliates.

set -euo pipefail

resolve_stable()
{
	local release

	repository=https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
	release=$(git ls-remote --tags --refs "$repository" "refs/tags/v$kernel")
	if [[ -z "$release" ]]; then
		printf 'No release found for kernel %s\n' "$kernel" >&2
		exit 1
	fi
	revision=$(printf '%s\n' "$release" | cut -f1)
	version=$kernel
}

resolve_bpf_next()
{
	repository=https://git.kernel.org/pub/scm/linux/kernel/git/bpf/bpf-next.git
	revision=$(git ls-remote "$repository" refs/heads/master | awk '{ print $1 }')
	version=bpf-next
}

kernel=${1:?usage: kernel-ref.sh 6.16|7.1|bpf-next}
case "$kernel" in
	6.16|7.1)
		resolve_stable
		;;
	bpf-next)
		resolve_bpf_next
		;;
	*)
		printf 'Unknown kernel: %s\n' "$kernel" >&2
		exit 1
		;;
esac
if [[ ! "$revision" =~ ^[[:xdigit:]]{40}$ ]]; then
	printf 'Invalid kernel revision: %s\n' "$revision" >&2
	exit 1
fi
printf 'repository=%s\nrevision=%s\nversion=%s\n' "$repository" "$revision" "$version"
