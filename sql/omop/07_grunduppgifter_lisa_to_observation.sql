/*
GRUNDUPPGIFTER AND LISA to [OBSERVATION] ETL

Transforms key demograhpic and socieconomic variables from GRUNDUPPGIFTER AND LISA into the OMOP CDM observation table. Diagnosis and external cause (ekod) codes are 
mapped to OMOP standard concepts if available using external source vocabulary:

*/

-- Widen soure value columns to avoid "value too long for type character (50) error"
ALTER TABLE {{OUTPUT_SCHEMA}}.observation
  ALTER COLUMN observation_source_value TYPE varchar(255);

ALTER TABLE {{OUTPUT_SCHEMA}}.observation
  ALTER COLUMN value_source_value TYPE varchar(255);

-- TPR: country of birth
DROP TABLE IF EXISTS routed_tpr;
CREATE TEMP TABLE routed_tpr AS
SELECT p.person_id AS person_id,
  4197735 AS observation_concept_id,
  make_date(g.fodelsear::integer, 01, 01) AS observation_date, -- set to first day of year
	32879 AS observation_type_concept_id, -- registry
	v.observation_source_value AS observation_source_value,
	v.value_as_concept_id AS value_as_concept_id,
	v.value_as_number AS value_as_number,
	v.value_as_string AS value_as_string,
  v.value_source_value AS value_source_value
FROM {{INPUT_SCHEMA}}.grunduppgifter g
INNER JOIN {{OUTPUT_SCHEMA}}.person p  -- restrict to lopnrs in [PERSON]
      ON p.person_id = g.lopnr
LEFT JOIN {{EXT_VOCAB_SCHEMA}}.lisa_tpr_map v
      ON g.fodelseLand_eu27_2020 = v.source_code
	    AND v.source_variable_description = 'country of birth grouped';

-- populate [OBSERVATION]
WITH current_max AS (
    SELECT COALESCE(MAX(observation_id), 0) AS max_id
    FROM {{OUTPUT_SCHEMA}}.observation
)
INSERT INTO {{OUTPUT_SCHEMA}}.observation (
  observation_id,
  person_id,
  observation_concept_id,
  observation_date,
  observation_type_concept_id,
  observation_source_value,
	value_as_concept_id,
	value_as_number,
	value_as_string,
	value_source_value
)
SELECT
  current_max.max_id + ROW_NUMBER() OVER ()::integer,
  person_id AS person_id,
  observation_concept_id AS observation_concept_id,
  observation_date AS observation_date,
  observation_type_concept_id AS observation_type_concept_id,
  observation_source_value AS observation_source_value,
	value_as_concept_id AS value_as_concept_id,
	value_as_number AS value_as_number,
	value_as_string AS value_as_string,
	value_source_value AS value_source_value
FROM routed_tpr
CROSS JOIN current_max;

-- LISA: county of residence 
DROP TABLE IF EXISTS routed_lisa_lan;
CREATE TEMP TABLE routed_lisa_lan (
  person_id BIGINT,
	observation_concept_id INTEGER,
  observation_date DATE,
  observation_type_concept_id INTEGER,
  observation_source_value TEXT,
  value_as_concept_id INTEGER,
  value_as_number NUMERIC,
  value_as_string TEXT,
  value_source_value TEXT
);

INSERT INTO routed_lisa_lan
SELECT
    p.person_id AS person_id,
    4201070 AS observation_concept_id,
    make_date(tbl.yr, 12, 31) AS observation_date,
    32879 AS observation_type_concept_id,
    v.observation_source_value AS observation_source_value,
    NULL::integer AS value_as_concept_id,
    v.value_as_number AS value_as_number,
    NULL::text AS value_as_string,
    v.value_source_value AS value_source_value
