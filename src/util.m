/*
 * Copyright (C) 2010, 2011, 2012 Mail.RU
 * Copyright (C) 2010, 2011, 2012 Yuriy Vostrikov
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

#import <util.h>
#import <fiber.h>
#import <octopus_ev.h>
#import <say.h>

#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>

#ifdef HAVE_LIBELF
# include <libelf.h>
# include <gelf.h>
#endif

extern ev_io keepalive_ev;
extern int keepalive_pipe[2];

void
close_all_xcpt(int fdc, ...)
{
	int keep[fdc];
	va_list ap;
	struct rlimit nofile;

	va_start(ap, fdc);
	for (int j = 0; j < fdc; j++) {
		keep[j] = va_arg(ap, int);
	}
	va_end(ap);

	if (getrlimit(RLIMIT_NOFILE, &nofile) != 0)
		nofile.rlim_cur = 10000;

	for (int i = 3; i < nofile.rlim_cur; i++) {
		bool found = false;
		for (int j = 0; j < fdc; j++) {
			if (keep[j] == i) {
				found = true;
				break;
			}
		}
		if (!found)
			close(i);
	}
}

void
maximize_core_rlimit()
{
	say_info("Maximizing RLIMIT_CORE");

	struct rlimit c = { 0, 0 };
	if (getrlimit(RLIMIT_CORE, &c) < 0) {
		say_syserror("getrlimit");
		return;
	}
	c.rlim_cur = c.rlim_max;
	if (setrlimit(RLIMIT_CORE, &c) < 0)
		say_syserror("setrlimit");
}

void
coredump(int dump_interval)
{
	static time_t last_coredump = 0;
	time_t now = time(NULL);

	if (now - last_coredump < dump_interval)
		return;

	last_coredump = now;

	if (tnt_fork() == 0) {
		close_all_xcpt(0);
#ifdef COVERAGE
		__gcov_flush();
#endif
		maximize_core_rlimit();
		abort();
	}
}

pid_t master_pid;

pid_t
tnt_fork()
{
	pid_t pid = fork();
	if (pid == 0) {
		sigset_t set;
		sigfillset(&set);
		sigprocmask(SIG_UNBLOCK, &set, NULL);
		signal(SIGPIPE, SIG_DFL);
		signal(SIGCHLD, SIG_DFL);
		/* Ignore SIGINT coming from a TTY
		   our parent will send SIGTERM to us when he catches SIGINT */
		signal(SIGINT, SIG_IGN);
		ev_loop_fork();
		ev_io_stop(&keepalive_ev);
		if (keepalive_pipe[0] > 0) {
			close(keepalive_pipe[0]);
			keepalive_pipe[0] = -1;
		}
	}
	return pid;
}

void
keepalive(void)
{
	char c = 0;
	if (write(keepalive_pipe[1], &c, 1) != 1)
		panic("parent is dead");
}

void
keepalive_read()
{
	char buf[16];
	ssize_t r;
next:
	r = read(keepalive_pipe[0], buf, sizeof(buf));
	if (r > 0) {
		if (r == sizeof(buf))
			goto next;
		return;
	}
	if (r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR))
		return;

	panic("read from keepalive_pipe failed");
}

volatile int gdb_wait_lock = 1;
void
wait_gdb(void)
{
	while(gdb_wait_lock);
}

double
drand(double top)
{
	return (top * (double)rand()) / RAND_MAX;
}

#if defined(__ia64__) && defined(__hpux__)
typedef unsigned _Unwind_Ptr __attribute__((__mode__(__word__)));
#else
typedef unsigned _Unwind_Ptr __attribute__((__mode__(__pointer__)));
#endif
typedef enum
{
  _URC_NO_REASON = 0,
  _URC_FOREIGN_EXCEPTION_CAUGHT = 1,
  _URC_FATAL_PHASE2_ERROR = 2,
  _URC_FATAL_PHASE1_ERROR = 3,
  _URC_NORMAL_STOP = 4,
  _URC_END_OF_STACK = 5,
  _URC_HANDLER_FOUND = 6,
  _URC_INSTALL_CONTEXT = 7,
  _URC_CONTINUE_UNWIND = 8
} _Unwind_Reason_Code;
struct _Unwind_Context;
typedef _Unwind_Reason_Code (*_Unwind_Trace_Fn) (struct _Unwind_Context *, void *);
extern _Unwind_Reason_Code _Unwind_Backtrace (_Unwind_Trace_Fn, void *);
extern _Unwind_Ptr _Unwind_GetIP (struct _Unwind_Context *);
extern void * _Unwind_FindEnclosingFunction (void *pc);

