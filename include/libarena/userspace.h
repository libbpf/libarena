// SPDX-License-Identifier: LGPL-2.1 OR BSD-2-Clause
/* Copyright (c) 2026 Meta Platforms, Inc. and affiliates. */
#pragma once

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>

#include <bpf/libbpf.h>
#include <bpf/bpf.h>

#include <libarena/common.h>
#include <libarena/asan.h>

static inline int libarena_run_prog(int prog_fd)
{
	LIBBPF_OPTS(bpf_test_run_opts, opts);
	int ret;

	ret = bpf_prog_test_run_opts(prog_fd, &opts);
	if (ret)
		return ret;

	return opts.retval;
}

static inline bool libarena_is_test_prog(const char *name)
{
	return strstr(name, "test_") == name;
}

static inline bool libarena_is_asan_test_prog(const char *name)
{
	return strstr(name, "asan_test") == name;
}

static inline bool libarena_is_parallel_test_prog(const char *name)
{
	return strstr(name, "parallel_test") == name;
}


static inline int libarena_run_prog_args(int prog_fd, void *args, size_t argsize)
{
	LIBBPF_OPTS(bpf_test_run_opts, opts);
	int ret;

	opts.ctx_in = args;
	opts.ctx_size_in = argsize;

	ret = bpf_prog_test_run_opts(prog_fd, &opts);

	return ret ?: opts.retval;
}

static inline int libarena_malloc(int prog_fd, struct buddy *buddy, size_t size, void **ptr)
{
	struct uarena_malloc_args args = { .buddy = buddy, .size = size };
	int ret;

	if (!ptr)
		return -EINVAL;

	*ptr = NULL;
	ret = libarena_run_prog_args(prog_fd, &args, sizeof(args));
	if (!ret)
		*ptr = (void *)(uintptr_t)args.ptr;

	return ret;
}

static inline int libarena_calloc(int prog_fd, struct buddy *buddy, size_t count,
				  size_t size, void **ptr)
{
	struct uarena_calloc_args args = { .buddy = buddy, .count = count, .size = size };
	int ret;

	if (!ptr)
		return -EINVAL;

	*ptr = NULL;
	ret = libarena_run_prog_args(prog_fd, &args, sizeof(args));
	if (!ret)
		*ptr = (void *)(uintptr_t)args.ptr;

	return ret;
}

static inline int libarena_free(int prog_fd, struct buddy *buddy, void *ptr)
{
	struct uarena_free_args args = { .buddy = buddy, .ptr = (uintptr_t)ptr };

	return libarena_run_prog_args(prog_fd, &args, sizeof(args));
}

static inline int libarena_grow(int prog_fd, struct buddy *buddy, size_t nr_chunks)
{
	struct uarena_grow_args args = { .buddy = buddy, .nr_chunks = nr_chunks };

	return libarena_run_prog_args(prog_fd, &args, sizeof(args));
}

static inline int libarena_get_arena_base(int arena_get_info_fd,
					  void **arena_base)
{
	LIBBPF_OPTS(bpf_test_run_opts, opts);
	struct arena_get_info_args args = { .arena_base = NULL };
	int ret;

	opts.ctx_in = &args;
	opts.ctx_size_in = sizeof(args);

	ret = bpf_prog_test_run_opts(arena_get_info_fd, &opts);
	if (ret)
		return ret;
	if (opts.retval)
		return opts.retval;

	*arena_base = args.arena_base;
	return 0;
}

static inline int libarena_get_globals_pages(int arena_get_globals_fd,
					     size_t arena_all_pages,
					     u64 *globals_pages)
{
	size_t pgsize = sysconf(_SC_PAGESIZE);
	void *arena_base;
	ssize_t i;
	u8 *vec;
	int ret;

	ret = libarena_get_arena_base(arena_get_globals_fd, &arena_base);
	if (ret)
		return ret;

	if (!arena_base)
		return -EINVAL;

	vec = calloc(arena_all_pages, sizeof(*vec));
	if (!vec)
		return -ENOMEM;

	if (mincore(arena_base, arena_all_pages * pgsize, vec) < 0) {
		ret = -errno;
		free(vec);
		return ret;
	}

	*globals_pages = 0;
	for (i = arena_all_pages - 1; i >= 0; i--) {
		if (!(vec[i] & 0x1))
			break;
		*globals_pages += 1;
	}

	free(vec);
	return 0;
}

static inline int libarena_asan_init(int arena_asan_init_fd,
				     int asan_init_fd,
				     size_t arena_all_pages)
{
	LIBBPF_OPTS(bpf_test_run_opts, opts);
	struct asan_init_args args;
	u64 globals_pages = 0;
	int ret;

	ret = libarena_get_globals_pages(arena_asan_init_fd,
					 arena_all_pages, &globals_pages);
	if (ret)
		return ret;

	args = (struct asan_init_args){
		.arena_all_pages = arena_all_pages,
		.arena_globals_pages = globals_pages,
	};

	opts.ctx_in = &args;
	opts.ctx_size_in = sizeof(args);

	ret = bpf_prog_test_run_opts(asan_init_fd, &opts);
	if (ret)
		return ret;
	return opts.retval;
}
