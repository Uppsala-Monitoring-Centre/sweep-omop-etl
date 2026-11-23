---------------------------------------------------------------------------------------------
-- Pre-OMOP sampling script 
-- The OMOP CDM mapping that will be performed during the workshop, will take a sample of data as 
-- input to avoid long processing times 
-- The sample will consists of 100K lopnrs
-- randomly sampled from grunduppgifter
-- All the other tables will be filtered for these LOPNRs
---------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------
-- Step 0: create a new dedicated schema
---------------------------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS {{OUTPUT_SCHEMA_SAMPLE}};

---------------------------------------------------------------------------------------------
-- Step 1: set seed and draw a random sample
---------------------------------------------------------------------------------------------

SELECT setseed(0.12345);

DROP TABLE IF EXISTS {{OUTPUT_SCHEMA_SAMPLE}}.sampled_lopnr;

CREATE TABLE {{OUTPUT_SCHEMA_SAMPLE}}.sampled_lopnr AS
SELECT lopnr
FROM {{INPUT_SCHEMA_SAMPLE}}.grunduppgifter
ORDER BY random()
LIMIT {{SAMPLE_SIZE}};

-- create index 
CREATE UNIQUE INDEX idx_sampled_lopnr
ON {{OUTPUT_SCHEMA_SAMPLE}}.sampled_lopnr (lopnr);

---------------------------------------------------------------------------------------------
-- Step 2: Copy grunduppgifter (filtered)
---------------------------------------------------------------------------------------------
DROP TABLE IF EXISTS {{OUTPUT_SCHEMA_SAMPLE}}.grunduppgifter;

CREATE TABLE {{OUTPUT_SCHEMA_SAMPLE}}.grunduppgifter AS
SELECT g.*
FROM {{INPUT_SCHEMA_SAMPLE}}.grunduppgifter g
JOIN {{OUTPUT_SCHEMA_SAMPLE}}.sampled_lopnr s
  ON g.lopnr = s.lopnr;

---------------------------------------------------------------------------------------------
-- Step 3: Copy all other person-level tables (filtered)
-- limited to the ones needed for the workshop OMOP-mapping
---------------------------------------------------------------------------------------------
-- lmed 
DROP TABLE IF EXISTS {{OUTPUT_SCHEMA_SAMPLE}}.lmed; 

CREATE TABLE {{OUTPUT_SCHEMA_SAMPLE}}.lmed AS
SELECT l.*
FROM {{INPUT_SCHEMA_SAMPLE}}.lmed l
JOIN {{OUTPUT_SCHEMA_SAMPLE}}.sampled_lopnr s
  ON l.lopnr = s.lopnr;
  
-- par_sv 
DROP TABLE IF EXISTS {{OUTPUT_SCHEMA_SAMPLE}}.par_sv; 

CREATE TABLE {{OUTPUT_SCHEMA_SAMPLE}}.par_sv AS
SELECT p.*
FROM {{INPUT_SCHEMA_SAMPLE}}.par_sv p
JOIN {{OUTPUT_SCHEMA_SAMPLE}}.sampled_lopnr s
  ON p.lopnr = s.lopnr;
-- par_ov 
DROP TABLE IF EXISTS {{OUTPUT_SCHEMA_SAMPLE}}.par_ov; 

CREATE TABLE {{OUTPUT_SCHEMA_SAMPLE}}.par_ov AS
SELECT p.*
FROM {{INPUT_SCHEMA_SAMPLE}}.par_ov p
JOIN {{OUTPUT_SCHEMA_SAMPLE}}.sampled_lopnr s
  ON p.lopnr = s.lopnr;
  
-- dors
DROP TABLE IF EXISTS {{OUTPUT_SCHEMA_SAMPLE}}.dors; 

CREATE TABLE {{OUTPUT_SCHEMA_SAMPLE}}.dors AS
SELECT d.*
FROM {{INPUT_SCHEMA_SAMPLE}}.dors d
JOIN {{OUTPUT_SCHEMA_SAMPLE}}.sampled_lopnr s
  ON d.lopnr = s.lopnr;
  
-- migrationer
DROP TABLE IF EXISTS {{OUTPUT_SCHEMA_SAMPLE}}.migrationer; 

