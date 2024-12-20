-- Copyright (c) 2013-2021, Todd M. Kover
-- All rights reserved.
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--       http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

\set ON_ERROR_STOP

DO $$
DECLARE
        _tal INTEGER;
BEGIN
        select count(*)
        from pg_catalog.pg_namespace
        into _tal
        where nspname = 'dns_utils';
        IF _tal = 0 THEN
                DROP SCHEMA IF EXISTS dns_utils;
                CREATE SCHEMA dns_utils AUTHORIZATION jazzhands;
		REVOKE ALL ON SCHEMA dns_utils FROM public;
		COMMENT ON SCHEMA dns_utils IS 'part of jazzhands';
        END IF;
END;
$$;

------------------------------------------------------------------------------
--
-- This is migrating to dns_manip
--
------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION dns_utils.add_ns_records(
	dns_domain_id	dns_domain.dns_domain_id%type,
	purge			boolean DEFAULT false
) RETURNS void AS
$$
BEGIN
	PERFORM dns_manip.add_ns_records(dns_domain_id, purge);
END;
$$
SET search_path=jazzhands
LANGUAGE plpgsql;

------------------------------------------------------------------------------
--
-- Given a cidr block, returns a list of all in-addr zones for that block.
-- Note that for ip6, it just makes it a /64.  This may or may not be correct.
--
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dns_utils.get_all_domains_for_cidr(
	block		netblock.ip_address%TYPE
) returns text[]
AS
$$
DECLARE
	cur			inet;
	rv			text[];
BEGIN
	IF family(block) = 4 THEN
		IF (masklen(block) >= 24) THEN
			rv = rv || dns_utils.get_domain_from_cidr(set_masklen(block, 24));
		ELSE
			FOR cur IN SELECT set_masklen((block + o), 24)
						FROM generate_series(0, (256 * (2 ^ (24 -
							masklen(block))) - 1)::integer, 256) as x(o)
			LOOP
				rv = rv || dns_utils.get_domain_from_cidr(cur);
			END LOOP;
		END IF;
	ELSIF family(block) = 6 THEN
			-- note sure if we should do this or not, but we are..
			cur := set_masklen(block, 64);
			rv = rv || dns_utils.get_domain_from_cidr(cur);
	ELSE
		RAISE EXCEPTION 'Not IPv% aware.', family(block);
	END IF;
    return rv;
END;
$$
SET search_path=jazzhands
LANGUAGE plpgsql;

------------------------------------------------------------------------------
-- The same as above, but return as rows, rather than an array
--
-- Given a cidr block, returns a list of all in-addr zones for that block.
-- Note that for ip6, it just makes it a /64.  This may or may not be correct.
--
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dns_utils.get_all_domain_rows_for_cidr(
	block		netblock.ip_address%TYPE
) returns TABLE (
	dns_domain_name	text
)
AS
$$
DECLARE
	cur			inet;
BEGIN
	IF family(block) = 4 THEN
		IF (masklen(block) >= 24) THEN
			dns_domain_name := dns_utils.get_domain_from_cidr(set_masklen(block, 24));
			RETURN NEXT;
		ELSE
			FOR cur IN
				SELECT
					set_masklen((block + o), 24)
				FROM
					generate_series(
						0,
						(256 * (2 ^ (24 - masklen(block))) - 1)::integer,
						256)
					AS x(o)
			LOOP
				dns_domain_name := dns_utils.get_domain_from_cidr(cur);
				RETURN NEXT;
			END LOOP;
		END IF;
	ELSIF family(block) = 6 THEN
			-- note sure if we should do this or not, but we are..
			cur := set_masklen(block, 64);
			dns_domain_name := dns_utils.get_domain_from_cidr(cur);
			RETURN NEXT;
	ELSE
		RAISE EXCEPTION 'Not IPv% aware.', family(block);
	END IF;
    return;
END;
$$
SET search_path=jazzhands
LANGUAGE plpgsql;

------------------------------------------------------------------------------
--
-- Given a cidr block, return its dns domain
--
-- Does /24 for v4 and /64 for v6.  (this happens in a called function)
--
-- Works for both v4 and v6
--
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dns_utils.get_domain_from_cidr(
	block		inet
) returns text
AS
$$
DECLARE
	ipaddr		text;
	ipnodes		text[];
	domain		text;
	j			text;
