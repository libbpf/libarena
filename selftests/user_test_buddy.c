// SPDX-License-Identifier: LGPL-2.1 OR BSD-2-Clause
/* Copyright (c) 2026 Meta Platforms, Inc. and affiliates. */

#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <libarena/common.h>
#include <libarena/buddy.h>
#include <libarena/userspace.h>

#include "user_test_buddy.h"

static int syscall_prog_fd(struct bpf_object *obj, const char *name)
{
	struct bpf_program *prog = bpf_object__find_program_by_name(obj, name);

	return prog ? bpf_program__fd(prog) : -ENOENT;
}

static int syscall_access(struct bpf_object *obj, void *ptr, size_t size,
			  bool expect_violation)
{
	struct syscall_access_args args = {
		.ptr = (uintptr_t)ptr,
		.size = size,
		.expect_violation = expect_violation,
	};

	return libarena_run_prog_args(syscall_prog_fd(obj, "syscall_access"),
				      &args, sizeof(args));
}

/* Fill the allocator without growing it, leaving cleanup to the runner. */
static int syscall_exhaust(struct bpf_object *obj, struct buddy *buddy)
{
	int fd = syscall_prog_fd(obj, "uarena_malloc_nogrow");
	void *ptr;
	size_t i;
	int ret;

	for (i = 0; i < 256; i++) {
		ret = libarena_malloc(fd, buddy, BUDDY_CHUNK_BYTES / 2, &ptr);
		if (ret == -ENOMEM)
			return ptr ? -EINVAL : 0;

		if (ret)
			return ret;

		if (!ptr)
			return -EINVAL;
	}

	return -E2BIG;
}

static int test_uarena_malloc(struct bpf_object *obj,
				struct buddy *buddy)
{
	void *ptr;
	int ret;

	ret = libarena_malloc(syscall_prog_fd(obj, "uarena_malloc"),
			      buddy, 257, &ptr);
	if (ret)
		return ret;

	if (!ptr)
		return -EINVAL;

	return syscall_access(obj, ptr, 257, false);
}

static int test_uarena_calloc(struct bpf_object *obj,
						struct buddy *buddy)
{
	const size_t size = 7 * 587;
	void *dirty, *ptr;
	size_t i;
	int ret;

	/* Bypass per-CPU caches so the next allocation reuses these bytes. */
	ret = libarena_malloc(syscall_prog_fd(obj, "uarena_malloc"),
			      buddy, size, &dirty);
	if (ret)
		return ret;

	if (!dirty)
		return -EINVAL;

	memset(dirty, 0xa5, size);
	ret = libarena_free(syscall_prog_fd(obj, "uarena_free"), buddy, dirty);
	if (ret)
		return ret;

	ret = libarena_calloc(syscall_prog_fd(obj, "uarena_calloc"),
			      buddy, 7, 587, &ptr);
	if (ret)
		return ret;

	if (ptr != dirty)
		return -EINVAL;

	for (i = 0; i < size; i++) {
		if (((u8 *)ptr)[i])
			return -EINVAL;
	}

	return 0;
}

static int test_uarena_free(struct bpf_object *obj,
				struct buddy *buddy)
{
	void *ptr, *reused;
	int ret;

	ret = libarena_malloc(syscall_prog_fd(obj, "uarena_malloc"),
			      buddy, BUDDY_CHUNK_BYTES / 2, &ptr);
	if (ret)
		return ret;

	if (!ptr)
		return -EINVAL;

	ret = syscall_exhaust(obj, buddy);
	if (ret)
		return ret;

	ret = libarena_free(syscall_prog_fd(obj, "uarena_free"), buddy, ptr);
	if (ret)
		return ret;

	ret = libarena_malloc(syscall_prog_fd(obj, "uarena_malloc_nogrow"),
			      buddy, BUDDY_CHUNK_BYTES / 2, &reused);
	if (ret)
		return ret;

	return reused ? 0 : -EINVAL;
}

static int test_uarena_grow(struct bpf_object *obj,
				struct buddy *buddy)
{
	u64 vaddr = buddy->vaddr;
	int ret;

	ret = libarena_grow(syscall_prog_fd(obj, "uarena_grow"), buddy, 2);
	if (ret)
		return ret;

