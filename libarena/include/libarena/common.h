// SPDX-License-Identifier: LGPL-2.1 OR BSD-2-Clause
/* Copyright (c) 2026 Meta Platforms, Inc. and affiliates. */
#pragma once

#ifdef __BPF__

#include <vmlinux.h>

#include <bpf_arena_common.h>
#include <bpf_arena_spin_lock.h>

#include <asm-generic/errno.h>

#ifndef __BPF_FEATURE_ADDR_SPACE_CAST
#error "Arena allocators require bpf_addr_space_cast feature"
#endif

static __always_inline int printk_args_unused(const char *fmt, ...) { return 0; }

/*
 * BPF streams postdate the oldest kernels this branch supports. libbpf's
 * bpf_stream_printk() calls the bpf_stream_vprintk() kfunc unconditionally,
 * and the verifier rejects the whole program where it is absent:
 *
 *   ; arena_stderr("illegal size request %lu\n", size); @ buddy.bpf.c:337
 *   190: <invalid kfunc call>
 *   kfunc 'bpf_stream_vprintk' is referenced but wasn't resolved
 *
 * bpf_ksym_exists() does not help: it gates weak *variable* ksyms, while a
 * weak kfunc call is still walked by the verifier, so the guard branch is
 * optimized out and the call remains.
 *
 * Compile the prints out. Callers keep working, they just lose diagnostics,
 * which those kernels could not deliver anyway. The arguments are still
 * evaluated for their side effects and to keep -Wunused quiet.
 */
#define arena_stdout(fmt, ...) ((void)(0 && printk_args_unused(fmt, ##__VA_ARGS__)), 0)
#define arena_stderr(fmt, ...) ((void)(0 && printk_args_unused(fmt, ##__VA_ARGS__)), 0)

#ifndef __maybe_unused
#define __maybe_unused __attribute__((__unused__))
#endif

#define private(name) SEC(".data." #name) __hidden __attribute__((aligned(8)))

#define ARENA_PAGES (1UL << (32 - __builtin_ffs(__PAGE_SIZE) + 1))

struct {
	__uint(type, BPF_MAP_TYPE_ARENA);
	__uint(map_flags, BPF_F_MMAPABLE);
	__uint(max_entries, ARENA_PAGES); /* number of pages */
#if defined(__TARGET_ARCH_arm64) || defined(__aarch64__)
	__ulong(map_extra, (1ull << 32)); /* start of mmap() region */
#else
	__ulong(map_extra, (1ull << 44)); /* start of mmap() region */
#endif
} arena __weak SEC(".maps");

/*
 * This is a variable used to aid verification. The may_goto directive
 * permits open-coded for loops, but requires that the index variable is
 * imprecise. To force the variable to be imprecise, initialize it with
 * the opaque volatile variable 0 instead of the constant 0.
 */
volatile u32 zero __weak;
extern volatile u64 asan_violated;

int arena_fls(__u64 word);

u64 arena_malloc_internal(size_t size);
#define arena_malloc(size) ((void __arena *)arena_malloc_internal((size)))
u64 arena_calloc_internal(size_t ncount, size_t size);
#define arena_calloc(ncount, size) \
	((void __arena *)arena_calloc_internal((ncount), (size)))
int arena_free(void __arena *ptr);

/*
 * The verifier associates arenas with programs by checking LD.IMM
 * instruction operands for an arena and populating the program state
 * with the first instance it finds. This requires accessing our global
 * arena variable, but subprogs do not necessarily do so while still
 * using pointers from that arena. Insert an LD.IMM instruction  to
 * access the arena and help the verifier.
 */
#define arena_subprog_init() do { asm volatile ("" :: "r"(&arena)); } while (0)

/*
 * BPF does not currently support the memset intrinsics. for large
 * sequential copies, or assignments of large data structures,
 * the frontend will generate an intrinsic that causes the BPF
 * backend to exit due to a missing implementation. Provide
 * implementations for the intrinsic.
 */
static inline int arena_memset(s8 __arena *dst, s8 val, size_t size)
{
	size_t headalign;
	size_t tailalign;
	u8 uval = (u8)val;
	size_t val64;
	size_t i;

	/*
	 * Calculate how many bytes to the next word-aligned one.
	 * We get this by truncating the 2s complement of the
	 * pointer to the last 3 bits. Intuitively, since
	 *
	 * The N LSBs of dst and -dst add to 1 << N, which
	 * is why dst + (-dst) = 0x0ULL through overflow. So the
	 * last N = 3 bits of the negative are the number of
	 * bytes to align dst on the last 3 bits.
	 *
	 */
	headalign = -(u64)dst & (sizeof(u64) - 1);
	if (!headalign || size < headalign)
		goto ptraligned;

	for (i = zero; i < headalign && can_loop; i++)
		dst[i] = uval;

	dst += headalign;
	size -= headalign;

ptraligned:

	/*
	 * Make a word with all bytes equal to the byte we are setting.
	 * Since 1 byte -> 2 hex digits.
	 *
	 * Shifting the value by a 0 bytes is equal to multiplication by 0x01
	 * Shifting by 1 bytes is equal to multiplication by 0x01 << 8,
	 * ...
	 * Shifting by 7 bytes is equal to multiplication by 0x01 << 56.
	 *
	 * End operation to replicate the byte into all the bytes of a word
	 * is (since a | b = a + b when a & b == 0):
	 *
	 * val + val * (1UL << 8) + val * (1UL << 16) + .. + val * (1UL << 56)
	 * = val * (1UL << 56 + 1UL << 48 + ... + 1UL << 0)
	 * = val * (0x01UL << 56 | 0x01UL << 48 + ... + 1UL << 0)
	 * = val * 0x0101 0101 0101 0101
	 */
	val64 = (u8)val * 0x0101010101010101ULL;

	/* Pointer is now aligned, use word-aligned assignments. */
	for (i = zero; i < size / sizeof(u64) && can_loop; i++)
		((u64 __arena *)dst)[i] = val64;

	/* Go back to byte-aligned for the tail. */
	tailalign = size % sizeof(u64);
	dst += size - tailalign;
	for (i = zero; i < tailalign && can_loop; i++)
		dst[i] = uval;

	return 0;
}

#else /* ! __BPF__ */

#include <stdint.h>

#define __arena

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int8_t s8;
typedef int16_t s16;
typedef int32_t s32;
typedef int64_t s64;

/* Dummy "definition" for userspace. */
#define arena_spinlock_t int

#endif /* __BPF__ */

struct arena_get_info_args {
	void __arena *arena_base;
};

struct arena_alloc_reserve_args {
	u64 nr_pages;
};

/* Reasonable default number of pages reserved by arena_alloc_reserve. */
#define ARENA_RESERVE_PAGES_DFL (8)
