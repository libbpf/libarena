// SPDX-License-Identifier: LGPL-2.1 OR BSD-2-Clause
/* Copyright (c) 2026 Meta Platforms, Inc. and affiliates. */

#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <bpf/libbpf.h>
#include <bpf/bpf.h>

#ifndef bpf_prog_stream_read_opts__last_field
#define BPF_NO_STREAMS
#endif

#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/sysinfo.h>

#include <libarena/common.h>
#include <libarena/asan.h>
#include <libarena/buddy.h>
#include <libarena/userspace.h>

#include "parallel.h"

#ifdef BPF_ARENA_ASAN
#include "libarena_asan.skel.h"
typedef struct libarena_asan selftest;
#define selftest__open libarena_asan__open
#define selftest__open_and_load libarena_asan__open_and_load
#define selftest__load libarena_asan__load
#define selftest__attach libarena_asan__attach
#define selftest__destroy libarena_asan__destroy
#else
#include "libarena.skel.h"
typedef struct libarena selftest;
#define selftest__open libarena__open
#define selftest__open_and_load libarena__open_and_load
#define selftest__load libarena__load
#define selftest__attach libarena__attach
#define selftest__destroy libarena__destroy
#endif

static bool verbose;
static int testno = 1;

int selftest_run_prog(int prog_fd)
{
#ifndef BPF_NO_STREAMS
	bool emit_stderr;
	char buf[1024];
	int err;
#endif
	int ret;

	ret = libarena_run_prog(prog_fd);

#ifndef BPF_NO_STREAMS
	if (verbose) {
		printf("BPF stdout:\n");
		while ((err = bpf_prog_stream_read(prog_fd, 1, buf, 1024, NULL)) > 0)
			printf("%.*s", err, buf);

		if (err) {
			printf("[HARNESS] stdout stream error\n");
			return err;
		}
	}

	emit_stderr = verbose || (ret != 0);
	if (emit_stderr)
		printf("BPF stderr:\n");

	while (true) {
		err = bpf_prog_stream_read(prog_fd, 2, buf, 1024, NULL);
		if (err < 0) {
			printf("[HARNESS] stderr stream error\n");
			return err;
		}

		/* No more data. */
		if (err == 0)
			break;

		/* Drain don't emit. */
		if (!emit_stderr)
			continue;

		printf("%.*s", err, buf);
	}
#endif

	return ret;
}

static int libbpf_print_fn(enum libbpf_print_level level,
		const char *format, va_list args)
{
	if (level == LIBBPF_DEBUG)
		return 0;
	return vfprintf(stderr, format, args);
}

static int init_arena(selftest *skel)
{
	struct arena_alloc_reserve_args args = {
		.nr_pages = ARENA_RESERVE_PAGES_DFL,
	};
	int ret;

	ret = libarena_run_prog_args(bpf_program__fd(skel->progs.arena_alloc_reserve),
				    &args, sizeof(args));
	if (ret && ret != -EOPNOTSUPP)
		return ret;

#ifdef BPF_ARENA_ASAN
	ret = libarena_asan_init(
		bpf_program__fd(skel->progs.arena_get_info),
		bpf_program__fd(skel->progs.asan_init),
		(1ULL << 32) / sysconf(_SC_PAGESIZE));
	if (ret)
		return ret;
#endif

	return 0;
}

static int run_test(selftest *skel, struct bpf_program *prog)
{
	int prog_fd;
	int ret;

	/* Buddy tests initialize the allocator directly. */
	if (strstr(bpf_program__name(prog), "test_buddy"))
		ret = libarena_run_prog(bpf_program__fd(skel->progs.arena_buddy_destroy));
	else
		ret = libarena_run_prog(bpf_program__fd(skel->progs.arena_buddy_reset));
	if (ret)
		return ret;

	prog_fd = bpf_program__fd(prog);
	if (prog_fd < 0)
		return prog_fd;

	return selftest_run_prog(prog_fd);
}

static void
banner(const char *progpath)
{
	const char *name = strrchr(progpath, '/');
	bool is_asan;

	name = name ? name + 1 : progpath;
	/* Check if our BPF programs are ASAN-capable using strstr on the prog name. */
	printf("%s\n", name);
	is_asan = strstr(name, "_asan");

	printf("=== %s %s===\n", "libarena selftests", is_asan ? "(asan) " : "");
}

int main(int argc, char *argv[])
{
	struct bpf_program *prog;
	selftest *skel;
	int err = 0;
	int ret;

	banner(argv[0]);

	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "-v") == 0 || strcmp(argv[i], "--verbose") == 0) {
			verbose = true;
			continue;
		}

		fprintf(stderr, "usage: ./%s [-v] [--verbose]\n", argv[0]);
		fprintf(stderr, "--verbose prints out BPF streams\n");

		return -EINVAL;
	}

	libbpf_set_print(libbpf_print_fn);

	skel = selftest__open_and_load();
	if (!skel) {
		fprintf(stderr, "Failed to open and load skeleton\n");
		return 1;
	}

	ret = selftest__attach(skel);
	if (ret) {
		fprintf(stderr, "Failed to attach skeleton\n");
		selftest__destroy(skel);
		return 1;
	}

	ret = init_arena(skel);
	if (ret) {
		fprintf(stderr, "Failed to initialize arena: %d\n", ret);
		selftest__destroy(skel);
		return 1;
	}

	bpf_object__for_each_program(prog, skel->obj) {
		const char *name = bpf_program__name(prog);
		bool skipped = false;
		size_t namelen = strlen(name);
		int printlen = namelen;

		if (libarena_is_parallel_test_prog(name)) {
			/* Each group is run once, when its __init program is found. */
			if (namelen < strlen("__init") ||
			    strcmp(name + namelen - strlen("__init"), "__init"))
				continue;
			printlen -= strlen("__init");
			ret = selftest_run_parallel(skel->obj, prog, &skipped);
		} else {
#ifdef BPF_ARENA_ASAN
			if (!libarena_is_asan_test_prog(name))
				continue;
#else
			if (!libarena_is_test_prog(name))
				continue;
#endif

			ret = run_test(skel, prog);
		}

		if (skipped)
			printf("ok %d - %.*s # SKIP unsupported\n", testno++, printlen, name);
		else if (ret)
			printf("not ok %d - %.*s (error %d)\n", testno++, printlen, name, ret);
		else
			printf("ok %d - %.*s\n", testno++, printlen, name);

		if (ret)
			err = -EINVAL;
	}

	selftest__destroy(skel);

	return err;
}
