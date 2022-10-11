--
-- PostgreSQL database dump
--

-- Dumped from database version 11.17
-- Dumped by pg_dump version 14.5 (Homebrew)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: uuid-ossp; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA public;


--
-- Name: EXTENSION "uuid-ossp"; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION "uuid-ossp" IS 'generate universally unique identifiers (UUIDs)';


--
-- Name: tsq_state; Type: TYPE; Schema: public; Owner: nwa
--

CREATE TYPE public.tsq_state AS (
	search_query text,
	parentheses_stack integer,
	skip_for integer,
	current_token text,
	current_index integer,
	current_char text,
	previous_char text,
	tokens text[]
);


ALTER TYPE public.tsq_state OWNER TO nwa;

--
-- Name: array_nremove(anyarray, anyelement, integer); Type: FUNCTION; Schema: public; Owner: nwa
--

CREATE FUNCTION public.array_nremove(anyarray, anyelement, integer) RETURNS anyarray
    LANGUAGE sql IMMUTABLE
    AS $_$
            WITH replaced_positions AS (
                SELECT UNNEST(
                    CASE
                    WHEN $2 IS NULL THEN
                        '{}'::int[]
                    WHEN $3 > 0 THEN
                        (array_positions($1, $2))[1:$3]
                    WHEN $3 < 0 THEN
                        (array_positions($1, $2))[
                            (cardinality(array_positions($1, $2)) + $3 + 1):
                        ]
                    ELSE
                        '{}'::int[]
                    END
                ) AS position
            )
            SELECT COALESCE((
                SELECT array_agg(value)
                FROM unnest($1) WITH ORDINALITY AS t(value, index)
                WHERE index NOT IN (SELECT position FROM replaced_positions)
            ), $1[1:0]);
        $_$;


ALTER FUNCTION public.array_nremove(anyarray, anyelement, integer) OWNER TO nwa;

--
-- Name: fixed_inputs_trigger(); Type: FUNCTION; Schema: public; Owner: nwa
--

CREATE FUNCTION public.fixed_inputs_trigger() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            UPDATE subscriptions SET tsv = NULL WHERE product_id = NEW.product_id;
            RETURN NEW;
        END
        $$;


ALTER FUNCTION public.fixed_inputs_trigger() OWNER TO nwa;

--
-- Name: generate_subscription_tsv(uuid); Type: FUNCTION; Schema: public; Owner: nwa
--

CREATE FUNCTION public.generate_subscription_tsv(sub_id uuid) RETURNS tsvector
    LANGUAGE plpgsql
    AS $$
        DECLARE
            gen_tsv TSVECTOR := NULL;
        BEGIN
            /*
             To generate a `tsvector` we first need to construct a `text` 'document' with
             meaningful data. That document is then fed into the `to_tsvector`
             function. That 'document' in our case boils down to all relevant data of a
             subscription. Because of our data model this requires a fair amount of
             joins. To make the data gathering step somewhat easier to follow we've
             split up the gathering of:

             - resource type data
             - subscription and product data
             - fixed input data
             - subscription customer description data

             into three separate queries using a Common Table Expression (CTE or WITH
             query). These three queries can be referenced to as tables, namely as
             tables:

             - rt_info
             - sub_prod_info
             - fi_info
             - cust_info

             The final query concatenates the corresponding rows of these three tables
             into a single document to be fed to `to_tsvector`.

             One thing of note is the usage of LEFT JOINs in the last query. This is
             for subscriptions that have been just created. Eg those that are 'initial'
             and as such might not yet have any resource types. A regular JOIN would
             not produce a result in that case leaving use with no document to feed
             into the `to_tsvector` function to populate the `tsv` column. Using a LEFT
             JOIN, together with `coalesce` to turn NULL values into empty strings
             (ensuring `concat_ws` does not return NULL), we will always get a
             meaningful value.
            */
            WITH rt_info AS (
                SELECT s.subscription_id,
                       string_agg(rt.resource_type || ': ' || siv.value, ', ' ORDER BY rt.resource_type) AS rt_info
                FROM subscription_instance_values siv
                         JOIN resource_types rt ON siv.resource_type_id = rt.resource_type_id
                         JOIN subscription_instances si ON siv.subscription_instance_id = si.subscription_instance_id
                         JOIN subscriptions s ON si.subscription_id = s.subscription_id
                GROUP BY s.subscription_id),
                 sub_prod_info AS (
                     SELECT s.subscription_id,
                            array_to_string(
                                    ARRAY ['subscription_id: ' || s.subscription_id,
                                        'status: ' || s.status,
                                        'insync: ' || s.insync,
                                        'subscription_description: ' || s.description,
                                        'note: ' || coalesce(s.note, ''),
                                        'customer_id: ' || s.customer_id,
                                        'product_id: ' || s.product_id],
                                    ', ') AS sub_info,
                            array_to_string(
                                    ARRAY ['product_name: ' || p.name,
                                        'product_description: ' || p.description,
                                        'tag: ' || p.tag,
                                        'product_type: ', p.product_type],
                                    ', ') AS prod_info
                     FROM subscriptions s
                              JOIN products p ON s.product_id = p.product_id),
                 fi_info AS (
                     SELECT s.subscription_id,
                            string_agg(fi.name || ': ' || fi.value, ', ' ORDER BY fi.name) AS fi_info
                     FROM subscriptions s
                              JOIN products p ON s.product_id = p.product_id
                              JOIN fixed_inputs fi ON p.product_id = fi.product_id
                     GROUP BY s.subscription_id),
                 cust_info AS (
                     SELECT s.subscription_id,
                            string_agg('customer_description: ' || scd.description, ', ') AS cust_info
                     FROM subscriptions s
                              JOIN subscription_customer_descriptions scd ON s.subscription_id = scd.subscription_id
                     GROUP BY s.subscription_id
                 )
            SELECT to_tsvector('english',
                           concat_ws(', ',
                                     coalesce(spi.sub_info, ''),
                                     coalesce(spi.prod_info, ''),
                                     coalesce(fi.fi_info, ''),
                                     coalesce(rti.rt_info, ''),
                                     coalesce(ci.cust_info, '')
                               ))
            INTO STRICT gen_tsv
            FROM subscriptions s
                     LEFT JOIN sub_prod_info spi ON s.subscription_id = spi.subscription_id
                     LEFT JOIN fi_info fi ON s.subscription_id = fi.subscription_id
                     LEFT JOIN rt_info rti ON s.subscription_id = rti.subscription_id
                     LEFT JOIN cust_info ci ON s.subscription_id = ci.subscription_id
            WHERE s.subscription_id = sub_id;
            RETURN gen_tsv;
        END
        $$;


ALTER FUNCTION public.generate_subscription_tsv(sub_id uuid) OWNER TO nwa;

--
-- Name: parse_websearch(text); Type: FUNCTION; Schema: public; Owner: nwa
--

CREATE FUNCTION public.parse_websearch(search_query text) RETURNS tsquery
    LANGUAGE sql IMMUTABLE
    AS $$
              SELECT parse_websearch('pg_catalog.simple', search_query);
              $$;


ALTER FUNCTION public.parse_websearch(search_query text) OWNER TO nwa;

--
-- Name: parse_websearch(regconfig, text); Type: FUNCTION; Schema: public; Owner: nwa
--