CREATE TABLE {{OUTPUT_SCHEMA_SAMPLE}}.migrationer AS
SELECT m.*
FROM {{INPUT_SCHEMA_SAMPLE}}.migrationer m
JOIN {{OUTPUT_SCHEMA_SAMPLE}}.sampled_lopnr s
  ON m.lopnr = s.lopnr;
  
--can
DROP TABLE IF EXISTS {{OUTPUT_SCHEMA_SAMPLE}}.can; 
CREATE TABLE {{OUTPUT_SCHEMA_SAMPLE}}.can AS
SELECT m.*
FROM {{INPUT_SCHEMA_SAMPLE}}.can m
JOIN {{OUTPUT_SCHEMA_SAMPLE}}.sampled_lopnr s
  ON m.lopnr = s.lopnr;

--lisa
DROP TABLE IF EXISTS {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2005;

CREATE TABLE {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2005 AS
SELECT l.*
FROM {{INPUT_SCHEMA_SAMPLE}}.lisa_2005 l
JOIN {{OUTPUT_SCHEMA_SAMPLE}}.sampled_lopnr s
  ON l.lopnr = s.lopnr;

DROP TABLE IF EXISTS {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2006;

CREATE TABLE {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2006 AS
SELECT l.*
FROM {{INPUT_SCHEMA_SAMPLE}}.lisa_2006 l
JOIN {{OUTPUT_SCHEMA_SAMPLE}}.sampled_lopnr s
  ON l.lopnr = s.lopnr;


DROP TABLE IF EXISTS {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2007;

CREATE TABLE {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2007 AS
SELECT l.*
FROM {{INPUT_SCHEMA_SAMPLE}}.lisa_2007 l
JOIN {{OUTPUT_SCHEMA_SAMPLE}}.sampled_lopnr s
  ON l.lopnr = s.lopnr;


DROP TABLE IF EXISTS {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2008;

CREATE TABLE {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2008 AS
SELECT l.*
FROM {{INPUT_SCHEMA_SAMPLE}}.lisa_2008 l
JOIN {{OUTPUT_SCHEMA_SAMPLE}}.sampled_lopnr s
  ON l.lopnr = s.lopnr;


DROP TABLE IF EXISTS {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2009;

CREATE TABLE {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2009 AS
SELECT l.*
FROM {{INPUT_SCHEMA_SAMPLE}}.lisa_2009 l
JOIN {{OUTPUT_SCHEMA_SAMPLE}}.sampled_lopnr s
  ON l.lopnr = s.lopnr;


DROP TABLE IF EXISTS {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2010;

CREATE TABLE {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2010 AS
SELECT l.*
FROM {{INPUT_SCHEMA_SAMPLE}}.lisa_2010 l
JOIN {{OUTPUT_SCHEMA_SAMPLE}}.sampled_lopnr s
  ON l.lopnr = s.lopnr;


DROP TABLE IF EXISTS {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2011;

CREATE TABLE {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2011 AS
SELECT l.*
FROM {{INPUT_SCHEMA_SAMPLE}}.lisa_2011 l
JOIN {{OUTPUT_SCHEMA_SAMPLE}}.sampled_lopnr s
  ON l.lopnr = s.lopnr;


DROP TABLE IF EXISTS {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2012;

CREATE TABLE {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2012 AS
SELECT l.*
FROM {{INPUT_SCHEMA_SAMPLE}}.lisa_2012 l
JOIN {{OUTPUT_SCHEMA_SAMPLE}}.sampled_lopnr s
  ON l.lopnr = s.lopnr;


DROP TABLE IF EXISTS {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2013;

CREATE TABLE {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2013 AS
SELECT l.*
FROM {{INPUT_SCHEMA_SAMPLE}}.lisa_2013 l
JOIN {{OUTPUT_SCHEMA_SAMPLE}}.sampled_lopnr s
  ON l.lopnr = s.lopnr;


DROP TABLE IF EXISTS {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2014;

CREATE TABLE {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2014 AS
SELECT l.*
FROM {{INPUT_SCHEMA_SAMPLE}}.lisa_2014 l
JOIN {{OUTPUT_SCHEMA_SAMPLE}}.sampled_lopnr s
  ON l.lopnr = s.lopnr;


DROP TABLE IF EXISTS {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2015;

CREATE TABLE {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2015 AS
SELECT l.*
FROM {{INPUT_SCHEMA_SAMPLE}}.lisa_2015 l
JOIN {{OUTPUT_SCHEMA_SAMPLE}}.sampled_lopnr s
  ON l.lopnr = s.lopnr;


DROP TABLE IF EXISTS {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2016;

CREATE TABLE {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2016 AS
SELECT l.*
FROM {{INPUT_SCHEMA_SAMPLE}}.lisa_2016 l
JOIN {{OUTPUT_SCHEMA_SAMPLE}}.sampled_lopnr s
  ON l.lopnr = s.lopnr;


DROP TABLE IF EXISTS {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2017;

CREATE TABLE {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2017 AS
SELECT l.*
FROM {{INPUT_SCHEMA_SAMPLE}}.lisa_2017 l
JOIN {{OUTPUT_SCHEMA_SAMPLE}}.sampled_lopnr s
  ON l.lopnr = s.lopnr;


DROP TABLE IF EXISTS {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2018;

CREATE TABLE {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2018 AS
SELECT l.*
FROM {{INPUT_SCHEMA_SAMPLE}}.lisa_2018 l
JOIN {{OUTPUT_SCHEMA_SAMPLE}}.sampled_lopnr s
  ON l.lopnr = s.lopnr;


DROP TABLE IF EXISTS {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2019;

CREATE TABLE {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2019 AS
SELECT l.*
FROM {{INPUT_SCHEMA_SAMPLE}}.lisa_2019 l
JOIN {{OUTPUT_SCHEMA_SAMPLE}}.sampled_lopnr s
  ON l.lopnr = s.lopnr;


DROP TABLE IF EXISTS {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2020;

CREATE TABLE {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2020 AS
SELECT l.*
FROM {{INPUT_SCHEMA_SAMPLE}}.lisa_2020 l
JOIN {{OUTPUT_SCHEMA_SAMPLE}}.sampled_lopnr s
  ON l.lopnr = s.lopnr;


DROP TABLE IF EXISTS {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2021;

CREATE TABLE {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2021 AS
SELECT l.*
FROM {{INPUT_SCHEMA_SAMPLE}}.lisa_2021 l
JOIN {{OUTPUT_SCHEMA_SAMPLE}}.sampled_lopnr s
  ON l.lopnr = s.lopnr;


DROP TABLE IF EXISTS {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2022;

CREATE TABLE {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2022 AS
SELECT l.*
FROM {{INPUT_SCHEMA_SAMPLE}}.lisa_2022 l
JOIN {{OUTPUT_SCHEMA_SAMPLE}}.sampled_lopnr s
  ON l.lopnr = s.lopnr;


DROP TABLE IF EXISTS {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2023;

CREATE TABLE {{OUTPUT_SCHEMA_SAMPLE}}.lisa_2023 AS
SELECT l.*
FROM {{INPUT_SCHEMA_SAMPLE}}.lisa_2023 l
JOIN {{OUTPUT_SCHEMA_SAMPLE}}.sampled_lopnr s
  ON l.lopnr = s.lopnr;


---------------------------------------------------------------------------------------------
-- Step 4: Add indexes
---------------------------------------------------------------------------------------------
-- INDEX_START
CREATE INDEX idx_lmed_lopnr
ON {{OUTPUT_SCHEMA_SAMPLE}}.lmed (lopnr);
CREATE INDEX idx_par_sv_lopnr
ON {{OUTPUT_SCHEMA_SAMPLE}}.par_sv (lopnr);
CREATE INDEX idx_par_ov_lopnr
ON {{OUTPUT_SCHEMA_SAMPLE}}.par_ov (lopnr);
CREATE INDEX idx_dors_lopnr
ON {{OUTPUT_SCHEMA_SAMPLE}}.dors (lopnr);
CREATE INDEX idx_migrationer_lopnr
ON {{OUTPUT_SCHEMA_SAMPLE}}.migrationer (lopnr);
-- INDEX_END

---------------------------------------------------------------------------------------------
-- Step 5: Sanity checks
---------------------------------------------------------------------------------------------
SELECT COUNT(*) FROM {{OUTPUT_SCHEMA_SAMPLE}}.sampled_lopnr;
-- All tables consistent
SELECT COUNT(DISTINCT lopnr) FROM {{OUTPUT_SCHEMA_SAMPLE}}.lmed;


