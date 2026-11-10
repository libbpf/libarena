// SPDX-License-Identifier: LGPL-2.1 OR BSD-2-Clause
/* Copyright (c) 2026 Meta Platforms, Inc. and affiliates. */
#pragma once

#include <stdbool.h>

struct bpf_object;
struct bpf_program;

int selftest_run_prog(int prog_fd);
int selftest_run_parallel(struct bpf_object *obj, struct bpf_program *init_prog,
			  bool *skipped);
