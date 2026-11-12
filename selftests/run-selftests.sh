#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1 OR BSD-2-Clause
# Copyright (c) 2026 Meta Platforms, Inc. and affiliates.

set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

result=0
for binary in ./test_libarena ./test_libarena_asan; do
	if ! "$binary" "$@"; then
		result=1
	fi
done

exit "$result"
