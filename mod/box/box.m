/*
 * Copyright (C) 2010, 2011, 2012, 2013, 2014 Mail.RU
 * Copyright (C) 2010, 2011, 2012, 2013, 2014 Yuriy Vostrikov
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
#import <iproto.h>
#import <log_io.h>
#import <net_io.h>
#import <pickle.h>
#import <salloc.h>
#import <say.h>
#import <stat.h>
#import <octopus.h>
#import <tbuf.h>
#import <util.h>
#import <objc.h>
#import <assoc.h>
#import <index.h>
#import <paxos.h>

#import <mod/box/box.h>
#import <mod/box/moonbox.h>
#import <mod/box/box_version.h>

#include <third_party/crc32.h>

#include <stdarg.h>
#include <stdint.h>
#include <stdbool.h>
#include <errno.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sysexits.h>

static struct service box_primary, box_secondary;

static int stat_base;
char * const box_ops[] = ENUM_STR_INITIALIZER(MESSAGES);

struct object_space *object_space_registry;
const int object_space_count = 256, object_space_max_idx = MAX_IDX;

void __attribute__((noreturn))
bad_object_type()
{
	raise("bad object type");
}

void *
next_field(void *f)
{
	u32 size = LOAD_VARINT32(f);
	return (u8 *)f + size;
}

void *
tuple_field(struct box_tuple *tuple, size_t i)
{
	void *field = tuple->data;

	if (i >= tuple->cardinality)
		return NULL;

	while (i-- > 0)
		field = next_field(field);

	return field;
}


static struct tnt_object *
tuple_alloc(unsigned cardinality, unsigned size)
{
	struct tnt_object *obj = object_alloc(BOX_TUPLE, sizeof(struct box_tuple) + size);
	struct box_tuple *tuple = box_tuple(obj);

	tuple->bsize = size;
	tuple->cardinality = cardinality;
	say_debug("tuple_alloc(%u, %u) = %p", cardinality, size, tuple);
	return obj;
}

ssize_t
tuple_bsize(u32 cardinality, const void *data, u32 max_len)
{
	struct tbuf tmp = TBUF(data, max_len, NULL);
	for (int i = 0; i < cardinality; i++)
		read_field(&tmp);

	return tmp.ptr - data;
}

static void
tuple_add(struct netmsg_head *h, struct tnt_object *obj)
{
	struct box_tuple *tuple = box_tuple(obj);
	size_t size = tuple->bsize +
		      sizeof(tuple->bsize) +
		      sizeof(tuple->cardinality);

	/* it's faster to copy & join small tuples into single large
	   iov entry. join is done by net_add_iov() */
	if (tuple->bsize > 512)
		net_add_obj_iov(h, obj, &tuple->bsize, size);
	else
		net_add_iov_dup(h, &tuple->bsize, size);
}

static void
box_replace(struct box_txn *txn)
{
	if (!txn->obj)
		return;

	foreach_index(index, txn->object_space) {
		if (index->conf.unique) {
			struct tnt_object *obj = [index find_by_obj:txn->obj];
			if (obj == NULL) {
				[index replace:txn->obj];
			} else if (obj == txn->old_obj) {
				[index valid_object:txn->obj];
				txn->index_eqmask |= 1 << index->conf.n;
			} else {
				iproto_raise_fmt(ERR_CODE_INDEX_VIOLATION,
						 "duplicate key value violates unique index %i:%s",
						 index->conf.n, [[index class] name]);
			}
		} else {
			[index replace:txn->obj];
		}
	}
}


enum obj_age {OLD, YOUNG};
static struct tnt_object *
txn_acquire(struct box_txn *txn, struct tnt_object *obj, enum obj_age age)
{
	say_debug("%s: obj:%p age:%s", __func__, obj, age == YOUNG ? "young" : "old");

	if (obj == NULL)
		return NULL;

	object_lock(obj); /* throws exception on lock failure */
	if (age == YOUNG) {
		txn->obj = obj;
		obj->flags |= GHOST;
	} else {
		txn->old_obj = obj;
	}
	object_incr_ref(obj);
	return obj;
}


static void __attribute__((noinline))
prepare_replace(struct box_txn *txn, size_t cardinality, const void *data, u32 data_len)
{
	if (cardinality == 0)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "cardinality can't be equal to 0");
	if (data_len == 0 || tuple_bsize(cardinality, data, data_len) != data_len)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "tuple encoding error");

	txn_acquire(txn, tuple_alloc(cardinality, data_len), YOUNG);
	struct box_tuple *tuple = box_tuple(txn->obj);
	memcpy(tuple->data, data, data_len);

	txn_acquire(txn, [txn->index find_by_obj:txn->obj], OLD);
	txn->obj_affected = txn->old_obj != NULL ? 2 : 1;

	if (txn->flags & BOX_ADD && txn->old_obj != NULL)
		iproto_raise(ERR_CODE_NODE_FOUND, "tuple found");
	if (txn->flags & BOX_REPLACE && txn->old_obj == NULL)
		iproto_raise(ERR_CODE_NODE_NOT_FOUND, "tuple not found");

	say_debug("%s: old_obj:%p obj:%p", __func__, txn->old_obj, txn->obj);
	box_replace(txn);
}