FROM (
    SELECT 2005 AS yr, lopnr, lan FROM {{INPUT_SCHEMA}}.lisa_2005
    UNION ALL SELECT 2006, lopnr, lan FROM {{INPUT_SCHEMA}}.lisa_2006
    UNION ALL SELECT 2007, lopnr, lan FROM {{INPUT_SCHEMA}}.lisa_2007
    UNION ALL SELECT 2008, lopnr, lan FROM {{INPUT_SCHEMA}}.lisa_2008
    UNION ALL SELECT 2009, lopnr, lan FROM {{INPUT_SCHEMA}}.lisa_2009
    UNION ALL SELECT 2010, lopnr, lan FROM {{INPUT_SCHEMA}}.lisa_2010
    UNION ALL SELECT 2011, lopnr, lan FROM {{INPUT_SCHEMA}}.lisa_2011
    UNION ALL SELECT 2012, lopnr, lan FROM {{INPUT_SCHEMA}}.lisa_2012
    UNION ALL SELECT 2013, lopnr, lan FROM {{INPUT_SCHEMA}}.lisa_2013
    UNION ALL SELECT 2014, lopnr, lan FROM {{INPUT_SCHEMA}}.lisa_2014
    UNION ALL SELECT 2015, lopnr, lan FROM {{INPUT_SCHEMA}}.lisa_2015
    UNION ALL SELECT 2016, lopnr, lan FROM {{INPUT_SCHEMA}}.lisa_2016
    UNION ALL SELECT 2017, lopnr, lan FROM {{INPUT_SCHEMA}}.lisa_2017
    UNION ALL SELECT 2018, lopnr, lan FROM {{INPUT_SCHEMA}}.lisa_2018
    UNION ALL SELECT 2019, lopnr, lan FROM {{INPUT_SCHEMA}}.lisa_2019
    UNION ALL SELECT 2020, lopnr, lan FROM {{INPUT_SCHEMA}}.lisa_2020
    UNION ALL SELECT 2021, lopnr, lan FROM {{INPUT_SCHEMA}}.lisa_2021
    UNION ALL SELECT 2022, lopnr, lan FROM {{INPUT_SCHEMA}}.lisa_2022
    UNION ALL SELECT 2023, lopnr, lan FROM {{INPUT_SCHEMA}}.lisa_2023
) tbl
INNER JOIN {{OUTPUT_SCHEMA}}.person p  -- restrict to lopnrs in [PERSON]
    ON p.person_id = tbl.lopnr
LEFT JOIN {{EXT_VOCAB_SCHEMA}}.lisa_tpr_map v
    ON tbl.lan = v.value_as_number
    AND v.source_variable_description = 'county of residence';

-- populate [OBSERVATION]
WITH current_max AS (
    SELECT COALESCE(MAX(observation_id), 0) AS max_id
    FROM {{OUTPUT_SCHEMA}}.observation
)
INSERT INTO {{OUTPUT_SCHEMA}}.observation (
  observation_id,
  person_id,
  observation_concept_id,
  observation_date,
  observation_type_concept_id,
  observation_source_value,
	value_as_concept_id,
	value_as_number,
	value_as_string,
	value_source_value
)
SELECT
  current_max.max_id + ROW_NUMBER() OVER ()::integer,
  person_id AS person_id,
  observation_concept_id AS observation_concept_id,
  observation_date AS observation_date,
  observation_type_concept_id AS observation_type_concept_id,
  observation_source_value AS observation_source_value,
	value_as_concept_id AS value_as_concept_id,
	value_as_number AS value_as_number,
	value_as_string AS value_as_string,
	value_source_value AS value_source_value
FROM routed_lisa_lan
CROSS JOIN current_max;

-- LISA: civil status
DROP TABLE IF EXISTS routed_lisa_civil;
CREATE TEMP TABLE routed_lisa_civil (
  person_id BIGINT,
	observation_concept_id INTEGER,
  observation_date DATE,
  observation_type_concept_id INTEGER,
  observation_source_value TEXT,
  value_as_concept_id INTEGER,
  value_as_number NUMERIC,
  value_as_string TEXT,
  value_source_value TEXT
);


