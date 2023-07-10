%{
/*
 * Copyright (C) 2023 PostGraphDB
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 * For PostgreSQL Database Management System:
 * (formerly known as Postgres, then as Postgres95)
 *
 * Portions Copyright (c) 2020-2023, Apache Software Foundation
 * Portions Copyright (c) 2019-2020, Bitnine Global
 */

#include "postgraph.h"

#include "nodes/makefuncs.h"
#include "nodes/nodes.h"
#include "nodes/parsenodes.h"
#include "nodes/pg_list.h"
#include "nodes/primnodes.h"
#include "nodes/value.h"
#include "parser/parser.h"

#include "nodes/ag_nodes.h"
#include "nodes/cypher_nodes.h"
#include "parser/ag_scanner.h"
#include "parser/cypher_gram.h"

// override the default action for locations
#define YYLLOC_DEFAULT(current, rhs, n) \
    do \
    { \
        if ((n) > 0) \
            current = (rhs)[1]; \
        else \
            current = -1; \
    } while (0)

#define YYMALLOC palloc
#define YYFREE pfree
%}

%locations
%name-prefix="cypher_yy"
%pure-parser

%lex-param {ag_scanner_t scanner}
%parse-param {ag_scanner_t scanner}
%parse-param {cypher_yy_extra *extra}

%union {
    /* types in cypher_yylex() */
    int integer;
    char *string;
    const char *keyword;

    /* extra types */
    bool boolean;
    Node *node;
    List *list;
}

%token <integer> INTEGER
%token <string> DECIMAL STRING

%token <string> IDENTIFIER
%token <string> PARAMETER

/* operators that have more than 1 character */
%token NOT_EQ LT_EQ GT_EQ DOT_DOT TYPECAST PLUS_EQ EQ_TILDE

/* keywords in alphabetical order */
%token <keyword> ALL AND AS ASC ASCENDING
                 BY
                 CALL CASE COALESCE CONTAINS CREATE
                 DELETE DESC DESCENDING DETACH DISTINCT
                 ELSE END_P ENDS EXISTS
                 FALSE_P
                 IN IS
                 LIMIT
                 MATCH MERGE
                 NOT NULL_P
                 OPTIONAL OR ORDER
                 REMOVE RETURN
                 SET SKIP STARTS
                 THEN TRUE_P
                 UNION UNWIND
                 WHEN WHERE WITH
                 XOR
                 YIELD

/* query */
%type <node> stmt
%type <list> single_query query_part_init query_part_last cypher_stmt
             reading_clause_list updating_clause_list_0 updating_clause_list_1
%type <node> reading_clause updating_clause

/* RETURN and WITH clause */
%type <node> return return_item sort_item skip_opt limit_opt with
%type <list> return_item_list order_by_opt sort_item_list
%type <integer> order_opt

/* MATCH clause */
%type <node> match cypher_varlen_opt cypher_range_opt cypher_range_idx
             cypher_range_idx_opt
%type <integer> Iconst
%type <boolean> optional_opt

/* CREATE clause */
%type <node> create

/* UNWIND clause */
%type <node> unwind

/* SET and REMOVE clause */
%type <node> set set_item remove remove_item
%type <list> set_item_list remove_item_list

/* DELETE clause */
%type <node> delete
%type <boolean> detach_opt

/* MERGE clause */
%type <node> merge

/* CALL ... YIELD clause */
%type <node> call_stmt yield_item
%type <list> yield_item_list

/* common */
%type <node> where_opt

/* pattern */
%type <list> pattern simple_path_opt_parens simple_path
%type <node> path anonymous_path
             path_node path_relationship path_relationship_body
             properties_opt
%type <string> label_opt

/* expression */
%type <node> expr expr_opt expr_atom expr_literal map list

%type <node> expr_case expr_case_when expr_case_default
%type <list> expr_case_when_list

%type <node> expr_var expr_func expr_func_norm expr_func_subexpr
%type <list> expr_list expr_list_opt map_keyval_list_opt map_keyval_list

/* names */
%type <string> property_key_name var_name var_name_opt label_name
%type <string> symbolic_name schema_name
%type <keyword> reserved_keyword safe_keywords conflicted_keywords
%type <list> func_name

/*set operations*/
%type <boolean> all_or_distinct

/* precedence: lowest to highest */
%left UNION
%left OR
%left AND
%left XOR
%right NOT
%left '=' NOT_EQ '<' LT_EQ '>' GT_EQ
%left '+' '-'
%left '*' '/' '%'
%left '^'
%nonassoc IN IS
%right UNARY_MINUS
%nonassoc CONTAINS ENDS EQ_TILDE STARTS
%left '[' ']' '(' ')'
%left '.'
%left TYPECAST

%{
//
// unique name generation
#define UNIQUE_NAME_NULL_PREFIX "_unique_null_prefix"
static char *create_unique_name(char *prefix_name);
static unsigned long get_a_unique_number(void);

// logical operators
static Node *make_or_expr(Node *lexpr, Node *rexpr, int location);
static Node *make_and_expr(Node *lexpr, Node *rexpr, int location);
static Node *make_xor_expr(Node *lexpr, Node *rexpr, int location);
static Node *make_not_expr(Node *expr, int location);

// arithmetic operators
static Node *do_negate(Node *n, int location);
static void do_negate_float(Value *v);

// indirection
static Node *append_indirection(Node *expr, Node *selector);

// literals
static Node *make_int_const(int i, int location);
static Node *make_float_const(char *s, int location);
static Node *make_string_const(char *s, int location);
static Node *make_bool_const(bool b, int location);
static Node *make_null_const(int location);

// typecast
static Node *make_typecast_expr(Node *expr, char *typecast, int location);

// setops
static Node *make_set_op(SetOperation op, bool all_or_distinct, List *larg,
                         List *rarg);

// VLE
static cypher_relationship *build_VLE_relation(List *left_arg,
                                               cypher_relationship *cr,
                                               Node *right_arg,
                                               int left_arg_location,
                                               int cr_location);
// comparison
static bool is_A_Expr_a_comparison_operation(A_Expr *a);
static Node *build_comparison_expression(Node *left_grammar_node,
                                         Node *right_grammar_node,
                                         char *opr_name, int location);
%}
%%

/*
 * query
 */

