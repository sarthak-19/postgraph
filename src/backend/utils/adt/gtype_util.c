
/*
 * converting between gtype and gtype_values, and iterating.
 *
 * Copyright (C) 2023 PostGraphDB
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 * 
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 * Portions Copyright (c) 2020-2023, Apache Software Foundation (ASF)
 * Portions Copyright (c) 2019-2020, Bitnine Global Inc.
 * Portions Copyright (c) 1996-2018, The PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, The Regents of the University of California
 */

#include "postgres.h"

#include <math.h>

#include "access/hash.h"
#include "catalog/pg_collation.h"
#include "miscadmin.h"
#include "utils/builtins.h"
#include "utils/memutils.h"
#include "utils/date.h"
#include "utils/timestamp.h"
#include "utils/varlena.h"

#include "utils/gtype.h"
#include "utils/gtype_ext.h"
#include "utils/graphid.h"

/*
 * Maximum number of elements in an array (or key/value pairs in an object).
 * This is limited by two things: the size of the agtentry array must fit
 * in MaxAllocSize, and the number of elements (or pairs) must fit in the bits
 * reserved for that in the gtype_container.header field.
 *
 * (The total size of an array's or object's elements is also limited by
 * AGTENTRY_OFFLENMASK, but we're not concerned about that here.)
 */
#define GTYPE_MAX_ELEMS (Min(MaxAllocSize / sizeof(gtype_value), AGT_CMASK))
#define GTYPE_MAX_PAIRS (Min(MaxAllocSize / sizeof(gtype_pair), AGT_CMASK))

static void fill_gtype_value(gtype_container *container, int index,
                              char *base_addr, uint32 offset,
                              gtype_value *result);
static bool equals_gtype_scalar_value(const gtype_value *a, const gtype_value *b);
static gtype *convert_to_gtype(gtype_value *val);
static void convert_gtype_value(StringInfo buffer, agtentry *header, gtype_value *val, int level);
static void convert_gtype_array(StringInfo buffer, agtentry *pheader, gtype_value *val, int level);
static void convert_gtype_object(StringInfo buffer, agtentry *pheader, gtype_value *val, int level);
static void convert_gtype_scalar(StringInfo buffer, agtentry *entry, gtype_value *scalar_val);
static void append_to_buffer(StringInfo buffer, const char *data, int len);
static void copy_to_buffer(StringInfo buffer, int offset, const char *data, int len);
static gtype_iterator *iterator_from_container(gtype_container *container, gtype_iterator *parent);
static gtype_iterator *free_and_get_parent(gtype_iterator *it);
static gtype_parse_state *push_state(gtype_parse_state **pstate);
static void append_key(gtype_parse_state *pstate, gtype_value *string);
static void append_value(gtype_parse_state *pstate, gtype_value *scalar_val);
static void append_element(gtype_parse_state *pstate, gtype_value *scalar_val);
static int length_compare_gtype_string_value(const void *a, const void *b);
static int length_compare_gtype_pair(const void *a, const void *b, void *binequal);
static gtype_value *push_gtype_value_scalar(gtype_parse_state **pstate,
                                              gtype_iterator_token seq,
                                              gtype_value *scalar_val);
static int compare_two_floats_orderability(float8 lhs, float8 rhs);
static int get_type_sort_priority(enum gtype_value_type type);

/*
 * Turn an in-memory gtype_value into an gtype for on-disk storage.
 *
 * There isn't an gtype_to_gtype_value(), because generally we find it more
 * convenient to directly iterate through the gtype representation and only
 * really convert nested scalar values.  gtype_iterator_next() does this, so
 * that clients of the iteration code don't have to directly deal with the
 * binary representation (gtype_deep_contains() is a notable exception,
 * although all exceptions are internal to this module).  In general, functions
 * that accept an gtype_value argument are concerned with the manipulation of
 * scalar values, or simple containers of scalar values, where it would be
 * inconvenient to deal with a great amount of other state.
 */
gtype *gtype_value_to_gtype(gtype_value *val)
{
    gtype *out;

    if (IS_A_GTYPE_SCALAR(val))
    {
        /* Scalar value */
        gtype_parse_state *pstate = NULL;
        gtype_value *res;
        gtype_value scalar_array;

        scalar_array.type = AGTV_ARRAY;
        scalar_array.val.array.raw_scalar = true;
        scalar_array.val.array.num_elems = 1;

        push_gtype_value(&pstate, WAGT_BEGIN_ARRAY, &scalar_array);
        push_gtype_value(&pstate, WAGT_ELEM, val);
        res = push_gtype_value(&pstate, WAGT_END_ARRAY, NULL);

        out = convert_to_gtype(res);
    }
    else if (val->type == AGTV_OBJECT || val->type == AGTV_ARRAY)
    {
        out = convert_to_gtype(val);
    }
    else
    {
        Assert(val->type == AGTV_BINARY);
        out = palloc(VARHDRSZ + val->val.binary.len);
        SET_VARSIZE(out, VARHDRSZ + val->val.binary.len);
        memcpy(VARDATA(out), val->val.binary.data, val->val.binary.len);
    }

    return out;
}

/*
 * Get the offset of the variable-length portion of an gtype node within
 * the variable-length-data part of its container.  The node is identified
 * by index within the container's agtentry array.
 */
uint32 get_gtype_offset(const gtype_container *agtc, int index)
{
    uint32 offset = 0;
    int i;

    /*
     * Start offset of this entry is equal to the end offset of the previous
     * entry.  Walk backwards to the most recent entry stored as an end
     * offset, returning that offset plus any lengths in between.
     */
    for (i = index - 1; i >= 0; i--)
    {
        offset += AGTE_OFFLENFLD(agtc->children[i]);
        if (AGTE_HAS_OFF(agtc->children[i]))
            break;
    }

    return offset;
}

/*
 * Get the length of the variable-length portion of an gtype node.
 * The node is identified by index within the container's agtentry array.
 */
uint32 get_gtype_length(const gtype_container *agtc, int index)
{
    uint32 off;
    uint32 len;

    /*
     * If the length is stored directly in the agtentry, just return it.
     * Otherwise, get the begin offset of the entry, and subtract that from
     * the stored end+1 offset.
     */
    if (AGTE_HAS_OFF(agtc->children[index]))
    {
        off = get_gtype_offset(agtc, index);
        len = AGTE_OFFLENFLD(agtc->children[index]) - off;
    }
    else
    {
        len = AGTE_OFFLENFLD(agtc->children[index]);
    }

    return len;
}

/*
 * Helper function to generate the sort priorty of a type. Larger
 * numbers have higher priority.
 */
static int get_type_sort_priority(enum gtype_value_type type)
{
    if (type == AGTV_OBJECT)
        return 0;
    if (type == AGTV_ARRAY)
        return 1;
    if (type == AGTV_STRING)
        return 2;
    if (type == AGTV_BOOL)
        return 3;
    if (type == AGTV_NUMERIC || type == AGTV_INTEGER || type == AGTV_FLOAT)
        return 4;
    if (type == AGTV_TIMESTAMP || type == AGTV_TIMESTAMPTZ)
	return 5;
    if (type == AGTV_DATE)
	return 6;
    if (type == AGTV_TIME || AGTV_TIMETZ)
	 return 7;
    if (type == AGTV_INTERVAL)
	 return 8;   
    if (type == AGTV_NULL)
        return 9;
    return -1;
}

/*
 * BT comparator worker function.  Returns an integer less than, equal to, or
 * greater than zero, indicating whether a is less than, equal to, or greater
 * than b.  Consistent with the requirements for a B-Tree operator class
 *
 * Strings are compared lexically, in contrast with other places where we use a
 * much simpler comparator logic for searching through Strings.  Since this is
 * called from B-Tree support function 1, we're careful about not leaking
 * memory here.
 */