INSERT INTO routed_lisa_civil
SELECT
    p.person_id AS person_id,
    4076095 as observation_concept_id,
    make_date(tbl.yr, 12, 31) AS observation_date,
    32879 AS observation_type_concept_id,
    v.observation_source_value AS observation_source_value,
    NULL::integer AS value_as_concept_id,
    v.value_as_number AS value_as_number,
    NULL::text AS value_as_string,
    v.value_source_value AS value_source_value
FROM (
    SELECT 2005 AS yr, lopnr, civil FROM {{INPUT_SCHEMA}}.lisa_2005
    UNION ALL SELECT 2006, lopnr, civil FROM {{INPUT_SCHEMA}}.lisa_2006
    UNION ALL SELECT 2007, lopnr, civil FROM {{INPUT_SCHEMA}}.lisa_2007
    UNION ALL SELECT 2008, lopnr, civil FROM {{INPUT_SCHEMA}}.lisa_2008
    UNION ALL SELECT 2009, lopnr, civil FROM {{INPUT_SCHEMA}}.lisa_2009
    UNION ALL SELECT 2010, lopnr, civil FROM {{INPUT_SCHEMA}}.lisa_2010
    UNION ALL SELECT 2011, lopnr, civil FROM {{INPUT_SCHEMA}}.lisa_2011
    UNION ALL SELECT 2012, lopnr, civil FROM {{INPUT_SCHEMA}}.lisa_2012
    UNION ALL SELECT 2013, lopnr, civil FROM {{INPUT_SCHEMA}}.lisa_2013
    UNION ALL SELECT 2014, lopnr, civil FROM {{INPUT_SCHEMA}}.lisa_2014
    UNION ALL SELECT 2015, lopnr, civil FROM {{INPUT_SCHEMA}}.lisa_2015
    UNION ALL SELECT 2016, lopnr, civil FROM {{INPUT_SCHEMA}}.lisa_2016
    UNION ALL SELECT 2017, lopnr, civil FROM {{INPUT_SCHEMA}}.lisa_2017
    UNION ALL SELECT 2018, lopnr, civil FROM {{INPUT_SCHEMA}}.lisa_2018
    UNION ALL SELECT 2019, lopnr, civil FROM {{INPUT_SCHEMA}}.lisa_2019
    UNION ALL SELECT 2020, lopnr, civil FROM {{INPUT_SCHEMA}}.lisa_2020
    UNION ALL SELECT 2021, lopnr, civil FROM {{INPUT_SCHEMA}}.lisa_2021
    UNION ALL SELECT 2022, lopnr, civil FROM {{INPUT_SCHEMA}}.lisa_2022
    UNION ALL SELECT 2023, lopnr, civil FROM {{INPUT_SCHEMA}}.lisa_2023
) tbl
INNER JOIN {{OUTPUT_SCHEMA}}.person p  -- restrict to lopnrs in [PERSON]
    ON p.person_id = tbl.lopnr
LEFT JOIN {{EXT_VOCAB_SCHEMA}}.lisa_tpr_map v
    ON tbl.civil = v.source_code
    AND v.source_variable_description = 'civil status';

-- populate [OBSERVATION]
WITH current_max AS (
    SELECT COALESCE(MAX(observation_id), 0) AS max_id
    FROM {{OUTPUT_SCHEMA}}.observation
)
INSERT INTO {{OUTPUT_SCHEMA}}.observation (
  observation_id,
  person_id,
  observation_concept_id,
  observation_date,
  observation_type_concept_id,
  observation_source_value,
	value_as_concept_id,
	value_as_number,
	value_as_string,
	value_source_value
)
SELECT
  current_max.max_id + ROW_NUMBER() OVER ()::integer,
  person_id AS person_id,
  observation_concept_id AS observation_concept_id,
  observation_date AS observation_date,
  observation_type_concept_id AS observation_type_concept_id,
  observation_source_value AS observation_source_value,
	value_as_concept_id AS value_as_concept_id,
	value_as_number AS value_as_number,
	value_as_string AS value_as_string,
	value_source_value AS value_source_value
