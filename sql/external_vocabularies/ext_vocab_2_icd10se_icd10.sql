---------------------------------------------------------------
-- ICD-10-SE to ICD-10 (WHO) mapping table
---------------------------------------------------------------
-- Builds icd10se_icd10 from Socialstyrelsen's ICD-10-SE code list (loaded into
-- icd10se_codes by 02_setup_ext_vocab.R) and the Athena ICD10 vocabulary in the CDM.
--
-- Rule ("truncation to the nearest parent"): each ICD-10-SE code is mapped to its
-- longest prefix that is a valid Athena ICD10 code, e.g.
--   A08.3A -> A08.3   (Swedish national extension)
--   X65.69 -> X65     (Swedish place/activity extension of an external cause)
-- Valid Athena ICD10 codes that are not in the ICD-10-SE list are added mapped to
-- themselves, so that WHO codes occurring in the registers are also covered.
--
-- Placeholders: {{EXT_VOCAB_SCHEMA}}, {{CDM_SCHEMA}}
---------------------------------------------------------------

DROP TABLE IF EXISTS {{EXT_VOCAB_SCHEMA}}.icd10se_icd10;

CREATE TABLE {{EXT_VOCAB_SCHEMA}}.icd10se_icd10 AS
WITH icd10 AS (
    -- valid Athena ICD10 codes (letter + two characters, e.g. A00, A00.0); excludes
    -- chapter and block ranges such as A00-A09
    SELECT concept_code, concept_name
    FROM {{CDM_SCHEMA}}.concept
    WHERE vocabulary_id = 'ICD10'
      AND invalid_reason IS NULL
      AND concept_code ~ '^[A-Z][0-9][0-9A-Z]'
      AND concept_code !~ '-'
),
se AS (
    -- ICD-10-SE codes: rows with a title, without chapter and section-range codes
    -- (same filters as mapping_table.R); the file repeats codes on rows without title
    SELECT DISTINCT ON (kod)
        kod                      AS icd10_se,
        titel                    AS title_se,
        kodniva_kodspecifikation
    FROM {{EXT_VOCAB_SCHEMA}}.icd10se_codes
    WHERE COALESCE(titel, '') <> ''
      AND COALESCE(kodniva_kodspecifikation, '') NOT IN ('Kapitelkod', 'Avsnittskod, kodintervall')
    ORDER BY kod, titel
),
best AS (
    -- longest prefix (at least 3 characters) that is a valid ICD10 code
    SELECT DISTINCT ON (se.icd10_se)
        se.icd10_se,
        i.concept_code,
        i.concept_name
    FROM se
    CROSS JOIN LATERAL generate_series(length(se.icd10_se), 3, -1) AS p(n)
    JOIN icd10 i
        ON i.concept_code = left(se.icd10_se, p.n)
    ORDER BY se.icd10_se, p.n DESC
)
SELECT
    se.icd10_se,
    length(se.icd10_se)        AS icd10_se_length,
    b.concept_code             AS icd10_se_map,   -- truncated code (= icd10_who_map)
    b.concept_code             AS icd10_who_map,  -- NULL when no prefix is an ICD10 code
    se.title_se,
    b.concept_name             AS title_who,
    se.kodniva_kodspecifikation
FROM se
LEFT JOIN best b
    ON b.icd10_se = se.icd10_se
UNION ALL
SELECT
    i.concept_code,
    length(i.concept_code),
    i.concept_code,
    i.concept_code,
    NULL,
    i.concept_name,
    NULL
FROM icd10 i
WHERE NOT EXISTS (SELECT 1 FROM se WHERE se.icd10_se = i.concept_code);