	return buddy->vaddr == vaddr + 2 * BUDDY_CHUNK_BYTES ? 0 : -EINVAL;
}

static int test_uarena_malloc_nogrow(struct bpf_object *obj,
				struct buddy *buddy)
{
	u64 vaddr = buddy->vaddr;
	void *ptr = (void *)1;
	int ret;

	ret = syscall_exhaust(obj, buddy);
	if (ret)
		return ret;

	ret = libarena_malloc(syscall_prog_fd(obj, "uarena_malloc_nogrow"),
			      buddy, BUDDY_CHUNK_BYTES / 2, &ptr);
	if (ret != -ENOMEM || ptr || buddy->vaddr != vaddr)
		return -EINVAL;

	return 0;
}

static int test_uarena_malloc_grow(struct bpf_object *obj,
				struct buddy *buddy)
{
	void *ptr;
	int ret;

	ret = syscall_exhaust(obj, buddy);
	if (ret)
		return ret;

	ret = libarena_malloc(syscall_prog_fd(obj, "uarena_malloc"),
			      buddy, BUDDY_CHUNK_BYTES / 2, &ptr);
	if (ret)
		return ret;

	return ptr ? 0 : -EINVAL;
}

#ifdef BPF_ARENA_ASAN

static int test_uarena_asan_oob(struct bpf_object *obj,
				struct buddy *buddy)
{
	void *ptr;
	int ret;

	ret = libarena_malloc(syscall_prog_fd(obj, "uarena_malloc"),
			      buddy, 257, &ptr);
	if (ret)
		return ret;

	if (!ptr)
		return -EINVAL;

	return syscall_access(obj, (u8 *)ptr + 257, 1, true);
}

static int test_uarena_asan_uaf(struct bpf_object *obj,
				struct buddy *buddy)
{
	void *ptr;
	int ret;

	ret = libarena_malloc(syscall_prog_fd(obj, "uarena_malloc"),
			      buddy, 257, &ptr);
	if (ret)
		return ret;

	if (!ptr)
		return -EINVAL;

	ret = libarena_free(syscall_prog_fd(obj, "uarena_free"), buddy, ptr);
	if (ret)
		return ret;

	return syscall_access(obj, ptr, 1, true);
}

#endif /* BPF_ARENA_ASAN */

int selftest_run_user_buddy(struct bpf_object *obj, struct buddy *buddy,
			    int *testno)
{
	static const struct {
		const char *name;
		int (*run)(struct bpf_object *, struct buddy *);
	} tests[] = {
		{ "test_uarena_malloc",
		  test_uarena_malloc },
		{ "test_uarena_calloc",
		  test_uarena_calloc },
		{ "test_uarena_free",
		  test_uarena_free },
		{ "test_uarena_grow",
		  test_uarena_grow },
		{ "test_uarena_malloc_nogrow",
		  test_uarena_malloc_nogrow },
		{ "test_uarena_malloc_grow",
		  test_uarena_malloc_grow },
#ifdef BPF_ARENA_ASAN
		{ "test_uarena_asan_oob",
		  test_uarena_asan_oob },
		{ "test_uarena_asan_uaf",
		  test_uarena_asan_uaf },
#endif
	};
	int reset_fd = syscall_prog_fd(obj, "syscall_buddy_reset");
	int destroy_fd = syscall_prog_fd(obj, "syscall_buddy_destroy");
	int err = 0, ret, cleanup;
	size_t i;

	for (i = 0; i < sizeof(tests) / sizeof(tests[0]); i++) {
		ret = libarena_run_prog(reset_fd);
		if (!ret)
			ret = tests[i].run(obj, buddy);

		cleanup = libarena_run_prog(destroy_fd);
		if (!cleanup)
			cleanup = syscall_access(obj, NULL, 0, false);

		ret = ret ?: cleanup;
		printf("%s %d - %s%s", ret ? "not ok" : "ok", (*testno)++,
#ifdef BPF_ARENA_ASAN
		       "asan_",
#else
		       "",
#endif
		       tests[i].name);
		if (ret) {
			printf(" (error %d)", ret);
			err = ret;
		}
		putchar('\n');
	}

	return err;
}