CREATE FUNCTION public.parse_websearch(config regconfig, search_query text) RETURNS tsquery
    LANGUAGE sql IMMUTABLE
    AS $$
              SELECT
                  string_agg(
                      (
                          CASE
                              WHEN position('''' IN words.word) > 0 THEN CONCAT(words.word, ':*')
                              ELSE words.word
                          END
                      ),
                      ' '
                  )::tsquery
              FROM (
                  SELECT trim(
                      regexp_split_to_table(
                          websearch_to_tsquery(config, lower(search_query))::text,
                          ' '
                      )
                  ) AS word
              ) AS words
              $$;


ALTER FUNCTION public.parse_websearch(config regconfig, search_query text) OWNER TO nwa;

--
-- Name: products_trigger(); Type: FUNCTION; Schema: public; Owner: nwa
--

CREATE FUNCTION public.products_trigger() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            UPDATE subscriptions SET tsv = NULL WHERE product_id = NEW.product_id;
            RETURN NEW;
        END
        $$;


ALTER FUNCTION public.products_trigger() OWNER TO nwa;

--
-- Name: subscription_customer_descriptions_trigger(); Type: FUNCTION; Schema: public; Owner: nwa
--

CREATE FUNCTION public.subscription_customer_descriptions_trigger() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            UPDATE subscriptions SET tsv = NULL WHERE subscription_id = NEW.subscription_id;
            RETURN NEW;
        END
        $$;


ALTER FUNCTION public.subscription_customer_descriptions_trigger() OWNER TO nwa;

--
-- Name: subscription_instance_values_trigger(); Type: FUNCTION; Schema: public; Owner: nwa
--

CREATE FUNCTION public.subscription_instance_values_trigger() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        DECLARE
            sub_id subscriptions.subscription_id%TYPE;
        BEGIN
            SELECT si.subscription_id
            INTO STRICT sub_id
            FROM subscription_instances si
            WHERE si.subscription_instance_id = NEW.subscription_instance_id;
            UPDATE subscriptions SET tsv = NULL WHERE subscription_id = sub_id;
            RETURN NEW;
        END
        $$;


ALTER FUNCTION public.subscription_instance_values_trigger() OWNER TO nwa;

--
-- Name: subscriptions_ins_trigger(); Type: FUNCTION; Schema: public; Owner: nwa
--

CREATE FUNCTION public.subscriptions_ins_trigger() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            /*
             We have a separate insert trigger for subscriptions for the simple reason
             that while we are processing the insert there is not yet a row, with the
             just generated NEW.subscription_id, in the database to join with. Hence
             this trigger will only use the values from the insert.
             */
            SELECT to_tsvector('english',
                           concat_ws(', ',
                                     array_to_string(
                                             ARRAY ['subscription_id: ' || NEW.subscription_id,
                                                 'status: ' || NEW.status,
                                                 'insync: ' || NEW.insync,
                                                 'subscription_description: ' || NEW.description,
                                                 'note: ' || coalesce(NEW.note, ''),
                                                 'customer_id: ' || NEW.customer_id,
                                                 'product_id: ' || NEW.product_id],
                                             ', '),
                                     array_to_string(
                                             ARRAY ['product_name: ' || p.name,
                                                 'product_description: ' || p.description,
                                                 'tag: ' || p.tag,
                                                 'product_type: ', p.product_type],
                                             ', ')))
            INTO STRICT NEW.tsv
            FROM products p
            WHERE p.product_id = NEW.product_id;
            RETURN NEW;
        END
        $$;


ALTER FUNCTION public.subscriptions_ins_trigger() OWNER TO nwa;

--
-- Name: subscriptions_set_tsv_trigger(); Type: FUNCTION; Schema: public; Owner: nwa
--

CREATE FUNCTION public.subscriptions_set_tsv_trigger() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            BEGIN
                UPDATE subscriptions
                SET tsv = generate_subscription_tsv(NEW.subscription_id)
                WHERE subscription_id = NEW.subscription_id;
                RETURN NULL;
            END
            $$;


ALTER FUNCTION public.subscriptions_set_tsv_trigger() OWNER TO nwa;

--
-- Name: subscriptions_upd_trigger(); Type: FUNCTION; Schema: public; Owner: nwa
--

CREATE FUNCTION public.subscriptions_upd_trigger() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
            BEGIN
                UPDATE subscriptions
                SET tsv = NULL
                WHERE subscription_id = NEW.subscription_id;
                RETURN NULL;
            END
            $$;


ALTER FUNCTION public.subscriptions_upd_trigger() OWNER TO nwa;

--
-- Name: tsq_append_current_token(public.tsq_state); Type: FUNCTION; Schema: public; Owner: nwa
--

CREATE FUNCTION public.tsq_append_current_token(state public.tsq_state) RETURNS public.tsq_state
    LANGUAGE plpgsql IMMUTABLE
    AS $$
        BEGIN
            IF state.current_token != '' THEN
                state.tokens := array_append(state.tokens, state.current_token);
                state.current_token := '';
            END IF;
            RETURN state;
        END;
        $$;


ALTER FUNCTION public.tsq_append_current_token(state public.tsq_state) OWNER TO nwa;

--
-- Name: tsq_parse(text); Type: FUNCTION; Schema: public; Owner: nwa
--

CREATE FUNCTION public.tsq_parse(search_query text) RETURNS tsquery
    LANGUAGE sql IMMUTABLE
    AS $$
            SELECT tsq_parse(get_current_ts_config(), search_query);
        $$;


ALTER FUNCTION public.tsq_parse(search_query text) OWNER TO nwa;

--
-- Name: tsq_parse(regconfig, text); Type: FUNCTION; Schema: public; Owner: nwa
--

CREATE FUNCTION public.tsq_parse(config regconfig, search_query text) RETURNS tsquery
    LANGUAGE sql IMMUTABLE
    AS $$
            SELECT tsq_process_tokens(config, tsq_tokenize(search_query));
        $$;


ALTER FUNCTION public.tsq_parse(config regconfig, search_query text) OWNER TO nwa;

--
-- Name: tsq_parse(text, text); Type: FUNCTION; Schema: public; Owner: nwa
--

CREATE FUNCTION public.tsq_parse(config text, search_query text) RETURNS tsquery
    LANGUAGE sql IMMUTABLE
    AS $$
            SELECT tsq_parse(config::regconfig, search_query);
        $$;


ALTER FUNCTION public.tsq_parse(config text, search_query text) OWNER TO nwa;

--
-- Name: tsq_process_tokens(text[]); Type: FUNCTION; Schema: public; Owner: nwa
--

CREATE FUNCTION public.tsq_process_tokens(tokens text[]) RETURNS tsquery
    LANGUAGE sql IMMUTABLE
    AS $$
            SELECT tsq_process_tokens(get_current_ts_config(), tokens);
        $$;


ALTER FUNCTION public.tsq_process_tokens(tokens text[]) OWNER TO nwa;

--
-- Name: tsq_process_tokens(regconfig, text[]); Type: FUNCTION; Schema: public; Owner: nwa
--

CREATE FUNCTION public.tsq_process_tokens(config regconfig, tokens text[]) RETURNS tsquery
    LANGUAGE plpgsql IMMUTABLE
    AS $$
        DECLARE
            result_query text;
            previous_value text;
            value text;
        BEGIN
            result_query := '';

            FOREACH value IN ARRAY tokens LOOP
                IF value = '"' THEN
                    CONTINUE;
                END IF;

                IF value = 'or' THEN
                    value := ' | ';
                END IF;

                IF left(value, 1) = '"' AND right(value, 1) = '"' THEN
                    value := phraseto_tsquery(config, value);
                ELSIF value NOT IN ('(', ' | ', ')', '-') THEN
                    value := quote_literal(value) || ':*';
                END IF;

                IF previous_value = '-' THEN
                    IF value = '(' THEN
                        value := '!' || value;
                    ELSIF value = ' | ' THEN
                        CONTINUE;
                    ELSE
                        value := '!(' || value || ')';
                    END IF;
                END IF;

                SELECT
                    CASE
                        WHEN result_query = '' THEN value
                        WHEN previous_value = ' | ' AND value = ' | ' THEN result_query
                        WHEN previous_value = ' | ' THEN result_query || ' | ' || value
                        WHEN previous_value IN ('!(', '(') OR value = ')' THEN result_query || value
                        WHEN value != ' | ' THEN result_query || ' & ' || value
                        ELSE result_query
                    END
                INTO result_query;
                previous_value := value;
            END LOOP;

            IF result_query = ' | ' THEN
                RETURN to_tsquery('');
            END IF;

            RETURN to_tsquery(config, result_query);
        END;
        $$;


ALTER FUNCTION public.tsq_process_tokens(config regconfig, tokens text[]) OWNER TO nwa;

--
-- Name: tsq_tokenize(text); Type: FUNCTION; Schema: public; Owner: nwa
--

CREATE FUNCTION public.tsq_tokenize(search_query text) RETURNS text[]
    LANGUAGE plpgsql IMMUTABLE
    AS $$
        DECLARE
            state tsq_state;
        BEGIN
            SELECT
                search_query::text AS search_query,
                0::int AS parentheses_stack,
                0 AS skip_for,
                ''::text AS current_token,
                0 AS current_index,
                ''::text AS current_char,
                ''::text AS previous_char,
                '{}'::text[] AS tokens
            INTO state;

            state.search_query := lower(trim(
                regexp_replace(search_query, '""+', '""', 'g')
            ));

            FOR state.current_index IN (
                SELECT generate_series(1, length(state.search_query))
            ) LOOP
                state.current_char := substring(
                    search_query FROM state.current_index FOR 1
                );

                IF state.skip_for > 0 THEN
                    state.skip_for := state.skip_for - 1;
                    CONTINUE;
                END IF;

                state := tsq_tokenize_character(state);
                state.previous_char := state.current_char;
            END LOOP;
            state := tsq_append_current_token(state);

            state.tokens := array_nremove(state.tokens, '(', -state.parentheses_stack);

            RETURN state.tokens;
        END;
        $$;


ALTER FUNCTION public.tsq_tokenize(search_query text) OWNER TO nwa;

--
-- Name: tsq_tokenize_character(public.tsq_state); Type: FUNCTION; Schema: public; Owner: nwa
--

CREATE FUNCTION public.tsq_tokenize_character(state public.tsq_state) RETURNS public.tsq_state
    LANGUAGE plpgsql IMMUTABLE
    AS $$
        BEGIN
            IF state.current_char = '(' THEN
                state.tokens := array_append(state.tokens, '(');
                state.parentheses_stack := state.parentheses_stack + 1;
                state := tsq_append_current_token(state);
            ELSIF state.current_char = ')' THEN
                IF (state.parentheses_stack > 0 AND state.current_token != '') THEN
                    state := tsq_append_current_token(state);
                    state.tokens := array_append(state.tokens, ')');
                    state.parentheses_stack := state.parentheses_stack - 1;
                END IF;
            ELSIF state.current_char = '"' THEN
                state.skip_for := position('"' IN substring(
                    state.search_query FROM state.current_index + 1
                ));

                IF state.skip_for > 1 THEN
                    state.tokens = array_append(
                        state.tokens,
                        substring(
                            state.search_query
                            FROM state.current_index FOR state.skip_for + 1
                        )
                    );
                ELSIF state.skip_for = 0 THEN
                    state.current_token := state.current_token || state.current_char;
                END IF;
            ELSIF (
                state.current_char = '-' AND
                (state.current_index = 1 OR state.previous_char = ' ')
            ) THEN
                state.tokens := array_append(state.tokens, '-');
            ELSIF state.current_char = ' ' THEN
                state := tsq_append_current_token(state);
            ELSE
                state.current_token = state.current_token || state.current_char;
            END IF;
            RETURN state;
        END;
        $$;


ALTER FUNCTION public.tsq_tokenize_character(state public.tsq_state) OWNER TO nwa;

SET default_tablespace = '';

--
-- Name: alembic_version; Type: TABLE; Schema: public; Owner: nwa
--

CREATE TABLE public.alembic_version (
    version_num character varying(32) NOT NULL
);


ALTER TABLE public.alembic_version OWNER TO nwa;

--
-- Name: engine_settings; Type: TABLE; Schema: public; Owner: nwa
--

CREATE TABLE public.engine_settings (
    global_lock boolean NOT NULL,
    running_processes integer NOT NULL,
    CONSTRAINT check_running_processes_positive CHECK ((running_processes >= 0))
);


ALTER TABLE public.engine_settings OWNER TO nwa;

--
-- Name: fixed_inputs; Type: TABLE; Schema: public; Owner: nwa
--

CREATE TABLE public.fixed_inputs (
    fixed_input_id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    name character varying NOT NULL,
    value character varying NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    product_id uuid NOT NULL
);


ALTER TABLE public.fixed_inputs OWNER TO nwa;

--
-- Name: process_steps; Type: TABLE; Schema: public; Owner: nwa
--

CREATE TABLE public.process_steps (
    stepid uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    pid uuid NOT NULL,
    name character varying NOT NULL,
    status character varying(50) NOT NULL,
    state jsonb NOT NULL,
    created_by character varying(255),
    executed_at timestamp with time zone DEFAULT statement_timestamp() NOT NULL,
    commit_hash character varying(40)
);


ALTER TABLE public.process_steps OWNER TO nwa;

--
-- Name: processes; Type: TABLE; Schema: public; Owner: nwa
--

CREATE TABLE public.processes (
    pid uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    workflow character varying(255) NOT NULL,
    assignee character varying(50) DEFAULT 'SYSTEM'::character varying NOT NULL,
    last_status character varying(50) NOT NULL,
    last_step character varying(255),
    started_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    last_modified_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    failed_reason text,
    traceback text,
    created_by character varying(255),
    is_task boolean DEFAULT false NOT NULL
);


ALTER TABLE public.processes OWNER TO nwa;

--
-- Name: processes_subscriptions; Type: TABLE; Schema: public; Owner: nwa
--

CREATE TABLE public.processes_subscriptions (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    pid uuid NOT NULL,
    subscription_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    workflow_target character varying(255) DEFAULT 'CREATE'::character varying NOT NULL
);


ALTER TABLE public.processes_subscriptions OWNER TO nwa;

--
-- Name: product_block_relations; Type: TABLE; Schema: public; Owner: nwa
--

CREATE TABLE public.product_block_relations (
    in_use_by_id uuid NOT NULL,
    depends_on_id uuid NOT NULL,
    min integer,
    max integer
);


ALTER TABLE public.product_block_relations OWNER TO nwa;

--
-- Name: product_block_resource_types; Type: TABLE; Schema: public; Owner: nwa
--

CREATE TABLE public.product_block_resource_types (
    product_block_id uuid NOT NULL,
    resource_type_id uuid NOT NULL
);


ALTER TABLE public.product_block_resource_types OWNER TO nwa;

--
-- Name: product_blocks; Type: TABLE; Schema: public; Owner: nwa
--

CREATE TABLE public.product_blocks (
    product_block_id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    name character varying NOT NULL,
    description text NOT NULL,
    tag character varying(20),
    status character varying(255),
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    end_date timestamp with time zone
);


ALTER TABLE public.product_blocks OWNER TO nwa;

--
-- Name: product_product_blocks; Type: TABLE; Schema: public; Owner: nwa
--

CREATE TABLE public.product_product_blocks (
    product_id uuid NOT NULL,
    product_block_id uuid NOT NULL
);


ALTER TABLE public.product_product_blocks OWNER TO nwa;

--
-- Name: products; Type: TABLE; Schema: public; Owner: nwa
--

CREATE TABLE public.products (
    product_id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    name character varying NOT NULL,
    description text NOT NULL,
    product_type character varying(255) NOT NULL,
    tag character varying(20) NOT NULL,
    status character varying(255) NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    end_date timestamp with time zone
);


ALTER TABLE public.products OWNER TO nwa;

--
-- Name: products_workflows; Type: TABLE; Schema: public; Owner: nwa
--

CREATE TABLE public.products_workflows (
    product_id uuid NOT NULL,
    workflow_id uuid NOT NULL
);


ALTER TABLE public.products_workflows OWNER TO nwa;

--
-- Name: resource_types; Type: TABLE; Schema: public; Owner: nwa
--

CREATE TABLE public.resource_types (
    resource_type_id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    resource_type character varying(510) NOT NULL,
    description text
);


ALTER TABLE public.resource_types OWNER TO nwa;

--
-- Name: subscription_customer_descriptions; Type: TABLE; Schema: public; Owner: nwa
--

CREATE TABLE public.subscription_customer_descriptions (
    id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    subscription_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    description text NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


ALTER TABLE public.subscription_customer_descriptions OWNER TO nwa;

--
-- Name: subscription_instance_relations; Type: TABLE; Schema: public; Owner: nwa
--

CREATE TABLE public.subscription_instance_relations (
    in_use_by_id uuid NOT NULL,
    depends_on_id uuid NOT NULL,
    order_id integer NOT NULL,
    domain_model_attr text
);


ALTER TABLE public.subscription_instance_relations OWNER TO nwa;

--
-- Name: subscription_instance_values; Type: TABLE; Schema: public; Owner: nwa
--

CREATE TABLE public.subscription_instance_values (
    subscription_instance_value_id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    subscription_instance_id uuid NOT NULL,
    resource_type_id uuid NOT NULL,
    value text NOT NULL
);


ALTER TABLE public.subscription_instance_values OWNER TO nwa;

--
-- Name: subscription_instances; Type: TABLE; Schema: public; Owner: nwa
--

CREATE TABLE public.subscription_instances (
    subscription_instance_id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    subscription_id uuid NOT NULL,
    product_block_id uuid NOT NULL,
    label character varying(255)
);


ALTER TABLE public.subscription_instances OWNER TO nwa;

--
-- Name: subscriptions; Type: TABLE; Schema: public; Owner: nwa
--

CREATE TABLE public.subscriptions (
    subscription_id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    description text NOT NULL,
    status character varying(255) NOT NULL,
    product_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    insync boolean NOT NULL,
    start_date timestamp with time zone,
    end_date timestamp with time zone,
    note text,
    tsv tsvector
);


ALTER TABLE public.subscriptions OWNER TO nwa;

--
-- Name: workflows; Type: TABLE; Schema: public; Owner: nwa
--

CREATE TABLE public.workflows (
    workflow_id uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    name character varying NOT NULL,
    target character varying NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


ALTER TABLE public.workflows OWNER TO nwa;

--
-- Data for Name: alembic_version; Type: TABLE DATA; Schema: public; Owner: nwa
--

COPY public.alembic_version (version_num) FROM stdin;
46287618baec
\.


--
-- Data for Name: engine_settings; Type: TABLE DATA; Schema: public; Owner: nwa
--

COPY public.engine_settings (global_lock, running_processes) FROM stdin;
f	0
\.


--
-- Data for Name: fixed_inputs; Type: TABLE DATA; Schema: public; Owner: nwa
--

COPY public.fixed_inputs (fixed_input_id, name, value, created_at, product_id) FROM stdin;
70cd63d7-3c76-46c6-bbdd-080067d77127	Affiliation	internal	2022-10-11 15:28:38.104715+02	3431992f-1628-44a1-8ec5-1b2f86440987
239eb96a-abda-4ed2-a069-3fd5d5c5b86a	Affiliation	external	2022-10-11 15:28:38.104715+02	77fe1b9b-badf-4144-9261-b95683a54023
\.


--
-- Data for Name: process_steps; Type: TABLE DATA; Schema: public; Owner: nwa
--

COPY public.process_steps (stepid, pid, name, status, state, created_by, executed_at, commit_hash) FROM stdin;
90ce6800-a1ed-4a8c-a05b-e86c936747a8	969f694d-28ea-47ad-b002-1a26159e93a7	Start	success	{"product": "800d1cf7-2039-4364-98b0-7cbbdd5fa44e", "reporter": "SYSTEM", "group_name": "werkt het?", "process_id": "969f694d-28ea-47ad-b002-1a26159e93a7", "product_name": "User group", "workflow_name": "create_user_group", "workflow_target": "CREATE"}	SYSTEM	2022-10-11 15:30:14.550022+02	b10dc16f5814952e95f24e58cedbf3f589ca5fb4
0c047f88-4291-4ee5-af20-89ad2faf08a9	969f694d-28ea-47ad-b002-1a26159e93a7	Create subscription	success	{"product": "800d1cf7-2039-4364-98b0-7cbbdd5fa44e", "reporter": "SYSTEM", "group_name": "werkt het?", "process_id": "969f694d-28ea-47ad-b002-1a26159e93a7", "product_name": "User group", "subscription": {"note": null, "insync": false, "status": "initial", "product": {"tag": "GROUP", "name": "User group", "status": "active", "end_date": null, "created_at": "2022-10-11T13:28:38+00:00", "product_id": "800d1cf7-2039-4364-98b0-7cbbdd5fa44e", "description": "User group product", "product_type": "UserGroup"}, "end_date": null, "settings": {"name": "UserGroupBlock", "label": null, "group_name": "werkt het?", "owner_subscription_id": "5b22fb23-80f5-4dbc-a5d3-5d55f3d0b916", "subscription_instance_id": "694a1c88-fe65-4a37-b034-235257533a51"}, "start_date": null, "customer_id": "0b4594d8-89ac-402b-ab5a-aa435b39abda", "description": "Initial subscription of User group product", "subscription_id": "5b22fb23-80f5-4dbc-a5d3-5d55f3d0b916"}, "workflow_name": "create_user_group", "subscription_id": "5b22fb23-80f5-4dbc-a5d3-5d55f3d0b916", "workflow_target": "CREATE", "subscription_description": "Initial subscription of User group product"}	SYSTEM	2022-10-11 15:30:14.703159+02	b10dc16f5814952e95f24e58cedbf3f589ca5fb4
5664925c-7dd0-4fb8-b454-a45207e6aceb	969f694d-28ea-47ad-b002-1a26159e93a7	Create Process Subscription relation	success	{"product": "800d1cf7-2039-4364-98b0-7cbbdd5fa44e", "reporter": "SYSTEM", "group_name": "werkt het?", "process_id": "969f694d-28ea-47ad-b002-1a26159e93a7", "product_name": "User group", "subscription": {"note": null, "insync": false, "status": "initial", "product": {"tag": "GROUP", "name": "User group", "status": "active", "end_date": null, "created_at": "2022-10-11T13:28:38+00:00", "product_id": "800d1cf7-2039-4364-98b0-7cbbdd5fa44e", "description": "User group product", "product_type": "UserGroup"}, "end_date": null, "settings": {"name": "UserGroupBlock", "label": null, "group_name": "werkt het?", "owner_subscription_id": "5b22fb23-80f5-4dbc-a5d3-5d55f3d0b916", "subscription_instance_id": "694a1c88-fe65-4a37-b034-235257533a51"}, "start_date": null, "customer_id": "0b4594d8-89ac-402b-ab5a-aa435b39abda", "description": "Initial subscription of User group product", "subscription_id": "5b22fb23-80f5-4dbc-a5d3-5d55f3d0b916"}, "workflow_name": "create_user_group", "subscription_id": "5b22fb23-80f5-4dbc-a5d3-5d55f3d0b916", "workflow_target": "CREATE", "subscription_description": "Initial subscription of User group product"}	SYSTEM	2022-10-11 15:30:14.729855+02	b10dc16f5814952e95f24e58cedbf3f589ca5fb4
937ac007-7389-4746-8443-a365332d8138	969f694d-28ea-47ad-b002-1a26159e93a7	Set description	success	{"product": "800d1cf7-2039-4364-98b0-7cbbdd5fa44e", "reporter": "SYSTEM", "group_name": "werkt het?", "process_id": "969f694d-28ea-47ad-b002-1a26159e93a7", "product_name": "User group", "subscription": {"note": null, "insync": false, "status": "initial", "product": {"tag": "GROUP", "name": "User group", "status": "active", "end_date": null, "created_at": "2022-10-11T13:28:38+00:00", "product_id": "800d1cf7-2039-4364-98b0-7cbbdd5fa44e", "description": "User group product", "product_type": "UserGroup"}, "end_date": null, "settings": {"name": "UserGroupBlock", "label": null, "group_name": "werkt het?", "owner_subscription_id": "5b22fb23-80f5-4dbc-a5d3-5d55f3d0b916", "subscription_instance_id": "694a1c88-fe65-4a37-b034-235257533a51"}, "start_date": null, "customer_id": "0b4594d8-89ac-402b-ab5a-aa435b39abda", "description": "Initial subscription of User group product", "subscription_id": "5b22fb23-80f5-4dbc-a5d3-5d55f3d0b916"}, "workflow_name": "create_user_group", "subscription_id": "5b22fb23-80f5-4dbc-a5d3-5d55f3d0b916", "workflow_target": "CREATE", "subscription_description": "Initial subscription of User group product"}	SYSTEM	2022-10-11 15:30:14.83712+02	b10dc16f5814952e95f24e58cedbf3f589ca5fb4
32ff1149-cfc3-4b64-8f56-03012f9ec63d	969f694d-28ea-47ad-b002-1a26159e93a7	Set subscription to 'active'	success	{"product": "800d1cf7-2039-4364-98b0-7cbbdd5fa44e", "reporter": "SYSTEM", "group_name": "werkt het?", "process_id": "969f694d-28ea-47ad-b002-1a26159e93a7", "product_name": "User group", "subscription": {"note": null, "insync": false, "status": "active", "product": {"tag": "GROUP", "name": "User group", "status": "active", "end_date": null, "created_at": "2022-10-11T13:28:38+00:00", "product_id": "800d1cf7-2039-4364-98b0-7cbbdd5fa44e", "description": "User group product", "product_type": "UserGroup"}, "end_date": null, "start_date": "2022-10-11T13:30:14+00:00", "customer_id": "0b4594d8-89ac-402b-ab5a-aa435b39abda", "description": "Initial subscription of User group product", "subscription_id": "5b22fb23-80f5-4dbc-a5d3-5d55f3d0b916"}, "workflow_name": "create_user_group", "subscription_id": "5b22fb23-80f5-4dbc-a5d3-5d55f3d0b916", "workflow_target": "CREATE", "subscription_description": "Initial subscription of User group product"}	SYSTEM	2022-10-11 15:30:14.923306+02	b10dc16f5814952e95f24e58cedbf3f589ca5fb4
55d053fd-e919-49ec-9c08-bf378c481e01	969f694d-28ea-47ad-b002-1a26159e93a7	Unlock subscription	success	{"product": "800d1cf7-2039-4364-98b0-7cbbdd5fa44e", "reporter": "SYSTEM", "group_name": "werkt het?", "process_id": "969f694d-28ea-47ad-b002-1a26159e93a7", "product_name": "User group", "subscription": {"note": null, "insync": true, "status": "active", "product": {"tag": "GROUP", "name": "User group", "status": "active", "end_date": null, "created_at": "2022-10-11T13:28:38+00:00", "product_id": "800d1cf7-2039-4364-98b0-7cbbdd5fa44e", "description": "User group product", "product_type": "UserGroup"}, "end_date": null, "start_date": "2022-10-11T13:30:14+00:00", "customer_id": "0b4594d8-89ac-402b-ab5a-aa435b39abda", "description": "Initial subscription of User group product", "subscription_id": "5b22fb23-80f5-4dbc-a5d3-5d55f3d0b916"}, "workflow_name": "create_user_group", "subscription_id": "5b22fb23-80f5-4dbc-a5d3-5d55f3d0b916", "workflow_target": "CREATE", "subscription_description": "Initial subscription of User group product"}	SYSTEM	2022-10-11 15:30:14.993758+02	b10dc16f5814952e95f24e58cedbf3f589ca5fb4
0c385c96-089e-4780-8208-34826cb00ffa	969f694d-28ea-47ad-b002-1a26159e93a7	Done	complete	{"product": "800d1cf7-2039-4364-98b0-7cbbdd5fa44e", "reporter": "SYSTEM", "group_name": "werkt het?", "process_id": "969f694d-28ea-47ad-b002-1a26159e93a7", "product_name": "User group", "subscription": {"note": null, "insync": true, "status": "active", "product": {"tag": "GROUP", "name": "User group", "status": "active", "end_date": null, "created_at": "2022-10-11T13:28:38+00:00", "product_id": "800d1cf7-2039-4364-98b0-7cbbdd5fa44e", "description": "User group product", "product_type": "UserGroup"}, "end_date": null, "start_date": "2022-10-11T13:30:14+00:00", "customer_id": "0b4594d8-89ac-402b-ab5a-aa435b39abda", "description": "Initial subscription of User group product", "subscription_id": "5b22fb23-80f5-4dbc-a5d3-5d55f3d0b916"}, "workflow_name": "create_user_group", "subscription_id": "5b22fb23-80f5-4dbc-a5d3-5d55f3d0b916", "workflow_target": "CREATE", "subscription_description": "Initial subscription of User group product"}	SYSTEM	2022-10-11 15:30:15.022616+02	b10dc16f5814952e95f24e58cedbf3f589ca5fb4
36d0f8b0-5be5-4cb1-a37d-7852650cbc9d	17f0af51-216d-4a9b-b79e-4054f8ec815f	Start	success	{"product": "800d1cf7-2039-4364-98b0-7cbbdd5fa44e", "reporter": "SYSTEM", "group_name": "help", "process_id": "17f0af51-216d-4a9b-b79e-4054f8ec815f", "product_name": "User group", "workflow_name": "create_user_group", "workflow_target": "CREATE"}	SYSTEM	2022-10-11 15:35:26.078774+02	b10dc16f5814952e95f24e58cedbf3f589ca5fb4
845d729a-8331-4638-a763-c839af64a381	17f0af51-216d-4a9b-b79e-4054f8ec815f	Create subscription	success	{"product": "800d1cf7-2039-4364-98b0-7cbbdd5fa44e", "reporter": "SYSTEM", "group_name": "help", "process_id": "17f0af51-216d-4a9b-b79e-4054f8ec815f", "product_name": "User group", "subscription": {"note": null, "insync": false, "status": "initial", "product": {"tag": "GROUP", "name": "User group", "status": "active", "end_date": null, "created_at": "2022-10-11T13:28:38+00:00", "product_id": "800d1cf7-2039-4364-98b0-7cbbdd5fa44e", "description": "User group product", "product_type": "UserGroup"}, "end_date": null, "settings": {"name": "UserGroupBlock", "label": null, "group_name": "help", "owner_subscription_id": "9d6ddc7c-a918-439c-acc9-d273934e70e7", "subscription_instance_id": "9c4773bc-606a-4091-b8cf-09e33e3d2d53"}, "start_date": null, "customer_id": "d4b81a67-efe3-4378-b4ab-d87357f31d10", "description": "Initial subscription of User group product", "subscription_id": "9d6ddc7c-a918-439c-acc9-d273934e70e7"}, "workflow_name": "create_user_group", "subscription_id": "9d6ddc7c-a918-439c-acc9-d273934e70e7", "workflow_target": "CREATE", "subscription_description": "Initial subscription of User group product"}	SYSTEM	2022-10-11 15:35:26.207903+02	b10dc16f5814952e95f24e58cedbf3f589ca5fb4
32609abd-536a-4126-9676-7e9425e9f672	17f0af51-216d-4a9b-b79e-4054f8ec815f	Set in sync and update lifecyle to provisioning	success	{"product": "800d1cf7-2039-4364-98b0-7cbbdd5fa44e", "reporter": "SYSTEM", "group_name": "help", "process_id": "17f0af51-216d-4a9b-b79e-4054f8ec815f", "product_name": "User group", "subscription": {"note": null, "insync": true, "status": "active", "product": {"tag": "GROUP", "name": "User group", "status": "active", "end_date": null, "created_at": "2022-10-11T13:28:38+00:00", "product_id": "800d1cf7-2039-4364-98b0-7cbbdd5fa44e", "description": "User group product", "product_type": "UserGroup"}, "end_date": null, "settings": {"name": "UserGroupBlock", "label": null, "group_name": "help", "owner_subscription_id": "9d6ddc7c-a918-439c-acc9-d273934e70e7", "subscription_instance_id": "9c4773bc-606a-4091-b8cf-09e33e3d2d53"}, "start_date": "2022-10-11T13:35:26+00:00", "customer_id": "d4b81a67-efe3-4378-b4ab-d87357f31d10", "description": "User group help", "subscription_id": "9d6ddc7c-a918-439c-acc9-d273934e70e7"}, "subsscription": {"note": null, "insync": false, "status": "initial", "product": {"tag": "GROUP", "name": "User group", "status": "active", "end_date": null, "created_at": "2022-10-11T13:28:38+00:00", "product_id": "800d1cf7-2039-4364-98b0-7cbbdd5fa44e", "description": "User group product", "product_type": "UserGroup"}, "end_date": null, "settings": {"name": "UserGroupBlock", "label": null, "group_name": "help", "owner_subscription_id": "9d6ddc7c-a918-439c-acc9-d273934e70e7", "subscription_instance_id": "9c4773bc-606a-4091-b8cf-09e33e3d2d53"}, "start_date": null, "customer_id": "d4b81a67-efe3-4378-b4ab-d87357f31d10", "description": "User group help", "subscription_id": "9d6ddc7c-a918-439c-acc9-d273934e70e7"}, "workflow_name": "create_user_group", "subscription_id": "9d6ddc7c-a918-439c-acc9-d273934e70e7", "workflow_target": "CREATE", "subscription_description": "Initial subscription of User group product"}	SYSTEM	2022-10-11 15:35:26.521407+02	b10dc16f5814952e95f24e58cedbf3f589ca5fb4
a4d658a1-3a10-4887-8024-25fe679e0f21	17f0af51-216d-4a9b-b79e-4054f8ec815f	Create Process Subscription relation	success	{"product": "800d1cf7-2039-4364-98b0-7cbbdd5fa44e", "reporter": "SYSTEM", "group_name": "help", "process_id": "17f0af51-216d-4a9b-b79e-4054f8ec815f", "product_name": "User group", "subscription": {"note": null, "insync": false, "status": "initial", "product": {"tag": "GROUP", "name": "User group", "status": "active", "end_date": null, "created_at": "2022-10-11T13:28:38+00:00", "product_id": "800d1cf7-2039-4364-98b0-7cbbdd5fa44e", "description": "User group product", "product_type": "UserGroup"}, "end_date": null, "settings": {"name": "UserGroupBlock", "label": null, "group_name": "help", "owner_subscription_id": "9d6ddc7c-a918-439c-acc9-d273934e70e7", "subscription_instance_id": "9c4773bc-606a-4091-b8cf-09e33e3d2d53"}, "start_date": null, "customer_id": "d4b81a67-efe3-4378-b4ab-d87357f31d10", "description": "Initial subscription of User group product", "subscription_id": "9d6ddc7c-a918-439c-acc9-d273934e70e7"}, "workflow_name": "create_user_group", "subscription_id": "9d6ddc7c-a918-439c-acc9-d273934e70e7", "workflow_target": "CREATE", "subscription_description": "Initial subscription of User group product"}	SYSTEM	2022-10-11 15:35:26.233623+02	b10dc16f5814952e95f24e58cedbf3f589ca5fb4
08127de3-c63f-481b-b212-636cf63b105f	17f0af51-216d-4a9b-b79e-4054f8ec815f	Set description	success	{"product": "800d1cf7-2039-4364-98b0-7cbbdd5fa44e", "reporter": "SYSTEM", "group_name": "help", "process_id": "17f0af51-216d-4a9b-b79e-4054f8ec815f", "product_name": "User group", "subscription": {"note": null, "insync": false, "status": "initial", "product": {"tag": "GROUP", "name": "User group", "status": "active", "end_date": null, "created_at": "2022-10-11T13:28:38+00:00", "product_id": "800d1cf7-2039-4364-98b0-7cbbdd5fa44e", "description": "User group product", "product_type": "UserGroup"}, "end_date": null, "settings": {"name": "UserGroupBlock", "label": null, "group_name": "help", "owner_subscription_id": "9d6ddc7c-a918-439c-acc9-d273934e70e7", "subscription_instance_id": "9c4773bc-606a-4091-b8cf-09e33e3d2d53"}, "start_date": null, "customer_id": "d4b81a67-efe3-4378-b4ab-d87357f31d10", "description": "Initial subscription of User group product", "subscription_id": "9d6ddc7c-a918-439c-acc9-d273934e70e7"}, "subsscription": {"note": null, "insync": false, "status": "initial", "product": {"tag": "GROUP", "name": "User group", "status": "active", "end_date": null, "created_at": "2022-10-11T13:28:38+00:00", "product_id": "800d1cf7-2039-4364-98b0-7cbbdd5fa44e", "description": "User group product", "product_type": "UserGroup"}, "end_date": null, "settings": {"name": "UserGroupBlock", "label": null, "group_name": "help", "owner_subscription_id": "9d6ddc7c-a918-439c-acc9-d273934e70e7", "subscription_instance_id": "9c4773bc-606a-4091-b8cf-09e33e3d2d53"}, "start_date": null, "customer_id": "d4b81a67-efe3-4378-b4ab-d87357f31d10", "description": "User group help", "subscription_id": "9d6ddc7c-a918-439c-acc9-d273934e70e7"}, "workflow_name": "create_user_group", "subscription_id": "9d6ddc7c-a918-439c-acc9-d273934e70e7", "workflow_target": "CREATE", "subscription_description": "Initial subscription of User group product"}	SYSTEM	2022-10-11 15:35:26.401175+02	b10dc16f5814952e95f24e58cedbf3f589ca5fb4
203be397-4f88-4574-9221-9eff3e729d59	17f0af51-216d-4a9b-b79e-4054f8ec815f	Done	complete	{"product": "800d1cf7-2039-4364-98b0-7cbbdd5fa44e", "reporter": "SYSTEM", "group_name": "help", "process_id": "17f0af51-216d-4a9b-b79e-4054f8ec815f", "product_name": "User group", "subscription": {"note": null, "insync": true, "status": "active", "product": {"tag": "GROUP", "name": "User group", "status": "active", "end_date": null, "created_at": "2022-10-11T13:28:38+00:00", "product_id": "800d1cf7-2039-4364-98b0-7cbbdd5fa44e", "description": "User group product", "product_type": "UserGroup"}, "end_date": null, "settings": {"name": "UserGroupBlock", "label": null, "group_name": "help", "owner_subscription_id": "9d6ddc7c-a918-439c-acc9-d273934e70e7", "subscription_instance_id": "9c4773bc-606a-4091-b8cf-09e33e3d2d53"}, "start_date": "2022-10-11T13:35:26+00:00", "customer_id": "d4b81a67-efe3-4378-b4ab-d87357f31d10", "description": "User group help", "subscription_id": "9d6ddc7c-a918-439c-acc9-d273934e70e7"}, "subsscription": {"note": null, "insync": false, "status": "initial", "product": {"tag": "GROUP", "name": "User group", "status": "active", "end_date": null, "created_at": "2022-10-11T13:28:38+00:00", "product_id": "800d1cf7-2039-4364-98b0-7cbbdd5fa44e", "description": "User group product", "product_type": "UserGroup"}, "end_date": null, "settings": {"name": "UserGroupBlock", "label": null, "group_name": "help", "owner_subscription_id": "9d6ddc7c-a918-439c-acc9-d273934e70e7", "subscription_instance_id": "9c4773bc-606a-4091-b8cf-09e33e3d2d53"}, "start_date": null, "customer_id": "d4b81a67-efe3-4378-b4ab-d87357f31d10", "description": "User group help", "subscription_id": "9d6ddc7c-a918-439c-acc9-d273934e70e7"}, "workflow_name": "create_user_group", "subscription_id": "9d6ddc7c-a918-439c-acc9-d273934e70e7", "workflow_target": "CREATE", "subscription_description": "Initial subscription of User group product"}	SYSTEM	2022-10-11 15:35:26.53766+02	b10dc16f5814952e95f24e58cedbf3f589ca5fb4
\.


--
-- Data for Name: processes; Type: TABLE DATA; Schema: public; Owner: nwa
--

COPY public.processes (pid, workflow, assignee, last_status, last_step, started_at, last_modified_at, failed_reason, traceback, created_by, is_task) FROM stdin;
969f694d-28ea-47ad-b002-1a26159e93a7	create_user_group	SYSTEM	completed	Done	2022-10-11 15:30:14.509662+02	2022-10-11 15:30:15.02492+02	\N	\N	SYSTEM	f
17f0af51-216d-4a9b-b79e-4054f8ec815f	create_user_group	SYSTEM	completed	Done	2022-10-11 15:35:26.029966+02	2022-10-11 15:35:26.538608+02	\N	\N	SYSTEM	f
\.


--
-- Data for Name: processes_subscriptions; Type: TABLE DATA; Schema: public; Owner: nwa
--

COPY public.processes_subscriptions (id, pid, subscription_id, created_at, workflow_target) FROM stdin;
bc757776-bcb1-46cf-bf8a-92055b27b6b8	969f694d-28ea-47ad-b002-1a26159e93a7	5b22fb23-80f5-4dbc-a5d3-5d55f3d0b916	2022-10-11 15:30:14.710501+02	CREATE
b2bc9760-2961-442c-93f0-e9c4d24441f9	17f0af51-216d-4a9b-b79e-4054f8ec815f	9d6ddc7c-a918-439c-acc9-d273934e70e7	2022-10-11 15:35:26.217936+02	CREATE
\.


--
-- Data for Name: product_block_relations; Type: TABLE DATA; Schema: public; Owner: nwa
--

COPY public.product_block_relations (in_use_by_id, depends_on_id, min, max) FROM stdin;
aee3e74b-4982-4e8e-b464-45103bc58954	b9a0accc-deec-462d-a843-184e9456bd0f	\N	\N
\.


--
-- Data for Name: product_block_resource_types; Type: TABLE DATA; Schema: public; Owner: nwa
--

COPY public.product_block_resource_types (product_block_id, resource_type_id) FROM stdin;
b9a0accc-deec-462d-a843-184e9456bd0f	b8a10b35-e52d-4ac9-8266-f226bdf6ba30
aee3e74b-4982-4e8e-b464-45103bc58954	d7dab36f-0a16-4bc1-b793-e44e2b5debea
aee3e74b-4982-4e8e-b464-45103bc58954	49e3fb4f-664f-44f1-8cf9-76cf4ae9a0a4
aee3e74b-4982-4e8e-b464-45103bc58954	93ecaf19-4646-423e-873c-5d91889b974e
\.


--
-- Data for Name: product_blocks; Type: TABLE DATA; Schema: public; Owner: nwa
--

COPY public.product_blocks (product_block_id, name, description, tag, status, created_at, end_date) FROM stdin;
b9a0accc-deec-462d-a843-184e9456bd0f	UserGroupBlock	User group settings	UGS	active	2022-10-11 15:28:38.104715+02	\N
aee3e74b-4982-4e8e-b464-45103bc58954	UserBlock	User settings	US	active	2022-10-11 15:28:38.104715+02	\N
\.


--
-- Data for Name: product_product_blocks; Type: TABLE DATA; Schema: public; Owner: nwa
--

COPY public.product_product_blocks (product_id, product_block_id) FROM stdin;
800d1cf7-2039-4364-98b0-7cbbdd5fa44e	b9a0accc-deec-462d-a843-184e9456bd0f
3431992f-1628-44a1-8ec5-1b2f86440987	aee3e74b-4982-4e8e-b464-45103bc58954
77fe1b9b-badf-4144-9261-b95683a54023	aee3e74b-4982-4e8e-b464-45103bc58954
\.


--
-- Data for Name: products; Type: TABLE DATA; Schema: public; Owner: nwa
--

COPY public.products (product_id, name, description, product_type, tag, status, created_at, end_date) FROM stdin;
800d1cf7-2039-4364-98b0-7cbbdd5fa44e	User group	User group product	UserGroup	GROUP	active	2022-10-11 15:28:38.104715+02	\N
3431992f-1628-44a1-8ec5-1b2f86440987	User internal	User product	User	INT_USER	active	2022-10-11 15:28:38.104715+02	\N
77fe1b9b-badf-4144-9261-b95683a54023	User external	User product	User	EXT_USER	active	2022-10-11 15:28:38.104715+02	\N
\.


--
-- Data for Name: products_workflows; Type: TABLE DATA; Schema: public; Owner: nwa
--

COPY public.products_workflows (product_id, workflow_id) FROM stdin;
800d1cf7-2039-4364-98b0-7cbbdd5fa44e	5618e957-fe94-432c-9121-98baa566c9c5
3431992f-1628-44a1-8ec5-1b2f86440987	5618e957-fe94-432c-9121-98baa566c9c5
77fe1b9b-badf-4144-9261-b95683a54023	5618e957-fe94-432c-9121-98baa566c9c5
800d1cf7-2039-4364-98b0-7cbbdd5fa44e	213011dd-2edc-4142-b0a8-48683e355fc0
800d1cf7-2039-4364-98b0-7cbbdd5fa44e	bcc26008-20ff-452e-9857-18ba31fcecce
3431992f-1628-44a1-8ec5-1b2f86440987	7bca620c-bb7f-4cb4-bd7d-89d51e655f3c
77fe1b9b-badf-4144-9261-b95683a54023	7bca620c-bb7f-4cb4-bd7d-89d51e655f3c
3431992f-1628-44a1-8ec5-1b2f86440987	f4e7b69c-b314-4377-a978-6c4c02d7a18e
77fe1b9b-badf-4144-9261-b95683a54023	f4e7b69c-b314-4377-a978-6c4c02d7a18e
\.


--
-- Data for Name: resource_types; Type: TABLE DATA; Schema: public; Owner: nwa
--

COPY public.resource_types (resource_type_id, resource_type, description) FROM stdin;
b8a10b35-e52d-4ac9-8266-f226bdf6ba30	group_name	Unique name of user group
d7dab36f-0a16-4bc1-b793-e44e2b5debea	affiliation	User affiliation
49e3fb4f-664f-44f1-8cf9-76cf4ae9a0a4	username	Unique name of user
93ecaf19-4646-423e-873c-5d91889b974e	age	Age of user
\.


--
-- Data for Name: subscription_customer_descriptions; Type: TABLE DATA; Schema: public; Owner: nwa
--

COPY public.subscription_customer_descriptions (id, subscription_id, customer_id, description, created_at) FROM stdin;
\.


--
-- Data for Name: subscription_instance_relations; Type: TABLE DATA; Schema: public; Owner: nwa
--

COPY public.subscription_instance_relations (in_use_by_id, depends_on_id, order_id, domain_model_attr) FROM stdin;
\.


--
-- Data for Name: subscription_instance_values; Type: TABLE DATA; Schema: public; Owner: nwa
--

COPY public.subscription_instance_values (subscription_instance_value_id, subscription_instance_id, resource_type_id, value) FROM stdin;
aeddeaa2-647e-4f68-ba91-a8973f963ed6	9c4773bc-606a-4091-b8cf-09e33e3d2d53	b8a10b35-e52d-4ac9-8266-f226bdf6ba30	help
\.


--
-- Data for Name: subscription_instances; Type: TABLE DATA; Schema: public; Owner: nwa
--

COPY public.subscription_instances (subscription_instance_id, subscription_id, product_block_id, label) FROM stdin;
9c4773bc-606a-4091-b8cf-09e33e3d2d53	9d6ddc7c-a918-439c-acc9-d273934e70e7	b9a0accc-deec-462d-a843-184e9456bd0f	\N
\.


--
-- Data for Name: subscriptions; Type: TABLE DATA; Schema: public; Owner: nwa
--

COPY public.subscriptions (subscription_id, description, status, product_id, customer_id, insync, start_date, end_date, note, tsv) FROM stdin;
5b22fb23-80f5-4dbc-a5d3-5d55f3d0b916	Initial subscription of User group product	active	800d1cf7-2039-4364-98b0-7cbbdd5fa44e	0b4594d8-89ac-402b-ab5a-aa435b39abda	t	2022-10-11 15:30:14.88027+02	\N	\N	'-2039':33 '-4364':34 '-98':35 '0b4594d8':25 '0b4594d8-89ac-402b-ab5a-aa435b39abda':24 '402b':27 '4dbc':6 '5b22fb23':4 '5b22fb23-80f5-4dbc-a5d3-5d55f3d0b916':3 '5d55f3d0b916':8 '7cbbdd5fa44e':38 '800d1cf7':32 '80f5':5 '89ac':26 'a5d3':7 'aa435b39abda':29 'ab5a':28 'activ':10 'b0':37 'b0-7cbbdd5fa44e':36 'custom':22 'descript':14,44 'group':19,42,46,49 'id':2,23,31 'initi':15 'insync':11 'name':40 'note':21 'product':20,30,39,43,47,50 'status':9 'subscript':1,13,16 'tag':48 'true':12 'type':51 'user':18,41,45 'usergroup':52
9d6ddc7c-a918-439c-acc9-d273934e70e7	User group help	active	800d1cf7-2039-4364-98b0-7cbbdd5fa44e	d4b81a67-efe3-4378-b4ab-d87357f31d10	t	2022-10-11 15:35:26.449521+02	\N	\N	'-2039':31 '-4364':32 '-98':33 '4378':24 '439c':6 '7cbbdd5fa44e':36 '800d1cf7':30 '9d6ddc7c':4 '9d6ddc7c-a918-439c-acc9-d273934e70e7':3 'a918':5 'acc9':7 'activ':10 'b0':35 'b0-7cbbdd5fa44e':34 'b4ab':26 'b4ab-d87357f31d10':25 'custom':19 'd273934e70e7':8 'd4b81a67':22 'd4b81a67-efe3':21 'd87357f31d10':27 'descript':14,42 'efe3':23 'group':16,40,44,47,51 'help':17,53 'id':2,20,29 'insync':11 'name':38,52 'note':18 'product':28,37,41,45,48 'status':9 'subscript':1,13 'tag':46 'true':12 'type':49 'user':15,39,43 'usergroup':50
\.


--
-- Data for Name: workflows; Type: TABLE DATA; Schema: public; Owner: nwa
--

COPY public.workflows (workflow_id, name, target, description, created_at) FROM stdin;
5618e957-fe94-432c-9121-98baa566c9c5	modify_note	MODIFY	Modify Note	2022-10-11 15:28:38.104715+02
08b58e4f-a51d-4bd3-a497-dc065b6b1406	task_clean_up_tasks	SYSTEM	Clean up old tasks	2022-10-11 15:28:38.104715+02
c15dea7f-c0f3-4784-b3ff-efc1695618d9	task_resume_workflows	SYSTEM	Resume all workflows that are stuck on tasks with the status 'waiting'	2022-10-11 15:28:38.104715+02
08709795-20b7-4469-8f22-1378c659ef81	task_validate_products	SYSTEM	Validate products	2022-10-11 15:28:38.104715+02
213011dd-2edc-4142-b0a8-48683e355fc0	create_user_group	CREATE	Create user group	2022-10-11 15:28:38.104715+02
bcc26008-20ff-452e-9857-18ba31fcecce	terminate_user_group	TERMINATE	Terminate user group	2022-10-11 15:28:38.104715+02
7bca620c-bb7f-4cb4-bd7d-89d51e655f3c	create_user	CREATE	Create user	2022-10-11 15:28:38.104715+02
f4e7b69c-b314-4377-a978-6c4c02d7a18e	terminate_user	TERMINATE	Terminate user	2022-10-11 15:28:38.104715+02
\.


--
-- Name: alembic_version alembic_version_pkc; Type: CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.alembic_version
    ADD CONSTRAINT alembic_version_pkc PRIMARY KEY (version_num);


--
-- Name: engine_settings engine_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.engine_settings
    ADD CONSTRAINT engine_settings_pkey PRIMARY KEY (global_lock);


--
-- Name: fixed_inputs fixed_inputs_name_product_id_key; Type: CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.fixed_inputs
    ADD CONSTRAINT fixed_inputs_name_product_id_key UNIQUE (name, product_id);


--
-- Name: fixed_inputs fixed_inputs_pkey; Type: CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.fixed_inputs
    ADD CONSTRAINT fixed_inputs_pkey PRIMARY KEY (fixed_input_id);


--
-- Name: process_steps process_steps_pkey; Type: CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.process_steps
    ADD CONSTRAINT process_steps_pkey PRIMARY KEY (stepid);


--
-- Name: processes processes_pkey; Type: CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.processes
    ADD CONSTRAINT processes_pkey PRIMARY KEY (pid);


--
-- Name: processes_subscriptions processes_subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.processes_subscriptions
    ADD CONSTRAINT processes_subscriptions_pkey PRIMARY KEY (id);


--
-- Name: product_block_relations product_block_relations_pkey; Type: CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.product_block_relations
    ADD CONSTRAINT product_block_relations_pkey PRIMARY KEY (in_use_by_id, depends_on_id);


--
-- Name: product_block_resource_types product_block_resource_types_pkey; Type: CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.product_block_resource_types
    ADD CONSTRAINT product_block_resource_types_pkey PRIMARY KEY (product_block_id, resource_type_id);


--
-- Name: product_blocks product_blocks_name_key; Type: CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.product_blocks
    ADD CONSTRAINT product_blocks_name_key UNIQUE (name);


--
-- Name: product_blocks product_blocks_pkey; Type: CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.product_blocks
    ADD CONSTRAINT product_blocks_pkey PRIMARY KEY (product_block_id);


--
-- Name: product_product_blocks product_product_blocks_pkey; Type: CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.product_product_blocks
    ADD CONSTRAINT product_product_blocks_pkey PRIMARY KEY (product_id, product_block_id);


--
-- Name: products products_name_key; Type: CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_name_key UNIQUE (name);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (product_id);


--
-- Name: products_workflows products_workflows_pkey; Type: CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.products_workflows
    ADD CONSTRAINT products_workflows_pkey PRIMARY KEY (product_id, workflow_id);


--
-- Name: resource_types resource_types_pkey; Type: CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.resource_types
    ADD CONSTRAINT resource_types_pkey PRIMARY KEY (resource_type_id);


--
-- Name: resource_types resource_types_resource_type_key; Type: CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.resource_types
    ADD CONSTRAINT resource_types_resource_type_key UNIQUE (resource_type);


--
-- Name: subscription_customer_descriptions subscription_customer_descriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.subscription_customer_descriptions
    ADD CONSTRAINT subscription_customer_descriptions_pkey PRIMARY KEY (id);


--
-- Name: subscription_instance_relations subscription_instance_relations_pkey; Type: CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.subscription_instance_relations
    ADD CONSTRAINT subscription_instance_relations_pkey PRIMARY KEY (in_use_by_id, depends_on_id, order_id);


--
-- Name: subscription_instance_values subscription_instance_values_pkey; Type: CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.subscription_instance_values
    ADD CONSTRAINT subscription_instance_values_pkey PRIMARY KEY (subscription_instance_value_id);


--
-- Name: subscription_instances subscription_instances_pkey; Type: CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.subscription_instances
    ADD CONSTRAINT subscription_instances_pkey PRIMARY KEY (subscription_instance_id);


--
-- Name: subscriptions subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_pkey PRIMARY KEY (subscription_id);


--
-- Name: subscription_customer_descriptions uniq_customer_subscription_description; Type: CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.subscription_customer_descriptions
    ADD CONSTRAINT uniq_customer_subscription_description UNIQUE (customer_id, subscription_id);


--
-- Name: workflows workflows_name_key; Type: CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.workflows
    ADD CONSTRAINT workflows_name_key UNIQUE (name);


--
-- Name: workflows workflows_pkey; Type: CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.workflows
    ADD CONSTRAINT workflows_pkey PRIMARY KEY (workflow_id);


--
-- Name: ix_process_steps_pid; Type: INDEX; Schema: public; Owner: nwa
--

CREATE INDEX ix_process_steps_pid ON public.process_steps USING btree (pid);


--
-- Name: ix_processes_is_task; Type: INDEX; Schema: public; Owner: nwa
--

CREATE INDEX ix_processes_is_task ON public.processes USING btree (is_task);


--
-- Name: ix_processes_pid; Type: INDEX; Schema: public; Owner: nwa
--

CREATE INDEX ix_processes_pid ON public.processes USING btree (pid);


--
-- Name: ix_processes_subscriptions_pid; Type: INDEX; Schema: public; Owner: nwa
--

CREATE INDEX ix_processes_subscriptions_pid ON public.processes_subscriptions USING btree (pid);


--
-- Name: ix_processes_subscriptions_subscription_id; Type: INDEX; Schema: public; Owner: nwa
--

CREATE INDEX ix_processes_subscriptions_subscription_id ON public.processes_subscriptions USING btree (subscription_id);


--
-- Name: ix_products_tag; Type: INDEX; Schema: public; Owner: nwa
--

CREATE INDEX ix_products_tag ON public.products USING btree (tag);


--
-- Name: ix_subscription_customer_descriptions_customer_id; Type: INDEX; Schema: public; Owner: nwa
--

CREATE INDEX ix_subscription_customer_descriptions_customer_id ON public.subscription_customer_descriptions USING btree (customer_id);


--
-- Name: ix_subscription_customer_descriptions_subscription_id; Type: INDEX; Schema: public; Owner: nwa
--

CREATE INDEX ix_subscription_customer_descriptions_subscription_id ON public.subscription_customer_descriptions USING btree (subscription_id);


--
-- Name: ix_subscription_instance_values_resource_type_id; Type: INDEX; Schema: public; Owner: nwa
--

CREATE INDEX ix_subscription_instance_values_resource_type_id ON public.subscription_instance_values USING btree (resource_type_id);


--
-- Name: ix_subscription_instance_values_subscription_instance_id; Type: INDEX; Schema: public; Owner: nwa
--

CREATE INDEX ix_subscription_instance_values_subscription_instance_id ON public.subscription_instance_values USING btree (subscription_instance_id);


--
-- Name: ix_subscription_instances_product_block_id; Type: INDEX; Schema: public; Owner: nwa
--

CREATE INDEX ix_subscription_instances_product_block_id ON public.subscription_instances USING btree (product_block_id);


--
-- Name: ix_subscription_instances_subscription_id; Type: INDEX; Schema: public; Owner: nwa
--

CREATE INDEX ix_subscription_instances_subscription_id ON public.subscription_instances USING btree (subscription_id);


--
-- Name: ix_subscriptions_customer_id; Type: INDEX; Schema: public; Owner: nwa
--

CREATE INDEX ix_subscriptions_customer_id ON public.subscriptions USING btree (customer_id);


--
-- Name: ix_subscriptions_product_id; Type: INDEX; Schema: public; Owner: nwa
--

CREATE INDEX ix_subscriptions_product_id ON public.subscriptions USING btree (product_id);


--
-- Name: ix_subscriptions_status; Type: INDEX; Schema: public; Owner: nwa
--

CREATE INDEX ix_subscriptions_status ON public.subscriptions USING btree (status);


--
-- Name: processes_subscriptions_ix; Type: INDEX; Schema: public; Owner: nwa
--

CREATE INDEX processes_subscriptions_ix ON public.processes_subscriptions USING btree (pid, subscription_id);


--
-- Name: product_block_relation_i_d_ix; Type: INDEX; Schema: public; Owner: nwa
--

CREATE UNIQUE INDEX product_block_relation_i_d_ix ON public.product_block_relations USING btree (in_use_by_id, depends_on_id);


--
-- Name: siv_si_rt_ix; Type: INDEX; Schema: public; Owner: nwa
--

CREATE INDEX siv_si_rt_ix ON public.subscription_instance_values USING btree (subscription_instance_value_id, subscription_instance_id, resource_type_id);


--
-- Name: subscription_customer_ix; Type: INDEX; Schema: public; Owner: nwa
--

CREATE INDEX subscription_customer_ix ON public.subscriptions USING btree (subscription_id, customer_id);


--
-- Name: subscription_instance_s_pb_ix; Type: INDEX; Schema: public; Owner: nwa
--

CREATE INDEX subscription_instance_s_pb_ix ON public.subscription_instances USING btree (subscription_instance_id, subscription_id, product_block_id);


--
-- Name: subscription_product_ix; Type: INDEX; Schema: public; Owner: nwa
--

CREATE INDEX subscription_product_ix ON public.subscriptions USING btree (subscription_id, product_id);


--
-- Name: subscription_relation_i_d_o_ix; Type: INDEX; Schema: public; Owner: nwa
--

CREATE UNIQUE INDEX subscription_relation_i_d_o_ix ON public.subscription_instance_relations USING btree (in_use_by_id, depends_on_id, order_id);


--
-- Name: subscription_tsv_ix; Type: INDEX; Schema: public; Owner: nwa
--

CREATE INDEX subscription_tsv_ix ON public.subscriptions USING gin (tsv);


--
-- Name: fixed_inputs fixed_inputs_trigger; Type: TRIGGER; Schema: public; Owner: nwa
--

CREATE TRIGGER fixed_inputs_trigger AFTER INSERT OR UPDATE ON public.fixed_inputs FOR EACH ROW EXECUTE PROCEDURE public.fixed_inputs_trigger();


--
-- Name: products products_trigger; Type: TRIGGER; Schema: public; Owner: nwa
--

CREATE TRIGGER products_trigger AFTER INSERT OR UPDATE ON public.products FOR EACH ROW EXECUTE PROCEDURE public.products_trigger();


--
-- Name: subscription_customer_descriptions subscription_customer_descriptions_trigger; Type: TRIGGER; Schema: public; Owner: nwa
--

CREATE TRIGGER subscription_customer_descriptions_trigger AFTER INSERT OR UPDATE ON public.subscription_customer_descriptions FOR EACH ROW EXECUTE PROCEDURE public.subscription_customer_descriptions_trigger();


--
-- Name: subscription_instance_values subscription_instance_values_trigger; Type: TRIGGER; Schema: public; Owner: nwa
--

CREATE TRIGGER subscription_instance_values_trigger AFTER INSERT OR UPDATE ON public.subscription_instance_values FOR EACH ROW EXECUTE PROCEDURE public.subscription_instance_values_trigger();


--
-- Name: subscriptions subscriptions_ins_trigger; Type: TRIGGER; Schema: public; Owner: nwa
--

CREATE TRIGGER subscriptions_ins_trigger BEFORE INSERT ON public.subscriptions FOR EACH ROW EXECUTE PROCEDURE public.subscriptions_ins_trigger();


--
-- Name: subscriptions subscriptions_set_tsv_trigger; Type: TRIGGER; Schema: public; Owner: nwa
--

CREATE TRIGGER subscriptions_set_tsv_trigger AFTER UPDATE ON public.subscriptions FOR EACH ROW WHEN ((new.tsv IS NULL)) EXECUTE PROCEDURE public.subscriptions_set_tsv_trigger();


--
-- Name: subscriptions subscriptions_upd_trigger; Type: TRIGGER; Schema: public; Owner: nwa
--

CREATE TRIGGER subscriptions_upd_trigger AFTER UPDATE ON public.subscriptions FOR EACH ROW WHEN ((NOT (old.tsv IS DISTINCT FROM new.tsv))) EXECUTE PROCEDURE public.subscriptions_upd_trigger();


--
-- Name: fixed_inputs fixed_inputs_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.fixed_inputs
    ADD CONSTRAINT fixed_inputs_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(product_id) ON DELETE CASCADE;


--
-- Name: process_steps process_steps_pid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.process_steps
    ADD CONSTRAINT process_steps_pid_fkey FOREIGN KEY (pid) REFERENCES public.processes(pid) ON DELETE CASCADE;


--
-- Name: processes_subscriptions processes_subscriptions_pid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.processes_subscriptions
    ADD CONSTRAINT processes_subscriptions_pid_fkey FOREIGN KEY (pid) REFERENCES public.processes(pid) ON DELETE CASCADE;


--
-- Name: processes_subscriptions processes_subscriptions_subscription_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.processes_subscriptions
    ADD CONSTRAINT processes_subscriptions_subscription_id_fkey FOREIGN KEY (subscription_id) REFERENCES public.subscriptions(subscription_id);


--
-- Name: product_block_relations product_block_relations_depends_on_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.product_block_relations
    ADD CONSTRAINT product_block_relations_depends_on_id_fkey FOREIGN KEY (depends_on_id) REFERENCES public.product_blocks(product_block_id) ON DELETE CASCADE;


--
-- Name: product_block_relations product_block_relations_in_use_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.product_block_relations
    ADD CONSTRAINT product_block_relations_in_use_by_id_fkey FOREIGN KEY (in_use_by_id) REFERENCES public.product_blocks(product_block_id) ON DELETE CASCADE;


--
-- Name: product_block_resource_types product_block_resource_types_product_block_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.product_block_resource_types
    ADD CONSTRAINT product_block_resource_types_product_block_id_fkey FOREIGN KEY (product_block_id) REFERENCES public.product_blocks(product_block_id) ON DELETE CASCADE;


--
-- Name: product_block_resource_types product_block_resource_types_resource_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.product_block_resource_types
    ADD CONSTRAINT product_block_resource_types_resource_type_id_fkey FOREIGN KEY (resource_type_id) REFERENCES public.resource_types(resource_type_id) ON DELETE CASCADE;


--
-- Name: product_product_blocks product_product_blocks_product_block_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.product_product_blocks
    ADD CONSTRAINT product_product_blocks_product_block_id_fkey FOREIGN KEY (product_block_id) REFERENCES public.product_blocks(product_block_id) ON DELETE CASCADE;


--
-- Name: product_product_blocks product_product_blocks_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.product_product_blocks
    ADD CONSTRAINT product_product_blocks_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(product_id) ON DELETE CASCADE;


--
-- Name: products_workflows products_workflows_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.products_workflows
    ADD CONSTRAINT products_workflows_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(product_id) ON DELETE CASCADE;


--
-- Name: products_workflows products_workflows_workflow_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.products_workflows
    ADD CONSTRAINT products_workflows_workflow_id_fkey FOREIGN KEY (workflow_id) REFERENCES public.workflows(workflow_id) ON DELETE CASCADE;


--
-- Name: subscription_customer_descriptions subscription_customer_descriptions_subscription_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.subscription_customer_descriptions
    ADD CONSTRAINT subscription_customer_descriptions_subscription_id_fkey FOREIGN KEY (subscription_id) REFERENCES public.subscriptions(subscription_id) ON DELETE CASCADE;


--
-- Name: subscription_instance_relations subscription_instance_relations_depends_on_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.subscription_instance_relations
    ADD CONSTRAINT subscription_instance_relations_depends_on_id_fkey FOREIGN KEY (depends_on_id) REFERENCES public.subscription_instances(subscription_instance_id) ON DELETE CASCADE;


--
-- Name: subscription_instance_relations subscription_instance_relations_in_use_by_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.subscription_instance_relations
    ADD CONSTRAINT subscription_instance_relations_in_use_by_id_fkey FOREIGN KEY (in_use_by_id) REFERENCES public.subscription_instances(subscription_instance_id) ON DELETE CASCADE;


--
-- Name: subscription_instance_values subscription_instance_values_resource_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.subscription_instance_values
    ADD CONSTRAINT subscription_instance_values_resource_type_id_fkey FOREIGN KEY (resource_type_id) REFERENCES public.resource_types(resource_type_id);


--
-- Name: subscription_instance_values subscription_instance_values_subscription_instance_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.subscription_instance_values
    ADD CONSTRAINT subscription_instance_values_subscription_instance_id_fkey FOREIGN KEY (subscription_instance_id) REFERENCES public.subscription_instances(subscription_instance_id) ON DELETE CASCADE;


--
-- Name: subscription_instances subscription_instances_product_block_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.subscription_instances
    ADD CONSTRAINT subscription_instances_product_block_id_fkey FOREIGN KEY (product_block_id) REFERENCES public.product_blocks(product_block_id);


--
-- Name: subscription_instances subscription_instances_subscription_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.subscription_instances
    ADD CONSTRAINT subscription_instances_subscription_id_fkey FOREIGN KEY (subscription_id) REFERENCES public.subscriptions(subscription_id) ON DELETE CASCADE;


--
-- Name: subscriptions subscriptions_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: nwa
--

ALTER TABLE ONLY public.subscriptions
    ADD CONSTRAINT subscriptions_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- PostgreSQL database dump complete
--