static void
do_field_arith(u8 op, struct tbuf *field, const void *arg, u32 arg_size)
{
	if (tbuf_len(field) != arg_size)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "num op arg size not equal to field size");

	switch (arg_size) {
	case 2:
		switch (op) {
		case 1: *(u16 *)field->ptr += *(u16 *)arg; break;
		case 2: *(u16 *)field->ptr &= *(u16 *)arg; break;
		case 3: *(u16 *)field->ptr ^= *(u16 *)arg; break;
		case 4: *(u16 *)field->ptr |= *(u16 *)arg; break;
		default: iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "unknown num op");
		}
		break;
	case 4:
		switch (op) {
		case 1: *(u32 *)field->ptr += *(u32 *)arg; break;
		case 2: *(u32 *)field->ptr &= *(u32 *)arg; break;
		case 3: *(u32 *)field->ptr ^= *(u32 *)arg; break;
		case 4: *(u32 *)field->ptr |= *(u32 *)arg; break;
		default: iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "unknown num op");
		}
		break;
	case 8:
		switch (op) {
		case 1: *(u64 *)field->ptr += *(u64 *)arg; break;
		case 2: *(u64 *)field->ptr &= *(u64 *)arg; break;
		case 3: *(u64 *)field->ptr ^= *(u64 *)arg; break;
		case 4: *(u64 *)field->ptr |= *(u64 *)arg; break;
		default: iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "unknown num op");
		}
		break;
	default: iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "bad num op size");
	}
}

static inline size_t __attribute__((pure))
field_len(const struct tbuf *b)
{
	return varint32_sizeof(tbuf_len(b)) + tbuf_len(b);
}

static size_t
do_field_splice(struct tbuf *field, const void *args_data, u32 args_data_size)
{
	struct tbuf args = TBUF(args_data, args_data_size, NULL);
	struct tbuf *new_field = NULL;
	const u8 *offset_field, *length_field, *list_field;
	u32 offset_size, length_size, list_size;
	i32 offset, length;
	u32 noffset, nlength;	/* normalized values */

	new_field = tbuf_alloc(fiber->pool);

	offset_field = read_field(&args);
	length_field = read_field(&args);
	list_field = read_field(&args);
	if (tbuf_len(&args)!= 0)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "do_field_splice: bad args");

	offset_size = LOAD_VARINT32(offset_field);
	if (offset_size == 0)
		noffset = 0;
	else if (offset_size == sizeof(offset)) {
		offset = *(u32 *)offset_field;
		if (offset < 0) {
			if (tbuf_len(field) < -offset)
				iproto_raise(ERR_CODE_ILLEGAL_PARAMS,
					  "do_field_splice: noffset is negative");
			noffset = offset + tbuf_len(field);
		} else
			noffset = offset;
	} else
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "do_field_splice: bad size of offset field");
	if (noffset > tbuf_len(field))
		noffset = tbuf_len(field);

	length_size = LOAD_VARINT32(length_field);
	if (length_size == 0)
		nlength = tbuf_len(field) - noffset;
	else if (length_size == sizeof(length)) {
		if (offset_size == 0)
			iproto_raise(ERR_CODE_ILLEGAL_PARAMS,
				  "do_field_splice: offset field is empty but length is not");

		length = *(u32 *)length_field;
		if (length < 0) {
			if ((tbuf_len(field) - noffset) < -length)
				nlength = 0;
			else
				nlength = length + tbuf_len(field) - noffset;
		} else
			nlength = length;
	} else
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "do_field_splice: bad size of length field");
	if (nlength > (tbuf_len(field) - noffset))
		nlength = tbuf_len(field) - noffset;

	list_size = LOAD_VARINT32(list_field);
	if (list_size > 0 && length_size == 0)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS,
			  "do_field_splice: length field is empty but list is not");
	if (list_size > (UINT32_MAX - (tbuf_len(field) - nlength)))
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "do_field_splice: list_size is too long");

	say_debug("do_field_splice: noffset = %i, nlength = %i, list_size = %u",
		  noffset, nlength, list_size);

	tbuf_reset(new_field);
	tbuf_append(new_field, field->ptr, noffset);
	tbuf_append(new_field, list_field, list_size);
	tbuf_append(new_field, field->ptr + noffset + nlength, tbuf_len(field) - (noffset + nlength));

	size_t diff = field_len(new_field) - field_len(field);

	*field = *new_field;
	return diff;
}