FROM routed_lisa_civil
CROSS JOIN current_max;

-- LISA: education level (2005-2018) 
DROP TABLE IF EXISTS routed_lisa_edu_2005_2018;
CREATE TEMP TABLE routed_lisa_edu_2005_2018 (
  person_id BIGINT,
	observation_concept_id INTEGER,
  observation_date DATE,
  observation_type_concept_id INTEGER,
  observation_source_value TEXT,
  value_as_concept_id INTEGER,
  value_as_number NUMERIC,
  value_as_string TEXT,
  value_source_value TEXT
);

INSERT INTO routed_lisa_edu_2005_2018
SELECT
    p.person_id AS person_id,
		4022643 AS observation_concept_id,
    make_date(tbl.yr, 12, 31) AS observation_date,
    32879 AS observation_type_concept_id,
    v.observation_source_value AS observation_source_value,
    NULL::integer AS value_as_concept_id,
    v.value_as_number AS value_as_number,
    NULL::text AS value_as_string,
    v.value_source_value AS value_source_value
FROM (
    SELECT 2005 AS yr, lopnr, sun2000niva_old FROM {{INPUT_SCHEMA}}.lisa_2005
    UNION ALL SELECT 2006, lopnr, sun2000niva_old FROM {{INPUT_SCHEMA}}.lisa_2006
    UNION ALL SELECT 2007, lopnr, sun2000niva_old FROM {{INPUT_SCHEMA}}.lisa_2007
    UNION ALL SELECT 2008, lopnr, sun2000niva_old FROM {{INPUT_SCHEMA}}.lisa_2008
    UNION ALL SELECT 2009, lopnr, sun2000niva_old FROM {{INPUT_SCHEMA}}.lisa_2009
    UNION ALL SELECT 2010, lopnr, sun2000niva_old FROM {{INPUT_SCHEMA}}.lisa_2010
    UNION ALL SELECT 2011, lopnr, sun2000niva_old FROM {{INPUT_SCHEMA}}.lisa_2011
    UNION ALL SELECT 2012, lopnr, sun2000niva_old FROM {{INPUT_SCHEMA}}.lisa_2012
    UNION ALL SELECT 2013, lopnr, sun2000niva_old FROM {{INPUT_SCHEMA}}.lisa_2013
    UNION ALL SELECT 2014, lopnr, sun2000niva_old FROM {{INPUT_SCHEMA}}.lisa_2014
    UNION ALL SELECT 2015, lopnr, sun2000niva_old FROM {{INPUT_SCHEMA}}.lisa_2015
    UNION ALL SELECT 2016, lopnr, sun2000niva_old FROM {{INPUT_SCHEMA}}.lisa_2016
    UNION ALL SELECT 2017, lopnr, sun2000niva_old FROM {{INPUT_SCHEMA}}.lisa_2017
    UNION ALL SELECT 2018, lopnr, sun2000niva_old FROM {{INPUT_SCHEMA}}.lisa_2018
) tbl
INNER JOIN {{OUTPUT_SCHEMA}}.person p  -- restrict to lopnrs in [PERSON]
    ON p.person_id = tbl.lopnr
LEFT JOIN {{EXT_VOCAB_SCHEMA}}.lisa_tpr_map v
    ON tbl.sun2000niva_old = v.source_code
    AND v.source_variable_description = 'education level 2000-2018';

-- populate [OBSERVATION]
WITH current_max AS (
    SELECT COALESCE(MAX(observation_id), 0) AS max_id
    FROM {{OUTPUT_SCHEMA}}.observation
)
INSERT INTO {{OUTPUT_SCHEMA}}.observation (
  observation_id,
  person_id,
  observation_concept_id,
  observation_date,
  observation_type_concept_id,
  observation_source_value,
	value_as_concept_id,
	value_as_number,
	value_as_string,
	value_source_value
)
SELECT
  current_max.max_id + ROW_NUMBER() OVER ()::integer,
  person_id AS person_id,
  observation_concept_id AS observation_concept_id,
  observation_date AS observation_date,
  observation_type_concept_id AS observation_type_concept_id,
  observation_source_value AS observation_source_value,
	value_as_concept_id AS value_as_concept_id,
	value_as_number AS value_as_number,
	value_as_string AS value_as_string,
	value_source_value AS value_source_value