int compare_gtype_containers_orderability(gtype_container *a, gtype_container *b)
{
    gtype_iterator *ita;
    gtype_iterator *itb;
    int res = 0;

    ita = gtype_iterator_init(a);
    itb = gtype_iterator_init(b);

    do
    {
        gtype_value va;
        gtype_value vb;
        gtype_iterator_token ra;
        gtype_iterator_token rb;

        ra = gtype_iterator_next(&ita, &va, false);
        rb = gtype_iterator_next(&itb, &vb, false);

        if (ra == rb)
        {
            if (ra == WAGT_DONE)
            {
                /* Decisively equal */
                break;
            }

            if (ra == WAGT_END_ARRAY || ra == WAGT_END_OBJECT)
            {
                /*
                 * There is no array or object to compare at this stage of
                 * processing.  AGTV_ARRAY/AGTV_OBJECT values are compared
                 * initially, at the WAGT_BEGIN_ARRAY and WAGT_BEGIN_OBJECT
                 * tokens.
                 */
                continue;
            }

            if ((va.type == vb.type) ||
                ((va.type == AGTV_INTEGER || va.type == AGTV_FLOAT || va.type == AGTV_NUMERIC ||
		  va.type == AGTV_TIMESTAMP || va.type == AGTV_DATE || va.type == AGTV_TIMESTAMPTZ ||
		  va.type == AGTV_TIMETZ || va.type == AGTV_TIME || va.type == AGTV_DATE) &&
                 (vb.type == AGTV_INTEGER || vb.type == AGTV_FLOAT || vb.type == AGTV_NUMERIC || 
		  vb.type == AGTV_TIMESTAMP || vb.type == AGTV_DATE || vb.type == AGTV_TIMESTAMPTZ ||
                  vb.type == AGTV_TIMETZ || vb.type == AGTV_TIME || vb.type == AGTV_DATE)))
            {
                switch (va.type)
                {
                case AGTV_STRING:
                case AGTV_NULL:
                case AGTV_NUMERIC:
                case AGTV_BOOL:
                case AGTV_INTEGER:
                case AGTV_FLOAT:
		case AGTV_TIMESTAMP:
		case AGTV_TIMESTAMPTZ:
		case AGTV_DATE:
		case AGTV_TIME:
		case AGTV_TIMETZ:
		case AGTV_INTERVAL:
                    res = compare_gtype_scalar_values(&va, &vb);
                    break;
                case AGTV_ARRAY:

                    /*
                     * This could be a "raw scalar" pseudo array.  That's
                     * a special case here though, since we still want the
                     * general type-based comparisons to apply, and as far
                     * as we're concerned a pseudo array is just a scalar.
                     */
                    if (va.val.array.raw_scalar != vb.val.array.raw_scalar)
                    {
                        if (va.val.array.raw_scalar)
                        {
                            /* advance iterator ita and get contained type */
                            ra = gtype_iterator_next(&ita, &va, false);
                            res = (get_type_sort_priority(va.type) < get_type_sort_priority(vb.type)) ?  -1 : 1;
                        }
                        else
                        {
                            /* advance iterator itb and get contained type */
                            rb = gtype_iterator_next(&itb, &vb, false);
                            res = (get_type_sort_priority(va.type) < get_type_sort_priority(vb.type)) ?  -1 : 1;
                        }
                    }
                    break;
                case AGTV_OBJECT:
                    break;
                case AGTV_BINARY:
                    ereport(ERROR, (errmsg("unexpected AGTV_BINARY value")));
                }
            }
            else
            {
                /* Type-defined order */
                res = (get_type_sort_priority(va.type) < get_type_sort_priority(vb.type)) ?  -1 : 1;
            }
        }
        else
        {
            /*
             * It's safe to assume that the types differed, and that the va
             * and vb values passed were set.
             *
             * If the two values were of the same container type, then there'd
             * have been a chance to observe the variation in the number of
             * elements/pairs (when processing WAGT_BEGIN_OBJECT, say). They're
             * either two heterogeneously-typed containers, or a container and
             * some scalar type.
             */

            /*
             * Check for the premature array or object end.
             * If left side is shorter, less than.
             */
            if (ra == WAGT_END_ARRAY || ra == WAGT_END_OBJECT)
            {
                res = -1;
                break;
            }
            /* If right side is shorter, greater than */
            if (rb == WAGT_END_ARRAY || rb == WAGT_END_OBJECT)
            {
                res = 1;
                break;
            }

            Assert(va.type != vb.type);
            Assert(va.type != AGTV_BINARY);
            Assert(vb.type != AGTV_BINARY);
            /* Type-defined order */
            res = (get_type_sort_priority(va.type) < get_type_sort_priority(vb.type)) ?  -1 : 1;
        }
    } while (res == 0);

    while (ita != NULL)
    {
        gtype_iterator *i = ita->parent;

        pfree(ita);
        ita = i;
    }
    while (itb != NULL)
    {
        gtype_iterator *i = itb->parent;

        pfree(itb);
        itb = i;
    }

    return res;
}

/*
 * Find value in object (i.e. the "value" part of some key/value pair in an
 * object), or find a matching element if we're looking through an array.  Do
 * so on the basis of equality of the object keys only, or alternatively
 * element values only, with a caller-supplied value "key".  The "flags"
 * argument allows the caller to specify which container types are of interest.
 *
 * This exported utility function exists to facilitate various cases concerned
 * with "containment".  If asked to look through an object, the caller had
 * better pass an gtype String, because their keys can only be strings.
 * Otherwise, for an array, any type of gtype_value will do.
 *
 * In order to proceed with the search, it is necessary for callers to have
 * both specified an interest in exactly one particular container type with an
 * appropriate flag, as well as having the pointed-to gtype container be of
 * one of those same container types at the top level. (Actually, we just do
 * whichever makes sense to save callers the trouble of figuring it out - at
 * most one can make sense, because the container either points to an array
 * (possibly a "raw scalar" pseudo array) or an object.)
 *
 * Note that we can return an AGTV_BINARY gtype_value if this is called on an
 * object, but we never do so on an array.  If the caller asks to look through
 * a container type that is not of the type pointed to by the container,
 * immediately fall through and return NULL.  If we cannot find the value,
 * return NULL.  Otherwise, return palloc()'d copy of value.
 */
gtype_value *find_gtype_value_from_container(gtype_container *container,
                                               uint32 flags, const gtype_value *key)
{
    agtentry *children = container->children;
    int count = GTYPE_CONTAINER_SIZE(container);
    gtype_value *result;

    Assert((flags & ~(AGT_FARRAY | AGT_FOBJECT)) == 0);

    /* Quick out without a palloc cycle if object/array is empty */
    if (count <= 0)
    {
        return NULL;
    }

    result = palloc(sizeof(gtype_value));

    if ((flags & AGT_FARRAY) && GTYPE_CONTAINER_IS_ARRAY(container))
    {
        char *base_addr = (char *)(children + count);
        uint32 offset = 0;
        int i;

        for (i = 0; i < count; i++)
        {
            fill_gtype_value(container, i, base_addr, offset, result);

            if (key->type == result->type)
            {
                if (equals_gtype_scalar_value(key, result))
                    return result;
            }

            AGTE_ADVANCE_OFFSET(offset, children[i]);
        }
    }
    else if ((flags & AGT_FOBJECT) && GTYPE_CONTAINER_IS_OBJECT(container))
    {
        /* Since this is an object, account for *Pairs* of AGTentrys */
        char *base_addr = (char *)(children + count * 2);
        uint32 stop_low = 0;
        uint32 stop_high = count;

        /* Object key passed by caller must be a string */
        Assert(key->type == AGTV_STRING);

        /* Binary search on object/pair keys *only* */
        while (stop_low < stop_high)
        {
            uint32 stop_middle;
            int difference;
            gtype_value candidate;

            stop_middle = stop_low + (stop_high - stop_low) / 2;

            candidate.type = AGTV_STRING;
            candidate.val.string.val =
                base_addr + get_gtype_offset(container, stop_middle);
            candidate.val.string.len = get_gtype_length(container,
                                                         stop_middle);

            difference = length_compare_gtype_string_value(&candidate, key);

            if (difference == 0)
            {
                /* Found our key, return corresponding value */
                int index = stop_middle + count;

                fill_gtype_value(container, index, base_addr,
                                  get_gtype_offset(container, index), result);

                return result;
            }
            else
            {
                if (difference < 0)
                    stop_low = stop_middle + 1;
                else
                    stop_high = stop_middle;
            }
        }
    }

    /* Not found */
    pfree(result);
    return NULL;
}

/*
 * Get i-th value of an gtype array.
 *
 * Returns palloc()'d copy of the value, or NULL if it does not exist.
 */
gtype_value *get_ith_gtype_value_from_container(gtype_container *container,
                                                  uint32 i)
{
    gtype_value *result;
    char *base_addr;
    uint32 nelements;

    if (!GTYPE_CONTAINER_IS_ARRAY(container))
        ereport(ERROR, (errmsg("container is not an gtype array")));

    nelements = GTYPE_CONTAINER_SIZE(container);
    base_addr = (char *)&container->children[nelements];

    if (i >= nelements)
        return NULL;

    result = palloc(sizeof(gtype_value));

    fill_gtype_value(container, i, base_addr, get_gtype_offset(container, i),
                      result);

    return result;
}

/*
 * A helper function to fill in an gtype_value to represent an element of an
 * array, or a key or value of an object.
 *
 * The node's agtentry is at container->children[index], and its variable-length
 * data is at base_addr + offset.  We make the caller determine the offset
 * since in many cases the caller can amortize that work across multiple
 * children.  When it can't, it can just call get_gtype_offset().
 *
 * A nested array or object will be returned as AGTV_BINARY, ie. it won't be
 * expanded.
 */