static void __attribute__((noinline))
prepare_update_fields(struct box_txn *txn, struct tbuf *data)
{
	struct tbuf *fields;
	const u8 *field;
	int i;
	u32 op_cnt;

	u32 key_cardinality = read_u32(data);
	if (key_cardinality < txn->object_space->index[0]->conf.min_tuple_cardinality)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "key isn't fully specified");

	txn_acquire(txn, [txn->index find_key:data with_cardinalty:key_cardinality], OLD);

	op_cnt = read_u32(data);
	if (op_cnt > 128)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "too many ops");
	if (op_cnt == 0)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "no ops");

	if (txn->old_obj == NULL) {
		/* pretend we parsed all data */
		tbuf_ltrim(data, tbuf_len(data));
		return;
	}
	txn->obj_affected = 1;

	struct box_tuple *old_tuple = box_tuple(txn->old_obj);
	size_t bsize = old_tuple->bsize;
	int cardinality = old_tuple->cardinality;
	int field_count = cardinality * 1.2;
	fields = palloc(fiber->pool, field_count * sizeof(struct tbuf));

	for (i = 0, field = old_tuple->data; i < cardinality; i++) {
		const void *src = field;
		int len = LOAD_VARINT32(field);
		/* .ptr  - start of varint
		   .end  - start of data
		   .free - len(data) */
		fields[i] = (struct tbuf){ .ptr = (void *)src, .end = (void *)field,
					   .free = len, .pool = NULL };
		field += len;
	}

	while (op_cnt-- > 0) {
		u8 op;
		u32 field_no, arg_size;
		const u8 *arg;
		struct tbuf *field = NULL;

		field_no = read_u32(data);
		op = read_u8(data);
		arg = read_field(data);
		arg_size = LOAD_VARINT32(arg);

		if (op <= 6) {
			if (field_no >= cardinality)
				iproto_raise(ERR_CODE_ILLEGAL_PARAMS,
					     "update of field beyond tuple cardinality");
			field = &fields[field_no];
		}
		if (op < 6) {
			if (field->pool == NULL) {
				void *field_data = field->end;
				int field_len = field->free;
				int expected_size = MAX(arg_size, field_len);
				field->ptr = palloc(fiber->pool, expected_size ? : 8);
				memcpy(field->ptr, field_data, field_len);
				field->end = field->ptr + field_len;
				field->free = expected_size - field_len;
				field->pool = fiber->pool;
			}
		}

		switch (op) {
		case 0:
			bsize -= field_len(field);
			bsize += varint32_sizeof(arg_size) + arg_size;
			tbuf_reset(field);
			tbuf_append(field, arg, arg_size);
			break;
		case 1 ... 4:
			do_field_arith(op, field, arg, arg_size);
			break;
		case 5:
			bsize += do_field_splice(field, arg, arg_size);
			break;
		case 6:
			if (arg_size != 0)
				iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "delete must have empty arg");
			if (field_no == 0)
				iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "unabled to delete PK");

			if (field->pool == NULL) {
				bsize -= tbuf_len(field) + tbuf_free(field);
			} else {
				bsize -= field_len(field);
			}
			for (int i = field_no; i < cardinality - 1; i++)
				fields[i] = fields[i + 1];
			cardinality--;
			break;
		case 7:
			if (field_no == 0)
				iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "unabled to insert PK");
			if (field_no > cardinality)
				iproto_raise(ERR_CODE_ILLEGAL_PARAMS,
					     "update of field beyond tuple cardinality");
			if (unlikely(field_count == cardinality)) {
				struct tbuf *tmp = fields;
				fields = p0alloc(fiber->pool,
						 (old_tuple->cardinality + 128) * sizeof(struct tbuf));
				memcpy(fields, tmp, field_count * sizeof(struct tbuf));
			}
			for (int i = cardinality - 1; i >= field_no; i--)
				fields[i + 1] = fields[i];
			void *ptr = palloc(fiber->pool, arg_size);
			fields[field_no] = TBUF(ptr, arg_size, fiber->pool);
			memcpy(fields[field_no].ptr, arg, arg_size);
			bsize += varint32_sizeof(arg_size) + arg_size;
			cardinality++;
			break;
		default:
			iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "invalid op");
		}
	}

	if (tbuf_len(data) != 0)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "can't unpack request");

	txn_acquire(txn, tuple_alloc(cardinality, bsize), YOUNG);

	u8 *p = box_tuple(txn->obj)->data;
	i = 0;
	do {
		if (fields[i].pool == NULL) {
			void *ptr = fields[i].ptr;
			void *end = fields[i].end + fields[i].free;
			for (i++; i < cardinality; i++) {
				if (end != fields[i].ptr)
					break;
				else
					end = fields[i].end + fields[i].free;
			}
			memcpy(p, ptr, end - ptr);
			p += end - ptr;
		} else {
			int len = tbuf_len(&fields[i]);
			p = save_varint32(p, len);
			memcpy(p, fields[i].ptr, len);
			p += len;
			i++;
		}
	} while (i < cardinality);

	Index<BasicIndex> *pk = txn->object_space->index[0];
	if (![pk eq:txn->old_obj :txn->obj])
		txn->obj_affected++;

	box_replace(txn);
}


static void __attribute__((noinline))
process_select(struct netmsg_head *h, Index<BasicIndex> *index,
	       u32 limit, u32 offset, struct tbuf *data)
{
	struct tnt_object *obj;
	uint32_t *found;
	u32 count = read_u32(data);

	say_debug("SELECT");
	found = palloc(h->pool, sizeof(*found));
	net_add_iov(h, found, sizeof(*found));
	*found = 0;

	if (index->conf.type == HASH || (index->conf.unique && index->conf.cardinality == 1)) {
		for (u32 i = 0; i < count; i++) {
			u32 c = read_u32(data);
			obj = [index find_key:data with_cardinalty:c];
			if (obj == NULL)
				continue;
			if (unlikely(ghost(obj)))
				continue;
			if (unlikely(limit == 0))
				continue;
			if (unlikely(offset > 0)) {
				offset--;
				continue;
			}

			(*found)++;
			tuple_add(h, obj);
			limit--;
		}
	} else {
		/* The only non unique index type is Tree */
		Tree *tree = (Tree *)index;
		for (u32 i = 0; i < count; i++) {
			u32 c = read_u32(data);
			[tree iterator_init:data with_cardinalty:c];

			if (unlikely(limit == 0))
				continue;

			while ((obj = [tree iterator_next_verify_pattern]) != NULL) {
				if (unlikely(ghost(obj)))
					continue;
				if (unlikely(limit == 0))
					continue;
				if (unlikely(offset > 0)) {
					offset--;
					continue;
				}

				(*found)++;
				tuple_add(h, obj);
				--limit;
			}
		}
	}

	if (tbuf_len(data) != 0)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "can't unpack request");

	stat_collect(stat_base, SELECT_KEYS, count);
}

