// SPDX-License-Identifier: LGPL-2.1 OR BSD-2-Clause
/* Copyright (c) 2026 Meta Platforms, Inc. and affiliates. */
#pragma once

#include <libarena/common.h>

struct syscall_access_args {
	u64 ptr;
	u64 size;
	u64 expect_violation;
};

#ifndef __BPF__

struct bpf_object;
struct buddy;

int selftest_run_user_buddy(struct bpf_object *obj, struct buddy *buddy,
			    int *testno);

#endif /* !__BPF__ */
