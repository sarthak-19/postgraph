/*
 * PostGraph
 * Copyright (C) 2023 by PostGraph
 *
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 *
 * Portions Copyright (c) 2020-2023, Apache Software Foundation
 * Portions Copyright (c) 2019-2020, Bitnine Global
 */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION age" to load this file. \quit

--
-- catalog tables
--
CREATE TABLE ag_graph (graphid oid NOT NULL, name name NOT NULL, namespace regnamespace NOT NULL);

CREATE UNIQUE INDEX ag_graph_graphid_index ON ag_graph USING btree (graphid);
CREATE UNIQUE INDEX ag_graph_name_index ON ag_graph USING btree (name);
CREATE UNIQUE INDEX ag_graph_namespace_index ON ag_graph USING btree (namespace);

-- 0 is an invalid label ID
CREATE DOMAIN label_id AS int NOT NULL CHECK (VALUE > 0 AND VALUE <= 65535);
CREATE DOMAIN label_kind AS "char" NOT NULL CHECK (VALUE = 'v' OR VALUE = 'e');

CREATE TABLE ag_label (name name NOT NULL, graph oid NOT NULL, id label_id, kind label_kind, relation regclass NOT NULL, CONSTRAINT fk_graph_oid FOREIGN KEY(graph) REFERENCES ag_graph(graphid));

CREATE UNIQUE INDEX ag_label_name_graph_index ON ag_label USING btree (name, graph);
CREATE UNIQUE INDEX ag_label_graph_oid_index ON ag_label USING btree (graph, id);
CREATE UNIQUE INDEX ag_label_relation_index ON ag_label USING btree (relation);

--
-- catalog lookup functions
--
CREATE FUNCTION _label_id(graph_name name, label_name name) RETURNS label_id LANGUAGE c STABLE PARALLEL SAFE AS 'MODULE_PATHNAME';

--
-- utility functions
--
CREATE FUNCTION create_graph(graph_name name) RETURNS void LANGUAGE c AS 'MODULE_PATHNAME';
CREATE FUNCTION create_graph_if_not_exists(graph_name name) RETURNS void LANGUAGE c AS 'MODULE_PATHNAME';
CREATE FUNCTION drop_graph(graph_name name, cascade boolean = false) RETURNS void LANGUAGE c AS 'MODULE_PATHNAME';
CREATE FUNCTION create_vlabel(graph_name name, label_name name) RETURNS void LANGUAGE c AS 'MODULE_PATHNAME';
CREATE FUNCTION create_elabel(graph_name name, label_name name) RETURNS void LANGUAGE c AS 'MODULE_PATHNAME';
CREATE FUNCTION alter_graph(graph_name name, operation cstring, new_value name) RETURNS void LANGUAGE c AS 'MODULE_PATHNAME';
CREATE FUNCTION drop_label(graph_name name, label_name name, force boolean = false) RETURNS void LANGUAGE c AS 'MODULE_PATHNAME';

--
-- graphid type
--
CREATE TYPE graphid;

CREATE FUNCTION graphid_in(cstring) RETURNS graphid LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION graphid_out(graphid) RETURNS cstring LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
-- binary I/O functions
CREATE FUNCTION graphid_send(graphid) RETURNS bytea LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION graphid_recv(internal) RETURNS graphid LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';

CREATE TYPE graphid (INPUT = graphid_in, OUTPUT = graphid_out, SEND = graphid_send, RECEIVE = graphid_recv, INTERNALLENGTH = 8, PASSEDBYVALUE, ALIGNMENT = float8, STORAGE = plain);

--
-- graphid - comparison operators (=, <>, <, >, <=, >=)
--
CREATE FUNCTION graphid_eq(graphid, graphid) RETURNS boolean LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR = (FUNCTION = graphid_eq, LEFTARG = graphid, RIGHTARG = graphid, COMMUTATOR = =, NEGATOR = <>, RESTRICT = eqsel, JOIN = eqjoinsel, HASHES, MERGES);
CREATE FUNCTION graphid_ne(graphid, graphid) RETURNS boolean LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR <> (FUNCTION = graphid_ne, LEFTARG = graphid, RIGHTARG = graphid, COMMUTATOR = <>, NEGATOR = =, RESTRICT = neqsel, JOIN = neqjoinsel);
CREATE FUNCTION graphid_lt(graphid, graphid) RETURNS boolean LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR < (FUNCTION = graphid_lt, LEFTARG = graphid, RIGHTARG = graphid, COMMUTATOR = >, NEGATOR = >=, RESTRICT = scalarltsel, JOIN = scalarltjoinsel);
CREATE FUNCTION graphid_gt(graphid, graphid) RETURNS boolean LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR > (FUNCTION = graphid_gt, LEFTARG = graphid, RIGHTARG = graphid, COMMUTATOR = <, NEGATOR = <=, RESTRICT = scalargtsel, JOIN = scalargtjoinsel);
CREATE FUNCTION graphid_le(graphid, graphid) RETURNS boolean LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR <= (FUNCTION = graphid_le, LEFTARG = graphid, RIGHTARG = graphid, COMMUTATOR = >=, NEGATOR = >, RESTRICT = scalarlesel, JOIN = scalarlejoinsel);
CREATE FUNCTION graphid_ge(graphid, graphid) RETURNS boolean LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR >= (FUNCTION = graphid_ge, LEFTARG = graphid, RIGHTARG = graphid, COMMUTATOR = <=, NEGATOR = <, RESTRICT = scalargesel, JOIN = scalargejoinsel);