static void __attribute__((noinline))
prepare_delete(struct box_txn *txn, struct tbuf *key_data)
{
	u32 c = read_u32(key_data);
	txn_acquire(txn, [txn->index find_key:key_data with_cardinalty:c], OLD);
	txn->obj_affected = txn->old_obj != NULL;
}

void
box_prepare(struct box_txn *txn, struct tbuf *data)
{
	say_debug("%s op:%i", __func__, txn->op);

	i32 n = read_u32(data);
	if (n < 0 || n > object_space_count - 1)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "bad namespace number");

	if (!object_space_registry[n].enabled)
		iproto_raise_fmt(ERR_CODE_ILLEGAL_PARAMS, "object_space %i is not enabled", n);

	if (object_space_registry[n].ignored)
		/* txn->object_space == NULL means this txn will be ignored */
		return;

	txn->object_space = &object_space_registry[n];
	txn->index = txn->object_space->index[0];

	switch (txn->op) {
	case INSERT:
		txn->flags = read_u32(data);
		u32 cardinality = read_u32(data);
		u32 data_len = tbuf_len(data);
		void *tuple_bytes = read_bytes(data, data_len);
		prepare_replace(txn, cardinality, tuple_bytes, data_len);
		break;

	case DELETE:
		txn->flags = read_u32(data); /* RETURN_TUPLE */
	case DELETE_1_3:
		prepare_delete(txn, data);
		break;

	case UPDATE_FIELDS:
		txn->flags = read_u32(data);
		prepare_update_fields(txn, data);
		break;

	case NOP:
		break;

	default:
		iproto_raise_fmt(ERR_CODE_ILLEGAL_PARAMS, "unknown opcode:%"PRIi32, txn->op);
	}

	if (txn->obj) {
		struct box_tuple *tuple = box_tuple(txn->obj);
		if (txn->object_space->cardinality > 0 &&
		    txn->object_space->cardinality != tuple->cardinality)
		{
			iproto_raise(ERR_CODE_ILLEGAL_PARAMS,
				     "tuple cardinality must match object_space cardinality");
		}

		if (tuple_bsize(tuple->cardinality, tuple->data, tuple->bsize) != tuple->bsize)
			iproto_raise(ERR_CODE_UNKNOWN_ERROR, "internal error");
	}
	if (tbuf_len(data) != 0)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "can't unpack request");
}

static void
box_lua_cb(struct iproto *request, struct conn *c)
{
	say_debug("%s: c:%p op:0x%02x sync:%u", __func__, c,
		  request->msg_code, request->sync);

	@try {
		ev_tstamp start = ev_now(), stop;

		if (unlikely(c->service != &box_primary))
			iproto_raise(ERR_CODE_NONMASTER, "updates forbiden on secondary port");

		box_dispach_lua(c, request);
		stat_collect(stat_base, EXEC_LUA, 1);

		stop = ev_now();
		if (stop - start > cfg.too_long_threshold)
			say_warn("too long %s: %.3f sec", box_ops[request->msg_code], stop - start);
	}
	@catch (Error *e) {
		say_warn("aborting lua request, [%s reason:\"%s\"] at %s:%d peer:%s",
			 [[e class] name], e->reason, e->file, e->line, conn_peer_name(c));
		if (e->backtrace)
			say_debug("backtrace:\n%s", e->backtrace);
		@throw;
	}
}

static void
box_paxos_cb(struct iproto *request __attribute__((unused)),
	     struct conn *c __attribute__((unused)))
{
	if ([recovery respondsTo:@selector(leader_redirect_raise)])
		[recovery perform:@selector(leader_redirect_raise)];
	else
		iproto_raise(ERR_CODE_UNSUPPORTED_COMMAND,
			     "PAXOS_LEADER unsupported in non cluster configuration");
}

static void
box_cb(struct iproto *request, struct conn *c)
{
	say_debug("%s: c:%p op:0x%02x sync:%u", __func__, c, request->msg_code, request->sync);

	struct box_txn txn = { .op = request->msg_code };
	@try {
		ev_tstamp start = ev_now(), stop;

		if (unlikely(c->service != &box_primary))
			iproto_raise(ERR_CODE_NONMASTER, "updates forbiden on secondary port");

		[recovery check_replica];

		box_prepare(&txn, &TBUF(request->data, request->data_len, NULL));

		if (!txn.object_space)
			iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "ignored object space");

		if (txn.obj_affected > 0) {
			if ([recovery submit:request->data
					 len:request->data_len
					 tag:request->msg_code<<5|TAG_WAL] != 1)
				iproto_raise(ERR_CODE_UNKNOWN_ERROR, "unable write wal row");
		}
		box_commit(&txn);

		struct netmsg_head *h = &c->out_messages;
		struct iproto_retcode *reply = iproto_reply_start(h, request);
		net_add_iov_dup(h, &txn.obj_affected, sizeof(u32));
		if (txn.flags & BOX_RETURN_TUPLE) {
			if (txn.obj)
				tuple_add(h, txn.obj);
			else if (request->msg_code == DELETE && txn.old_obj)
				tuple_add(h, txn.old_obj);
		}
		iproto_reply_fixup(h, reply);

		stop = ev_now();
		if (stop - start > cfg.too_long_threshold)
			say_warn("too long %s: %.3f sec", box_ops[txn.op], stop - start);
	}
	@catch (Error *e) {
		if (e->file && strcmp(e->file, "src/paxos.m") != 0) {
			say_warn("aborting txn, [%s reason:\"%s\"] at %s:%d peer:%s",
				 [[e class] name], e->reason, e->file, e->line, conn_peer_name(c));
			if (e->backtrace)
				say_debug("backtrace:\n%s", e->backtrace);
		}
		box_rollback(&txn);
		@throw;
	}
	@finally {
		box_cleanup(&txn);
	}
}