stmt:
    cypher_stmt semicolon_opt
        {
            /*
             * If there is no transition for the lookahead token and the
             * clauses can be reduced to single_query, the parsing is
             * considered successful although it actually isn't.
             *
             * For example, when `MATCH ... CREATE ... MATCH ... ;` query is
             * being parsed, there is no transition for the second `MATCH ...`
             * because the query is wrong but `MATCH .. CREATE ...` is correct
             * so it will be reduced to query_part_last anyway even if there
             * are more tokens to read.
             *
             * Throw syntax error in this case.
             */
            if (yychar != YYEOF)
                yyerror(&yylloc, scanner, extra, "syntax error");

            extra->result = $1;
        }
    ;

cypher_stmt:
    single_query
        {
            $$ = $1;
        }
    | cypher_stmt UNION all_or_distinct cypher_stmt
        {
            $$ = list_make1(make_set_op(SETOP_UNION, $3, $1, $4));
        }
    ;

call_stmt:
    CALL expr_func_norm
        {
            ereport(ERROR,
                    (errcode(ERRCODE_SYNTAX_ERROR),
                     errmsg("CALL not supported yet"),
                     ag_scanner_errposition(@1, scanner)));
        }
    | CALL expr_func_norm YIELD yield_item_list where_opt
        {
            ereport(ERROR,
                    (errcode(ERRCODE_SYNTAX_ERROR),
                     errmsg("CALL... [YIELD] not supported yet"),
                     ag_scanner_errposition(@1, scanner)));
        }
    ;

yield_item_list:
    yield_item
        {
            $$ = list_make1($1);
        }
    | yield_item_list ',' yield_item
        {
            $$ = lappend($1, $3);
        }
    ;

yield_item:
    expr AS var_name
        {

        }
    | expr
        {

        }
    ;

semicolon_opt:
    /* empty */
    | ';'
    ;

all_or_distinct:
    ALL
    {
        $$ = true;
    }
    | DISTINCT
    {
        $$ = false;
    }
    | /*EMPTY*/
    {
        $$ = false;
    }

/*
 * The overall structure of single_query looks like below.
 *
 * ( reading_clause* updating_clause* with )*
 * reading_clause* ( updating_clause+ | updating_clause* return )
 */
single_query:
    query_part_init query_part_last
        {
            $$ = list_concat($1, $2);
        }
    ;

query_part_init:
    /* empty */
        {
            $$ = NIL;
        }
    | query_part_init reading_clause_list updating_clause_list_0 with
        {
            $$ = lappend(list_concat(list_concat($1, $2), $3), $4);
        }
    ;

query_part_last:
    reading_clause_list updating_clause_list_1
        {
            $$ = list_concat($1, $2);
        }
    | reading_clause_list updating_clause_list_0 return
        {
            $$ = lappend(list_concat($1, $2), $3);
        }
    ;

reading_clause_list:
    /* empty */
        {
            $$ = NIL;
        }
    | reading_clause_list reading_clause
        {
            $$ = lappend($1, $2);
        }
    ;

reading_clause:
    match
    | unwind
    ;

updating_clause_list_0:
    /* empty */
        {
            $$ = NIL;
        }
    | updating_clause_list_1
    ;

updating_clause_list_1:
    updating_clause
        {
            $$ = list_make1($1);
        }
    | updating_clause_list_1 updating_clause
        {
            $$ = lappend($1, $2);
        }
    ;

updating_clause:
    create
    | set
    | remove
    | delete
    | merge
    | call_stmt
    ;

cypher_varlen_opt:
    '*' cypher_range_opt
        {
            A_Indices *n = (A_Indices *) $2;

            if (n->lidx == NULL)
                n->lidx = make_int_const(1, @2);

            if (n->uidx != NULL)
            {
                A_Const    *lidx = (A_Const *) n->lidx;
                A_Const    *uidx = (A_Const *) n->uidx;

                if (lidx->val.val.ival > uidx->val.val.ival)
                    ereport(ERROR, (errcode(ERRCODE_SYNTAX_ERROR),
                                    errmsg("invalid range"),
                                    ag_scanner_errposition(@2, scanner)));
            }
            $$ = (Node *) n;
        }
    | /* EMPTY */
        {
            $$ = NULL;
        }
    ;

cypher_range_opt:
    cypher_range_idx
        {
            A_Indices  *n;

            n = makeNode(A_Indices);
            n->lidx = copyObject($1);
            n->uidx = $1;
            $$ = (Node *) n;
        }
    | cypher_range_idx_opt DOT_DOT cypher_range_idx_opt
        {
            A_Indices  *n;

            n = makeNode(A_Indices);
            n->lidx = $1;
            n->uidx = $3;
            $$ = (Node *) n;
        }
    | /* EMPTY */
        {
            $$ = (Node *) makeNode(A_Indices);
        }
    ;

cypher_range_idx:
    Iconst
        {
            $$ = make_int_const($1, @1);
        }
    ;

cypher_range_idx_opt:
                        cypher_range_idx
                        | /* EMPTY */                   { $$ = NULL; }
                ;

Iconst: INTEGER

/*
 * RETURN and WITH clause
 */

return:
    RETURN DISTINCT return_item_list order_by_opt skip_opt limit_opt
        {
            cypher_return *n;

            n = make_ag_node(cypher_return);
            n->distinct = true;
            n->items = $3;
            n->order_by = $4;
            n->skip = $5;
            n->limit = $6;

            $$ = (Node *)n;
        }
    | RETURN return_item_list order_by_opt skip_opt limit_opt
        {
            cypher_return *n;

            n = make_ag_node(cypher_return);
            n->distinct = false;
            n->items = $2;
            n->order_by = $3;
            n->skip = $4;
            n->limit = $5;

            $$ = (Node *)n;
        }

    ;

return_item_list:
    return_item
        {
            $$ = list_make1($1);
        }
    | return_item_list ',' return_item
        {
            $$ = lappend($1, $3);
        }
    ;

return_item:
    expr AS var_name
        {
            ResTarget *n;

            n = makeNode(ResTarget);
            n->name = $3;
            n->indirection = NIL;
            n->val = $1;
            n->location = @1;

            $$ = (Node *)n;
        }
    | expr
        {
            ResTarget *n;

            n = makeNode(ResTarget);
            n->name = NULL;
            n->indirection = NIL;
            n->val = $1;
            n->location = @1;

            $$ = (Node *)n;
        }
    | '*'
        {
            ColumnRef *cr;
            ResTarget *rt;

            cr = makeNode(ColumnRef);
            cr->fields = list_make1(makeNode(A_Star));
            cr->location = @1;

            rt = makeNode(ResTarget);
            rt->name = NULL;
            rt->indirection = NIL;
            rt->val = (Node *)cr;
            rt->location = @1;

            $$ = (Node *)rt;
        }
    ;

