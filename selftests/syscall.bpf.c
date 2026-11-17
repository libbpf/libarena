// SPDX-License-Identifier: LGPL-2.1 OR BSD-2-Clause
/* Copyright (c) 2026 Meta Platforms, Inc. and affiliates. */
#include <libarena/common.h>
#include <libarena/asan.h>
#include <libarena/buddy.h>

#include "user_test_buddy.h"

struct buddy __arena syscall_buddy;

SEC("syscall")
__weak int syscall_buddy_reset(void)
{
	buddy_destroy(&syscall_buddy);

	return buddy_init(&syscall_buddy);
}

SEC("syscall")
__weak int syscall_buddy_destroy(void)
{
	return buddy_destroy(&syscall_buddy);
}

static __always_inline int syscall_validate_access(u64 addr, bool expected)
{
#ifdef BPF_ARENA_ASAN
	bool violated = asan_violated != 0;
	bool correct_addr = !violated || asan_violated == addr;

	asan_violated = 0;

	if (violated != expected || !correct_addr)
		return -EINVAL;

#else

	if (expected)
		return -EOPNOTSUPP;

#endif
	return 0;
}

SEC("syscall")
__weak int syscall_access(struct syscall_access_args *args)
{
	volatile u8 __arena *ptr = (void __arena *)args->ptr;
	u64 i;
	int ret;

	arena_subprog_init();
	/* Allocator operations must not leave an unexpected ASAN violation. */
	ret = syscall_validate_access(0, false);
	if (ret)
		return ret;

	bpf_for(i, 0, args->size) {
		ptr[i] = 0xa5;
		ret = syscall_validate_access((u64)&ptr[i], args->expect_violation);
		if (ret)
			return ret;
	}

	return 0;
}

__weak char _license[] SEC("license") = "GPL";