static void
box_select_cb(struct netmsg_head *h, struct iproto *request, struct conn *c __attribute__((unused)))
{
	struct tbuf data = TBUF(request->data, request->data_len, fiber->pool);
	struct iproto_retcode *reply = iproto_reply_start(h, request);
	struct object_space *object_space;

	i32 n = read_u32(&data);
	u32 i = read_u32(&data);
	u32 offset = read_u32(&data);
	u32 limit = read_u32(&data);

	if (n < 0 || n > object_space_count - 1)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "bad namespace number");

	if (!object_space_registry[n].enabled)
		iproto_raise_fmt(ERR_CODE_ILLEGAL_PARAMS, "object_space %i is not enabled", n);

	if (i > MAX_IDX)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "index too big");

	object_space = &object_space_registry[n];

	if ((object_space->index[i]) == NULL)
		iproto_raise(ERR_CODE_ILLEGAL_PARAMS, "index is invalid");

	process_select(h, object_space->index[i], limit, offset, &data);
	iproto_reply_fixup(h, reply);
	stat_collect(stat_base, request->msg_code, 1);
}


static void
configure(void)
{
	if (cfg.object_space == NULL)
		panic("at least one object_space should be configured");

	for (int i = 0; i < object_space_count; i++) {
		if (cfg.object_space[i] == NULL)
			break;

		if (!CNF_STRUCT_DEFINED(cfg.object_space[i]))
			object_space_registry[i].enabled = false;
		else
			object_space_registry[i].enabled = !!cfg.object_space[i]->enabled;

		if (!object_space_registry[i].enabled)
			continue;

		object_space_registry[i].ignored = !!cfg.object_space[i]->ignored;
		object_space_registry[i].cardinality = cfg.object_space[i]->cardinality;

		if (cfg.object_space[i]->index == NULL)
			panic("(object_space = %" PRIu32 ") at least one index must be defined", i);

		for (int j = 0; j < nelem(object_space_registry[i].index); j++) {

			if (cfg.object_space[i]->index[j] == NULL)
				break;

			struct index_conf *ic = cfg_box2index_conf(cfg.object_space[i]->index[j]);
			if (ic == NULL)
				panic("(object_space = %" PRIu32 " index = %" PRIu32 ") "
				      "unknown index type `%s'", i, j, cfg.object_space[i]->index[j]->type);

			ic->n = j;
			Index *index = [Index new_conf:ic dtor:&box_tuple_dtor];

			if (index == nil)
				panic("(object_space = %" PRIu32 " index = %" PRIu32 ") "
				      "XXX unknown index type `%s'", i, j, cfg.object_space[i]->index[j]->type);

			/* FIXME: only reasonable for HASH indexes */
			if ([index respondsTo:@selector(resize:)])
				[(id)index resize:cfg.object_space[i]->estimated_rows];

			if (index->conf.type == TREE && j > 0)
				index = [[DummyIndex alloc] init_with_index:index];

			object_space_registry[i].index[j] = (Index<BasicIndex> *)index;
		}

		Index *pk = object_space_registry[i].index[0];

		if (pk->conf.unique == false)
			panic("(object_space = %" PRIu32 ") object_space PK index must be unique", i);

		object_space_registry[i].enabled = true;

		say_info("object space %i successfully configured", i);
		say_info("  PK %i:%s", pk->conf.n, [[pk class] name]);
	}
}

static void
build_object_space_trees(struct object_space *object_space)
{
	Index<BasicIndex> *pk = object_space->index[0];
	size_t n_tuples = [pk size];
        size_t estimated_tuples = n_tuples * 1.2;

	Tree *ts[MAX_IDX] = { nil, };
	void *nodes[MAX_IDX] = { NULL, };
	int i = 0, tree_count = 0;

	for (int j = 0; object_space->index[j]; j++)
		if ([object_space->index[j] isKindOf:[DummyIndex class]]) {
			DummyIndex *dummy = (id)object_space->index[j];
			if ([dummy is_wrapper_of:[Tree class]]) {
				object_space->index[j] = [dummy unwrap];
				ts[i++] = (id)object_space->index[j];
			}
		}
	tree_count = i;
	if (tree_count == 0)
		return;

	say_info("Building tree indexes of object space %i", object_space->n);

        if (n_tuples > 0) {
		for (int i = 0; i < tree_count; i++) {
                        nodes[i] = xmalloc(estimated_tuples * ts[i]->node_size);
			if (nodes[i] == NULL)
                                panic("can't allocate node array");
                }

		struct tnt_object *obj;
		u32 t = 0;
		[pk iterator_init];
		while ((obj = [pk iterator_next])) {
			for (int i = 0; i < tree_count; i++) {
                                struct index_node *node = nodes[i] + t * ts[i]->node_size;
                                ts[i]->dtor(obj, node, ts[i]->dtor_arg);
                        }
                        t++;
		}
	}

	for (int i = 0; i < tree_count; i++) {
		say_info("  %i:%s", ts[i]->conf.n, [[ts[i] class] name]);
		[ts[i] set_nodes:nodes[i]
			   count:n_tuples
		       allocated:estimated_tuples];
	}
}