order_by_opt:
    /* empty */
        {
            $$ = NIL;
        }
    | ORDER BY sort_item_list
        {
            $$ = $3;
        }
    ;

sort_item_list:
    sort_item
        {
            $$ = list_make1($1);
        }
    | sort_item_list ',' sort_item
        {
            $$ = lappend($1, $3);
        }
    ;

sort_item:
    expr order_opt
        {
            SortBy *n;

            n = makeNode(SortBy);
            n->node = $1;
            n->sortby_dir = $2;
            n->sortby_nulls = SORTBY_NULLS_DEFAULT;
            n->useOp = NIL;
            n->location = -1; // no operator

            $$ = (Node *)n;
        }
    ;

order_opt:
    /* empty */
        {
            $$ = SORTBY_DEFAULT; // is the same with SORTBY_ASC
        }
    | ASC
        {
            $$ = SORTBY_ASC;
        }
    | ASCENDING
        {
            $$ = SORTBY_ASC;
        }
    | DESC
        {
            $$ = SORTBY_DESC;
        }
    | DESCENDING
        {
            $$ = SORTBY_DESC;
        }
    ;

skip_opt:
    /* empty */
        {
            $$ = NULL;
        }
    | SKIP expr
        {
            $$ = $2;
        }
    ;

limit_opt:
    /* empty */
        {
            $$ = NULL;
        }
    | LIMIT expr
        {
            $$ = $2;
        }
    ;

with:
    WITH DISTINCT return_item_list order_by_opt skip_opt limit_opt where_opt
        {
            ListCell *li;
            cypher_with *n;

            // check expressions are aliased
            foreach (li, $3)
            {
                ResTarget *item = lfirst(li);

                // variable does not have to be aliased
                if (IsA(item->val, ColumnRef) || item->name)
                    continue;

                ereport(ERROR,
                        (errcode(ERRCODE_SYNTAX_ERROR),
                         errmsg("expression item must be aliased"),
                         errhint("Items can be aliased by using AS."),
                         ag_scanner_errposition(item->location, scanner)));
            }

            n = make_ag_node(cypher_with);
            n->distinct = true;
            n->items = $3;
            n->order_by = $4;
            n->skip = $5;
            n->limit = $6;
            n->where = $7;

            $$ = (Node *)n;
        }
    | WITH return_item_list order_by_opt skip_opt limit_opt
    where_opt
        {
            ListCell *li;
            cypher_with *n;

            // check expressions are aliased
            foreach (li, $2)
            {
                ResTarget *item = lfirst(li);

                // variable does not have to be aliased
                if (IsA(item->val, ColumnRef) || item->name)
                    continue;

                ereport(ERROR,
                        (errcode(ERRCODE_SYNTAX_ERROR),
                         errmsg("expression item must be aliased"),
                         errhint("Items can be aliased by using AS."),
                         ag_scanner_errposition(item->location, scanner)));
            }

            n = make_ag_node(cypher_with);
            n->distinct = false;
            n->items = $2;
            n->order_by = $3;
            n->skip = $4;
            n->limit = $5;
            n->where = $6;

            $$ = (Node *)n;
        }
    ;

/*
 * MATCH clause
 */

match:
    optional_opt MATCH pattern where_opt
        {
            cypher_match *n;

            n = make_ag_node(cypher_match);
            n->optional = $1;
            n->pattern = $3;
            n->where = $4;

            $$ = (Node *)n;
        }
    ;

optional_opt:
    OPTIONAL
        {
            $$ = true;
        }
    | /* EMPTY */
        {
            $$ = false;
        }
    ;


unwind:
    UNWIND expr AS var_name
        {
            ResTarget  *res;
            cypher_unwind *n;

            res = makeNode(ResTarget);
            res->name = $4;
            res->val = (Node *) $2;
            res->location = @2;

            n = make_ag_node(cypher_unwind);
            n->target = res;
            $$ = (Node *) n;
        }

/*
 * CREATE clause
 */

create:
    CREATE pattern
        {
            cypher_create *n;

            n = make_ag_node(cypher_create);
            n->pattern = $2;

            $$ = (Node *)n;
        }
    ;

/*
 * SET and REMOVE clause
 */

set:
    SET set_item_list
        {
            cypher_set *n;

            n = make_ag_node(cypher_set);
            n->items = $2;
            n->is_remove = false;
            n->location = @1;

            $$ = (Node *)n;
        }
    ;

set_item_list:
    set_item
        {
            $$ = list_make1($1);
        }
    | set_item_list ',' set_item
        {
            $$ = lappend($1, $3);
        }
    ;

set_item:
    expr '=' expr
        {
            cypher_set_item *n;

            n = make_ag_node(cypher_set_item);
            n->prop = $1;
            n->expr = $3;
            n->is_add = false;
            n->location = @1;

            $$ = (Node *)n;
        }
   | expr PLUS_EQ expr
        {
            cypher_set_item *n;

            n = make_ag_node(cypher_set_item);
            n->prop = $1;
            n->expr = $3;
            n->is_add = true;
            n->location = @1;

            $$ = (Node *)n;
        }
    ;

remove:
    REMOVE remove_item_list
        {
            cypher_set *n;

            n = make_ag_node(cypher_set);
            n->items = $2;
            n->is_remove = true;
             n->location = @1;

            $$ = (Node *)n;
        }
    ;

remove_item_list:
    remove_item
        {
            $$ = list_make1($1);
        }
    | remove_item_list ',' remove_item
        {
            $$ = lappend($1, $3);
        }
    ;

remove_item:
    expr
        {
            cypher_set_item *n;

            n = make_ag_node(cypher_set_item);
            n->prop = $1;
            n->expr = make_null_const(-1);
            n->is_add = false;

            $$ = (Node *)n;
        }
    ;

/*
 * DELETE clause
 */

delete:
    detach_opt DELETE expr_list
        {
            cypher_delete *n;

            n = make_ag_node(cypher_delete);
            n->detach = $1;
            n->exprs = $3;
            n->location = @1;

            $$ = (Node *)n;
        }
    ;

