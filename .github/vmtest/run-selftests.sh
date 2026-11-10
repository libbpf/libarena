#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1 OR BSD-2-Clause
# Copyright (c) 2026 Meta Platforms, Inc. and affiliates.

set -euo pipefail

logs=$(mktemp -d)
# shellcheck disable=SC2317 # Invoked by the EXIT trap.
cleanup()
{
	local runner_status=$?
	rm -rf "$logs"
	printf 'libarena-ci: exit %d\n' "$runner_status"
	exit "$runner_status"
}
trap cleanup EXIT
result=0

# Attempt both variants even when an earlier test fails.
for binary in ./test_libarena ./test_libarena_asan; do
	log="$logs/${binary##*/}.log"
	set +e
	stdbuf -oL -eL "$binary" "$@" 2>&1 | tee "$log"
	statuses=("${PIPESTATUS[@]}")
	set -e
	for status in "${statuses[@]}"; do
		if ((status != 0)); then
			result=1
		fi
	done
	if ! awk '
		FILENAME == ARGV[1] { expected[$1] = 1; total++; next }
		/^(not )?ok [0-9]+ - / {
			failed = $1 == "not"
			number = failed ? $3 : $2
			name = failed ? $5 : $4
			if (number != ++count || !(name in expected) || seen[name]++) {
				print "Invalid or duplicate selftest result: " $0 > "/dev/stderr"
				bad = 1
			}
			if (failed || toupper($0) ~ /#[ \t]*(SKIP|TODO)([ \t]|$)/) {
				print "Selftest did not pass: " $0 > "/dev/stderr"
				bad = 1
			}
		}
		END {
			for (name in expected) {
				if (!(name in seen)) {
					print "Missing selftest result: " name > "/dev/stderr"
					bad = 1
				}
			}
			if (!total || count != total) {
				print "Selftest result count differs from compiled tests" > "/dev/stderr"
				bad = 1
			}
			exit bad ? 1 : 0
		}
	' "$binary.tests" "$log"; then
		result=1
	fi
done

exit "$result"