static void
build_secondary_indexes()
{
	title("building_indexes");
	@try {
		for (u32 n = 0; n < object_space_count; n++) {
			if (object_space_registry[n].enabled)
				build_object_space_trees(&object_space_registry[n]);
		}
	}
	@catch (Error *e) {
		raise("unable to built tree indexes: %s", e->reason);
	}

	for (u32 n = 0; n < object_space_count; n++) {
		if (!object_space_registry[n].enabled)
			continue;

		struct tbuf *i = tbuf_alloc(fiber->pool);
		foreach_index(index, &object_space_registry[n])
			tbuf_printf(i, " %i:%s", index->conf.n, [[index class] name]);

		say_info("Object space %i indexes:%.*s", n, tbuf_len(i), (char *)i->ptr);
	}
}

void
box_bound_to_primary(int fd)
{
	if (fd < 0) {
		if (!cfg.local_hot_standby)
			panic("unable bind to %s", cfg.primary_addr);
		return;
	}

	if (cfg.local_hot_standby) {
		@try {
			[recovery enable_local_writes];
		}
		@catch (Error *e) {
			panic("Recovery failure: %s", e->reason);
		}
	}
}

static void
box_service_register(struct service *s)
{
	service_iproto(s);

	service_register_iproto_stream(s, NOP, box_select_cb, 0);
	service_register_iproto_stream(s, SELECT, box_select_cb, 0);
	service_register_iproto_stream(s, SELECT_LIMIT, box_select_cb, 0);
	service_register_iproto_block(s, INSERT, box_cb, 0);
	service_register_iproto_block(s, UPDATE_FIELDS, box_cb, 0);
	service_register_iproto_block(s, DELETE, box_cb, 0);
	service_register_iproto_block(s, DELETE_1_3, box_cb, 0);
	service_register_iproto_block(s, EXEC_LUA, box_lua_cb, 0);
	service_register_iproto_block(s, PAXOS_LEADER, box_paxos_cb, 0);
}

static void
initialize_service()
{
	tcp_service(&box_primary, cfg.primary_addr, box_bound_to_primary, iproto_wakeup_workers);
	box_service_register(&box_primary);

	for (int i = 0; i < MAX(1, cfg.wal_writer_inbox_size); i++)
		fiber_create("box_worker", iproto_worker, &box_primary);

	if (cfg.secondary_addr != NULL && strcmp(cfg.secondary_addr, cfg.primary_addr) != 0) {
		tcp_service(&box_secondary, cfg.secondary_addr, NULL, iproto_wakeup_workers);
		box_service_register(&box_secondary);
		fiber_create("box_secondary_worker", iproto_worker, &box_secondary);
	}
	say_info("(silver)box initialized (%i workers)", cfg.wal_writer_inbox_size);
}

void
box_cleanup(struct box_txn *txn)
{
	assert(!txn->closed);
	txn->closed = true;

	if (txn->old_obj) {
		object_unlock(txn->old_obj);
		object_decr_ref(txn->old_obj);
	}
	if (txn->obj) {
		object_unlock(txn->obj);
		txn->obj->flags &= ~GHOST;
		object_decr_ref(txn->obj);
	}
}

void
box_commit(struct box_txn *txn)
{
	if (!txn->object_space)
		return;

	if (txn->old_obj) {
		foreach_index(index, txn->object_space) {
			if (!index->conf.unique ||
			    (txn->index_eqmask & 1 << index->conf.n) == 0)
				[index remove:txn->old_obj];
		}
		object_decr_ref(txn->old_obj);
	}

	if (txn->obj) {
		foreach_index(index, txn->object_space) {
			if (index->conf.unique &&
			    txn->index_eqmask & 1 << index->conf.n)
				[index replace:txn->obj];
		}
		object_incr_ref(txn->obj);
	}

	stat_collect(stat_base, txn->op, 1);

}

void
box_rollback(struct box_txn *txn)
{
	if (!txn->object_space)
		return;

	if (txn->obj == NULL)
		return;

	foreach_index(index, txn->object_space) {
		if (index->conf.unique && [index find_by_obj:txn->obj] != txn->obj)
			continue;

		@try {
			[index remove:txn->obj];
		}
		@catch (IndexError *e) {
			/* obj with invalid shape will cause exception on txn_prepare.
			   since index traversing order is same for prepare and rollback
			   there is no references to obj in following indexes */
			break;
		}
	}
}

@implementation Recovery (Box)

- (void)
apply:(struct tbuf *)data tag:(u16)tag
{
	struct box_txn txn = { .op = 0 };

	@try {

		say_debug("%s tag:%s data:%s", __func__,
			  xlog_tag_to_a(tag), tbuf_to_hex(data));

		int tag_type = tag & ~TAG_MASK;
		tag &= TAG_MASK;

		switch (tag_type) {
		case TAG_WAL:
			if (tag == wal_data)
				txn.op = read_u16(data);
			else if(tag >= user_tag)
				txn.op = tag >> 5;
			else
				return;

			box_prepare(&txn, data);
			break;
		case TAG_SNAP:
			if (tag != snap_data)
				return;

			const struct box_snap_row *snap = box_snap_row(data);
			txn.object_space = &object_space_registry[snap->object_space];
			if (!txn.object_space->enabled)
				raise("object_space %i is not configured", txn.object_space->n);
			if (txn.object_space->ignored) {
				txn.object_space = NULL;
				return;
			}

			txn.op = INSERT;
			txn.index = txn.object_space->index[0];
			assert(txn.index != nil);

			prepare_replace(&txn, snap->tuple_size, snap->data, snap->data_size);
			break;
		case TAG_SYS:
			return;
		}

		box_commit(&txn);
	}
	@catch (id e) {
		box_rollback(&txn);
		@throw;
	}
	@finally {
		box_cleanup(&txn);
	}
}