--
-- graphid - B-tree support functions
--
-- comparison support
CREATE FUNCTION graphid_btree_cmp(graphid, graphid) RETURNS int LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
-- sort support
CREATE FUNCTION graphid_btree_sort(internal) RETURNS void LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';

--
-- define operator classes for graphid
--
CREATE OPERATOR CLASS graphid_ops DEFAULT FOR TYPE graphid USING btree AS OPERATOR 1 <, OPERATOR 2 <=, OPERATOR 3 =, OPERATOR 4 >=, OPERATOR 5 >,
FUNCTION 1 graphid_btree_cmp (graphid, graphid), FUNCTION 2 graphid_btree_sort (internal);

--
-- graphid functions
--
CREATE FUNCTION _graphid(label_id int, entry_id bigint) RETURNS graphid LANGUAGE c IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION _label_name(graph_oid oid, graphid) RETURNS cstring LANGUAGE c STABLE PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION _extract_label_id(graphid) RETURNS label_id LANGUAGE c STABLE PARALLEL SAFE AS 'MODULE_PATHNAME';

--
-- gtype type and its support functions
--
CREATE TYPE gtype;

CREATE FUNCTION gtype_in(cstring) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION gtype_out(gtype) RETURNS cstring LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
-- binary I/O functions
CREATE FUNCTION gtype_send(gtype) RETURNS bytea LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION gtype_recv(internal) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';

CREATE TYPE gtype (INPUT = gtype_in, OUTPUT = gtype_out, SEND = gtype_send, RECEIVE = gtype_recv, LIKE = jsonb);

--
-- vertex
--
CREATE TYPE vertex;

CREATE FUNCTION vertex_in(cstring) RETURNS vertex LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION vertex_out(vertex) RETURNS cstring LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION build_vertex(graphid, cstring, gtype) RETURNS vertex LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';

CREATE TYPE vertex (INPUT = vertex_in, OUTPUT = vertex_out, LIKE = jsonb);

--
-- vertex - equality operators (=, <>)
--
CREATE FUNCTION vertex_eq(vertex, vertex) RETURNS boolean LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR = (FUNCTION = vertex_eq, LEFTARG = vertex, RIGHTARG = vertex, COMMUTATOR = =, NEGATOR = <>, RESTRICT = eqsel, JOIN = eqjoinsel, HASHES, MERGES);
CREATE FUNCTION vertex_ne(vertex, vertex) RETURNS boolean LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR <> (FUNCTION = vertex_ne, LEFTARG = vertex, RIGHTARG = vertex, COMMUTATOR = <>, NEGATOR = =, RESTRICT = neqsel, JOIN = neqjoinsel);

--
-- vertex - access operators (->, ->> )
--
CREATE FUNCTION vertex_property_access(vertex, text) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR -> (LEFTARG = vertex, RIGHTARG = text, FUNCTION = vertex_property_access);
CREATE FUNCTION vertex_property_access_text(vertex, text) RETURNS text LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR ->> (LEFTARG = vertex, RIGHTARG = text, FUNCTION = vertex_property_access_text);

--
-- vertex - contains operators (@>, <@)
--
CREATE FUNCTION vertex_contains(vertex, gtype) RETURNS boolean LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR @> (LEFTARG = vertex, RIGHTARG = gtype, FUNCTION = vertex_contains, COMMUTATOR = '<@', RESTRICT = contsel, JOIN = contjoinsel);
CREATE FUNCTION vertex_contained_by(gtype, vertex) RETURNS boolean LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR <@ (LEFTARG = gtype, RIGHTARG = vertex, FUNCTION = vertex_contained_by, COMMUTATOR = '@>', RESTRICT = contsel, JOIN = contjoinsel);

--
-- vertex - key existence operators (?, ?|, ?&)
--
CREATE FUNCTION vertex_exists(vertex, text) RETURNS boolean LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR ? (LEFTARG = vertex, RIGHTARG = text, FUNCTION = vertex_exists, COMMUTATOR = '?', RESTRICT = contsel, JOIN = contjoinsel);
CREATE FUNCTION vertex_exists_any(vertex, text[]) RETURNS boolean LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR ?| (LEFTARG = vertex, RIGHTARG = text[], FUNCTION = vertex_exists_any, RESTRICT = contsel, JOIN = contjoinsel);
CREATE FUNCTION vertex_exists_all(vertex, text[]) RETURNS boolean LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR ?& (LEFTARG = vertex, RIGHTARG = text[], FUNCTION = vertex_exists_all, RESTRICT = contsel, JOIN = contjoinsel);