detach_opt:
    DETACH
        {
            $$ = true;
        }
    | /* EMPTY */
        {
            $$ = false;
        }
    ;

/*
 * MERGE clause
 */
merge:
    MERGE path
        {
            cypher_merge *n;

            n = make_ag_node(cypher_merge);
            n->path = $2;

            $$ = (Node *)n;
        }
    ;

/*
 * common
 */

where_opt:
    /* empty */
        {
            $$ = NULL;
        }
    | WHERE expr
        {
            $$ = $2;
        }
    ;

/*
 * pattern
 */

/* pattern is a set of one or more paths */
pattern:
    path
        {
            $$ = list_make1($1);
        }
    | pattern ',' path
        {
            $$ = lappend($1, $3);
        }
    ;

/* path is a series of connected nodes and relationships */
path:
    anonymous_path
    | var_name '=' anonymous_path /* named path */
        {
            cypher_path *p;

            p = (cypher_path *)$3;
            p->var_name = $1;

            $$ = (Node *)p;
        }

    ;

anonymous_path:
    simple_path_opt_parens
        {
            cypher_path *n;

            n = make_ag_node(cypher_path);
            n->path = $1;
            n->var_name = NULL;
            n->location = @1;

            $$ = (Node *)n;
        }
    ;

simple_path_opt_parens:
    simple_path
    | '(' simple_path ')'
        {
            $$ = $2;
        }
    ;

simple_path:
    path_node
        {
            $$ = list_make1($1);
        }
    | simple_path path_relationship path_node
        {
            cypher_relationship *cr = (cypher_relationship *)$2;

            if (cr->varlen) {
                cr = build_VLE_relation($1, cr, $3, @1, @2);

                $$ = lappend(lappend($1, cr), $3);
            } else {
                $$ = lappend(lappend($1, $2), $3);
            }
        }
    ;

path_node:
    '(' var_name_opt label_opt properties_opt ')'
        {
            cypher_node *n;

            n = make_ag_node(cypher_node);
            n->name = $2;
            n->label = $3;
            n->props = $4;
            n->location = @1;

            $$ = (Node *)n;
        }
    ;

path_relationship:
    '-' path_relationship_body '-'
        {
            cypher_relationship *n = (cypher_relationship *)$2;

            n->dir = CYPHER_REL_DIR_NONE;
            n->location = @2;

            $$ = $2;
        }
    | '-' path_relationship_body '-' '>'
        {
            cypher_relationship *n = (cypher_relationship *)$2;

            n->dir = CYPHER_REL_DIR_RIGHT;
            n->location = @2;

            $$ = $2;
        }
    | '<' '-' path_relationship_body '-'
        {
            cypher_relationship *n = (cypher_relationship *)$3;

            n->dir = CYPHER_REL_DIR_LEFT;
            n->location = @3;

            $$ = $3;
        }
    ;

path_relationship_body:
    '[' var_name_opt label_opt cypher_varlen_opt properties_opt ']'
        {
            cypher_relationship *n;

            n = make_ag_node(cypher_relationship);
            n->name = $2;
            n->label = $3;
            n->varlen = $4;
            n->props = $5;

            $$ = (Node *)n;
        }
    |
    /* empty */
        {
            cypher_relationship *n;

            n = make_ag_node(cypher_relationship);
            n->name = NULL;
            n->label = NULL;
            n->varlen = NULL;
            n->props = NULL;

            $$ = (Node *)n;
        }
    ;

label_opt:
    /* empty */
        {
            $$ = NULL;
        }
    | ':' label_name
        {
            $$ = $2;
        }
    ;

properties_opt:
    /* empty */
        {
            $$ = NULL;
        }
    | map
    | PARAMETER
        {
            cypher_param *n;

            n = make_ag_node(cypher_param);
            n->name = $1;
            n->location = @1;

            $$ = (Node *)n;
        }

    ;

/*
 * expression
 */