static char backtrace_buf[4096 * 4];
struct print_state {
	char *p;
	size_t len;
};
static _Unwind_Reason_Code
print_frame(struct _Unwind_Context *ctx,
	    void *arg)
{
	struct print_state *s = arg;
	void *pc = (void *)_Unwind_GetIP(ctx);
	void *fn = _Unwind_FindEnclosingFunction(pc);
	size_t r;

	if (pc == NULL || fn == NULL)
		return _URC_NO_REASON;

	r = snprintf(s->p, s->len, "        - { pc: %p", fn);
	if (r >= s->len)
		r = s->len;
	s->p += r;
	s->len -= r;

#ifdef HAVE_LIBELF
	struct symbol *sym = addr2symbol(fn);
	if (sym != NULL) {
		r = snprintf(s->p, s->len, ", sym: '%s+%zu'", sym->name, pc - fn);
		if (r >= s->len)
			r = s->len;
		s->p += r;
		s->len -= r;

	}
#endif
	r = snprintf(s->p, s->len, " }\r\n");
	if (r >= s->len)
		r = s->len;

	s->p += r;
	s->len -= r;
	return _URC_NO_REASON;
}

const char *
tnt_backtrace(void)
{
	struct print_state s = { backtrace_buf, sizeof(backtrace_buf) };
	_Unwind_Backtrace(print_frame, &s);
	*(s.p) = 0;
        return backtrace_buf;
}

void __attribute__ ((noreturn))
assert_fail(const char *assertion, const char *file, unsigned line, const char *function)
{
	_say(FATAL, file, line, "%s: assertion %s failed.\n%s", function, assertion, tnt_backtrace());
	if (getpid() == master_pid) /* try to close all accept()ing sockets */
		close_all_xcpt(0);
	abort();
}

#ifdef HAVE_LIBELF
static struct symbol *symbols;
static size_t symbol_count;

int
compare_symbol(const void *_a, const void *_b)
{
	const struct symbol *a = _a, *b = _b;
	if (a->addr > b->addr)
		return 1;
	if (a->addr == b->addr)
		return 0;
	return -1;
}

void
load_symbols(const char *name)
{
	Elf *elf;
	GElf_Shdr shdr;
	GElf_Sym sym;
	Elf_Scn *scn;
	Elf_Data *data;
	int fd, j = 0;

	elf_version(EV_CURRENT);

	if ((fd = open(name, O_RDONLY)) < 0) {
		say_syserror("load_symbols, open: %s", name);
		return;
	}

	if ((elf = elf_begin(fd, ELF_C_READ, NULL)) == NULL) {
		say_error("elf_begin: %s", elf_errmsg(-1));
		goto cleanup;
	}

	scn = NULL;
	while ((scn = elf_nextscn(elf, scn)) != NULL) {
		gelf_getshdr(scn, &shdr);
		if (shdr.sh_type != SHT_SYMTAB)
			continue;

		data = NULL;
		while ((data = elf_getdata(scn, data)) != NULL) {
			int count = shdr.sh_size / shdr.sh_entsize;
			for (int i = 0; i < count; i++) {
				gelf_getsym(data, i, &sym);
				if (GELF_ST_TYPE(sym.st_info) != STT_FUNC ||
				    sym.st_value == 0)
					continue;

				symbol_count++;
			}
		}
	}

	symbols = xmalloc(symbol_count * sizeof(struct symbol));

	scn = NULL;
	while ((scn = elf_nextscn(elf, scn)) != NULL) {
		gelf_getshdr(scn, &shdr);
		if (shdr.sh_type != SHT_SYMTAB)
			continue;

		data = NULL;
		while ((data = elf_getdata(scn, data)) != NULL) {
			int count = shdr.sh_size / shdr.sh_entsize;
			for (int i = 0; i < count; i++) {
				gelf_getsym(data, i, &sym);
				if (GELF_ST_TYPE(sym.st_info) != STT_FUNC ||
				    sym.st_value == 0)
					continue;

				char *name = elf_strptr(elf, shdr.sh_link, sym.st_name);
				symbols[j].name = strdup(name);
				symbols[j].addr = (void *)(uintptr_t)sym.st_value;
				symbols[j].end = (void *)(uintptr_t)sym.st_value + sym.st_size;
				j++;
			}
		}
	}

	qsort(symbols, symbol_count, sizeof(struct symbol), compare_symbol);

	if (symbol_count == 0)
		say_warn("no symbols were loaded");

cleanup:
	if (elf)
		elf_end(elf);
	close(fd);
}

struct symbol *
addr2symbol(void *addr)
{
	int low = 0, high = symbol_count, middle = -1;
	struct symbol *ret, key = {.addr = addr};

	while(low < high) {
		middle = low + (high - low) / 2;
		int diff = compare_symbol(symbols + middle, &key);

		if (diff < 0) {
			low = middle + 1;
		} else if (diff > 0) {
			high = middle;
		} else {
			ret = symbols + middle;
			goto out;
		}
	}
	ret = symbols + high - 1;

out:
	if (middle != -1 && ret->addr <= addr && addr <= ret->end)
		return ret;
	return NULL;
}

#endif

void *
xmalloc(size_t size)
{
	void *ptr = malloc(size);
	if (ptr == NULL)
		panic("Out of memory");
	return ptr;
}

void *
xcalloc(size_t nmemb, size_t size)
{
	void *ptr = calloc(nmemb, size);
	if (ptr == NULL)
		panic("Out of memory");
	return ptr;
}

void *
xrealloc(void *ptr, size_t size)
{
	ptr = realloc(ptr, size);
	if (size > 0 && ptr == NULL)
		panic("Out of memory");
	return ptr;
}


register_source();