--
-- vertex functions
--
CREATE FUNCTION id(vertex) RETURNS graphid LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME', 'vertex_id';
CREATE FUNCTION label(vertex) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME', 'vertex_label';
CREATE FUNCTION properties(vertex) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME', 'vertex_properties';

--
-- edge
--
CREATE TYPE edge;

CREATE FUNCTION edge_in(cstring) RETURNS edge LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION edge_out(edge) RETURNS cstring LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION build_edge(graphid, graphid, graphid, cstring, gtype) RETURNS edge LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';

CREATE TYPE edge (INPUT = edge_in, OUTPUT = edge_out, LIKE = jsonb);

--
-- edge equality operators
--
CREATE FUNCTION edge_eq(edge, edge) RETURNS boolean LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR = (FUNCTION = edge_eq, LEFTARG = edge, RIGHTARG = edge, COMMUTATOR = =, NEGATOR = <>, RESTRICT = eqsel, JOIN = eqjoinsel, HASHES, MERGES);
CREATE FUNCTION edge_ne(edge, edge) RETURNS boolean LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR <> (FUNCTION = edge_ne, LEFTARG = edge, RIGHTARG = edge, COMMUTATOR = <>, NEGATOR = =, RESTRICT = neqsel, JOIN = neqjoinsel);

--
-- edge functions
--
CREATE FUNCTION id(edge) RETURNS graphid LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME', 'edge_id';
CREATE FUNCTION start_id(edge) RETURNS graphid LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME', 'edge_start_id';
CREATE FUNCTION end_id(edge) RETURNS graphid LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME', 'edge_end_id';
CREATE FUNCTION label(edge) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME', 'edge_label';
CREATE FUNCTION properties(edge) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME', 'edge_properties';

--
-- path
--
CREATE TYPE traversal;

CREATE FUNCTION traversal_in(cstring) RETURNS traversal LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION traversal_out(traversal) RETURNS cstring LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION build_traversal(variadic "any") RETURNS traversal LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';

CREATE TYPE traversal (INPUT = traversal_in, OUTPUT = traversal_out, LIKE = jsonb);



--
-- partial traversal
--
CREATE TYPE variable_edge;

CREATE FUNCTION variable_edge_in(cstring) RETURNS variable_edge LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION variable_edge_out(variable_edge) RETURNS cstring LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION build_variable_edge(variadic "any") RETURNS variable_edge LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';

CREATE TYPE variable_edge (INPUT = variable_edge_in, OUTPUT = variable_edge_out, LIKE = jsonb);