expr:
    expr OR expr
        {
            $$ = make_or_expr($1, $3, @2);
        }
    | expr AND expr
        {
            $$ = make_and_expr($1, $3, @2);
        }
    | expr XOR expr
        {
            $$ = make_xor_expr($1, $3, @2);
        }
    | NOT expr
        {
            $$ = make_not_expr($2, @1);
        }
    | expr '=' expr
        {
            $$ = build_comparison_expression($1, $3, "=", @2);
        }
    | expr NOT_EQ expr
        {
            $$ = build_comparison_expression($1, $3, "<>", @2);
        }
    | expr '<' expr
        {
            $$ = build_comparison_expression($1, $3, "<", @2);
        }
    | expr LT_EQ expr
        {
            $$ = build_comparison_expression($1, $3, "<=", @2);
        }
    | expr '>' expr
        {
            $$ = build_comparison_expression($1, $3, ">", @2);
        }
    | expr GT_EQ expr
        {
            $$ = build_comparison_expression($1, $3, ">=", @2);
        }
    | expr '+' expr
        {
            $$ = (Node *)makeSimpleA_Expr(AEXPR_OP, "+", $1, $3, @2);
        }
    | expr '-' expr
        {
            $$ = (Node *)makeSimpleA_Expr(AEXPR_OP, "-", $1, $3, @2);
        }
    | expr '*' expr
        {
            $$ = (Node *)makeSimpleA_Expr(AEXPR_OP, "*", $1, $3, @2);
        }
    | expr '/' expr
        {
            $$ = (Node *)makeSimpleA_Expr(AEXPR_OP, "/", $1, $3, @2);
        }
    | expr '%' expr
        {
            $$ = (Node *)makeSimpleA_Expr(AEXPR_OP, "%", $1, $3, @2);
        }
    | expr '^' expr
        {
            $$ = (Node *)makeSimpleA_Expr(AEXPR_OP, "^", $1, $3, @2);
        }
    | expr IN expr
        {
            $$ = (Node *)makeSimpleA_Expr(AEXPR_OP, "@=", $1, $3, @2);
        }
    | expr IS NULL_P %prec IS
        {
            NullTest *n;

            n = makeNode(NullTest);
            n->arg = (Expr *)$1;
            n->nulltesttype = IS_NULL;
            n->location = @2;

            $$ = (Node *)n;
        }
    | expr IS NOT NULL_P %prec IS
        {
            NullTest *n;

            n = makeNode(NullTest);
            n->arg = (Expr *)$1;
            n->nulltesttype = IS_NOT_NULL;
            n->location = @2;

            $$ = (Node *)n;
        }
    | '-' expr %prec UNARY_MINUS
        {
            $$ = do_negate($2, @1);
        }
    | expr STARTS WITH expr %prec STARTS
        {
            cypher_string_match *n;

            n = make_ag_node(cypher_string_match);
            n->operation = CSMO_STARTS_WITH;
            n->lhs = $1;
            n->rhs = $4;
            n->location = @2;

            $$ = (Node *)n;
        }
    | expr ENDS WITH expr %prec ENDS
        {
            cypher_string_match *n;

            n = make_ag_node(cypher_string_match);
            n->operation = CSMO_ENDS_WITH;
            n->lhs = $1;
            n->rhs = $4;
            n->location = @2;

            $$ = (Node *)n;
        }
    | expr CONTAINS expr
        {
            cypher_string_match *n;

            n = make_ag_node(cypher_string_match);
            n->operation = CSMO_CONTAINS;
            n->lhs = $1;
            n->rhs = $3;
            n->location = @2;

            $$ = (Node *)n;
        }
    | expr EQ_TILDE expr
        {
            $$ = (Node *)makeFuncCall(list_make1(makeString("eq_tilde")),
                                    list_make2($1, $3), COERCE_SQL_SYNTAX, @2);
        }
    | expr '[' expr ']'  %prec '.'
        {
            A_Indices *i;

            i = makeNode(A_Indices);
            i->is_slice = false;
            i->lidx = NULL;
            i->uidx = $3;

            $$ = append_indirection($1, (Node *)i);
        }
    | expr '[' expr_opt DOT_DOT expr_opt ']'
        {
            A_Indices *i;

            i = makeNode(A_Indices);
            i->is_slice = true;
            i->lidx = $3;
            i->uidx = $5;

            $$ = append_indirection($1, (Node *)i);
        }
    | expr '.' expr
        {
            /*
             * This checks for the grammar rule -
             *    symbolic_name '.' expr
             * Where expr is a function call.
             * Note: symbolic_name ends up as a ColumnRef
             */
            if (IsA($3, FuncCall) && IsA($1, ColumnRef))
            {
                FuncCall *fc = (FuncCall*)$3;
                ColumnRef *cr = (ColumnRef*)$1;
                List *fields = cr->fields;
                Value *string = linitial(fields);

                fc->funcname = lcons(string, fc->funcname);
                $$ = (Node*)fc;
            }
            else
            {
                $$ = append_indirection($1, $3);
            }
        }
    | expr TYPECAST symbolic_name
        {
            $$ = make_typecast_expr($1, $3, @2);
        }
    | expr_atom
    ;

expr_opt:
    /* empty */
        {
            $$ = NULL;
        }
    | expr
    ;

expr_list:
    expr
        {
            $$ = list_make1($1);
        }
    | expr_list ',' expr
        {
            $$ = lappend($1, $3);
        }
    ;

expr_list_opt:
    /* empty */
        {
            $$ = NIL;
        }
    | expr_list
    ;

expr_func:
    expr_func_norm
    | expr_func_subexpr
    ;

expr_func_norm:
    func_name '(' ')'
        {
            $$ = (Node *)makeFuncCall($1, NIL, COERCE_SQL_SYNTAX, @1);
        }
    | func_name '(' expr_list ')'
        {
            $$ = (Node *)makeFuncCall($1, $3, COERCE_SQL_SYNTAX, @1);
        }
    /* borrowed from PG's grammar */
    | func_name '(' '*' ')'
        {
            /*
             * We consider AGGREGATE(*) to invoke a parameterless
             * aggregate.  This does the right thing for COUNT(*),
             * and there are no other aggregates in SQL that accept
             * '*' as parameter.
             *
             * The FuncCall node is also marked agg_star = true,
             * so that later processing can detect what the argument
             * really was.
             */
             FuncCall *n = (FuncCall *)makeFuncCall($1, NIL, COERCE_SQL_SYNTAX, @1);
             n->agg_star = true;
             $$ = (Node *)n;
         }
    | func_name '(' DISTINCT  expr_list ')'
        {
            FuncCall *n = (FuncCall *)makeFuncCall($1, $4, COERCE_SQL_SYNTAX, @1);
            n->agg_order = NIL;
            n->agg_distinct = true;
            $$ = (Node *)n;
        }
    ;

expr_func_subexpr:
    COALESCE '(' expr_list ')'
        {
            CoalesceExpr *c;

            c = makeNode(CoalesceExpr);
            c->args = $3;
            c->location = @1;
            $$ = (Node *) c;
        }
    | EXISTS '(' anonymous_path ')'
        {
            cypher_sub_pattern *sub;
            SubLink    *n;

            sub = make_ag_node(cypher_sub_pattern);
            sub->kind = CSP_EXISTS;
            sub->pattern = list_make1($3);

            n = makeNode(SubLink);
            n->subLinkType = EXISTS_SUBLINK;
            n->subLinkId = 0;
            n->testexpr = NULL;
            n->operName = NIL;
            n->subselect = (Node *) sub;
            n->location = @1;
            $$ = (Node *) n;
        }
    ;


expr_atom:
    expr_literal
    | PARAMETER
        {
            cypher_param *n;

            n = make_ag_node(cypher_param);
            n->name = $1;
            n->location = @1;

            $$ = (Node *)n;
        }
    | '(' expr ')'
        {
            $$ = $2;
        }
    | expr_case
    | expr_var
    | expr_func
    ;

expr_literal:
    INTEGER
        {
            $$ = make_int_const($1, @1);
        }
    | DECIMAL
        {
            $$ = make_float_const($1, @1);
        }
    | STRING
        {
            $$ = make_string_const($1, @1);
        }
    | TRUE_P
        {
            $$ = make_bool_const(true, @1);
        }
    | FALSE_P
        {
            $$ = make_bool_const(false, @1);
        }
    | NULL_P
        {
            $$ = make_null_const(@1);
        }
    | map
    | list
    ;

map:
    '{' map_keyval_list_opt '}'
        {
            cypher_map *n;

            n = make_ag_node(cypher_map);
            n->keyvals = $2;

            $$ = (Node *)n;
        }
    ;

map_keyval_list_opt:
    /* empty */
        {
            $$ = NIL;
        }
    | map_keyval_list
    ;

