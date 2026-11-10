// SPDX-License-Identifier: LGPL-2.1 OR BSD-2-Clause
/* Copyright (c) 2026 Meta Platforms, Inc. and affiliates. */

#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <bpf/libbpf.h>

#include "parallel.h"

/* Max suffix is ceil((lg 2^32) / (lg 10)) + sizeof("__") = 10 + 2 = 12. */
#define MAX_PARTEST_SUFFIX (12)
#define MAX_PARTEST_NAME (1024)
#define MAX_PARTEST_PREFIX (MAX_PARTEST_NAME - MAX_PARTEST_SUFFIX)

static void *run_parallel_prog(void *arg)
{
	struct bpf_program *prog = arg;

	return (void *)(intptr_t)selftest_run_prog(bpf_program__fd(prog));
}

static int parallel_prog_name(char *buf, const char *prefix, size_t prefixlen,
			      const char *suffix)
{
	int ret;

	ret = snprintf(buf, MAX_PARTEST_NAME, "%.*s__%s", (int)prefixlen,
		       prefix, suffix);
	if (ret < 0 || ret >= MAX_PARTEST_NAME)
		return -ENAMETOOLONG;

	return 0;
}

static int run_parallel_workers(struct bpf_object *obj, const char *name,
				size_t prefixlen)
{
	pthread_t *threads = NULL, *tmp_threads;
	char tdname[MAX_PARTEST_NAME];
	struct bpf_program *tdprog;
	unsigned int nthreads, i;
	bool interrupted = false;
	void *thread_ret;
	int ret, err = 0;
	int worker_err;

	for (nthreads = 0; nthreads < UINT_MAX; nthreads++) {
		ret = snprintf(tdname, sizeof(tdname), "%.*s__%u", (int)prefixlen,
			       name, nthreads);
		if (ret < 0 || ret >= MAX_PARTEST_NAME) {
			err = -ENAMETOOLONG;
			break;
		}

		/* Worker suffixes start at __0 and are contiguous. */
		tdprog = bpf_object__find_program_by_name(obj, tdname);
		if (!tdprog)
			break;

		tmp_threads = realloc(threads, ((size_t)nthreads + 1) * sizeof(*threads));
		if (!tmp_threads) {
			err = -ENOMEM;
			break;
		}
		threads = tmp_threads;

		ret = pthread_create(&threads[nthreads], NULL, run_parallel_prog, tdprog);
		if (ret) {
			fprintf(stderr, "%s: pthread_create: %s\n", tdname, strerror(ret));
			err = -ret;
			break;
		}
	}

	if (!nthreads && !err)
		err = -ENOENT;

	for (i = 0; i < nthreads; i++) {
		ret = pthread_join(threads[i], &thread_ret);
		if (ret) {
			fprintf(stderr, "%.*s__%u: pthread_join: %s\n",
				(int)prefixlen, name, i, strerror(ret));
			err = err ?: -ret;
			continue;
		}

		worker_err = (intptr_t)thread_ret;
		if (!worker_err)
			continue;

		/* Preserve the causal error when other workers abort with -EINTR. */
		if (worker_err == -EINTR) {
			interrupted = true;
			continue;
		}

		err = err ?: worker_err;
		fprintf(stderr, "%.*s__%u returned %d\n", (int)prefixlen, name,
			i, worker_err);
	}

	free(threads);

	/* An interrupted test must still fail if no worker reported its cause. */
	return err ?: (interrupted ? -EINTR : 0);
}

int selftest_run_parallel(struct bpf_object *obj, struct bpf_program *init_prog,
			  bool *skipped)
{
	const char *name = bpf_program__name(init_prog);
	struct bpf_program *prog, *fini_prog;
	char progname[MAX_PARTEST_NAME];
	size_t prefixlen, namelen = strlen(name);
	int ret, fini_ret;

	*skipped = false;
	if (namelen < strlen("__init") ||
	    strcmp(name + namelen - strlen("__init"), "__init"))
		return -EINVAL;

	prefixlen = namelen - strlen("__init");
	if (!prefixlen || prefixlen >= MAX_PARTEST_PREFIX)
		return -ENAMETOOLONG;

	ret = parallel_prog_name(progname, name, prefixlen, "enabled");
	if (ret)
		return ret;

	prog = bpf_object__find_program_by_name(obj, progname);
	if (prog) {
		ret = selftest_run_prog(bpf_program__fd(prog));
		if (ret == -EOPNOTSUPP) {
			*skipped = true;
			return 0;
		}
		if (ret)
			return ret;
	}

	ret = parallel_prog_name(progname, name, prefixlen, "fini");
	if (ret)
		return ret;

	fini_prog = bpf_object__find_program_by_name(obj, progname);
	if (!fini_prog) {
		fprintf(stderr, "Missing parallel teardown program %s\n", progname);
		return -ENOENT;
	}

	prog = bpf_object__find_program_by_name(obj, "arena_buddy_reset");
	if (!prog)
		return -ENOENT;

	ret = selftest_run_prog(bpf_program__fd(prog));
	if (ret)
		return ret;

	ret = selftest_run_prog(bpf_program__fd(init_prog));
	if (ret)
		return ret;

	ret = run_parallel_workers(obj, name, prefixlen);
	fini_ret = selftest_run_prog(bpf_program__fd(fini_prog));
	if (fini_ret)
		fprintf(stderr, "%s returned %d\n", progname, fini_ret);

	return ret ?: fini_ret;
}