- (void)
check_replica
{
	if ([self is_replica])
		iproto_raise(ERR_CODE_NONMASTER, "replica is readonly");
}

- (void)
wal_final_row
{
	if (box_primary.name == NULL) {
		build_secondary_indexes();
		initialize_service();
	}
}

- (void)
status_changed
{
	/* ugly hack: since it's a category it also breaks feeders title() */
	if (self == recovery)
		title(NULL);
}


- (int)
snapshot_fold
{
	struct tnt_object *obj;
	struct box_tuple *tuple;

	u32 crc = 0;
#ifdef FOLD_DEBUG
	int count = 0;
#endif
	for (int n = 0; n < object_space_count; n++) {
		if (!object_space_registry[n].enabled)
			continue;

		id pk = object_space_registry[n].index[0];

		if ([pk respondsTo:@selector(ordered_iterator_init)])
			[pk ordered_iterator_init];
		else

			[pk iterator_init];

		while ((obj = [pk iterator_next])) {
			tuple = box_tuple(obj);
#ifdef FOLD_DEBUG
			struct tbuf *b = tbuf_alloc(fiber->pool);
			tuple_print(b, tuple->cardinality, tuple->data);
			say_info("row %i: %.*s", count++, tbuf_len(b), (char *)b->ptr);
#endif
			crc = crc32c(crc, (unsigned char *)&tuple->bsize,
				     tuple->bsize + sizeof(tuple->bsize) +
				     sizeof(tuple->cardinality));
		}
	}
	printf("CRC: 0x%08x\n", crc);
	return 0;
}

@end

@implementation SnapWriter (Box)
- (u32)
snapshot_estimate
{
	size_t total_rows = 0;
	for (int n = 0; n < object_space_count; n++)
		if (object_space_registry[n].enabled)
			total_rows += [object_space_registry[n].index[0] size];
	return total_rows;
}

- (int)
snapshot_write_rows:(XLog *)l
{
	struct box_snap_row header;
	struct tnt_object *obj;
	struct box_tuple *tuple;
	struct palloc_pool *pool = palloc_create_pool(__func__);
	struct tbuf *row = tbuf_alloc(pool);
	int ret = 0;
	size_t rows = 0, pk_rows, total_rows = [self snapshot_estimate];

	for (int n = 0; n < object_space_count; n++) {
		if (!object_space_registry[n].enabled)
			continue;

		pk_rows = 0;
		id pk = object_space_registry[n].index[0];
		[pk iterator_init];
		while ((obj = [pk iterator_next])) {
			if (unlikely(ghost(obj)))
				continue;

			if (obj->refs <= 0) {
				say_error("heap invariant violation: n:%i obj->refs == %i", n, obj->refs);
				errno = EINVAL;
				ret = -1;
				goto out;
			}

			tuple = box_tuple(obj);
			if (tuple_bsize(tuple->cardinality, tuple->data, tuple->bsize) != tuple->bsize) {
				say_error("heap invariant violation: n:%i invalid tuple %p", n, obj);
				errno = EINVAL;
				ret = -1;
				goto out;
			}

			header.object_space = n;
			header.tuple_size = tuple->cardinality;
			header.data_size = tuple->bsize;

			tbuf_reset(row);
			tbuf_append(row, &header, sizeof(header));
			tbuf_append(row, tuple->data, tuple->bsize);

			if (snapshot_write_row(l, snap_data, row) < 0) {
				ret = -1;
				goto out;
			}

			pk_rows++;
			if (++rows % 100000 == 0) {
				float pct = (float)rows / total_rows * 100.;
				say_info("%.1fM/%.2f%% rows written", rows / 1000000., pct);
				title("snap_dump %.2f%%", pct);
			}
			if (rows % 10000 == 0)
				[l confirm_write];
		}

		foreach_index(index, &object_space_registry[n]) {
			if (index->conf.n == 0)
				continue;

			/* during initial load of replica secondary indexes isn't configured yet */
			if ([index isKindOf:[DummyIndex class]])
				continue;

			title("snap_dump/check index:%i", index->conf.n);

			size_t index_rows = 0;
			[index iterator_init];
			while ([index iterator_next])
				index_rows++;
			if (pk_rows != index_rows) {
				say_error("heap invariant violation: n:%i index:%i rows:%zi != pk_rows:%zi",
					  n, index->conf.n, index_rows, pk_rows);
				errno = EINVAL;
				ret = -1;
				goto out;
			}
		}
	}

out:
	palloc_destroy_pool(pool);
	return ret;
}

@end


static void init_second_stage(va_list ap __attribute__((unused)));