map_keyval_list:
    property_key_name ':' expr
        {
            $$ = list_make2(makeString($1), $3);
        }
    | map_keyval_list ',' property_key_name ':' expr
        {
            $$ = lappend(lappend($1, makeString($3)), $5);
        }
    ;

list:
    '[' expr_list_opt ']'
        {
            cypher_list *n;

            n = make_ag_node(cypher_list);
            n->elems = $2;

            $$ = (Node *)n;
        }
    ;

expr_case:
    CASE expr expr_case_when_list expr_case_default END_P
        {
            CaseExpr *n;

            n = makeNode(CaseExpr);
            n->casetype = InvalidOid;
            n->arg = (Expr *) $2;
            n->args = $3;
            n->defresult = (Expr *) $4;
            n->location = @1;
            $$ = (Node *) n;
        }
    | CASE expr_case_when_list expr_case_default END_P
        {
            CaseExpr *n;

            n = makeNode(CaseExpr);
            n->casetype = InvalidOid;
            n->args = $2;
            n->defresult = (Expr *) $3;
            n->location = @1;
            $$ = (Node *) n;
        }
    ;

expr_case_when_list:
    expr_case_when
        {
            $$ = list_make1($1);
        }
    | expr_case_when_list expr_case_when
        {
            $$ = lappend($1, $2);
        }
    ;

expr_case_when:
    WHEN expr THEN expr
        {
            CaseWhen   *n;

            n = makeNode(CaseWhen);
            n->expr = (Expr *) $2;
            n->result = (Expr *) $4;
            n->location = @1;
            $$ = (Node *) n;
        }
    ;

expr_case_default:
    ELSE expr
        {
            $$ = $2;
        }
    | /* EMPTY */
        {
            $$ = NULL;
        }
    ;

expr_var:
    var_name
        {
            ColumnRef *n;

            n = makeNode(ColumnRef);
            n->fields = list_make1(makeString($1));
            n->location = @1;

            $$ = (Node *)n;
        }
    ;

/*
 * names
 */
func_name:
    symbolic_name
        {
            $$ = list_make1(makeString($1));
        }
    /*
     * symbolic_name '.' symbolic_name is already covered with the
     * rule expr '.' expr above. This rule is to allow most reserved
     * keywords to be used as well. So, it essentially makes the
     * rule schema_name '.' symbolic_name for func_name
     */
    | safe_keywords '.' symbolic_name
        {
            $$ = list_make2(makeString((char *)$1), makeString($3));
        }
    ;

property_key_name:
    schema_name
    ;

var_name:
    symbolic_name
    ;

var_name_opt:
    /* empty */
        {
            $$ = NULL;
        }
    | var_name
    ;

label_name:
    schema_name
    ;

symbolic_name:
    IDENTIFIER
    ;

schema_name:
    symbolic_name
    | reserved_keyword
        {
            /* we don't need to copy it, as it already has been */
            $$ = (char *) $1;
        }
    ;

reserved_keyword:
    safe_keywords
    | conflicted_keywords
    ;

/*
 * All keywords need to be copied and properly terminated with a null before
 * using them, pnstrdup effectively does this for us.
 */

safe_keywords:
    ALL          { $$ = pnstrdup($1, 3); }
    | AND        { $$ = pnstrdup($1, 3); }
    | AS         { $$ = pnstrdup($1, 2); }
    | ASC        { $$ = pnstrdup($1, 3); }
    | ASCENDING  { $$ = pnstrdup($1, 9); }
    | BY         { $$ = pnstrdup($1, 2); }
    | CALL       { $$ = pnstrdup($1, 4); }
    | CASE       { $$ = pnstrdup($1, 4); }
    | COALESCE   { $$ = pnstrdup($1, 8); }
    | CONTAINS   { $$ = pnstrdup($1, 8); }
    | CREATE     { $$ = pnstrdup($1, 6); }
    | DELETE     { $$ = pnstrdup($1, 6); }
    | DESC       { $$ = pnstrdup($1, 4); }
    | DESCENDING { $$ = pnstrdup($1, 10); }
    | DETACH     { $$ = pnstrdup($1, 6); }
    | DISTINCT   { $$ = pnstrdup($1, 8); }
    | ELSE       { $$ = pnstrdup($1, 4); }
    | ENDS       { $$ = pnstrdup($1, 4); }
    | EXISTS     { $$ = pnstrdup($1, 6); }
    | IN         { $$ = pnstrdup($1, 2); }
    | IS         { $$ = pnstrdup($1, 2); }
    | LIMIT      { $$ = pnstrdup($1, 6); }
    | MATCH      { $$ = pnstrdup($1, 6); }
    | MERGE      { $$ = pnstrdup($1, 6); }
    | NOT        { $$ = pnstrdup($1, 3); }
    | OPTIONAL   { $$ = pnstrdup($1, 8); }
    | OR         { $$ = pnstrdup($1, 2); }
    | ORDER      { $$ = pnstrdup($1, 5); }
    | REMOVE     { $$ = pnstrdup($1, 6); }
    | RETURN     { $$ = pnstrdup($1, 6); }
    | SET        { $$ = pnstrdup($1, 3); }
    | SKIP       { $$ = pnstrdup($1, 4); }
    | STARTS     { $$ = pnstrdup($1, 6); }
    | THEN       { $$ = pnstrdup($1, 4); }
    | UNION      { $$ = pnstrdup($1, 5); }
    | WHEN       { $$ = pnstrdup($1, 4); }
    | WHERE      { $$ = pnstrdup($1, 5); }
    | WITH       { $$ = pnstrdup($1, 4); }
    | XOR        { $$ = pnstrdup($1, 3); }
    | YIELD      { $$ = pnstrdup($1, 5); }
    ;

conflicted_keywords:
    END_P     { $$ = pnstrdup($1, 5); }
    | FALSE_P { $$ = pnstrdup($1, 7); }
    | NULL_P  { $$ = pnstrdup($1, 6); }
    | TRUE_P  { $$ = pnstrdup($1, 6); }
    ;

%%

/*
 * logical operators
 */

static Node *make_or_expr(Node *lexpr, Node *rexpr, int location)
{
    // flatten "a OR b OR c ..." to a single BoolExpr on sight
    if (IsA(lexpr, BoolExpr))
    {
        BoolExpr *bexpr = (BoolExpr *)lexpr;

        if (bexpr->boolop == OR_EXPR)
        {
            bexpr->args = lappend(bexpr->args, rexpr);

            return (Node *)bexpr;
        }
    }

    return (Node *)makeBoolExpr(OR_EXPR, list_make2(lexpr, rexpr), location);
}

