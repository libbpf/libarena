#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1 OR BSD-2-Clause
# Copyright (c) 2026 Meta Platforms, Inc. and affiliates.

"""List the selftests that must produce results for a linked BPF object."""

import re
import subprocess
import sys


def expected_tests(object_path):
    headers = subprocess.check_output(
        ["readelf", "--wide", "--section-headers", object_path], text=True
    )
    sections = dict(re.findall(r"\[\s*(\d+)\]\s+(\S+)", headers))
    symbols = subprocess.check_output(
        ["readelf", "--wide", "--symbols", object_path], text=True
    )
    tests = set()
    parallel_groups = set()
    for line in symbols.splitlines():
        fields = line.split()
        if len(fields) != 8 or fields[3] != "FUNC":
            continue
        section = sections.get(fields[6], "")
        if not section or section == ".text" or section.startswith(".text."):
            continue
        name = fields[7]
        if name.startswith("parallel_test"):
            group, separator, suffix = name.rpartition("__")
            if not separator:
                raise ValueError(f"parallel program has no group suffix: {name}")
            parallel_groups.add(group)
            if suffix == "init":
                tests.add(group)
        elif name.startswith(("test_", "asan_test")):
            tests.add(name)
    missing = parallel_groups - tests
    if missing:
        raise ValueError(f"parallel groups lack initialization: {sorted(missing)}")
    if not tests:
        raise ValueError(f"no selftests found in {object_path}")
    return sorted(tests)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: selftest-programs.py LINKED_BPF_OBJECT")
    try:
        print("\n".join(expected_tests(sys.argv[1])))
    except (ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