--
-- gtype - mathematical operators (+, -, *, /, %, ^)
--
CREATE FUNCTION gtype_add(gtype, gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR + (FUNCTION = gtype_add, LEFTARG = gtype, RIGHTARG = gtype, COMMUTATOR = +);
CREATE FUNCTION gtype_sub(gtype, gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR - (FUNCTION = gtype_sub, LEFTARG = gtype, RIGHTARG = gtype);
CREATE FUNCTION gtype_neg(gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR - (FUNCTION = gtype_neg, RIGHTARG = gtype);
CREATE FUNCTION gtype_mul(gtype, gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR * (FUNCTION = gtype_mul, LEFTARG = gtype, RIGHTARG = gtype, COMMUTATOR = *);
CREATE FUNCTION gtype_div(gtype, gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR / (FUNCTION = gtype_div, LEFTARG = gtype, RIGHTARG = gtype);
CREATE FUNCTION gtype_mod(gtype, gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR % (FUNCTION = gtype_mod, LEFTARG = gtype, RIGHTARG = gtype);
CREATE FUNCTION gtype_pow(gtype, gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR ^ (FUNCTION = gtype_pow, LEFTARG = gtype, RIGHTARG = gtype);


--
-- graphid - hash operator class
--
CREATE FUNCTION graphid_hash_cmp(graphid) RETURNS INTEGER LANGUAGE c IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR CLASS graphid_ops_hash DEFAULT FOR TYPE graphid USING hash AS OPERATOR 1 =, FUNCTION 1 graphid_hash_cmp(graphid);

--
-- gtype - comparison operators (=, <>, <, >, <=, >=)
--
CREATE FUNCTION gtype_eq(gtype, gtype) RETURNS boolean LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR = (FUNCTION = gtype_eq, LEFTARG = gtype, RIGHTARG = gtype, COMMUTATOR = =, NEGATOR = <>, RESTRICT = eqsel, JOIN = eqjoinsel, HASHES);
CREATE FUNCTION gtype_ne(gtype, gtype) RETURNS boolean LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR <> (FUNCTION = gtype_ne, LEFTARG = gtype, RIGHTARG = gtype, COMMUTATOR = <>, NEGATOR = =, RESTRICT = neqsel, JOIN = neqjoinsel);
CREATE FUNCTION gtype_lt(gtype, gtype) RETURNS boolean LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR < (FUNCTION = gtype_lt, LEFTARG = gtype, RIGHTARG = gtype, COMMUTATOR = >, NEGATOR = >=, RESTRICT = scalarltsel, JOIN = scalarltjoinsel);
CREATE FUNCTION gtype_gt(gtype, gtype) RETURNS boolean LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR > (FUNCTION = gtype_gt, LEFTARG = gtype, RIGHTARG = gtype, COMMUTATOR = <, NEGATOR = <=, RESTRICT = scalargtsel, JOIN = scalargtjoinsel);
CREATE FUNCTION gtype_le(gtype, gtype) RETURNS boolean LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR <= (FUNCTION = gtype_le, LEFTARG = gtype, RIGHTARG = gtype, COMMUTATOR = >=, NEGATOR = >, RESTRICT = scalarlesel, JOIN = scalarlejoinsel);
CREATE FUNCTION gtype_ge(gtype, gtype) RETURNS boolean LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR >= (FUNCTION = gtype_ge, LEFTARG = gtype, RIGHTARG = gtype, COMMUTATOR = <=, NEGATOR = <, RESTRICT = scalargesel, JOIN = scalargejoinsel);
CREATE FUNCTION gtype_btree_cmp(gtype, gtype) RETURNS INTEGER LANGUAGE c IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';

--
-- gtype - btree operator class
--
CREATE OPERATOR CLASS gtype_ops_btree DEFAULT FOR TYPE gtype USING btree AS OPERATOR 1 <, OPERATOR 2 <=, OPERATOR 3 =, OPERATOR 4 >, OPERATOR 5 >=, FUNCTION 1 gtype_btree_cmp(gtype, gtype);

--
-- gtype - hash operator class
--
CREATE FUNCTION gtype_hash_cmp(gtype) RETURNS INTEGER LANGUAGE c IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR CLASS gtype_ops_hash DEFAULT FOR TYPE gtype USING hash AS OPERATOR 1 =, FUNCTION 1 gtype_hash_cmp(gtype);

--
-- gtype - access operators (->, ->>)
--
CREATE FUNCTION gtype_object_field(gtype, text) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR -> (LEFTARG = gtype, RIGHTARG = text, FUNCTION = gtype_object_field);
CREATE FUNCTION gtype_object_field_text(gtype, text) RETURNS text LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR ->> (LEFTARG = gtype, RIGHTARG = text, FUNCTION = gtype_object_field_text);
CREATE FUNCTION gtype_array_element(gtype, int4) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR -> (LEFTARG = gtype, RIGHTARG = int4, FUNCTION = gtype_array_element);
CREATE FUNCTION gtype_array_element_text(gtype, int4) RETURNS text LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR ->> (LEFTARG = gtype, RIGHTARG = int4, FUNCTION = gtype_array_element_text);

--
-- gtype - contains operators (@>, <@)
--
CREATE FUNCTION gtype_contains(gtype, gtype) RETURNS boolean LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR @> (LEFTARG = gtype, RIGHTARG = gtype, FUNCTION = gtype_contains, COMMUTATOR = '<@', RESTRICT = contsel, JOIN = contjoinsel);
CREATE FUNCTION gtype_contained_by(gtype, gtype) RETURNS boolean LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR <@ (LEFTARG = gtype, RIGHTARG = gtype, FUNCTION = gtype_contained_by, COMMUTATOR = '@>', RESTRICT = contsel, JOIN = contjoinsel);

--
-- Key Existence Operators (?, ?|, ?&)
--
CREATE FUNCTION gtype_exists(gtype, text) RETURNS boolean LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR ? (LEFTARG = gtype, RIGHTARG = text, FUNCTION = gtype_exists, COMMUTATOR = '?', RESTRICT = contsel, JOIN = contjoinsel);
CREATE FUNCTION gtype_exists_any(gtype, text[]) RETURNS boolean LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR ?| (LEFTARG = gtype, RIGHTARG = text[], FUNCTION = gtype_exists_any, RESTRICT = contsel, JOIN = contjoinsel);
CREATE FUNCTION gtype_exists_all(gtype, text[]) RETURNS boolean LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR ?& (LEFTARG = gtype, RIGHTARG = text[], FUNCTION = gtype_exists_all, RESTRICT = contsel, JOIN = contjoinsel);

--
-- gtype GIN support
--
CREATE FUNCTION gin_compare_gtype(text, text) RETURNS int AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION gin_extract_gtype(gtype, internal) RETURNS internal AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION gin_extract_gtype_query(gtype, internal, int2, internal, internal) RETURNS internal AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION gin_consistent_gtype(internal, int2, gtype, int4, internal, internal) RETURNS bool AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
CREATE FUNCTION gin_triconsistent_gtype(internal, int2, gtype, int4, internal, internal, internal) RETURNS bool AS 'MODULE_PATHNAME' LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE OPERATOR CLASS gin_gtype_ops DEFAULT FOR TYPE gtype USING gin AS
OPERATOR 7 @>, OPERATOR 9 ?(gtype, text), OPERATOR 10 ?|(gtype, text[]), OPERATOR 11 ?&(gtype, text[]),
FUNCTION 1 gin_compare_gtype, FUNCTION 2 gin_extract_gtype, FUNCTION 3 gin_extract_gtype_query, FUNCTION 4 gin_consistent_gtype, FUNCTION 6 gin_triconsistent_gtype,
STORAGE text;

--
-- graphid typecasting
--
CREATE FUNCTION graphid_to_gtype(graphid) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE CAST (graphid AS gtype) WITH FUNCTION graphid_to_gtype(graphid);
CREATE FUNCTION gtype_to_graphid(gtype) RETURNS graphid LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE CAST (gtype AS graphid) WITH FUNCTION gtype_to_graphid(gtype) AS IMPLICIT;

--
-- gtype - entity creation
--
CREATE FUNCTION _gtype_build_path(VARIADIC "any") RETURNS gtype LANGUAGE c STABLE CALLED ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION _gtype_build_vertex(graphid, cstring, gtype) RETURNS gtype LANGUAGE c IMMUTABLE CALLED ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION _gtype_build_edge(graphid, graphid, graphid, cstring, gtype) RETURNS gtype LANGUAGE c IMMUTABLE CALLED ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';

--
-- MATCH edge uniqueness
--
CREATE FUNCTION _ag_enforce_edge_uniqueness(VARIADIC "any") RETURNS bool LANGUAGE c IMMUTABLE PARALLEL SAFE RETURNS NULL ON NULL INPUT as 'MODULE_PATHNAME';

--
-- gtype - map literal (`{key: expr, ...}`)
--
CREATE FUNCTION gtype_build_map(VARIADIC "any") RETURNS gtype LANGUAGE c IMMUTABLE CALLED ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION gtype_build_map() RETURNS gtype LANGUAGE c IMMUTABLE CALLED ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME', 'gtype_build_map_noargs';

--
-- There are times when the optimizer might eliminate
-- functions we need. Wrap the function with this to
-- prevent that from happening
--
CREATE FUNCTION gtype_volatile_wrapper(agt gtype) RETURNS gtype AS $return_value$
BEGIN RETURN agt; END;
$return_value$ LANGUAGE plpgsql
VOLATILE
CALLED ON NULL INPUT
PARALLEL SAFE;

--
-- gtype - list literal (`[expr, ...]`)
--

CREATE FUNCTION gtype_build_list(VARIADIC "any") RETURNS gtype LANGUAGE c IMMUTABLE CALLED ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION gtype_build_list() RETURNS gtype LANGUAGE c IMMUTABLE CALLED ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME', 'gtype_build_list_noargs';

--
-- gtype - typecasting to and from Postgres types
--
-- gtype -> text
CREATE FUNCTION gtype_to_text(gtype) RETURNS text LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE CAST (gtype AS text) WITH FUNCTION gtype_to_text(gtype);
-- text -> gtype
CREATE FUNCTION text_to_gtype(text) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE CAST (text AS gtype) WITH FUNCTION text_to_gtype(text);
-- gtype -> boolean
CREATE FUNCTION gtype_to_bool(gtype) RETURNS boolean LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE CAST (gtype AS boolean) WITH FUNCTION gtype_to_bool(gtype) AS IMPLICIT;
-- boolean -> gtype
CREATE FUNCTION bool_to_gtype(boolean) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE CAST (boolean AS gtype) WITH FUNCTION bool_to_gtype(boolean);
-- float8 -> gtype
CREATE FUNCTION float8_to_gtype(float8) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE CAST (float8 AS gtype) WITH FUNCTION float8_to_gtype(float8);
-- gtype -> float8
CREATE FUNCTION gtype_to_float8(gtype) RETURNS float8 LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE CAST (gtype AS float8) WITH FUNCTION gtype_to_float8(gtype);
-- int8 -> gtype
CREATE FUNCTION int8_to_gtype(int8) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE CAST (int8 AS gtype) WITH FUNCTION int8_to_gtype(int8);
-- gtype -> int8
CREATE FUNCTION gtype_to_int8(gtype) RETURNS bigint LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE CAST (gtype AS bigint) WITH FUNCTION gtype_to_int8(gtype) AS ASSIGNMENT;
-- gtype -> int8[]
CREATE FUNCTION gtype_to_int8_array(gtype) RETURNS bigint[] LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE CAST (gtype AS bigint[]) WITH FUNCTION gtype_to_int8_array(gtype);
-- gtype -> int4
CREATE FUNCTION gtype_to_int4(gtype) RETURNS int LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE CAST (gtype AS int) WITH FUNCTION gtype_to_int4(gtype);
-- gtype -> int2
CREATE FUNCTION gtype_to_int2(gtype) RETURNS smallint LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE CAST (gtype AS smallint) WITH FUNCTION gtype_to_int2(gtype);
-- gtype -> int4[]
CREATE FUNCTION gtype_to_int4_array(gtype) RETURNS int[] LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE CAST (gtype AS int[]) WITH FUNCTION gtype_to_int4_array(gtype);

--
-- gtype - typecasting to other gtype types
--
-- XXX: Need to merge the underlying logic between this and the above functions
--
CREATE FUNCTION age_toboolean(gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_tofloat(gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_tointeger(gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME', 'gtype_tointeger';
CREATE FUNCTION age_tostring(gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_tonumeric(gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE RETURNS NULL ON NULL INPUT AS 'MODULE_PATHNAME';
CREATE FUNCTION age_totimestamp(gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE RETURNS NULL ON NULL INPUT AS 'MODULE_PATHNAME';


--
-- gtype - access operators
--
-- for series of `map.key` and `container[expr]`
CREATE FUNCTION gtype_field_access(gtype, gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR -> (LEFTARG = gtype, RIGHTARG = gtype, FUNCTION = gtype_field_access);
CREATE FUNCTION gtype_access_slice(gtype, gtype, gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION gtype_in_operator(gtype, gtype) RETURNS bool LANGUAGE c IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR @= (FUNCTION = gtype_in_operator, LEFTARG = gtype, RIGHTARG = gtype, NEGATOR = !@=, RESTRICT = eqsel, JOIN = eqjoinsel, HASHES, MERGES);

--
-- gtype - string matching (`STARTS WITH`, `ENDS WITH`, `CONTAINS`, & =~)
--
CREATE FUNCTION gtype_string_match_starts_with(gtype, gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION gtype_string_match_ends_with(gtype, gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION gtype_string_match_contains(gtype, gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_eq_tilde(gtype, gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';

--
-- functions for updating clauses
--
-- This function is defined as a VOLATILE function to prevent the optimizer
-- from pulling up Query's for CREATE clauses.
CREATE FUNCTION _cypher_create_clause(internal) RETURNS void LANGUAGE c AS 'MODULE_PATHNAME';
CREATE FUNCTION _cypher_set_clause(internal) RETURNS void LANGUAGE c AS 'MODULE_PATHNAME';
CREATE FUNCTION _cypher_delete_clause(internal) RETURNS void LANGUAGE c AS 'MODULE_PATHNAME';
CREATE FUNCTION _cypher_merge_clause(internal) RETURNS void LANGUAGE c AS 'MODULE_PATHNAME';

--
-- query functions
--
CREATE FUNCTION cypher(graph_name name, query_string cstring, params gtype = NULL) RETURNS SETOF record LANGUAGE c AS 'MODULE_PATHNAME';
CREATE FUNCTION get_cypher_keywords(OUT word text, OUT catcode "char", OUT catdesc text) RETURNS SETOF record LANGUAGE c STABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE COST 10 ROWS 60 AS 'MODULE_PATHNAME';

--
-- Scalar Functions
--
CREATE FUNCTION age_id(gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_start_id(gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_end_id(gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_head(gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_last(gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_properties(gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_startnode(gtype, gtype) RETURNS gtype LANGUAGE c STABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_endnode(gtype, gtype) RETURNS gtype LANGUAGE c STABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_length(gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_size(gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_type(gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME','age_label';
CREATE FUNCTION age_label(gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';

--
-- list functions
--
CREATE FUNCTION age_keys(gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_labels(gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_nodes(gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_relationships(gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_range(gtype, gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_range(gtype, gtype, gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_unnest(gtype, block_types boolean = false) RETURNS SETOF gtype LANGUAGE c IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';

--
-- String functions
--
CREATE FUNCTION age_reverse(gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_toupper(gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_tolower(gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_ltrim(gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_rtrim(gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_trim(gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_right(gtype, gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE RETURNS NULL ON NULL INPUT AS 'MODULE_PATHNAME';
CREATE FUNCTION age_left(gtype, gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE RETURNS NULL ON NULL INPUT AS 'MODULE_PATHNAME';
CREATE FUNCTION age_substring(gtype, gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_substring(gtype, gtype, gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_split(gtype, gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE RETURNS NULL ON NULL INPUT AS 'MODULE_PATHNAME';
CREATE FUNCTION age_replace(gtype, gtype, gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';

--
-- Trig functions - radian input
--
CREATE FUNCTION age_sin(gtype) RETURNS gtype LANGUAGE c IMMUTABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_cos(gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE RETURNS NULL ON NULL INPUT AS 'MODULE_PATHNAME';
CREATE FUNCTION age_tan(gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE RETURNS NULL ON NULL INPUT AS 'MODULE_PATHNAME';
CREATE FUNCTION age_cot(gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE RETURNS NULL ON NULL INPUT AS 'MODULE_PATHNAME';
CREATE FUNCTION age_asin(gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE RETURNS NULL ON NULL INPUT AS 'MODULE_PATHNAME';
CREATE FUNCTION age_acos(gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE RETURNS NULL ON NULL INPUT AS 'MODULE_PATHNAME';
CREATE FUNCTION age_atan(gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE RETURNS NULL ON NULL INPUT AS 'MODULE_PATHNAME';
CREATE FUNCTION age_atan2(gtype, gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE RETURNS NULL ON NULL INPUT AS 'MODULE_PATHNAME';
CREATE FUNCTION age_degrees(gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE RETURNS NULL ON NULL INPUT AS 'MODULE_PATHNAME';
CREATE FUNCTION age_radians(gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE RETURNS NULL ON NULL INPUT AS 'MODULE_PATHNAME';
CREATE FUNCTION age_round(gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_round(gtype, gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_ceil(gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE RETURNS NULL ON NULL INPUT AS 'MODULE_PATHNAME';
CREATE FUNCTION age_floor(gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE RETURNS NULL ON NULL INPUT AS 'MODULE_PATHNAME';
CREATE FUNCTION age_abs(gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE RETURNS NULL ON NULL INPUT AS 'MODULE_PATHNAME';
CREATE FUNCTION age_sign(gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_log(gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE RETURNS NULL ON NULL INPUT AS 'MODULE_PATHNAME';
CREATE FUNCTION age_log10(gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE RETURNS NULL ON NULL INPUT AS 'MODULE_PATHNAME';
CREATE FUNCTION age_e() RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_exp(gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE RETURNS NULL ON NULL INPUT AS 'MODULE_PATHNAME';
CREATE FUNCTION age_sqrt(gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE RETURNS NULL ON NULL INPUT AS 'MODULE_PATHNAME';
CREATE FUNCTION age_pi() RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_rand() RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';

--
-- Agreggation
--
-- accumlates floats into an array for aggregation
CREATE FUNCTION gtype_accum(float8[], gtype) RETURNS float8[] LANGUAGE c IMMUTABLE STRICT PARALLEL SAFE AS 'MODULE_PATHNAME';

-- count
CREATE AGGREGATE age_count(*) (stype = int8, sfunc = int8inc, finalfunc = int8_to_gtype, combinefunc = int8pl, finalfunc_modify = READ_ONLY, initcond = 0, parallel = SAFE);
CREATE AGGREGATE age_count(gtype) (stype = int8, sfunc = int8inc_any, finalfunc = int8_to_gtype, combinefunc = int8pl, finalfunc_modify = READ_ONLY, initcond = 0, parallel = SAFE);
CREATE AGGREGATE age_count(vertex) (stype = int8, sfunc = int8inc_any, finalfunc = int8_to_gtype, combinefunc = int8pl, finalfunc_modify = READ_ONLY, initcond = 0, parallel = SAFE);
CREATE AGGREGATE age_count(edge) (stype = int8, sfunc = int8inc_any, finalfunc = int8_to_gtype, combinefunc = int8pl, finalfunc_modify = READ_ONLY, initcond = 0, parallel = SAFE);
CREATE AGGREGATE age_count(traversal) (stype = int8, sfunc = int8inc_any, finalfunc = int8_to_gtype, combinefunc = int8pl, finalfunc_modify = READ_ONLY, initcond = 0, parallel = SAFE);
CREATE AGGREGATE age_count(variable_edge) (stype = int8, sfunc = int8inc_any, finalfunc = int8_to_gtype, combinefunc = int8pl, finalfunc_modify = READ_ONLY, initcond = 0, parallel = SAFE);
-- stdev
CREATE FUNCTION gtype_stddev_samp_final(float8[]) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE AGGREGATE age_stdev(gtype) (stype = float8[], sfunc = gtype_accum, finalfunc = gtype_stddev_samp_final, combinefunc = float8_combine, finalfunc_modify = READ_ONLY, initcond = '{0,0,0}', parallel = SAFE);
-- stdevp
CREATE FUNCTION gtype_stddev_pop_final(float8[]) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE AGGREGATE age_stdevp(gtype) (stype = float8[], sfunc = gtype_accum, finalfunc = gtype_stddev_pop_final, combinefunc = float8_combine, finalfunc_modify = READ_ONLY, initcond = '{0,0,0}', parallel = SAFE);
-- avg
CREATE AGGREGATE age_avg(gtype) (stype = float8[], sfunc = gtype_accum, finalfunc = float8_avg, combinefunc = float8_combine, finalfunc_modify = READ_ONLY, initcond = '{0,0,0}', parallel = SAFE);
-- sum
CREATE FUNCTION age_gtype_sum(gtype, gtype) RETURNS gtype LANGUAGE c IMMUTABLE STRICT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE AGGREGATE age_sum(gtype) (stype = gtype, sfunc = age_gtype_sum, combinefunc = age_gtype_sum, finalfunc_modify = READ_ONLY, parallel = SAFE);
-- max
CREATE FUNCTION gtype_max_trans(gtype, gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE AGGREGATE age_max(gtype) (stype = gtype, sfunc = gtype_max_trans, combinefunc = gtype_max_trans, finalfunc_modify = READ_ONLY, parallel = SAFE);
-- min
CREATE FUNCTION gtype_min_trans(gtype, gtype) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE AGGREGATE age_min(gtype) (stype = gtype, sfunc = gtype_min_trans, combinefunc = gtype_min_trans, finalfunc_modify = READ_ONLY, parallel = SAFE);
-- percentileCont and percentileDisc
CREATE FUNCTION age_percentile_aggtransfn(internal, gtype, gtype) RETURNS internal LANGUAGE c IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_percentile_cont_aggfinalfn(internal) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_percentile_disc_aggfinalfn(internal) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE AGGREGATE age_percentilecont(gtype, gtype) (stype = internal, sfunc = age_percentile_aggtransfn, finalfunc = age_percentile_cont_aggfinalfn, parallel = SAFE);
CREATE AGGREGATE age_percentiledisc(gtype, gtype) (stype = internal, sfunc = age_percentile_aggtransfn, finalfunc = age_percentile_disc_aggfinalfn, parallel = SAFE);
-- collect
CREATE FUNCTION age_collect_aggtransfn(internal, gtype) RETURNS internal LANGUAGE c IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE FUNCTION age_collect_aggfinalfn(internal) RETURNS gtype LANGUAGE c IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE AGGREGATE age_collect(gtype) (stype = internal, sfunc = age_collect_aggtransfn, finalfunc = age_collect_aggfinalfn, parallel = safe);

--
-- John's crap
--
CREATE FUNCTION age_vle(IN gtype, IN gtype, IN gtype, IN gtype, IN gtype, IN gtype, IN gtype, OUT edges gtype) RETURNS SETOF gtype LANGUAGE C STABLE CALLED ON NULL INPUT PARALLEL UNSAFE AS 'MODULE_PATHNAME';
-- TODO: remove
CREATE FUNCTION age_build_vle_match_edge(gtype, gtype) RETURNS gtype LANGUAGE C IMMUTABLE PARALLEL SAFE AS 'MODULE_PATHNAME';

CREATE FUNCTION age_match_vle_terminal_edge_start("any", gtype) RETURNS boolean LANGUAGE C STABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR !>= (FUNCTION = age_match_vle_terminal_edge_start, LEFTARG = "any", RIGHTARG = gtype);
CREATE FUNCTION age_match_vle_terminal_edge_end("any", gtype) RETURNS boolean LANGUAGE C STABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR @>= (FUNCTION = age_match_vle_terminal_edge_end, LEFTARG = "any", RIGHTARG = gtype);
CREATE FUNCTION age_match_vle_terminal_edge_left_check_end("any", gtype) RETURNS boolean LANGUAGE C STABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR !<= (FUNCTION = age_match_vle_terminal_edge_left_check_end, LEFTARG = "any", RIGHTARG = gtype);
CREATE FUNCTION age_match_vle_terminal_right_check_start("any", gtype) RETURNS boolean LANGUAGE C STABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR @<= (FUNCTION = age_match_vle_terminal_right_check_start, LEFTARG = "any", RIGHTARG = gtype);


CREATE FUNCTION gid_is_first_startid(graphid, variable_edge) RETURNS boolean LANGUAGE C STABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR !>= (FUNCTION = gid_is_first_startid, LEFTARG = graphid, RIGHTARG = variable_edge);

CREATE FUNCTION vertex_is_first_start_vertex(vertex, variable_edge) RETURNS boolean LANGUAGE C STABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR !>= (FUNCTION = vertex_is_first_start_vertex, LEFTARG = vertex, RIGHTARG = variable_edge);

CREATE FUNCTION gid_is_first_endid(graphid, variable_edge) RETURNS boolean LANGUAGE C STABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR @>= (FUNCTION = gid_is_first_endid, LEFTARG = graphid, RIGHTARG = variable_edge);
CREATE FUNCTION vertex_is_first_end_vertex(vertex, variable_edge) RETURNS boolean LANGUAGE C STABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR @>= (FUNCTION = vertex_is_first_end_vertex, LEFTARG = vertex, RIGHTARG = variable_edge);


CREATE FUNCTION gid_is_last_startid(graphid, variable_edge) RETURNS boolean LANGUAGE C STABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR !<= (FUNCTION = gid_is_last_startid, LEFTARG = graphid, RIGHTARG = variable_edge);

CREATE FUNCTION vertex_is_last_start_vertex(vertex, variable_edge) RETURNS boolean LANGUAGE C STABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR !<= (FUNCTION = vertex_is_last_start_vertex, LEFTARG = vertex, RIGHTARG = variable_edge);


CREATE FUNCTION gid_is_last_endid(graphid, variable_edge) RETURNS boolean LANGUAGE C STABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR @<= (FUNCTION = gid_is_last_endid, LEFTARG = graphid, RIGHTARG = variable_edge);
CREATE FUNCTION vertex_is_last_end_vertex(vertex, variable_edge) RETURNS boolean LANGUAGE C STABLE RETURNS NULL ON NULL INPUT PARALLEL SAFE AS 'MODULE_PATHNAME';
CREATE OPERATOR @<= (FUNCTION = vertex_is_last_end_vertex, LEFTARG = vertex, RIGHTARG = variable_edge);


--
-- End
--
