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
#import <tbuf.h>
#import <say.h>
#import <stat.h>

#define SECS 5

struct {
	const char *name;
	i64 value;
} *stats = NULL;
static int stats_size = 0;
static int stats_max = 0;
static int base = 0;

int
stat_register(char * const * name, size_t count)
{
	int initial_base = base;

	for (int i = 0; i < count; i++, name++, base++) {
		if (stats_size <= base) {
			stats_size += 1024;
			stats = xrealloc(stats, sizeof(*stats) * stats_size);
			if (stats == NULL)
				abort();
		}

		stats[base].name = *name;

		if (*name == NULL)
			continue;

		stats[base].value = 0;

		stats_max = base;
	}

	return initial_base;
}

void
stat_collect(int base, int name, i64 value)
{
	stats[base + name].value += value;
}

void
stat_print(lua_State *L, struct tbuf *buf)
{
	lua_getglobal(L, "stat");
	lua_getfield(L, -1, "print");
	lua_remove(L, -2);
	if (lua_pcall(L, 0, 1, 0) == 0) {
		size_t len;
		const char *str = lua_tolstring(L, -1, &len);
		tbuf_append(buf, str, len);
	} else {
		say_error("lua_pcall(stat.print): %s", lua_tostring(L, -1));
	}
	lua_pop(L, 1);
}

static int
stat_record(lua_State *L)
{
	if (stats == NULL)
		return 0;

	lua_newtable(L); /* table with stats */
	for (int i = 0; i <= stats_max; i++) {
		if (stats[i].name == NULL)
			continue;

		lua_pushstring(L, stats[i].name);
		lua_pushnumber(L, stats[i].value);
		lua_settable(L, -3);
	}

	for (int i = 0; i <= stats_max; i++) {
			if (stats[i].name == NULL)
				continue;
			stats[i].value = 0;
	}

	return 1;
}

void
stat_init()
{
	lua_State *L = fiber->L;
	int top = lua_gettop(L);
	lua_pushcfunction(L, luaT_traceback);
	lua_getglobal(L, "stat");
	lua_getfield(L, -1, "new_with_graphite");
	lua_pushstring(L, "stat");
	lua_pushcfunction(L, stat_record);
	if (lua_pcall(L, 2, 0, top+1)) {
		panic("could not initialize statistic, lua error: %s", lua_tostring(L, -1));
	}
	lua_settop(L, top);
}

register_source();