BEGIN
	IF family(block) != 4 THEN
		j := '';
		-- this needs to be tweaked to expand ::, which postgresql does
		-- not easily do.  This requires more thinking than I was up for today.
		ipaddr := net_manip.expand_ipv6_address(block);
		ipaddr := regexp_replace(ipaddr, ':', '', 'g');
		ipaddr := lpad(ipaddr, masklen(block)/4, '0');
	ELSE
		j := '\.';
		ipaddr := host(block);
	END IF;

	EXECUTE 'select array_agg(member order by rn desc)
		from (
        select
			row_number() over () as rn, *
			from
			unnest(regexp_split_to_array($1, $2)) as member
		) x
	' INTO ipnodes USING ipaddr, j;

	IF family(block) = 4 THEN
		domain := array_to_string(ARRAY[ipnodes[2],ipnodes[3],ipnodes[4]], '.')
			|| '.in-addr.arpa';
	ELSE
		domain := array_to_string(ipnodes, '.')
			|| '.ip6.arpa';
	END IF;

	RETURN domain;
END;
$$
SET search_path=jazzhands
LANGUAGE plpgsql;

------------------------------------------------------------------------------
--
-- If the host is an in-addr block, figure out the netblock and setup linkage
-- for it.  This just works on one zone
--
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dns_utils.get_or_create_inaddr_domain_netblock_link(
	dns_domain_name	dns_domain.dns_domain_name%type,
	dns_domain_id	dns_domain.dns_domain_id%type
) RETURNS netblock.netblock_id%type AS $$
DECLARE
	nblk_id	netblock.netblock_id%type;
	blk text;
	root	text;
	brk	text[];
	ipmember text[];
	ip	inet;
	j text;
BEGIN
	brk := regexp_matches(dns_domain_name, '^(.+)\.(in-addr|ip6)\.arpa$');
	IF brk[2] = 'in-addr' THEN
		j := '.';
	ELSE
		j := ':';
	END IF;

	EXECUTE 'select array_agg(member order by rn desc), $2
		from (
        select
			row_number() over () as rn, *
			from
			unnest(regexp_split_to_array($1, $3)) as member
		) x
	' INTO ipmember USING brk[1], j, '\.';

	IF brk[2] = 'in-addr' THEN
		IF array_length(ipmember, 1) > 4 THEN
			RAISE EXCEPTION 'Unable to work with anything smaller than a /24';
		ELSIF array_length(ipmember, 1) != 3 THEN
			-- If this is not a /24, then do not add any rvs association
			RETURN NULL;
		END IF;
		WHILE array_length(ipmember, 1) < 4
		LOOP
			ipmember := array_append(ipmember, '0');
		END LOOP;
		ip := concat(array_to_string(ipmember, j),'/24')::inet;
	ELSE
		ip := concat(
			regexp_replace(
				array_to_string(ipmember, ''), '(....)', '\1:', 'g'),
			':/64')::inet;
	END IF;

	SELECT netblock_id
		INTO	nblk_id
		FROM	netblock
		WHERE	netblock_type = 'dns'
		AND		is_single_address = false
		AND		can_subnet = false
		AND		netblock_status = 'Allocated'
		AND		ip_universe_id = 0
		AND		ip_address = ip;

	IF NOT FOUND THEN
		INSERT INTO netblock (
			ip_address, netblock_type, is_single_address,
			can_subnet, netblock_status, ip_universe_id
		) VALUES (
			ip, 'dns', false,
			false, 'Allocated', 0
		) RETURNING netblock_id INTO nblk_id;
	END IF;

	EXECUTE '
		INSERT INTO dns_record(
			dns_domain_id, dns_class, dns_type, netblock_id
		) values (
			$1, $2, $3, $4
		)
	' USING dns_domain_id, 'IN', 'REVERSE_ZONE_BLOCK_PTR', nblk_id;

	RETURN nblk_id;
END;
$$
SET search_path=jazzhands
LANGUAGE plpgsql;

------------------------------------------------------------------------------
--
-- given a dns domain, type and boolean, add the domain with that type and
-- optionally (tho defaulting to true) at default nameservers
--
-- XXX ip universes need to be folded in better, particularly with reverse
-- and default nameservers
--
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dns_utils.add_dns_domain(
	dns_domain_name		dns_domain.dns_domain_name%type,
	dns_domain_type		dns_domain.dns_domain_type%type DEFAULT NULL,
	ip_universes		integer[] DEFAULT NULL,
	add_nameservers		boolean DEFAULT true
) RETURNS dns_domain.dns_domain_id%type AS $$
DECLARE
	elements		text[];
	parent_zone		text;
	parent_id		dns_domain.dns_domain_id%type;
	domain_id		dns_domain.dns_domain_id%type;
	elem			text;
	sofar			text;
	rvs_nblk_id		netblock.netblock_id%type;
	univ			ip_universe.ip_universe_id%type;