static void fill_gtype_value(gtype_container *container, int index,
                              char *base_addr, uint32 offset,
                              gtype_value *result)
{
    agtentry entry = container->children[index];

    if (AGTE_IS_NULL(entry))
    {
        result->type = AGTV_NULL;
    }
    else if (AGTE_IS_STRING(entry))
    {
        char *string_val;
        int string_len;

        result->type = AGTV_STRING;
        /* get the position and length of the string */
        string_val = base_addr + offset;
        string_len = get_gtype_length(container, index);
        /* we need to do a deep copy of the string value */
        result->val.string.val = pnstrdup(string_val, string_len);
        result->val.string.len = string_len;
        Assert(result->val.string.len >= 0);
    }
    else if (AGTE_IS_NUMERIC(entry))
    {
        Numeric numeric;
        Numeric numeric_copy;

        result->type = AGTV_NUMERIC;
        /* we need to do a deep copy here */
        numeric = (Numeric)(base_addr + INTALIGN(offset));
        numeric_copy = (Numeric) palloc(VARSIZE(numeric));
        memcpy(numeric_copy, numeric, VARSIZE(numeric));
        result->val.numeric = numeric_copy;
    }
    /*
     * If this is an gtype.
     * This is needed because we allow the original jsonb type to be
     * passed in.
     */
    else if (AGTE_IS_GTYPE(entry))
    {
        ag_deserialize_extended_type(base_addr, offset, result);
    }
    else if (AGTE_IS_BOOL_TRUE(entry))
    {
        result->type = AGTV_BOOL;
        result->val.boolean = true;
    }
    else if (AGTE_IS_BOOL_FALSE(entry))
    {
        result->type = AGTV_BOOL;
        result->val.boolean = false;
    }
    else
    {
        Assert(AGTE_IS_CONTAINER(entry));
        result->type = AGTV_BINARY;
        /* Remove alignment padding from data pointer and length */
        result->val.binary.data =
            (gtype_container *)(base_addr + INTALIGN(offset));
        result->val.binary.len = get_gtype_length(container, index) -
                                 (INTALIGN(offset) - offset);
    }
}

/*
 * Push gtype_value into gtype_parse_state.
 *
 * Used when parsing gtype tokens to form gtype, or when converting an
 * in-memory gtype_value to an gtype.
 *
 * Initial state of *gtype_parse_state is NULL, since it'll be allocated here
 * originally (caller will get gtype_parse_state back by reference).
 *
 * Only sequential tokens pertaining to non-container types should pass an
 * gtype_value.  There is one exception -- WAGT_BEGIN_ARRAY callers may pass a
 * "raw scalar" pseudo array to append it - the actual scalar should be passed
 * next and it will be added as the only member of the array.
 *
 * Values of type AGTV_BINARY, which are rolled up arrays and objects,
 * are unpacked before being added to the result.
 */
gtype_value *push_gtype_value(gtype_parse_state **pstate,
                                gtype_iterator_token seq,
                                gtype_value *agtval)
{
    gtype_iterator *it;
    gtype_value *res = NULL;
    gtype_value v;
    gtype_iterator_token tok;

    if (!agtval || (seq != WAGT_ELEM && seq != WAGT_VALUE) ||
        agtval->type != AGTV_BINARY)
    {
        /* drop through */
        return push_gtype_value_scalar(pstate, seq, agtval);
    }

    /* unpack the binary and add each piece to the pstate */
    it = gtype_iterator_init(agtval->val.binary.data);
    while ((tok = gtype_iterator_next(&it, &v, false)) != WAGT_DONE)
    {
        res = push_gtype_value_scalar(pstate, tok,
                                       tok < WAGT_BEGIN_ARRAY ? &v : NULL);
    }

    return res;
}

/*
 * Do the actual pushing, with only scalar or pseudo-scalar-array values
 * accepted.
 */
static gtype_value *push_gtype_value_scalar(gtype_parse_state **pstate,
                                              gtype_iterator_token seq,
                                              gtype_value *scalar_val)
{
    gtype_value *result = NULL;

    switch (seq)
    {
    case WAGT_BEGIN_ARRAY:
        Assert(!scalar_val || scalar_val->val.array.raw_scalar);
        *pstate = push_state(pstate);
        result = &(*pstate)->cont_val;
        (*pstate)->cont_val.type = AGTV_ARRAY;
        (*pstate)->cont_val.val.array.num_elems = 0;
        (*pstate)->cont_val.val.array.raw_scalar =
            (scalar_val && scalar_val->val.array.raw_scalar);
        if (scalar_val && scalar_val->val.array.num_elems > 0)
        {
            /* Assume that this array is still really a scalar */
            Assert(scalar_val->type == AGTV_ARRAY);
            (*pstate)->size = scalar_val->val.array.num_elems;
        }
        else
        {
            (*pstate)->size = 4;
        }
        (*pstate)->cont_val.val.array.elems =
            palloc(sizeof(gtype_value) * (*pstate)->size);
        (*pstate)->last_updated_value = NULL;
        break;
    case WAGT_BEGIN_OBJECT:
        Assert(!scalar_val);
        *pstate = push_state(pstate);
        result = &(*pstate)->cont_val;
        (*pstate)->cont_val.type = AGTV_OBJECT;
        (*pstate)->cont_val.val.object.num_pairs = 0;
        (*pstate)->size = 4;
        (*pstate)->cont_val.val.object.pairs =
            palloc(sizeof(gtype_pair) * (*pstate)->size);
        (*pstate)->last_updated_value = NULL;
        break;
    case WAGT_KEY:
        Assert(scalar_val->type == AGTV_STRING);
        append_key(*pstate, scalar_val);
        break;
    case WAGT_VALUE:
        Assert(IS_A_GTYPE_SCALAR(scalar_val));
        append_value(*pstate, scalar_val);
        break;
    case WAGT_ELEM:
        Assert(IS_A_GTYPE_SCALAR(scalar_val));
        append_element(*pstate, scalar_val);
        break;
    case WAGT_END_OBJECT:
        uniqueify_gtype_object(&(*pstate)->cont_val);
        /* fall through! */
    case WAGT_END_ARRAY:
        /* Steps here common to WAGT_END_OBJECT case */
        Assert(!scalar_val);
        result = &(*pstate)->cont_val;

        /*
         * Pop queue and push current array/object as value in parent
         * array/object
         */
        *pstate = (*pstate)->next;
        if (*pstate)
        {
            switch ((*pstate)->cont_val.type)
            {
            case AGTV_ARRAY:
                append_element(*pstate, result);
                break;
            case AGTV_OBJECT:
                append_value(*pstate, result);
                break;
            default:
                ereport(ERROR, (errmsg("invalid gtype container type %d",
                                       (*pstate)->cont_val.type)));
            }
        }
        break;
    default:
        ereport(ERROR,
                (errmsg("unrecognized gtype sequential processing token")));
    }

    return result;
}

/*
 * push_gtype_value() worker:  Iteration-like forming of gtype
 */
static gtype_parse_state *push_state(gtype_parse_state **pstate)
{
    gtype_parse_state *ns = palloc(sizeof(gtype_parse_state));

    ns->next = *pstate;
    return ns;
}

/*
 * push_gtype_value() worker:  Append a pair key to state when generating
 *                              gtype
 */
static void append_key(gtype_parse_state *pstate, gtype_value *string)
{
    gtype_value *object = &pstate->cont_val;

    Assert(object->type == AGTV_OBJECT);
    Assert(string->type == AGTV_STRING);

    if (object->val.object.num_pairs >= GTYPE_MAX_PAIRS)
        ereport(
            ERROR,
            (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
             errmsg(
                 "number of gtype object pairs exceeds the maximum allowed (%zu)",
                 GTYPE_MAX_PAIRS)));

    if (object->val.object.num_pairs >= pstate->size)
    {
        pstate->size *= 2;
        object->val.object.pairs = repalloc(
            object->val.object.pairs, sizeof(gtype_pair) * pstate->size);
    }

    object->val.object.pairs[object->val.object.num_pairs].key = *string;
    object->val.object.pairs[object->val.object.num_pairs].order =
        object->val.object.num_pairs;
}

/*
 * push_gtype_value() worker:  Append a pair value to state when generating an
 *                              gtype
 */
static void append_value(gtype_parse_state *pstate, gtype_value *scalar_val)
{
    gtype_value *object = &pstate->cont_val;

    Assert(object->type == AGTV_OBJECT);

    object->val.object.pairs[object->val.object.num_pairs].value = *scalar_val;

    pstate->last_updated_value =
        &object->val.object.pairs[object->val.object.num_pairs++].value;
}

/*
 * push_gtype_value() worker:  Append an element to state when generating an
 *                              gtype
 */
