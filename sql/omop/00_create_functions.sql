CREATE SCHEMA IF NOT EXISTS etl_common;

CREATE OR REPLACE FUNCTION etl_common.parse_par_date(
    raw_value text,
    partial_date_rule text DEFAULT 'exact'
)
RETURNS date
LANGUAGE sql
IMMUTABLE
AS $function$
WITH cleaned AS (
    SELECT
        NULLIF(BTRIM(raw_value), '') AS v,
        LOWER(BTRIM(partial_date_rule)) AS rule
),

parts AS (
    SELECT
        v,
        rule,
        LENGTH(v) AS len,

        CASE
            WHEN v ~ '^[0-9]{4}$'
              OR v ~ '^[0-9]{6}$'
              OR v ~ '^[0-9]{8}$'
                THEN SUBSTRING(v FROM 1 FOR 4)::int
        END AS yyyy,

        CASE
            WHEN v ~ '^[0-9]{6}$'
              OR v ~ '^[0-9]{8}$'
                THEN SUBSTRING(v FROM 5 FOR 2)::int
        END AS mm,

        CASE
            WHEN v ~ '^[0-9]{8}$'
                THEN SUBSTRING(v FROM 7 FOR 2)::int
        END AS dd
    FROM cleaned
),

validated AS (
    SELECT
        *,
        yyyy BETWEEN 1 AND 9999 AS valid_year,
        yyyy BETWEEN 1 AND 9999
            AND mm BETWEEN 1 AND 12 AS valid_year_month
    FROM parts
),

month_info AS (
    SELECT
        *,
        CASE
            WHEN valid_year_month THEN
                EXTRACT(
                    DAY FROM (
                        make_date(yyyy, mm, 1)
                        + INTERVAL '1 month - 1 day'
                    )
                )::int
        END AS last_day
    FROM validated
),

date_validated AS (
    SELECT
        *,
        valid_year_month
            AND dd BETWEEN 1 AND last_day AS valid_year_month_day
    FROM month_info
)

SELECT
    CASE
        WHEN v IS NULL THEN NULL::date

        -- Invalid rule name
        WHEN rule NOT IN ('exact', 'period_start', 'period_end', 'midpoint')
            THEN NULL::date

        -- YYYY: year known only
        WHEN len = 4
             AND valid_year
             AND rule = 'period_start'
            THEN make_date(yyyy, 1, 1)

        WHEN len = 4
             AND valid_year
             AND rule = 'period_end'
            THEN make_date(yyyy, 12, 31)

        WHEN len = 4
             AND valid_year
             AND rule = 'midpoint'
            THEN make_date(yyyy, 6, 30)

        -- YYYYMM: year and month known
        WHEN len = 6
             AND valid_year_month
             AND rule = 'period_start'
            THEN make_date(yyyy, mm, 1)

        WHEN len = 6
             AND valid_year_month
             AND rule = 'period_end'
            THEN make_date(yyyy, mm, last_day)

        WHEN len = 6
             AND valid_year_month
             AND rule = 'midpoint'
            THEN make_date(yyyy, mm, 15)

        -- YYYY0000: year known, month/day unknown
        WHEN len = 8
             AND valid_year
             AND mm = 0
             AND dd = 0
             AND rule = 'period_start'
            THEN make_date(yyyy, 1, 1)

        WHEN len = 8
             AND valid_year
             AND mm = 0
             AND dd = 0
             AND rule = 'period_end'
            THEN make_date(yyyy, 12, 31)

        WHEN len = 8
             AND valid_year
             AND mm = 0
             AND dd = 0
             AND rule = 'midpoint'
            THEN make_date(yyyy, 6, 30)

        -- YYYYMM00: year and month known, day unknown
        WHEN len = 8
             AND valid_year_month
             AND dd = 0
             AND rule = 'period_start'
            THEN make_date(yyyy, mm, 1)

        WHEN len = 8
             AND valid_year_month
             AND dd = 0
             AND rule = 'period_end'
            THEN make_date(yyyy, mm, last_day)

        WHEN len = 8
             AND valid_year_month
             AND dd = 0
             AND rule = 'midpoint'
            THEN make_date(yyyy, mm, 15)

        -- Full valid YYYYMMDD
        -- Invalid Feb 29 in non-leap year: coerce to Feb 28
        WHEN len = 8
            AND valid_year
            AND mm = 2
            AND dd = 29
            AND last_day = 28
           THEN make_date(yyyy, 2, 28)
           
        WHEN len = 8
             AND valid_year_month_day
            THEN make_date(yyyy, mm, dd)

        ELSE NULL::date
    END
FROM date_validated
$function$;


CREATE OR REPLACE FUNCTION etl_common.get_icd10se_map()
RETURNS TABLE (
    icd10_se text,
    standard_concept_id integer,
    target_domain_id text
)
LANGUAGE sql
STABLE
AS $function$
    SELECT
        m.icd10_se,
        MIN(m.standard_concept_id) AS standard_concept_id,
        c.domain_id AS target_domain_id
    FROM {{EXT_VOCAB_SCHEMA}}.icd10_se_who_snomed_map m
    JOIN {{OUTPUT_SCHEMA}}.concept c
        ON c.concept_id = m.standard_concept_id
    WHERE m.standard_concept_id IS NOT NULL
      AND c.standard_concept = 'S'
      AND c.invalid_reason IS NULL
    GROUP BY
        m.icd10_se,
        c.domain_id
$function$;


CREATE OR REPLACE FUNCTION etl_common.get_icd10_map()
RETURNS TABLE (
    code text,
    standard_concept_id integer,
    target_domain_id text
)
LANGUAGE sql
STABLE
AS $function$
    SELECT
        regexp_replace(upper(btrim(m.icd10_who)), '\.', '', 'g')::text AS code,
        MIN(m.standard_concept_id)::integer AS standard_concept_id,
        c.domain_id::text AS target_domain_id
    FROM {{EXT_VOCAB_SCHEMA}}.icd10_who_snomed_map m
    JOIN {{OUTPUT_SCHEMA}}.concept c
        ON c.concept_id = m.standard_concept_id
    WHERE m.standard_concept_id IS NOT NULL
      AND c.standard_concept = 'S'
      AND c.invalid_reason IS NULL
    GROUP BY
        regexp_replace(upper(btrim(m.icd10_who)), '\.', '', 'g'),
        c.domain_id
$function$;

CREATE OR REPLACE FUNCTION etl_common.get_icdo3_map()
RETURNS TABLE (
    icdo3 text,
    standard_concept_id integer,
    target_domain_id text
)
LANGUAGE sql
STABLE
AS $function$
    SELECT
        c_source.concept_code::text AS icdo3,
        MIN(c_standard.concept_id)::integer AS standard_concept_id,
        c_standard.domain_id::text AS target_domain_id
    FROM {{OUTPUT_SCHEMA}}.concept c_source
    JOIN {{OUTPUT_SCHEMA}}.concept_relationship cr
        ON cr.concept_id_1 = c_source.concept_id
       AND cr.relationship_id = 'Maps to'
       AND cr.invalid_reason IS NULL
    JOIN {{OUTPUT_SCHEMA}}.concept c_standard
        ON c_standard.concept_id = cr.concept_id_2
       AND c_standard.standard_concept = 'S'
       AND c_standard.invalid_reason IS NULL
    WHERE c_source.vocabulary_id = 'ICDO3'
      AND c_source.invalid_reason IS NULL
    GROUP BY
        c_source.concept_code,
        c_standard.domain_id
$function$;