BEGIN
	IF dns_domain_name IS NULL THEN
		RETURN NULL;
	END IF;
	elements := regexp_split_to_array(dns_domain_name, '\.');
	sofar := '';
	FOREACH elem in ARRAY elements
	LOOP
		IF octet_length(sofar) > 0 THEN
			sofar := sofar || '.';
		END IF;
		sofar := sofar || elem;
		parent_zone := regexp_replace(dns_domain_name, '^'||sofar||'.', '');
		EXECUTE 'SELECT dns_domain_id FROM dns_domain
			WHERE dns_domain_name = $1' INTO parent_id USING parent_zone;
		IF parent_id IS NOT NULL THEN
			EXIT;
		END IF;
	END LOOP;

	IF ip_universes IS NULL THEN
		SELECT array_agg(ip_universe_id)
		INTO	ip_universes
		FROM	ip_universe
		WHERE	ip_universe_name = 'default';
	END IF;

	IF dns_domain_type IS NULL THEN
		IF dns_domain_name ~ '^.*(in-addr|ip6)\.arpa$' THEN
			dns_domain_type := 'reverse';
		END IF;
	END IF;

	IF dns_domain_type IS NULL THEN
		RAISE EXCEPTION 'Unable to guess dns_domain_type for %',
			dns_domain_name USING ERRCODE = 'not_null_violation';
	END IF;

	EXECUTE '
		INSERT INTO dns_domain (
			dns_domain_name,
			parent_dns_domain_id,
			dns_domain_type
		) VALUES (
			$1,
			$2,
			$3
		) RETURNING dns_domain_id' INTO domain_id
		USING dns_domain_name,
			parent_id,
			dns_domain_type
	;

	FOREACH univ IN ARRAY ip_universes
	LOOP
		EXECUTE '
			INSERT INTO dns_domain_ip_universe (
				dns_domain_id,
				ip_universe_id,
				soa_class,
				soa_mname,
				soa_rname,
				should_generate
			) VALUES (
				$1,
				$2,
				$3,
				$4,
				$5,
				$6
			);'
			USING domain_id, univ,
				'IN',
				(select property_value from property
					where property_type = 'Defaults'
					and property_name = '_dnsmname' ORDER BY property_id LIMIT 1),
				(select property_value from property
					where property_type = 'Defaults'
					and property_name = '_dnsrname' ORDER BY property_id LIMIT 1),
				true
		;
	END LOOP;

	IF dns_domain_type = 'reverse' THEN
		rvs_nblk_id := dns_utils.get_or_create_inaddr_domain_netblock_link(
			dns_domain_name, domain_id);
	END IF;

	IF add_nameservers THEN
		PERFORM dns_utils.add_ns_records(domain_id);
	END IF;

	--
	-- XXX - need to reconsider how ip universes fit into this.
	IF parent_id IS NOT NULL THEN
		INSERT INTO dns_change_record (
			dns_domain_id
		) SELECT dns_domain_id
		FROM dns_domain
		WHERE dns_domain_id = parent_id
		AND dns_domain_id IN (
			SELECT dns_domain_id
			FROM dns_domain_ip_universe
			WHERE should_generate = true
		);
	END IF;

	RETURN domain_id;
END;
$$
SET search_path=jazzhands
LANGUAGE plpgsql;



------------------------------------------------------------------------------
--
-- Given a cidr block, add a dns domain for it, which will take care of linkage
-- to an in-addr record for ipv4 addresses or ipv6 addresses as appropriate.
--
--
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dns_utils.add_domain_from_cidr(
	block		inet
) returns dns_domain.dns_domain_id%TYPE
AS
$$
DECLARE
	ipaddr		text;
	ipnodes		text[];
	domain		text;
	domain_id	dns_domain.dns_domain_id%TYPE;
	j			text;
BEGIN
	RETURN dns_manip.add_domain_from_cidr(block);
END;
$$
SET search_path=jazzhands
LANGUAGE plpgsql;