static void
init(void)
{
	stat_base = stat_register(box_ops, nelem(box_ops));

	object_space_registry = xcalloc(object_space_count, sizeof(struct object_space));
	for (int i = 0; i < object_space_count; i++)
		object_space_registry[i].n = i;

	title("loading");
	if (cfg.paxos_enabled) {
		if (cfg.wal_feeder_addr)
			panic("wal_feeder_addr is incompatible with paxos");
		if (cfg.local_hot_standby)
			panic("wal_hot_standby is incompatible with paxos");
	}

	struct feeder_param feeder;
	enum feeder_cfg_e fid_err = feeder_param_fill_from_cfg(&feeder, NULL);
	if (fid_err) panic("wrong feeder conf");

	recovery = [[Recovery alloc] init_snap_dir:strdup(cfg.snap_dir)
					   wal_dir:strdup(cfg.wal_dir)
				      rows_per_wal:cfg.rows_per_wal
				      feeder_param:&feeder
					     flags:init_storage ? RECOVER_READONLY : 0];

	if (init_storage)
		return;

	/* fiber is required to successfully pull from remote */
	fiber_create("box_init", init_second_stage);
}

static void
init_second_stage(va_list ap __attribute__((unused)))
{
	luaT_openbox(root_L);
	luaT_require_or_panic("box_init", false, NULL);

	configure();

	@try {
		i64 local_lsn = [recovery recover_start];
		if (cfg.paxos_enabled) {
			[recovery enable_local_writes];
		} else {
			if (local_lsn == 0) {
				if (![recovery feeder_addr_configured]) {
					say_error("unable to find initial snapshot");
					say_info("don't you forget to initialize "
						 "storage with --init-storage switch?");
					exit(EX_USAGE);
				}

				/* Break circular dependency.
				   Remote recovery depends on [enable_local_writes] wich itself
				   depends on binding to primary port.
				   Binding to primary port depends on wal_final_row from
				   remote replication. (There is no data in local WALs yet)
				 */
				if ([recovery feeder_addr_configured] && cfg.local_hot_standby)
					[recovery wal_final_row];
			}
			if (!cfg.local_hot_standby)
				[recovery enable_local_writes];
		}
	}
	@catch (Error *e) {
		panic("Recovery failure: %s", e->reason);
	}
	title(NULL);
}



static void
info(struct tbuf *out, const char *what)
{
	if (what == NULL) {
		tbuf_printf(out, "info:" CRLF);
		tbuf_printf(out, "  version: \"%s\"" CRLF, octopus_version());
		tbuf_printf(out, "  uptime: %i" CRLF, tnt_uptime());
		tbuf_printf(out, "  pid: %i" CRLF, getpid());
		struct child *wal_writer = [recovery wal_writer];
		if (wal_writer)
			tbuf_printf(out, "  wal_writer_pid: %" PRIi64 CRLF,
				    (i64)wal_writer->pid);
		tbuf_printf(out, "  lsn: %" PRIi64 CRLF, [recovery lsn]);
		tbuf_printf(out, "  scn: %" PRIi64 CRLF, [recovery scn]);
		if ([recovery is_replica]) {
			tbuf_printf(out, "  recovery_lag: %.3f" CRLF, [recovery lag]);
			tbuf_printf(out, "  recovery_last_update: %.3f" CRLF, [recovery last_update_tstamp]);
			if (!cfg.ignore_run_crc) {
				tbuf_printf(out, "  recovery_run_crc_lag: %.3f" CRLF, [recovery run_crc_lag]);
				tbuf_printf(out, "  recovery_run_crc_status: %s" CRLF, [recovery run_crc_status]);
			}
		}
		tbuf_printf(out, "  status: %s%s%s" CRLF, [recovery status],
			    cfg.custom_proc_title ? "@" : "",
			    cfg.custom_proc_title ?: "");
		tbuf_printf(out, "  config: \"%s\""CRLF, cfg_filename);

		tbuf_printf(out, "  namespaces:" CRLF);
		for (uint32_t n = 0; n < object_space_count; ++n) {
			if (!object_space_registry[n].enabled)
				continue;
			tbuf_printf(out, "  - n: %i"CRLF, n);
			tbuf_printf(out, "    objects: %i"CRLF, [object_space_registry[n].index[0] size]);
			tbuf_printf(out, "    indexes:"CRLF);
			foreach_index(index, &object_space_registry[n])
				tbuf_printf(out, "    - { index: %i, slots: %i, bytes: %zi }" CRLF,
					    index->conf.n, [index slots], [index bytes]);
		}
		return;
	}

	if (strcmp(what, "net") == 0) {
		if (box_primary.name != NULL)
			service_info(out, &box_primary);
		if (box_secondary.name != NULL)
			service_info(out, &box_secondary);
		return;
	}
}

static int
check_config(struct octopus_cfg *new)
{
	extern void out_warning(int v, char *format, ...);
	struct feeder_param feeder;
	enum feeder_cfg_e e = feeder_param_fill_from_cfg(&feeder, new);
	if (e) {
		out_warning(0, "wal_feeder config is wrong");
		return -1;
	}

	return 0;
}

static void
reload_config(struct octopus_cfg *old _unused_,
	      struct octopus_cfg *new)
{
	struct feeder_param feeder;
	feeder_param_fill_from_cfg(&feeder, new);
	[recovery feeder_changed:&feeder];
}

static struct tnt_module box = {
	.name = "box",
	.version = box_version_string,
	.init = init,
	.check_config = check_config,
	.reload_config = reload_config,
	.cat = box_cat,
	.cat_scn = box_cat_scn,
	.info = info
};

register_module(box);
register_source();
