/*
 * Copyright (C) 2011, 2012, 2013, 2014 Mail.RU
 * Copyright (C) 2011, 2012, 2013, 2014 Yuriy Vostrikov
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

#ifndef IPROTO_H
#define IPROTO_H

#include <util.h>
#include <objc.h>
#include <tbuf.h>
#include <net_io.h>

#include <stdint.h>

#include <iproto_def.h>

extern const uint32_t msg_ping;
extern const uint32_t msg_replica;

static inline struct iproto *iproto(const struct tbuf *t)
{
	return (struct iproto *)t->ptr;
}

static inline struct iproto_retcode *iproto_retcode(const struct tbuf *t)
{
	return (struct iproto_retcode *)t->ptr;
}

static inline struct iproto *iproto_parse(struct tbuf *t)
{
	if (tbuf_len(t) < sizeof(struct iproto) ||
	    tbuf_len(t) < sizeof(struct iproto) + iproto(t)->data_len)
		return NULL;

	struct iproto *ret = iproto(t);
	tbuf_ltrim(t, sizeof(struct iproto) + ret->data_len);
	return ret;
}


struct netmsg_head;
struct iproto_retcode * iproto_reply(struct netmsg_head *h, const struct iproto *request);
struct iproto_retcode * iproto_reply_start(struct netmsg_head *h, const struct iproto *request);
void iproto_reply_fixup(struct netmsg_head *h, struct iproto_retcode *reply);
void iproto_error(struct netmsg_head *h, const struct iproto *request, u32 ret_code, const char *err);

void iproto_worker(va_list ap);

struct iproto_peer {
	struct conn c;
	SLIST_ENTRY(iproto_peer) link;
	int id;
	const char *name;
	struct sockaddr_in addr;
	bool connect_err_said;

	ev_tstamp last_connect_try;
};
SLIST_HEAD(iproto_group, iproto_peer);

int init_iproto_peer(struct iproto_peer *p, int id, const char *name, const char *addr);

void iproto_ping(struct netmsg_head *h, struct iproto *r, struct conn *c);

void
service_register_iproto_stream(struct service *s, u32 cmd,
			       void (*cb)(struct netmsg_head *, struct iproto *, struct conn *),
			       int flags);
void
service_register_iproto_block(struct service *s, u32 cmd,
			      void (*cb)(struct iproto *, struct conn *),
			      int flags);

struct iproto_req {
	struct iproto header;
	const char *name;
	u16 count, quorum;
	ev_timer timer;
	struct fiber *waiter;
	ev_tstamp sent, timeout, closed;
	struct iproto **reply;
};


u32 iproto_next_sync();
void iproto_reply_reader(va_list ap);
void iproto_collect_reply(struct conn *c, struct iproto *msg);
void iproto_rendevouz(va_list ap);
void iproto_pinger(va_list ap);

struct iproto_req *iproto_req_make(u16 msg_code, ev_tstamp timeout, const char *name);
void iproto_req_release(struct iproto_req *r);
void iproto_send(struct iproto_peer *peer, struct iproto_req *r,
		 const struct iovec *iov, int iovcnt);
void iproto_broadcast(struct iproto_group *group, int quorum, struct iproto_req *r,
		      const struct iovec *iov, int iovcnt);

#define FOREACH_REPLY(req, var) for (struct iproto **var##p = (req)->reply, *var = *var##p; \
				     var; var  = *++var##p)

@interface IProtoError : Error {
@public
	u32 code;
}
- (IProtoError *)init_code:(u32)code_
		      line:(unsigned)line_
		      file:(const char *)file_
		 backtrace:(const char *)backtrace_
		    reason:(const char *)reason_;
- (IProtoError *)init_code:(u32)code_
		      line:(unsigned)line_
		      file:(const char *)file_
		 backtrace:(const char *)backtrace_
		    format:(const char *)fmt, ...;
- (u32)code;
@end

#define iproto_exc(err, msg)						\
	[[IProtoError palloc] init_code:(err)				\
				   line:__LINE__			\
				   file:__FILE__			\
			      backtrace:NULL				\
				 reason:(msg)]
#define iproto_fexc(err, fmt, ...)					\
	[[IProtoError palloc] init_code:(err)				\
				   line:__LINE__			\
				   file:__FILE__			\
			      backtrace:NULL				\
				 format:(fmt), __VA_ARGS__]

#define iproto_raise(...) @throw iproto_exc(__VA_ARGS__)
#define iproto_raise_fmt(...) @throw iproto_fexc(__VA_ARGS__)

enum error_codes ENUM_INITIALIZER(ERROR_CODES);

#endif