------------------------------------------------------------------------------
--
-- Given a netblock, add all the dns domains so in-addr lookups work,
-- including the A<>PTR association magic.
--
-- Works for both v4 and v6
--
-- This is called from the routines that add netblocks to automatically setup
-- DNS
--
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dns_utils.add_domains_from_netblock(
	netblock_id		netblock.netblock_id%TYPE
) returns TABLE(
	dns_domain_id	jazzhands.dns_domain.dns_domain_id%TYPE,
	dns_domain_name		text
)
AS
$$
BEGIN

	RETURN QUERY select *
	FROM jsonb_to_recordset(
                        dns_manip.add_domains_from_netblock ( netblock_id )
                ) AS x(dns_domain_id int, dns_domain_name text)
	;
END;
$$
SET search_path=jazzhands
LANGUAGE plpgsql SECURITY definer;

------------------------------------------------------------------------------
--
-- Given a DNS name, return the host part, the domain part, and the
-- dns_domain_id if it exists
--
-- If no domain is found that matches, then no rows are returned
--
-- if it matches the apex zone, it returns null
--
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dns_utils.find_dns_domain(
	fqdn	text
) returns TABLE(
	dns_name		text,
	dns_domain_name		text,
	dns_domain_id	jazzhands.dns_domain.dns_domain_id%TYPE
)
AS
$$
BEGIN
	IF fqdn !~ '^[^.][a-zA-Z0-9_.-]+[^.]$' THEN
		RAISE EXCEPTION '% is not a valid DNS name', fqdn;
	END IF;

	RETURN QUERY SELECT
		regexp_replace(fqdn, '.' || dd.dns_domain_name || '$', '')::text,
		dd.dns_domain_name::text,
		dd.dns_domain_id
	FROM
		dns_domain dd
	WHERE
		fqdn LIKE ('%.' || dd.dns_domain_name)
	ORDER BY
		length(dd.dns_domain_name) DESC
	LIMIT 1;

	RETURN;
END;
$$
SET search_path=jazzhands
LANGUAGE plpgsql SECURITY DEFINER;

------------------------------------------------------------------------------
--
-- similar to above but return json.
--
--  returns apex zone record if it matches a zone
--
-- The above should go away in favor of this.
--
------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dns_utils.find_dns_domain_from_fqdn(
	fqdn	text
) returns jsonb
AS
$$
DECLARE
	_r	RECORD;
BEGIN
	IF fqdn !~ '^[^.][a-zA-Z0-9_.-]+[^.]$' THEN
		RAISE EXCEPTION '% is not a valid DNS name', fqdn;
	END IF;

	SELECT
		regexp_replace(fqdn, '\.?' || dd.dns_domain_name || '$', '')::text
			as dns_name,
		dd.dns_domain_name::text,
		dd.dns_domain_id
	INTO _r
	FROM
		dns_domain dd
	WHERE fqdn LIKE ('%.' || dd.dns_domain_name)
	OR fqdn = dd.dns_domain_name
	ORDER BY
		length(dd.dns_domain_name) DESC
	LIMIT 1;

	IF _r IS NULL THEN
		RETURN NULL;
	END IF;

	RETURN to_jsonb(_r);
END;
$$
SET search_path=jazzhands
LANGUAGE plpgsql SECURITY DEFINER;

------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dns_utils.v6_inaddr(
	ip_address inet
) RETURNS TEXT
AS
$$
BEGIN
	return trim(trailing '.' from
		regexp_replace(reverse(regexp_replace(
			dns_utils.expand_v6(ip_address), ':', '',
			'g')), '(.)', '\1.', 'g'));
END;
$$
SET search_path=jazzhands
LANGUAGE plpgsql SECURITY INVOKER;

CREATE OR REPLACE FUNCTION dns_utils.expand_v6(
	ip_address inet
) RETURNS TEXT
AS
$$
BEGIN
	RETURN array_to_string(array_agg(lpad(n, 4, '0')), ':') from
	unnest(regexp_split_to_array(
	regexp_replace(
	regexp_replace(host(ip_address)::text,
		'::',
		concat(':', repeat('0:',
			6 -
			(length(regexp_replace(host(ip_address)::text, '::', '')) -
				length(regexp_replace(
					regexp_replace(host(ip_address)::text, '::', ''),
					':',  '', 'g')))::integer
			)) , 'i'),
		':$', ':0'),
	':')) as n;
END;
$$
SET search_path=jazzhands
LANGUAGE plpgsql SECURITY INVOKER;

REVOKE ALL ON SCHEMA dns_utils FROM public;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA dns_utils FROM public;

GRANT ALL ON SCHEMA dns_utils TO iud_role;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA dns_utils TO iud_role;
