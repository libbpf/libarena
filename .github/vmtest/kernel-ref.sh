#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1 OR BSD-2-Clause
# Copyright (c) 2026 Meta Platforms, Inc. and affiliates.

set -euo pipefail

kernel=${1:?usage: kernel-ref.sh 6.16|7.1|bpf-next}
case "$kernel" in
	6.16|7.1)
		repository=https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
		tags=$(git ls-remote --tags --refs "$repository" "refs/tags/v$kernel" "refs/tags/v$kernel.*")
		version=$(printf '%s\n' "$tags" | sed -n 's|.*refs/tags/v\([0-9.]*\)$|\1|p' | sort -V | tail -n 1)
		if [[ -z "$version" ]]; then
			printf 'No release found for kernel %s\n' "$kernel" >&2
			exit 1
		fi
		revision=$(printf '%s\n' "$tags" | awk -v tag="refs/tags/v$version" '$2 == tag { print $1 }')
		;;
	bpf-next)
		repository=https://git.kernel.org/pub/scm/linux/kernel/git/bpf/bpf-next.git
		revision=$(git ls-remote "$repository" refs/heads/master | awk '{ print $1 }')
		version=bpf-next
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