static void append_element(gtype_parse_state *pstate,
                           gtype_value *scalar_val)
{
    gtype_value *array = &pstate->cont_val;

    Assert(array->type == AGTV_ARRAY);

    if (array->val.array.num_elems >= GTYPE_MAX_ELEMS)
        ereport(
            ERROR,
            (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
             errmsg(
                 "number of gtype array elements exceeds the maximum allowed (%zu)",
                 GTYPE_MAX_ELEMS)));

    if (array->val.array.num_elems >= pstate->size)
    {
        pstate->size *= 2;
        array->val.array.elems = repalloc(array->val.array.elems,
                                          sizeof(gtype_value) * pstate->size);
    }

    array->val.array.elems[array->val.array.num_elems] = *scalar_val;
    pstate->last_updated_value =
        &array->val.array.elems[array->val.array.num_elems++];
}

/*
 * Given an gtype_container, expand to gtype_iterator to iterate over items
 * fully expanded to in-memory representation for manipulation.
 *
 * See gtype_iterator_next() for notes on memory management.
 */
gtype_iterator *gtype_iterator_init(gtype_container *container)
{
    return iterator_from_container(container, NULL);
}

/*
 * Get next gtype_value while iterating
 *
 * Caller should initially pass their own, original iterator.  They may get
 * back a child iterator palloc()'d here instead.  The function can be relied
 * on to free those child iterators, lest the memory allocated for highly
 * nested objects become unreasonable, but only if callers don't end iteration
 * early (by breaking upon having found something in a search, for example).
 *
 * Callers in such a scenario, that are particularly sensitive to leaking
 * memory in a long-lived context may walk the ancestral tree from the final
 * iterator we left them with to its oldest ancestor, pfree()ing as they go.
 * They do not have to free any other memory previously allocated for iterators
 * but not accessible as direct ancestors of the iterator they're last passed
 * back.
 *
 * Returns "gtype sequential processing" token value.  Iterator "state"
 * reflects the current stage of the process in a less granular fashion, and is
 * mostly used here to track things internally with respect to particular
 * iterators.
 *
 * Clients of this function should not have to handle any AGTV_BINARY values
 * (since recursive calls will deal with this), provided skip_nested is false.
 * It is our job to expand the AGTV_BINARY representation without bothering
 * them with it.  However, clients should not take it upon themselves to touch
 * array or Object element/pair buffers, since their element/pair pointers are
 * garbage.  Also, *val will not be set when returning WAGT_END_ARRAY or
 * WAGT_END_OBJECT, on the assumption that it's only useful to access values
 * when recursing in.
 */
gtype_iterator_token gtype_iterator_next(gtype_iterator **it,
                                           gtype_value *val, bool skip_nested)
{
    if (*it == NULL)
        return WAGT_DONE;

    /*
     * When stepping into a nested container, we jump back here to start
     * processing the child. We will not recurse further in one call, because
     * processing the child will always begin in AGTI_ARRAY_START or
     * AGTI_OBJECT_START state.
     */
recurse:
    switch ((*it)->state)
    {
    case AGTI_ARRAY_START:
        /* Set v to array on first array call */
        val->type = AGTV_ARRAY;
        val->val.array.num_elems = (*it)->num_elems;

        /*
         * v->val.array.elems is not actually set, because we aren't doing
         * a full conversion
         */
        val->val.array.raw_scalar = (*it)->is_scalar;
        (*it)->curr_index = 0;
        (*it)->curr_data_offset = 0;
        (*it)->curr_value_offset = 0; /* not actually used */
        /* Set state for next call */
        (*it)->state = AGTI_ARRAY_ELEM;
        return WAGT_BEGIN_ARRAY;

    case AGTI_ARRAY_ELEM:
        if ((*it)->curr_index >= (*it)->num_elems)
        {
            /*
             * All elements within array already processed.  Report this
             * to caller, and give it back original parent iterator (which
             * independently tracks iteration progress at its level of
             * nesting).
             */
            *it = free_and_get_parent(*it);
            return WAGT_END_ARRAY;
        }

        fill_gtype_value((*it)->container, (*it)->curr_index,
                          (*it)->data_proper, (*it)->curr_data_offset, val);

        AGTE_ADVANCE_OFFSET((*it)->curr_data_offset,
                            (*it)->children[(*it)->curr_index]);
        (*it)->curr_index++;

        if (!IS_A_GTYPE_SCALAR(val) && !skip_nested)
        {
            /* Recurse into container. */
            *it = iterator_from_container(val->val.binary.data, *it);
            goto recurse;
        }
        else
        {
            /*
             * Scalar item in array, or a container and caller didn't want
             * us to recurse into it.
             */
            return WAGT_ELEM;
        }

    case AGTI_OBJECT_START:
        /* Set v to object on first object call */
        val->type = AGTV_OBJECT;
        val->val.object.num_pairs = (*it)->num_elems;

        /*
         * v->val.object.pairs is not actually set, because we aren't
         * doing a full conversion
         */
        (*it)->curr_index = 0;
        (*it)->curr_data_offset = 0;
        (*it)->curr_value_offset = get_gtype_offset((*it)->container,
                                                     (*it)->num_elems);
        /* Set state for next call */
        (*it)->state = AGTI_OBJECT_KEY;
        return WAGT_BEGIN_OBJECT;

    case AGTI_OBJECT_KEY:
        if ((*it)->curr_index >= (*it)->num_elems)
        {
            /*
             * All pairs within object already processed.  Report this to
             * caller, and give it back original containing iterator
             * (which independently tracks iteration progress at its level
             * of nesting).
             */
            *it = free_and_get_parent(*it);
            return WAGT_END_OBJECT;
        }
        else
        {
            /* Return key of a key/value pair.  */
            fill_gtype_value((*it)->container, (*it)->curr_index,
                              (*it)->data_proper, (*it)->curr_data_offset,
                              val);
            if (val->type != AGTV_STRING)
                ereport(ERROR,
                        (errmsg("unexpected gtype type as object key %d",
                                val->type)));

            /* Set state for next call */
            (*it)->state = AGTI_OBJECT_VALUE;
            return WAGT_KEY;
        }

    case AGTI_OBJECT_VALUE:
        /* Set state for next call */
        (*it)->state = AGTI_OBJECT_KEY;

        fill_gtype_value((*it)->container,
                          (*it)->curr_index + (*it)->num_elems,
                          (*it)->data_proper, (*it)->curr_value_offset, val);

        AGTE_ADVANCE_OFFSET((*it)->curr_data_offset,
                            (*it)->children[(*it)->curr_index]);
        AGTE_ADVANCE_OFFSET(
            (*it)->curr_value_offset,
            (*it)->children[(*it)->curr_index + (*it)->num_elems]);
        (*it)->curr_index++;

        /*
         * Value may be a container, in which case we recurse with new,
         * child iterator (unless the caller asked not to, by passing
         * skip_nested).
         */
        if (!IS_A_GTYPE_SCALAR(val) && !skip_nested)
        {
            *it = iterator_from_container(val->val.binary.data, *it);
            goto recurse;
        }
        else
        {
            return WAGT_VALUE;
        }
    }

    ereport(ERROR, (errmsg("invalid iterator state %d", (*it)->state)));
    return -1;
}

/*
 * Initialize an iterator for iterating all elements in a container.
 */
static gtype_iterator *iterator_from_container(gtype_container *container,
                                                gtype_iterator *parent)
{
    gtype_iterator *it;

    it = palloc0(sizeof(gtype_iterator));
    it->container = container;
    it->parent = parent;
    it->num_elems = GTYPE_CONTAINER_SIZE(container);

    /* Array starts just after header */
    it->children = container->children;

    switch (container->header & (AGT_FARRAY | AGT_FOBJECT))
    {
    case AGT_FARRAY:
        it->data_proper = (char *)it->children +
                          it->num_elems * sizeof(agtentry);
        it->is_scalar = GTYPE_CONTAINER_IS_SCALAR(container);
        /* This is either a "raw scalar", or an array */
        Assert(!it->is_scalar || it->num_elems == 1);

        it->state = AGTI_ARRAY_START;
        break;

    case AGT_FOBJECT:
        it->data_proper = (char *)it->children +
                          it->num_elems * sizeof(agtentry) * 2;
        it->state = AGTI_OBJECT_START;
        break;

    default:
        ereport(ERROR,
                (errmsg("unknown type of gtype container %d",
                        container->header & (AGT_FARRAY | AGT_FOBJECT))));
    }

    return it;
}

/*
 * gtype_iterator_next() worker: Return parent, while freeing memory for
 *                                current iterator
 */
static gtype_iterator *free_and_get_parent(gtype_iterator *it)
{
    gtype_iterator *v = it->parent;

    pfree(it);
    return v;
}

