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
#include <stdbool.h>

#import <say.h>
#import <tbuf.h>
#import <fiber.h>
#import <pickle.h>
#import <index.h>

@implementation IndexError
@end

@implementation Index
- (id)
init
{
	[super init];
	for (int i = 0; i < INDEX_NODE_CACHE; i++)
		node_cache[i] = calloc(1, 512);
	return self;
}

- (void)
valid_object:(struct tnt_object*)obj
{
	GET_NODE(obj);
}

- (u32)
cardinality
{
	return 1;
}
@end

void __attribute__((noreturn, cold))
index_raise_(const char *file, int line, const char *msg)
{
	@throw [[IndexError palloc] init_line:line
					 file:file
				    backtrace:NULL
				       reason:msg];
}