FROM routed_lisa_edu_2005_2018
CROSS JOIN current_max;

-- LISA: education level (2019-2023) 
DROP TABLE IF EXISTS routed_lisa_edu_2019_2023;
CREATE TEMP TABLE routed_lisa_edu_2019_2023 (
  person_id BIGINT,
	observation_concept_id INTEGER,
  observation_date DATE,
  observation_type_concept_id INTEGER,
  observation_source_value TEXT,
  value_as_concept_id INTEGER,
  value_as_number NUMERIC,
  value_as_string TEXT,
  value_source_value TEXT
);

INSERT INTO routed_lisa_edu_2019_2023
SELECT
    p.person_id AS person_id,
		4022643 as observation_concept_id,
    make_date(tbl.yr, 12, 31) AS observation_date,
    32879 AS observation_type_concept_id,
    v.observation_source_value AS observation_source_value,
    NULL::integer AS value_as_concept_id,
    v.value_as_number AS value_as_number,
    NULL::text AS value_as_string,
    v.value_source_value AS value_source_value
FROM (
    SELECT 2019 AS yr, lopnr, sun2020niva_old FROM {{INPUT_SCHEMA}}.lisa_2019
    UNION ALL SELECT 2020, lopnr, sun2020niva_old FROM {{INPUT_SCHEMA}}.lisa_2020
    UNION ALL SELECT 2021, lopnr, sun2020niva_old FROM {{INPUT_SCHEMA}}.lisa_2021
    UNION ALL SELECT 2022, lopnr, sun2020niva_old FROM {{INPUT_SCHEMA}}.lisa_2022
    UNION ALL SELECT 2023, lopnr, sun2020niva_old FROM {{INPUT_SCHEMA}}.lisa_2023
) tbl
INNER JOIN {{OUTPUT_SCHEMA}}.person p  -- restrict to lopnrs in [PERSON]
    ON p.person_id = tbl.lopnr
LEFT JOIN {{EXT_VOCAB_SCHEMA}}.lisa_tpr_map v
    ON tbl.sun2020niva_old = v.source_code
    AND v.source_variable_description = 'education level 2019 -';

-- populate [OBSERVATION]
WITH current_max AS (
    SELECT COALESCE(MAX(observation_id), 0) AS max_id
    FROM {{OUTPUT_SCHEMA}}.observation
)
INSERT INTO {{OUTPUT_SCHEMA}}.observation (
  observation_id,
  person_id,
  observation_concept_id,
  observation_date,
  observation_type_concept_id,
  observation_source_value,
	value_as_concept_id,
 	value_as_number,
	value_as_string,
	value_source_value
)
SELECT
  current_max.max_id + ROW_NUMBER() OVER ()::integer,
  person_id AS person_id,
  observation_concept_id AS observation_concept_id,
  observation_date AS observation_date,
  observation_type_concept_id AS observation_type_concept_id,
  observation_source_value AS observation_source_value,
	value_as_concept_id AS value_as_concept_id,
	value_as_number AS value_as_number,
	value_as_string AS value_as_string,
	value_source_value AS value_source_value
FROM routed_lisa_edu_2019_2023
CROSS JOIN current_max;

-- LISA disposable income - LOOP
DROP TABLE IF EXISTS routed_lisa_income;
CREATE TEMP TABLE routed_lisa_income (
  person_id BIGINT,
	observation_concept_id INTEGER,
  observation_date DATE,
  observation_type_concept_id INTEGER,
  observation_source_value TEXT,
  value_as_concept_id INTEGER,
  value_as_number NUMERIC,
  value_as_string TEXT,
  value_source_value TEXT
);