/*
 * Worker for "contains" operator's function
 *
 * Formally speaking, containment is top-down, unordered subtree isomorphism.
 *
 * Takes iterators that belong to some container type.  These iterators
 * "belong" to those values in the sense that they've just been initialized in
 * respect of them by the caller (perhaps in a nested fashion).
 *
 * "val" is lhs gtype, and m_contained is rhs gtype when called from top
 * level. We determine if m_contained is contained within val.
 */
bool gtype_deep_contains(gtype_iterator **val, gtype_iterator **m_contained)
{
    gtype_value vval;
    gtype_value vcontained;
    gtype_iterator_token rval;
    gtype_iterator_token rcont;

    /*
     * Guard against queue overflow due to overly complex gtype.
     *
     * Functions called here independently take this precaution, but that
     * might not be sufficient since this is also a recursive function.
     */
    check_stack_depth();

    rval = gtype_iterator_next(val, &vval, false);
    rcont = gtype_iterator_next(m_contained, &vcontained, false);

    if (rval != rcont)
    {
        /*
         * The differing return values can immediately be taken as indicating
         * two differing container types at this nesting level, which is
         * sufficient reason to give up entirely (but it should be the case
         * that they're both some container type).
         */
        Assert(rval == WAGT_BEGIN_OBJECT || rval == WAGT_BEGIN_ARRAY);
        Assert(rcont == WAGT_BEGIN_OBJECT || rcont == WAGT_BEGIN_ARRAY);
        return false;
    }
    else if (rcont == WAGT_BEGIN_OBJECT)
    {
        Assert(vval.type == AGTV_OBJECT);
        Assert(vcontained.type == AGTV_OBJECT);

        /*
         * If the lhs has fewer pairs than the rhs, it can't possibly contain
         * the rhs.  (This conclusion is safe only because we de-duplicate
         * keys in all gtype objects; thus there can be no corresponding
         * optimization in the array case.)  The case probably won't arise
         * often, but since it's such a cheap check we may as well make it.
         */
        if (vval.val.object.num_pairs < vcontained.val.object.num_pairs)
            return false;

        /* Work through rhs "is it contained within?" object */
        for (;;)
        {
            gtype_value *lhs_val; /* lhs_val is from pair in lhs object */

            rcont = gtype_iterator_next(m_contained, &vcontained, false);

            /*
             * When we get through caller's rhs "is it contained within?"
             * object without failing to find one of its values, it's
             * contained.
             */
            if (rcont == WAGT_END_OBJECT)
                return true;

            Assert(rcont == WAGT_KEY);

            /* First, find value by key... */
            lhs_val = find_gtype_value_from_container(
                (*val)->container, AGT_FOBJECT, &vcontained);

            if (!lhs_val)
                return false;

            /*
             * ...at this stage it is apparent that there is at least a key
             * match for this rhs pair.
             */
            rcont = gtype_iterator_next(m_contained, &vcontained, true);

            Assert(rcont == WAGT_VALUE);

            /*
             * Compare rhs pair's value with lhs pair's value just found using
             * key
             */
            if (lhs_val->type != vcontained.type)
            {
                return false;
            }
            else if (IS_A_GTYPE_SCALAR(lhs_val))
            {
                if (!equals_gtype_scalar_value(lhs_val, &vcontained))
                    return false;
            }
            else
            {
                /* Nested container value (object or array) */
                gtype_iterator *nestval;
                gtype_iterator *nest_contained;

                Assert(lhs_val->type == AGTV_BINARY);
                Assert(vcontained.type == AGTV_BINARY);

                nestval = gtype_iterator_init(lhs_val->val.binary.data);
                nest_contained =
                    gtype_iterator_init(vcontained.val.binary.data);

                /*
                 * Match "value" side of rhs datum object's pair recursively.
                 * It's a nested structure.
                 *
                 * Note that nesting still has to "match up" at the right
                 * nesting sub-levels.  However, there need only be zero or
                 * more matching pairs (or elements) at each nesting level
                 * (provided the *rhs* pairs/elements *all* match on each
                 * level), which enables searching nested structures for a
                 * single String or other primitive type sub-datum quite
                 * effectively (provided the user constructed the rhs nested
                 * structure such that we "know where to look").
                 *
                 * In other words, the mapping of container nodes in the rhs
                 * "vcontained" gtype to internal nodes on the lhs is
                 * injective, and parent-child edges on the rhs must be mapped
                 * to parent-child edges on the lhs to satisfy the condition
                 * of containment (plus of course the mapped nodes must be
                 * equal).
                 */
                if (!gtype_deep_contains(&nestval, &nest_contained))
                    return false;
            }
        }
    }
    else if (rcont == WAGT_BEGIN_ARRAY)
    {
        gtype_value *lhs_conts = NULL;
        uint32 num_lhs_elems = vval.val.array.num_elems;

        Assert(vval.type == AGTV_ARRAY);
        Assert(vcontained.type == AGTV_ARRAY);

        /*
         * Handle distinction between "raw scalar" pseudo arrays, and real
         * arrays.
         *
         * A raw scalar may contain another raw scalar, and an array may
         * contain a raw scalar, but a raw scalar may not contain an array. We
         * don't do something like this for the object case, since objects can
         * only contain pairs, never raw scalars (a pair is represented by an
         * rhs object argument with a single contained pair).
         */
        if (vval.val.array.raw_scalar && !vcontained.val.array.raw_scalar)
            return false;

        /* Work through rhs "is it contained within?" array */
        for (;;)
        {
            rcont = gtype_iterator_next(m_contained, &vcontained, true);

            /*
             * When we get through caller's rhs "is it contained within?"
             * array without failing to find one of its values, it's
             * contained.
             */
            if (rcont == WAGT_END_ARRAY)
                return true;

            Assert(rcont == WAGT_ELEM);

            if (IS_A_GTYPE_SCALAR(&vcontained))
            {
                if (!find_gtype_value_from_container((*val)->container,
                                                      AGT_FARRAY, &vcontained))
                    return false;
            }
            else
            {
                uint32 i;

                /*
                 * If this is first container found in rhs array (at this
                 * depth), initialize temp lhs array of containers
                 */
                if (lhs_conts == NULL)
                {
                    uint32 j = 0;

                    /* Make room for all possible values */
                    lhs_conts = palloc(sizeof(gtype_value) * num_lhs_elems);

                    for (i = 0; i < num_lhs_elems; i++)
                    {
                        /* Store all lhs elements in temp array */
                        rcont = gtype_iterator_next(val, &vval, true);
                        Assert(rcont == WAGT_ELEM);

                        if (vval.type == AGTV_BINARY)
                            lhs_conts[j++] = vval;
                    }

                    /* No container elements in temp array, so give up now */
                    if (j == 0)
                        return false;

                    /* We may have only partially filled array */
                    num_lhs_elems = j;
                }

                /* XXX: Nested array containment is O(N^2) */
                for (i = 0; i < num_lhs_elems; i++)
                {
                    /* Nested container value (object or array) */
                    gtype_iterator *nestval;
                    gtype_iterator *nest_contained;
                    bool contains;

                    nestval =
                        gtype_iterator_init(lhs_conts[i].val.binary.data);
                    nest_contained =
                        gtype_iterator_init(vcontained.val.binary.data);

                    contains = gtype_deep_contains(&nestval, &nest_contained);

                    if (nestval)
                        pfree(nestval);
                    if (nest_contained)
                        pfree(nest_contained);
                    if (contains)
                        break;
                }

                /*
                 * Report rhs container value is not contained if couldn't
                 * match rhs container to *some* lhs cont
                 */
                if (i == num_lhs_elems)
                    return false;
            }
        }
    }
    else
    {
        ereport(ERROR, (errmsg("invalid gtype container type")));
    }

    ereport(ERROR, (errmsg("unexpectedly fell off end of gtype container")));
    return false;
}

/*
 * Hash an gtype_value scalar value, mixing the hash value into an existing
 * hash provided by the caller.
 *
 * Some callers may wish to independently XOR in AGT_FOBJECT and AGT_FARRAY
 * flags.
 */
void gtype_hash_scalar_value(const gtype_value *scalar_val, uint32 *hash)
{
    uint32 tmp;

    /* Compute hash value for scalar_val */
    switch (scalar_val->type)
    {
    case AGTV_NULL:
        tmp = 0x01;
        break;
    case AGTV_STRING:
        tmp = DatumGetUInt32(
            hash_any((const unsigned char *)scalar_val->val.string.val,
                     scalar_val->val.string.len));
        break;
    case AGTV_NUMERIC:
        /* Must hash equal numerics to equal hash codes */
        tmp = DatumGetUInt32(DirectFunctionCall1(
            hash_numeric, NumericGetDatum(scalar_val->val.numeric)));
        break;
    case AGTV_BOOL:
        tmp = scalar_val->val.boolean ? 0x02 : 0x04;
        break;
    case AGTV_INTEGER:
        tmp = DatumGetUInt32(DirectFunctionCall1(
            hashint8, Int64GetDatum(scalar_val->val.int_value)));
        break;
    case AGTV_FLOAT:
        tmp = DatumGetUInt32(DirectFunctionCall1(
            hashfloat8, Float8GetDatum(scalar_val->val.float_value)));
        break;
    default:
        ereport(ERROR, (errmsg("invalid gtype scalar type %d to compute hash",
                               scalar_val->type)));
        tmp = 0; /* keep compiler quiet */
        break;
    }

    /*
     * Combine hash values of successive keys, values and elements by rotating
     * the previous value left 1 bit, then XOR'ing in the new
     * key/value/element's hash value.
     */
    *hash = (*hash << 1) | (*hash >> 31);
    *hash ^= tmp;
}

