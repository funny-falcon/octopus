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

#ifndef NET_IO_H
#define NET_IO_H

#include <tbuf.h>
#include <octopus.h>
#include <octopus_ev.h>
#include <palloc.h>

#include <third_party/queue.h>

#include <stdbool.h>
#include <sys/uio.h>
#include <netinet/in.h>

/* macro for generating laujit's cdefs*/
#ifndef LUA_DEF
# define LUA_DEF
#endif

struct fiber;
struct service;

struct netmsg;
TAILQ_HEAD(netmsg_tailq, netmsg);

struct netmsg_head {
	struct netmsg_tailq q;
	struct palloc_pool *pool;
	ssize_t bytes;
};

#ifndef IOV_MAX
#  define IOV_MAX 1024
#endif


#define NETMSG_IOV_SIZE 64
struct netmsg {
	TAILQ_ENTRY(netmsg) link; /* first sizeof(void *) bytes are trashed by salloc() */
	int count;
	struct iovec *barrier;

	struct iovec iov[NETMSG_IOV_SIZE];
	uintptr_t ref[NETMSG_IOV_SIZE];
};

struct netmsg_mark {
	struct netmsg *m;
	struct iovec iov;
	int offset;
};

enum conn_memory_ownership {
	MO_MALLOC	 = 0x01,
	MO_STATIC	 = 0x02,
	MO_SLAB		 = 0x03,
	MO_MY_OWN_POOL   = 0x10
};
#define MO_CONN_OWNERSHIP_MASK	(MO_MALLOC | MO_STATIC | MO_SLAB)

struct conn {
	struct palloc_pool *pool;
	struct tbuf *rbuf;
	int fd, ref;
	struct netmsg_head out_messages;

	enum conn_memory_ownership  memory_ownership;
	enum { CLOSED, IN_CONNECT, CONNECTED } state;
	LIST_ENTRY(conn) link;
	TAILQ_ENTRY(conn) processing_link;
	ev_io in, out;
	struct service *service;
	char peer_name[22]; /* aaa.bbb.ccc.ddd:xxxxx */

	ev_timer 	timer;

	int iov_offset;
	struct iovec *iov_end;
	struct iovec iov[IOV_MAX];
};

enum { IPROTO_NONBLOCK = 1 };
struct iproto;
typedef union {
	void (*stream)(struct netmsg_head *, struct iproto *, struct conn *);
	void (*block)(struct iproto *, struct conn *);
} iproto_cb;

struct iproto_handler {
	iproto_cb cb;
	int flags;
	int code;
};

struct service {
	struct palloc_pool *pool;
	size_t pool_allocated; /* used for differential calls to palloc_gc */
	const char *name;
	TAILQ_HEAD(conn_tailq, conn) processing;
	LIST_HEAD(, conn) conn;
	struct fiber *acceptor, *input_reader, *output_flusher;
	SLIST_HEAD(, fiber) workers; /* <- handlers */
	int batch;
	ev_prepare wakeup;
	struct iproto_handler default_handler;
	int ih_size, ih_mask;
	struct iproto_handler *ih;
};
#define SERVICE_DEFAULT_CAPA 0x100

void service_set_handler(struct service *s, struct iproto_handler h);

static inline struct iproto_handler*
service_find_code(struct service *s, int code)
{
	int pos = code & s->ih_mask;
	if (s->ih[pos].code == code) return &s->ih[pos];
	if (s->ih[pos].code == -1) return &s->default_handler;
	int dlt = (code % s->ih_mask) | 1;
	do {
		pos = (pos + dlt) & s->ih_mask;
		if (s->ih[pos].code == code) return &s->ih[pos];
	} while(s->ih[pos].code != -1);
	return &s->default_handler;
}


void netmsg_head_init(struct netmsg_head *h, struct palloc_pool *pool) LUA_DEF;
void netmsg_head_release(struct netmsg_head *h) LUA_DEF;

struct netmsg *netmsg_concat(struct netmsg_head *dst, struct netmsg_head *src) LUA_DEF;
void netmsg_release(struct netmsg_head *h, struct netmsg *m) LUA_DEF;
void netmsg_rewind(struct netmsg_head *h, const struct netmsg_mark *mark) LUA_DEF;
void netmsg_getmark(struct netmsg_head *h, struct netmsg_mark *mark) LUA_DEF;

void net_add_iov(struct netmsg_head *o, const void *buf, size_t len) LUA_DEF;
struct iovec *net_reserve_iov(struct netmsg_head *o) LUA_DEF;
void net_add_iov_dup(struct netmsg_head *o, const void *buf, size_t len) LUA_DEF;
#define net_add_dup(o, buf) net_add_iov_dup(o, (buf), sizeof(*(buf)))
void net_add_ref_iov(struct netmsg_head *o, uintptr_t ref, const void *buf, size_t len) LUA_DEF;
void net_add_obj_iov(struct netmsg_head *o, struct tnt_object *obj, const void *buf, size_t len) LUA_DEF;
void netmsg_verify_ownership(struct netmsg_head *h); /* debug method */

struct conn *conn_init(struct conn *c, struct palloc_pool *pool, int fd,
		       struct fiber *in, struct fiber *out, enum conn_memory_ownership memory_ownership);
void conn_set(struct conn *c, int fd);
int conn_close(struct conn *c);
void conn_gc(struct palloc_pool *pool, void *ptr);
ssize_t conn_recv(struct conn *c);
ssize_t conn_read(struct conn *c, void *buf, size_t count);
ssize_t conn_write(struct conn *c, const void *buf, size_t count);
ssize_t conn_write_netmsg(struct conn *c);
ssize_t conn_flush(struct conn *c);
char *conn_peer_name(struct conn *c);
void conn_unref(struct conn *c) LUA_DEF;

void conn_flusher(va_list ap __attribute__((unused)));

enum tac_state {
	tac_ok = 0,
	tac_error,
	tac_wait,
	tac_alien_event
};
enum tac_state  tcp_async_connect(struct conn *c, ev_watcher *w,
				struct sockaddr_in 	*dst,
				struct sockaddr_in 	*src,
				ev_tstamp		timeout);

int tcp_connect(struct sockaddr_in *dst, struct sockaddr_in *src, ev_tstamp timeout);
struct tcp_server_state {
	const char *addr;
	void (*handler)(int fd, void *data, struct tcp_server_state *state);
	void (*on_bind)(int fd);
	void *data;
	struct sockaddr_in saddr;
	ev_io io;
};
void tcp_server(va_list ap);
void tcp_server_stop(struct tcp_server_state *state);
void udp_server(va_list ap);
int server_socket(int type, struct sockaddr_in *src, int nonblock,
		  void (*on_bind)(int fd), void (*sleep)(ev_tstamp tm));

void tcp_service(struct service *s , const char *addr, void (*on_bind)(int fd), void (*wakeup)(ev_prepare *));
void wakeup_workers(ev_prepare *ev);
void service_iproto(struct service *s);
void iproto_wakeup_workers(ev_prepare *ev);

int atosin(const char *orig, struct sockaddr_in *addr) LUA_DEF;
const char *sintoa(const struct sockaddr_in *addr);
int net_fixup_addr(char **addr, int port);

void service_info(struct tbuf *out, struct service *service);


void luaT_opennet(struct lua_State *L);
int luaT_pushnetmsg(struct lua_State *L);

void title(const char *fmt, ...);
#endif