static Node *make_and_expr(Node *lexpr, Node *rexpr, int location)
{
    // flatten "a AND b AND c ..." to a single BoolExpr on sight
    if (IsA(lexpr, BoolExpr))
    {
        BoolExpr *bexpr = (BoolExpr *)lexpr;

        if (bexpr->boolop == AND_EXPR)
        {
            bexpr->args = lappend(bexpr->args, rexpr);

            return (Node *)bexpr;
        }
    }

    return (Node *)makeBoolExpr(AND_EXPR, list_make2(lexpr, rexpr), location);
}

static Node *make_xor_expr(Node *lexpr, Node *rexpr, int location)
{
    Expr *aorb;
    Expr *notaandb;

    // XOR is (A OR B) AND (NOT (A AND B))
    aorb = makeBoolExpr(OR_EXPR, list_make2(lexpr, rexpr), location);

    notaandb = makeBoolExpr(AND_EXPR, list_make2(lexpr, rexpr), location);
    notaandb = makeBoolExpr(NOT_EXPR, list_make1(notaandb), location);

    return (Node *)makeBoolExpr(AND_EXPR, list_make2(aorb, notaandb), location);
}

static Node *make_not_expr(Node *expr, int location)
{
    return (Node *)makeBoolExpr(NOT_EXPR, list_make1(expr), location);
}

/*
 * arithmetic operators
 */

static Node *do_negate(Node *n, int location)
{
    if (IsA(n, A_Const))
    {
        A_Const *c = (A_Const *)n;

        // report the constant's location as that of the '-' sign
        c->location = location;

        if (c->val.type == T_Integer)
        {
            c->val.val.ival = -c->val.val.ival;
            return n;
        }
        else if (c->val.type == T_Float)
        {
            do_negate_float(&c->val);
            return n;
        }
    }

    return (Node *)makeSimpleA_Expr(AEXPR_OP, "-", NULL, n, location);
}

static void do_negate_float(Value *v)
{
    Assert(IsA(v, Float));

    if (v->val.str[0] == '-')
        v->val.str = v->val.str + 1; // just strip the '-'
    else
        v->val.str = psprintf("-%s", v->val.str);
}

/*
 * indirection
 */

static Node *append_indirection(Node *expr, Node *selector)
{
    A_Indirection *indir;

    if (IsA(expr, A_Indirection))
    {
        indir = (A_Indirection *)expr;
        indir->indirection = lappend(indir->indirection, selector);

        return expr;
    }
    else
    {
        indir = makeNode(A_Indirection);
        indir->arg = expr;
        indir->indirection = list_make1(selector);

        return (Node *)indir;
    }
}

/*
 * literals
 */

static Node *make_int_const(int i, int location)
{
    A_Const *n;

    n = makeNode(A_Const);
    n->val.type = T_Integer;
    n->val.val.ival = i;
    n->location = location;

    return (Node *)n;
}

static Node *make_float_const(char *s, int location)
{
    A_Const *n;

    n = makeNode(A_Const);
    n->val.type = T_Float;
    n->val.val.str = s;
    n->location = location;

    return (Node *)n;
}

static Node *make_string_const(char *s, int location)
{
    A_Const *n;

    n = makeNode(A_Const);
    n->val.type = T_String;
    n->val.val.str = s;
    n->location = location;

    return (Node *)n;
}

static Node *make_bool_const(bool b, int location)
{
    cypher_bool_const *n;

    n = make_ag_node(cypher_bool_const);
    n->boolean = b;
    n->location = location;

    return (Node *)n;
}

static Node *make_null_const(int location)
{
    A_Const *n;

    n = makeNode(A_Const);
    n->val.type = T_Null;
    n->location = location;

    return (Node *)n;
}

static Node *make_typecast_expr(Node *expr, char *typecast, int location)
{
    cypher_typecast *node;

    node = make_ag_node(cypher_typecast);
    node->expr = expr;
    node->typecast = typecast;
    node->location = location;

    return (Node *)node;
}

/* function to create a unique name given a prefix */
static char *create_unique_name(char *prefix_name)
{
    char *name = NULL;
    char *prefix = NULL;
    uint nlen = 0;
    unsigned long unique_number = 0;

    /* get a unique number */
    unique_number = get_a_unique_number();

    /* was a valid prefix supplied */
    if (prefix_name == NULL || strlen(prefix_name) <= 0)
    {
        prefix = pnstrdup(UNIQUE_NAME_NULL_PREFIX,
                          strlen(UNIQUE_NAME_NULL_PREFIX));
    }
    else
    {
        prefix = prefix_name;
    }

    /* get the length of the combinded string */
    nlen = snprintf(NULL, 0, "%s_%lu", prefix, unique_number);

    /* allocate the space */
    name = palloc0(nlen + 1);

    /* create the name */
    snprintf(name, nlen + 1, "%s_%lu", prefix, unique_number);

    /* if we created the prefix, we need to free it */
    if (prefix_name == NULL || strlen(prefix_name) <= 0)
    {
        pfree(prefix);
    }

    return name;
}

/* function to return a unique unsigned long number */
static unsigned long get_a_unique_number(void)
{
    /* STATIC VARIABLE unique_counter for number uniqueness */
    static unsigned long unique_counter = 0;

    return unique_counter++;
}

/*set operation function node to make a set op node*/
static Node *make_set_op(SetOperation op, bool all_or_distinct, List *larg,
                         List *rarg)
{
    cypher_return *n = make_ag_node(cypher_return);

    n->op = op;
    n->all_or_distinct = all_or_distinct;
    n->larg = (List *) larg;
    n->rarg = (List *) rarg;
    return (Node *) n;
}