/*
 * Hash a value to a 64-bit value, with a seed. Otherwise, similar to
 * gtype_hash_scalar_value.
 */
void gtype_hash_scalar_value_extended(const gtype_value *scalar_val,
                                       uint64 *hash, uint64 seed)
{
    uint64 tmp = 0;

    switch (scalar_val->type)
    {
    case AGTV_NULL:
        tmp = seed + 0x01;
        break;
    case AGTV_STRING:
        tmp = DatumGetUInt64(hash_any_extended(
            (const unsigned char *)scalar_val->val.string.val,
            scalar_val->val.string.len, seed));
        break;
    case AGTV_NUMERIC:
        tmp = DatumGetUInt64(DirectFunctionCall2(
            hash_numeric_extended, NumericGetDatum(scalar_val->val.numeric),
            UInt64GetDatum(seed)));
        break;
    case AGTV_BOOL:
        if (seed)
        {
            tmp = DatumGetUInt64(DirectFunctionCall2(
                hashcharextended, BoolGetDatum(scalar_val->val.boolean),
                UInt64GetDatum(seed)));
        }
        else
        {
            tmp = scalar_val->val.boolean ? 0x02 : 0x04;
        }
        break;
    case AGTV_INTEGER:
        tmp = DatumGetUInt64(DirectFunctionCall2(
            hashint8extended, Int64GetDatum(scalar_val->val.int_value),
            UInt64GetDatum(seed)));
        break;
    case AGTV_FLOAT:
        tmp = DatumGetUInt64(DirectFunctionCall2(
            hashfloat8extended, Float8GetDatum(scalar_val->val.float_value),
            UInt64GetDatum(seed)));
        break;
    default:
        ereport(
            ERROR,
            (errmsg("invalid gtype scalar type %d to compute hash extended",
                    scalar_val->type)));
        break;
    }

    *hash = ROTATE_HIGH_AND_LOW_32BITS(*hash);
    *hash ^= tmp;
}

/*
 * Function to compare two floats, obviously. However, there are a few
 * special cases that we need to cover with regards to NaN and +/-Infinity.
 * NaN is not equal to any other number, including itself. However, for
 * ordering, we need to allow NaN = NaN and NaN > any number including
 * positive infinity -
 *
 *     -Infinity < any number < +Infinity < NaN
 *
 * Note: This is copied from float8_cmp_internal.
 * Note: Special float values can cause exceptions, hence the order of the
 *       comparisons.
 */
static int compare_two_floats_orderability(float8 lhs, float8 rhs)
{
    /*
     * We consider all NANs to be equal and larger than any non-NAN. This is
     * somewhat arbitrary; the important thing is to have a consistent sort
     * order.
     */
    if (isnan(lhs))
    {
        if (isnan(rhs))
            return 0; /* NAN = NAN */
        else
            return 1; /* NAN > non-NAN */
    }
    else if (isnan(rhs))
    {
        return -1; /* non-NAN < NAN */
    }
    else
    {
        if (lhs > rhs)
            return 1;
        else if (lhs < rhs)
            return -1;
        else
            return 0;
    }
}

/*
 * Are two scalar gtype_values of the same type a and b equal?
 */
static bool equals_gtype_scalar_value(const gtype_value *a, const gtype_value *b)
{
    /* if the values are of the same type */
    if (a->type == b->type)
    {
        switch (a->type)
        {
        case AGTV_NULL:
            return true;
        case AGTV_STRING:
            return length_compare_gtype_string_value(a, b) == 0;
        case AGTV_NUMERIC:
            return DatumGetBool(DirectFunctionCall2(
                numeric_eq, PointerGetDatum(a->val.numeric),
                PointerGetDatum(b->val.numeric)));
        case AGTV_BOOL:
            return a->val.boolean == b->val.boolean;
        case AGTV_INTEGER:
        case AGTV_TIMESTAMP:
        case AGTV_TIME:
            return a->val.int_value == b->val.int_value;
        case AGTV_TIMESTAMPTZ:
            return timestamptz_cmp_internal(a->val.int_value, b->val.int_value) == 0;
        case AGTV_DATE:
            return a->val.date == b->val.date;
        case AGTV_TIMETZ:
            return timetz_cmp_internal(&a->val.timetz, &b->val.timetz) == 0;
        case AGTV_INTERVAL:
            return interval_cmp_internal(&a->val.interval, &b->val.interval) == 0;
	case AGTV_FLOAT:
            return a->val.float_value == b->val.float_value;
        default:
            ereport(ERROR, (errmsg("invalid gtype scalar type %d for equals", a->type)));
        }
    }
    /* otherwise, the values are of differing type */
    else
        ereport(ERROR, (errmsg("gtype input scalars must be of same type")));

    /* execution will never reach this point due to the ereport call */
    return false;
}

/*
 * Compare two scalar gtype_values, returning -1, 0, or 1.
 *
 * Strings are compared using the default collation.  Used by B-tree
 * operators, where a lexical sort order is generally expected.
 */
int compare_gtype_scalar_values(gtype_value *a, gtype_value *b)
{
    if (a->type == b->type)
    {
        switch (a->type)
        {
        case AGTV_NULL:
            return 0;
        case AGTV_STRING:
            return varstr_cmp(a->val.string.val, a->val.string.len, b->val.string.val, b->val.string.len,
                              DEFAULT_COLLATION_OID);
        case AGTV_NUMERIC:
            return DatumGetInt32(DirectFunctionCall2(
                numeric_cmp, PointerGetDatum(a->val.numeric),
                PointerGetDatum(b->val.numeric)));
        case AGTV_BOOL:
            if (a->val.boolean == b->val.boolean)
                return 0;
            else if (a->val.boolean > b->val.boolean)
                return 1;
            else
                return -1;
        case AGTV_TIMESTAMP:
	    return timestamp_cmp_internal(a->val.int_value, b->val.int_value);
	case AGTV_TIMESTAMPTZ:
	    return timestamptz_cmp_internal(a->val.int_value, b->val.int_value);
	case AGTV_INTEGER:
	case AGTV_TIME:
            if (a->val.int_value == b->val.int_value)
                return 0;
            else if (a->val.int_value > b->val.int_value)
                return 1;
            else
                return -1;
	case AGTV_DATE:
            if (a->val.date == b->val.date)
                return 0;
            else if (a->val.date > b->val.date)
                return 1;
            else
                return -1;
	case AGTV_TIMETZ:
	    return timetz_cmp_internal(&a->val.timetz, &b->val.timetz);
	case AGTV_INTERVAL:
	    return interval_cmp_internal(&a->val.interval, &b->val.interval);
        case AGTV_FLOAT:
            return compare_two_floats_orderability(a->val.float_value, b->val.float_value);
	default:
            ereport(ERROR, (errmsg("invalid gtype scalar type %d for compare", a->type)));
        }
    }

    // timestamp and timestamp with timezone
    if (a->type == AGTV_TIMESTAMP && b->type == AGTV_TIMESTAMPTZ)
        return timestamp_cmp_timestamptz_internal(a->val.int_value, b->val.int_value);

    if (a->type == AGTV_TIMESTAMPTZ && b->type == AGTV_TIMESTAMP)
        return -1 * timestamp_cmp_timestamptz_internal(b->val.int_value, a->val.int_value);

    // date and timestamp
    if (a->type == AGTV_DATE && b->type == AGTV_TIMESTAMP)
        return date_cmp_timestamp_internal(a->val.date, b->val.int_value);

    if (a->type == AGTV_TIMESTAMP && b->type == AGTV_DATE)
        return -1 * date_cmp_timestamp_internal(b->val.date, a->val.int_value);

    // date and timestamp with timezone
    if (a->type == AGTV_DATE && b->type == AGTV_TIMESTAMPTZ)
        return date_cmp_timestamptz_internal(a->val.date, b->val.int_value);

    if (a->type == AGTV_TIMESTAMPTZ && b->type == AGTV_DATE)
        return -1 * date_cmp_timestamptz_internal(b->val.date, a->val.int_value);

    // time and time with timezone
    if (a->type == AGTV_TIME && b->type == AGTV_TIMETZ) {
         int64 b_time = DatumGetTimeADT(DirectFunctionCall1(timetz_time, TimeTzADTPGetDatum(&b->val.timetz)));

         if (a->val.int_value == b_time)
            return 0;
         else if (a->val.int_value > b_time)
            return 1;
         else
            return -1;
    }

    if (a->type == AGTV_TIMETZ && b->type == AGTV_TIME) {
         int64 a_time = DatumGetTimeADT(DirectFunctionCall1(timetz_time, TimeTzADTPGetDatum(&a->val.timetz)));

         if (a_time == b->val.int_value)
            return 0;
         else if (a_time > b->val.int_value)
            return 1;
         else
            return -1; 
    }


    /* check for integer compared to float */
    if (a->type == AGTV_INTEGER && b->type == AGTV_FLOAT)
        return compare_two_floats_orderability((float8)a->val.int_value, b->val.float_value);
    /* check for float compared to integer */
    if (a->type == AGTV_FLOAT && b->type == AGTV_INTEGER)
        return compare_two_floats_orderability(a->val.float_value, (float8)b->val.int_value);
    /* check for integer or float compared to numeric */
    if (is_numeric_result(a, b))
    {
        Datum numd, lhsd, rhsd;

        lhsd = get_numeric_datum_from_gtype_value(a);
        rhsd = get_numeric_datum_from_gtype_value(b);
        numd = DirectFunctionCall2(numeric_cmp, lhsd, rhsd);

        return DatumGetInt32(numd);
    }

    ereport(ERROR, (errmsg("gtype input scalar type mismatch")));
    return -1;
}

