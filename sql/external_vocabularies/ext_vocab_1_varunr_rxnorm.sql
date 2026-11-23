-- VARUNR - RxNorm + RxNorm extensions conversion script 
-- Maps VARUNR to RxNorm and RxNorm Extension through externally sourced NPLID mapping file (loaded into nplid_rxnorm
-- by 02_setup_ext_vocab.R), matching on product name + form + strength.
-- Mapping quality is measured by R/mapping_quality/run_drug_mapping_quality.R.
-- This script creates the 'varunr_to_concept_final' table to be used in the OMOP mapping pipeline
-- with drug_source_value (varunr, the mapping key), drug_concept_id (dst_val from externally sourced mapping file), produkt, and descriptors
-- Placeholders: {{INPUT_SCHEMA}}, {{EXT_VOCAB_SCHEMA}}


-- Create a RxNorm + RxNorm extensions mapping vocabulary
-- Product descriptors per VARUNR, taken from the input lmed table. This replaces
-- clean.produkt_db, which no longer exists and was a SELECT DISTINCT of the same
-- columns from raw lmed.
-- - produkt, styrkalf, and lform are the variables actually used for the mapping
-- - varunr, and subnamn are stored for convenience, but don't have a role in the mapping
-- temp_produkt is only needed while this script runs, so it is a TEMP table
-- (dropped automatically at the end of the session). Earlier versions created it
-- as a permanent table in the external vocabulary schema: drop that leftover.
DROP TABLE IF EXISTS {{EXT_VOCAB_SCHEMA}}.temp_produkt;
DROP TABLE IF EXISTS pg_temp.temp_produkt;

CREATE TEMP TABLE temp_produkt AS
SELECT DISTINCT
    varunr::TEXT AS varunr,
    produkt,
    lform,
    styrkalf,
    subnamn
FROM {{INPUT_SCHEMA}}.lmed
WHERE varunr IS NOT NULL;

-- Remove trademarks from 'produkt' to match with externally sourced NPLID mapping file 
UPDATE pg_temp.temp_produkt
SET produkt = REPLACE(produkt, '®', '');
-- replace , with . in styrkalf for marchting with externally sourced NPLID mapping file 
UPDATE pg_temp.temp_produkt
SET styrkalf = REPLACE(styrkalf, ',', '.');

-- Create ext_vocab.varunr_rxnorm with produkt rows that are mapped to RxNorm + RxNorm extensions by externally sourced NPLID mapping file
DROP TABLE IF EXISTS {{EXT_VOCAB_SCHEMA}}.varunr_rxnorm;

CREATE TABLE {{EXT_VOCAB_SCHEMA}}.varunr_rxnorm AS
SELECT DISTINCT
   v.varunr,
   v.produkt,
   v.lform,
   v.styrkalf,
   n.src_desc_raw_product_name,
   n.src_desc_formtext_sv,
   n.src_desc_strengthtext_original
FROM pg_temp.temp_produkt v
INNER JOIN {{EXT_VOCAB_SCHEMA}}.nplid_rxnorm n
  ON v.produkt = n.src_desc_raw_product_name
 AND v.lform = n.src_desc_formtext_sv
 AND v.styrkalf = n.src_desc_strengthtext_original;

-- Store unmapped rows 
DROP TABLE IF EXISTS {{EXT_VOCAB_SCHEMA}}.varunr_rxnorm_out;

CREATE TABLE {{EXT_VOCAB_SCHEMA}}.varunr_rxnorm_out AS
SELECT DISTINCT
   v.varunr,
   v.produkt,
   v.lform,
   v.styrkalf
FROM pg_temp.temp_produkt v
WHERE NOT EXISTS (
	SELECT 1
	FROM {{EXT_VOCAB_SCHEMA}}.varunr_rxnorm m
	WHERE m.varunr = v.varunr
);


----------------------------------------------------------------------
-- Build ext_vocab.varunr_to_concept for OMOP mapping 
----------------------------------------------------------------------
-- Build mapping table including RxNorm related field (from externally sourced NPLID mapping file)
DROP TABLE IF EXISTS {{EXT_VOCAB_SCHEMA}}.varunr_to_concept;

CREATE TABLE {{EXT_VOCAB_SCHEMA}}.varunr_to_concept AS
SELECT DISTINCT ON(
	v.varunr
)
	v.varunr, 
	n.dst_val::INTEGER AS drug_concept_id, -- OMOP target
	v.varunr AS drug_source_value,
	v.produkt,
	v.lform,
	v.styrkalf, 
	n.dst_desc, -- keep for debugging
	n.dst_class, -- keep for debugging
	n.dst_vocab -- keep for debugging
FROM pg_temp.temp_produkt v
INNER JOIN {{EXT_VOCAB_SCHEMA}}.nplid_rxnorm n
	ON v.produkt = n.src_desc_raw_product_name
	AND v.lform = n.src_desc_formtext_sv
	AND v.styrkalf = n.src_desc_strengthtext_original
ORDER BY 
	v.varunr, 
	CASE 
		WHEN n.dst_class = 'Clinical Drug' THEN 1
		WHEN n.dst_class = 'Clinical Drug Comp' THEN 2
		WHEN n.dst_class = 'Clinical Drug Form' THEN 3
		WHEN n.dst_class = 'Ingredient' THEN 4
	END; -- hierarchical fallback approach: when the best mapping exists, use Clinical Drug, otherise fallback to less complete mappings

-- Handle unmapped
DROP TABLE IF EXISTS {{EXT_VOCAB_SCHEMA}}.varunr_to_concept_unmapped;

CREATE TABLE {{EXT_VOCAB_SCHEMA}}.varunr_to_concept_unmapped AS
SELECT 
	v.varunr AS drug_source_value, 
	0 AS drug_concept_id, 
	v.produkt
FROM {{EXT_VOCAB_SCHEMA}}.varunr_rxnorm_out v;

-- Merge mapped + unmapped for a final table
-- UNION ALL matches columns by position, so both SELECTs must list them in the same order
DROP TABLE IF EXISTS {{EXT_VOCAB_SCHEMA}}.varunr_to_concept_final;

CREATE TABLE {{EXT_VOCAB_SCHEMA}}.varunr_to_concept_final AS
SELECT
    drug_source_value::TEXT,  drug_concept_id::INTEGER, produkt::TEXT, lform, styrkalf, dst_class
FROM {{EXT_VOCAB_SCHEMA}}.varunr_to_concept
UNION ALL
SELECT
    drug_source_value::TEXT, drug_concept_id::INTEGER, produkt::TEXT, NULL::TEXT AS lform, NULL::TEXT AS styrkalf, NULL::TEXT AS dst_class
FROM {{EXT_VOCAB_SCHEMA}}.varunr_to_concept_unmapped;