/* check if A_Expr is a comparison expression */
static bool is_A_Expr_a_comparison_operation(A_Expr *a)
{
    Value *v = NULL;
    char *opr_name = NULL;

    /* we don't support qualified comparison operators */
    if (list_length(a->name) != 1)
    {
        ereport(ERROR,
                (errcode(ERRCODE_SYNTAX_ERROR),
                 errmsg("qualified comparison operator names are not permitted")));
    }

    /* get the value and verify that it is a string */
    v = linitial(a->name);
    Assert(v->type == T_String);

    /* get the string value */
    opr_name = v->val.str;

    /* verify it is a comparison operation */
    if (strcmp(opr_name, "<") == 0)
        return true;
    else if (strcmp(opr_name, ">") == 0)
        return true;
    else if (strcmp(opr_name, "<=") == 0)
        return true;
    else if (strcmp(opr_name, "=>") == 0)
        return true;
    else if (strcmp(opr_name, "=") == 0)
        return true;
    else if (strcmp(opr_name, "<>") == 0)
        return true;


    return false;
}

/*
 * Helper function to build the comparison operator expression. It will also
 * build a chained comparison operator expression if it detects a chained
 * comparison.
 */
static Node *build_comparison_expression(Node *left_grammar_node, Node *right_grammar_node, char *opr_name, int location) {
    Node *result_expr = NULL;

    Assert(left_grammar_node != NULL);
    Assert(right_grammar_node != NULL);
    Assert(opr_name != NULL);

    /*
     * Case 1:
     *    If the previous expression is an A_Expr and it is also a
     *    comparison, then this is part of a chained comparison. In this
     *    specific case, the second chained element.
     */
    if (IsA(left_grammar_node, A_Expr) &&
        is_A_Expr_a_comparison_operation((A_Expr *)left_grammar_node))
    {
        A_Expr *aexpr = NULL;
        Node *lexpr = NULL;
        Node *n = NULL;

        /* get the A_Expr on the left side */
        aexpr = (A_Expr *) left_grammar_node;
        /* get its rexpr which will be our lexpr */
        lexpr = aexpr->rexpr;
        /* build our comparison operator */
        n = (Node *)makeSimpleA_Expr(AEXPR_OP, opr_name, lexpr,
                                     right_grammar_node, location);

        /* now add it (AND) to the other comparison */
        result_expr = make_and_expr(left_grammar_node, n, location);
    }

    /*
     * Case 2:
     *    If the previous expression is a boolean AND and its right most
     *    expression is an A_Expr and a comparison, then this is part of
     *    a chained comparison. In this specific case, the third and
     *    beyond chained element.
     */
    if (IsA(left_grammar_node, BoolExpr) &&
        ((BoolExpr*)left_grammar_node)->boolop == AND_EXPR)
    {
        BoolExpr *bexpr = NULL;
        Node *last = NULL;

        /* cast the left to a boolean */
        bexpr = (BoolExpr *)left_grammar_node;
        /* extract the last node - ANDs are chained in a flat list */
        last = llast(bexpr->args);

        /* is the last node an A_Expr and a comparison operator */
        if (IsA(last, A_Expr) &&
            is_A_Expr_a_comparison_operation((A_Expr *)last))
        {
            A_Expr *aexpr = NULL;
            Node *lexpr = NULL;
            Node *n = NULL;

            /* get the last expressions right expression */
            aexpr = (A_Expr *) last;
            lexpr = aexpr->rexpr;
            /* make our comparison operator */
            n = (Node *)makeSimpleA_Expr(AEXPR_OP, opr_name, lexpr,
                                         right_grammar_node, location);

            result_expr = make_and_expr(left_grammar_node, n, location);
        }
    }

    /*
     * Case 3:
     *    The previous expression isn't a chained comparison. So, treat
     *    it as a regular comparison expression.
     */
    if (result_expr == NULL)
        result_expr = (Node *)makeSimpleA_Expr(AEXPR_OP, opr_name, left_grammar_node, right_grammar_node, location);

    return result_expr;
}

static cypher_relationship *build_VLE_relation(List *left_arg, cypher_relationship *cr, Node *right_arg, int left_arg_location, int cr_location) {
    ColumnRef *cref = NULL;
    A_Indices *ai = NULL;
    List *args = NIL;
    List *eargs = NIL;
    List *fname = NIL;
    cypher_node *cnl = NULL;
    cypher_node *cnr = NULL;
    Node *node = NULL;
    int location = 0;

    /* get the location */
    location = cr->location;

    /* get the left and right cypher_nodes */
    cnl = (cypher_node*)llast(left_arg);
    cnr = (cypher_node*)right_arg;

    // If the left name is NULL we need to create a variable name for the left node.
    if (cnl->name == NULL)
        cnl->name = create_unique_name("_vle_function_start_var");

    /* add in the start vertex as a ColumnRef if necessary */
    if (cnl->name != NULL) {
        cref = makeNode(ColumnRef);
        cref->fields = list_make2(makeString(cnl->name), makeString("id"));
        cref->location = left_arg_location;
        args = lappend(args, cref);
    } else {
        args = lappend(args, make_null_const(-1));
    }

    if (cnr->name == NULL)
        cnr->name = create_unique_name("_vle_function_end_var");

    if (cnl->name == NULL)
    {
        cref = makeNode(ColumnRef);
        cref->fields = list_make2(makeString(cnr->name), makeString("id"));
        cref->location = left_arg_location;
        args = lappend(args, cref);
    } else {
        args = lappend(args, make_null_const(-1));
    }

    /* build the required edge arguments */
    if (!cr->label)
        eargs = lappend(eargs, make_null_const(location));
    else
        eargs = lappend(eargs, make_string_const(cr->label, location));

    if (!cr->props)
        eargs = lappend(eargs, make_null_const(location));
    else
        eargs = lappend(eargs, cr->props);

    /* build the edge function name (schema.funcname) */
    fname = list_make2(makeString(CATALOG_SCHEMA), makeString("age_build_vle_match_edge"));

    /* build the edge function node */
    node = (Node *)makeFuncCall(fname, eargs, COERCE_SQL_SYNTAX, location);

    /* add in the edge*/
    args = lappend(args, node);
    
    /* add in the lidx and uidx range as Const */
    ai = (A_Indices*)cr->varlen;
    if (!ai || !ai->lidx)
        args = lappend(args, make_null_const(location));
    else
        args = lappend(args, ai->lidx);

    if (!ai || !ai->uidx)
        args = lappend(args, make_null_const(location));
    else
        args = lappend(args, ai->uidx);

    /* add in the direction as Const */
    args = lappend(args, make_int_const(cr->dir, cr_location));

    /* build the VLE function node */
    cr->varlen = (Node *)makeFuncCall(list_make1(makeString("vle")), args, COERCE_SQL_SYNTAX, cr_location);

    return cr;
}