/*
 * Functions for manipulating the resizeable buffer used by convert_gtype and
 * its subroutines.
 */

/*
 * Reserve 'len' bytes, at the end of the buffer, enlarging it if necessary.
 * Returns the offset to the reserved area. The caller is expected to fill
 * the reserved area later with copy_to_buffer().
 */
int reserve_from_buffer(StringInfo buffer, int len)
{
    int offset;

    /* Make more room if needed */
    enlargeStringInfo(buffer, len);

    /* remember current offset */
    offset = buffer->len;

    /* reserve the space */
    buffer->len += len;

    /*
     * Keep a trailing null in place, even though it's not useful for us; it
     * seems best to preserve the invariants of StringInfos.
     */
    buffer->data[buffer->len] = '\0';

    return offset;
}

/*
 * Copy 'len' bytes to a previously reserved area in buffer.
 */
static void copy_to_buffer(StringInfo buffer, int offset, const char *data,
                           int len)
{
    memcpy(buffer->data + offset, data, len);
}

/*
 * A shorthand for reserve_from_buffer + copy_to_buffer.
 */
static void append_to_buffer(StringInfo buffer, const char *data, int len)
{
    int offset;

    offset = reserve_from_buffer(buffer, len);
    copy_to_buffer(buffer, offset, data, len);
}

/*
 * Append padding, so that the length of the StringInfo is int-aligned.
 * Returns the number of padding bytes appended.
 */
short pad_buffer_to_int(StringInfo buffer)
{
    int padlen;
    int p;
    int offset;

    padlen = INTALIGN(buffer->len) - buffer->len;

    offset = reserve_from_buffer(buffer, padlen);

    /* padlen must be small, so this is probably faster than a memset */
    for (p = 0; p < padlen; p++)
        buffer->data[offset + p] = '\0';

    return padlen;
}

/*
 * Given an gtype_value, convert to gtype. The result is palloc'd.
 */
static gtype *convert_to_gtype(gtype_value *val)
{
    StringInfoData buffer;
    agtentry aentry;
    gtype *res;

    /* Should not already have binary representation */
    Assert(val->type != AGTV_BINARY);

    /* Allocate an output buffer. It will be enlarged as needed */
    initStringInfo(&buffer);

    /* Make room for the varlena header */
    reserve_from_buffer(&buffer, VARHDRSZ);

    convert_gtype_value(&buffer, &aentry, val, 0);

    /*
     * Note: the agtentry of the root is discarded. Therefore the root
     * gtype_container struct must contain enough information to tell what
     * kind of value it is.
     */

    res = (gtype *)buffer.data;

    SET_VARSIZE(res, buffer.len);

    return res;
}

/*
 * Subroutine of convert_gtype: serialize a single gtype_value into buffer.
 *
 * The agtentry header for this node is returned in *header.  It is filled in
 * with the length of this value and appropriate type bits.  If we wish to
 * store an end offset rather than a length, it is the caller's responsibility
 * to adjust for that.
 *
 * If the value is an array or an object, this recurses. 'level' is only used
 * for debugging purposes.
 */
static void convert_gtype_value(StringInfo buffer, agtentry *header,
                                 gtype_value *val, int level)
{
    check_stack_depth();

    if (!val)
        return;

    /*
     * An gtype_value passed as val should never have a type of AGTV_BINARY,
     * and neither should any of its sub-components. Those values will be
     * produced by convert_gtype_array and convert_gtype_object, the results
     * of which will not be passed back to this function as an argument.
     */

    if (IS_A_GTYPE_SCALAR(val))
        convert_gtype_scalar(buffer, header, val);
    else if (val->type == AGTV_ARRAY)
        convert_gtype_array(buffer, header, val, level);
    else if (val->type == AGTV_OBJECT)
        convert_gtype_object(buffer, header, val, level);
    else
        ereport(ERROR,
                (errmsg("unknown gtype type %d to convert", val->type)));
}

static void convert_gtype_array(StringInfo buffer, agtentry *pheader,
                                 gtype_value *val, int level)
{
    int base_offset;
    int agtentry_offset;
    int i;
    int totallen;
    uint32 header;
    int num_elems = val->val.array.num_elems;

    /* Remember where in the buffer this array starts. */
    base_offset = buffer->len;

    /* Align to 4-byte boundary (any padding counts as part of my data) */
    pad_buffer_to_int(buffer);

    /*
     * Construct the header agtentry and store it in the beginning of the
     * variable-length payload.
     */
    header = num_elems | AGT_FARRAY;
    if (val->val.array.raw_scalar)
    {
        Assert(num_elems == 1);
        Assert(level == 0);
        header |= AGT_FSCALAR;
    }

    append_to_buffer(buffer, (char *)&header, sizeof(uint32));

    /* Reserve space for the agtentrys of the elements. */
    agtentry_offset = reserve_from_buffer(buffer,
                                          sizeof(agtentry) * num_elems);

    totallen = 0;
    for (i = 0; i < num_elems; i++)
    {
        gtype_value *elem = &val->val.array.elems[i];
        int len;
        agtentry meta;

        /*
         * Convert element, producing a agtentry and appending its
         * variable-length data to buffer
         */
        convert_gtype_value(buffer, &meta, elem, level + 1);

        len = AGTE_OFFLENFLD(meta);
        totallen += len;

        /*
         * Bail out if total variable-length data exceeds what will fit in a
         * agtentry length field.  We check this in each iteration, not just
         * once at the end, to forestall possible integer overflow.
         */
        if (totallen > AGTENTRY_OFFLENMASK)
        {
            ereport(
                ERROR,
                (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
                 errmsg(
                     "total size of gtype array elements exceeds the maximum of %u bytes",
                     AGTENTRY_OFFLENMASK)));
        }

        /*
         * Convert each AGT_OFFSET_STRIDE'th length to an offset.
         */
        if ((i % AGT_OFFSET_STRIDE) == 0)
            meta = (meta & AGTENTRY_TYPEMASK) | totallen | AGTENTRY_HAS_OFF;

        copy_to_buffer(buffer, agtentry_offset, (char *)&meta,
                       sizeof(agtentry));
        agtentry_offset += sizeof(agtentry);
    }

    /* Total data size is everything we've appended to buffer */
    totallen = buffer->len - base_offset;

    /* Check length again, since we didn't include the metadata above */
    if (totallen > AGTENTRY_OFFLENMASK)
    {
        ereport(
            ERROR,
            (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
             errmsg(
                 "total size of gtype array elements exceeds the maximum of %u bytes",
                 AGTENTRY_OFFLENMASK)));
    }

    /* Initialize the header of this node in the container's agtentry array */
    *pheader = AGTENTRY_IS_CONTAINER | totallen;
}

void convert_extended_array(StringInfo buffer, agtentry *pheader,
                            gtype_value *val)
{
    convert_gtype_array(buffer, pheader, val, 0);
}

void convert_extended_object(StringInfo buffer, agtentry *pheader,
                             gtype_value *val)
{
    convert_gtype_object(buffer, pheader, val, 0);
}