INSERT INTO routed_lisa_income
SELECT
    p.person_id AS person_id,
		4073460 AS observation_concept_id,
    make_date(tbl.yr, 12, 31) AS observation_date,
    32879 AS observation_type_concept_id,
    'Individual income' AS observation_source_value,
    NULL::integer AS value_as_concept_id,
    dispink04 * 100 AS value_as_number,
    NULL::text AS value_as_string,
    dispink04 AS value_source_value
FROM (
    SELECT 2005 AS yr, lopnr, dispink04 FROM {{INPUT_SCHEMA}}.lisa_2005
    UNION ALL SELECT 2006, lopnr, dispink04 FROM {{INPUT_SCHEMA}}.lisa_2006
    UNION ALL SELECT 2007, lopnr, dispink04 FROM {{INPUT_SCHEMA}}.lisa_2007
    UNION ALL SELECT 2008, lopnr, dispink04 FROM {{INPUT_SCHEMA}}.lisa_2008
    UNION ALL SELECT 2009, lopnr, dispink04 FROM {{INPUT_SCHEMA}}.lisa_2009
    UNION ALL SELECT 2010, lopnr, dispink04 FROM {{INPUT_SCHEMA}}.lisa_2010
    UNION ALL SELECT 2011, lopnr, dispink04 FROM {{INPUT_SCHEMA}}.lisa_2011
    UNION ALL SELECT 2012, lopnr, dispink04 FROM {{INPUT_SCHEMA}}.lisa_2012
    UNION ALL SELECT 2013, lopnr, dispink04 FROM {{INPUT_SCHEMA}}.lisa_2013
    UNION ALL SELECT 2014, lopnr, dispink04 FROM {{INPUT_SCHEMA}}.lisa_2014
    UNION ALL SELECT 2015, lopnr, dispink04 FROM {{INPUT_SCHEMA}}.lisa_2015
    UNION ALL SELECT 2016, lopnr, dispink04 FROM {{INPUT_SCHEMA}}.lisa_2016
    UNION ALL SELECT 2017, lopnr, dispink04 FROM {{INPUT_SCHEMA}}.lisa_2017
    UNION ALL SELECT 2018, lopnr, dispink04 FROM {{INPUT_SCHEMA}}.lisa_2018
    UNION ALL SELECT 2019, lopnr, dispink04 FROM {{INPUT_SCHEMA}}.lisa_2019
    UNION ALL SELECT 2020, lopnr, dispink04 FROM {{INPUT_SCHEMA}}.lisa_2020
    UNION ALL SELECT 2021, lopnr, dispink04 FROM {{INPUT_SCHEMA}}.lisa_2021
    UNION ALL SELECT 2022, lopnr, dispink04 FROM {{INPUT_SCHEMA}}.lisa_2022
    UNION ALL SELECT 2023, lopnr, dispink04 FROM {{INPUT_SCHEMA}}.lisa_2023
) tbl
INNER JOIN {{OUTPUT_SCHEMA}}.person p  -- restrict to lopnrs in [PERSON]
    ON p.person_id = tbl.lopnr;

-- populate [OBSERVATION]
WITH current_max AS (
    SELECT COALESCE(MAX(observation_id), 0) AS max_id
    FROM {{OUTPUT_SCHEMA}}.observation
)
INSERT INTO {{OUTPUT_SCHEMA}}.observation (
  observation_id,
  person_id,
  observation_concept_id,
  observation_date,
  observation_type_concept_id,
  observation_source_value,
	value_as_concept_id,
  value_as_number,
	value_as_string,
	value_source_value
)
SELECT
  current_max.max_id + ROW_NUMBER() OVER ()::integer,
  person_id AS person_id,
  observation_concept_id AS observation_concept_id,
  observation_date AS observation_date,
  observation_type_concept_id AS observation_type_concept_id,
  observation_source_value AS observation_source_value,
  NULL::integer AS value_as_concept_id,
	value_as_number AS value_as_number,
	NULL::text AS value_as_string,
	value_source_value AS value_source_value
FROM routed_lisa_income
CROSS JOIN current_max;