static void convert_gtype_object(StringInfo buffer, agtentry *pheader,
                                  gtype_value *val, int level)
{
    int base_offset;
    int agtentry_offset;
    int i;
    int totallen;
    uint32 header;
    int num_pairs = val->val.object.num_pairs;

    /* Remember where in the buffer this object starts. */
    base_offset = buffer->len;

    /* Align to 4-byte boundary (any padding counts as part of my data) */
    pad_buffer_to_int(buffer);

    /*
     * Construct the header agtentry and store it in the beginning of the
     * variable-length payload.
     */
    header = num_pairs | AGT_FOBJECT;
    append_to_buffer(buffer, (char *)&header, sizeof(uint32));

    /* Reserve space for the agtentrys of the keys and values. */
    agtentry_offset = reserve_from_buffer(buffer,
                                          sizeof(agtentry) * num_pairs * 2);

    /*
     * Iterate over the keys, then over the values, since that is the ordering
     * we want in the on-disk representation.
     */
    totallen = 0;
    for (i = 0; i < num_pairs; i++)
    {
        gtype_pair *pair = &val->val.object.pairs[i];
        int len;
        agtentry meta;

        /*
         * Convert key, producing an agtentry and appending its variable-length
         * data to buffer
         */
        convert_gtype_scalar(buffer, &meta, &pair->key);

        len = AGTE_OFFLENFLD(meta);
        totallen += len;

        /*
         * Bail out if total variable-length data exceeds what will fit in a
         * agtentry length field.  We check this in each iteration, not just
         * once at the end, to forestall possible integer overflow.
         */
        if (totallen > AGTENTRY_OFFLENMASK)
        {
            ereport(
                ERROR,
                (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
                 errmsg(
                     "total size of gtype object elements exceeds the maximum of %u bytes",
                     AGTENTRY_OFFLENMASK)));
        }

        /*
         * Convert each AGT_OFFSET_STRIDE'th length to an offset.
         */
        if ((i % AGT_OFFSET_STRIDE) == 0)
            meta = (meta & AGTENTRY_TYPEMASK) | totallen | AGTENTRY_HAS_OFF;

        copy_to_buffer(buffer, agtentry_offset, (char *)&meta,
                       sizeof(agtentry));
        agtentry_offset += sizeof(agtentry);
    }
    for (i = 0; i < num_pairs; i++)
    {
        gtype_pair *pair = &val->val.object.pairs[i];
        int len;
        agtentry meta;

        /*
         * Convert value, producing an agtentry and appending its
         * variable-length data to buffer
         */
        convert_gtype_value(buffer, &meta, &pair->value, level + 1);

        len = AGTE_OFFLENFLD(meta);
        totallen += len;

        /*
         * Bail out if total variable-length data exceeds what will fit in a
         * agtentry length field.  We check this in each iteration, not just
         * once at the end, to forestall possible integer overflow.
         */
        if (totallen > AGTENTRY_OFFLENMASK)
        {
            ereport(
                ERROR,
                (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
                 errmsg(
                     "total size of gtype object elements exceeds the maximum of %u bytes",
                     AGTENTRY_OFFLENMASK)));
        }

        /*
         * Convert each AGT_OFFSET_STRIDE'th length to an offset.
         */
        if (((i + num_pairs) % AGT_OFFSET_STRIDE) == 0)
            meta = (meta & AGTENTRY_TYPEMASK) | totallen | AGTENTRY_HAS_OFF;

        copy_to_buffer(buffer, agtentry_offset, (char *)&meta,
                       sizeof(agtentry));
        agtentry_offset += sizeof(agtentry);
    }

    /* Total data size is everything we've appended to buffer */
    totallen = buffer->len - base_offset;

    /* Check length again, since we didn't include the metadata above */
    if (totallen > AGTENTRY_OFFLENMASK)
    {
        ereport(
            ERROR,
            (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
             errmsg(
                 "total size of gtype object elements exceeds the maximum of %u bytes",
                 AGTENTRY_OFFLENMASK)));
    }

    /* Initialize the header of this node in the container's agtentry array */
    *pheader = AGTENTRY_IS_CONTAINER | totallen;
}

static void convert_gtype_scalar(StringInfo buffer, agtentry *entry,
                                  gtype_value *scalar_val)
{
    int numlen;
    short padlen;
    bool status;

    switch (scalar_val->type)
    {
    case AGTV_NULL:
        *entry = AGTENTRY_IS_NULL;
        break;

    case AGTV_STRING:
        append_to_buffer(buffer, scalar_val->val.string.val,
                         scalar_val->val.string.len);

        *entry = scalar_val->val.string.len;
        break;

    case AGTV_NUMERIC:
        numlen = VARSIZE_ANY(scalar_val->val.numeric);
        padlen = pad_buffer_to_int(buffer);

        append_to_buffer(buffer, (char *)scalar_val->val.numeric, numlen);

        *entry = AGTENTRY_IS_NUMERIC | (padlen + numlen);
        break;

    case AGTV_BOOL:
        *entry = (scalar_val->val.boolean) ? AGTENTRY_IS_BOOL_TRUE :
                                             AGTENTRY_IS_BOOL_FALSE;
        break;

    default:
        /* returns true if there was a valid extended type processed */
        status = ag_serialize_extended_type(buffer, entry, scalar_val);
        /* if nothing was found, error log out */
        if (!status)
            ereport(ERROR, (errmsg("invalid gtype scalar type %d to convert",
                                   scalar_val->type)));
    }
}

/*
 * Compare two AGTV_STRING gtype_value values, a and b.
 *
 * This is a special qsort() comparator used to sort strings in certain
 * internal contexts where it is sufficient to have a well-defined sort order.
 * In particular, object pair keys are sorted according to this criteria to
 * facilitate cheap binary searches where we don't care about lexical sort
 * order.
 *
 * a and b are first sorted based on their length.  If a tie-breaker is
 * required, only then do we consider string binary equality.
 */
static int length_compare_gtype_string_value(const void *a, const void *b)
{
    const gtype_value *va = (const gtype_value *)a;
    const gtype_value *vb = (const gtype_value *)b;
    int res;

    Assert(va->type == AGTV_STRING);
    Assert(vb->type == AGTV_STRING);

    if (va->val.string.len == vb->val.string.len)
    {
        res = memcmp(va->val.string.val, vb->val.string.val,
                     va->val.string.len);
    }
    else
    {
        res = (va->val.string.len > vb->val.string.len) ? 1 : -1;
    }

    return res;
}

/*
 * qsort_arg() comparator to compare gtype_pair values.
 *
 * Third argument 'binequal' may point to a bool. If it's set, *binequal is set
 * to true iff a and b have full binary equality, since some callers have an
 * interest in whether the two values are equal or merely equivalent.
 *
 * N.B: String comparisons here are "length-wise"
 *
 * Pairs with equals keys are ordered such that the order field is respected.
 */
static int length_compare_gtype_pair(const void *a, const void *b,
                                      void *binequal)
{
    const gtype_pair *pa = (const gtype_pair *)a;
    const gtype_pair *pb = (const gtype_pair *)b;
    int res;

    res = length_compare_gtype_string_value(&pa->key, &pb->key);
    if (res == 0 && binequal)
        *((bool *)binequal) = true;

    /*
     * Guarantee keeping order of equal pair.  Unique algorithm will prefer
     * first element as value.
     */
    if (res == 0)
        res = (pa->order > pb->order) ? -1 : 1;

    return res;
}

/*
 * Sort and unique-ify pairs in gtype_value object
 */
void uniqueify_gtype_object(gtype_value *object)
{
    bool has_non_uniq = false;

    Assert(object->type == AGTV_OBJECT);

    if (object->val.object.num_pairs > 1)
        qsort_arg(object->val.object.pairs, object->val.object.num_pairs,
                  sizeof(gtype_pair), length_compare_gtype_pair,
                  &has_non_uniq);

    if (has_non_uniq)
    {
        gtype_pair *ptr = object->val.object.pairs + 1;
        gtype_pair *res = object->val.object.pairs;

        while (ptr - object->val.object.pairs < object->val.object.num_pairs)
        {
            /* Avoid copying over duplicate */
            if (length_compare_gtype_string_value(ptr, res) != 0)
            {
                res++;
                if (ptr != res)
                    memcpy(res, ptr, sizeof(gtype_pair));
            }
            ptr++;
        }

        object->val.object.num_pairs = res + 1 - object->val.object.pairs;
    }
}

char *gtype_value_type_to_string(enum gtype_value_type type)
{
    switch (type)
    {
        case AGTV_NULL:
            return "NULL";
        case AGTV_STRING:
            return "string";
        case AGTV_NUMERIC:
            return "numeric";
        case AGTV_INTEGER:
            return "integer";
        case AGTV_FLOAT:
            return "float";
        case AGTV_BOOL:
            return "boolean";
        case AGTV_ARRAY:
            return "array";
        case AGTV_OBJECT:
            return "map";
        case AGTV_BINARY:
            return "binary";
        default:
            ereport(ERROR,
                    (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                            errmsg("unknown gtype")));
    }

    return NULL;
}
