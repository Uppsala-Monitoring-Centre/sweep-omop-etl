/*

Creates visit occurrences from inpatient (par_sv) and outpatient (par_ov) records, removing invalid records
and collapsing overlapping visits

Logic:
- visits are captured in two source tables (par_sv and par_ov). need to collapse visits for two scenarios:
	1.  if one visit (v2) is subumed by another visit 1 (v2.start > v1.start AND v2.end <= v1.start), delete the visit2
	2.  if one visit overlaps another (v2.start < v1.end AND v2.end > v1.start), extend to a composite visit (min(v1.start, v2.start)  -> max(v1.end, v2.end)
  note, visits that start/end on the same day should remain separate


Date handling:
Incomplete dates:
-- inpatient admission dates (indatuma) are required to be fully specified  (1 date with missing month and day is discarded)
   -> rationale: given the low frequency of incomplete date values and considering that imputation of admission dates could result in implausible lengths of hospitalisation.
-- inpatient discharge dates (utdatuma) are required to be fully specified  (225 dates with missing month and day are discarded)
   -> rationale: given the low frequency of incomplete date values and considering that imputation of discharge dates could result in implausible lengths of hospitalisation.
-- outpatient indatuma (admission) dates are imputed with the mid of the month or year.
   -> rationale: since these dates concern onset events, imputing to the midpoint is preferable to minimize systematic bias in either direction.
Invalid dates:
-- see dates listed
Censoring of dates:
-- visit occurence end date are censored at the last day of observation
   -> rationale: to avoid entries after this date

Potential data quality issues to review:
- records from PAR_SV and par_ov
- records with invalid persons
- records with overlapping dates (that will be collapsed)
- records with end date < start date

*/


TRUNCATE TABLE {{OUTPUT_SCHEMA}}.visit_occurrence;

-- create candidate visit records
-- inpatient records
WITH candidate_visit_records AS MATERIALIZED (
	SELECT sv.lopnr AS person_id,
		etl_common.parse_par_date(
            raw_value => sv.indatuma::text,
            partial_date_rule => 'exact'
        ) AS start_date,

    etl_common.parse_par_date(
            raw_value => sv.utdatuma::text,
            partial_date_rule => 'exact'
        ) AS end_date,
		9201 AS visit_concept_id
	FROM 
		{{INPUT_SCHEMA}}.par_sv sv
		INNER JOIN {{OUTPUT_SCHEMA}}.person
		ON sv.lopnr = person.person_id
		WHERE sv.indatuma <= sv.utdatuma   -- to ensure visit end not before visit start
	  AND sv.indatuma NOT IN ('.', '20030', '18991231')
    AND  sv.indatuma IS NOT NULL
    AND  sv.utdatuma NOT IN ('52320030')

	UNION ALL 
-- outpatient records (where all visits are treated as occuring on the same day, start date = end date)	
	SELECT ov.lopnr AS person_id,
      etl_common.parse_par_date(
            raw_value => ov.indatuma::text,
            partial_date_rule => 'midpoint'
        ) AS start_date,
      etl_common.parse_par_date(
            raw_value => ov.indatuma::text,
            partial_date_rule => 'midpoint'
        ) AS end_date,
		9202 AS visit_concept_id
	FROM 
		{{INPUT_SCHEMA}}.par_ov ov
		INNER JOIN {{OUTPUT_SCHEMA}}.person
		ON ov.lopnr = person.person_id
		WHERE ov.indatuma NOT IN (
           '060201',
           '060710',
           '10060113',
           '1320',
           '51200102',
           '22060914',
           '21200601',
           '20600526'
       )
),
-- identify overlapping visit records
visit_records_w_overlap AS
(
	SELECT cvr1.person_id, cvr1.start_date, cvr1.end_date
	FROM candidate_visit_records cvr1
	INNER JOIN candidate_visit_records cvr2
	ON cvr1.person_id = cvr2.person_id
	WHERE (cvr2.start_date < cvr1.end_date AND cvr2.end_date > cvr1.start_date)
	OR (cvr1.start_date < cvr2.end_date AND cvr1.end_date > cvr2.start_date)
),
-- identify non-overlapping visit records
visit_records_wo_overlap AS
(
	SELECT cvr1.person_id, cvr1.start_date, cvr1.end_date, cvr1.visit_concept_id
	FROM candidate_visit_records cvr1
	LEFT JOIN candidate_visit_records cvr2
	ON cvr1.person_id = cvr2.person_id
	AND ((cvr2.start_date < cvr1.end_date AND cvr2.end_date > cvr1.start_date)
	OR (cvr1.start_date < cvr2.end_date AND cvr1.end_date > cvr2.start_date))
	WHERE cvr2.person_id IS NULL
),
-- collapse overlapping visit records (erafy records that overlap or are subsumed) 
erafied_visit_records AS (
SELECT
person_id, min(start_date) as start_date, (max(end_date) + -1 * 0*INTERVAL'1 day') as end_date
FROM
(
  select person_id, start_date, end_date, sum(is_start) over (partition by person_id order by start_date, is_start desc rows unbounded preceding) group_idx
  from (
    select person_id, start_date, end_date, 
      case when max(end_date) over (partition by person_id order by start_date rows between unbounded preceding and 1 preceding) >= start_date then 0 else 1 end is_start
    from (
      select person_id, start_date, (end_date + 0*INTERVAL'1 day') as end_date
      from visit_records_w_overlap
    ) CR
  ) ST
) GR
group by person_id, group_idx
) 
-- population [VISIT_OCCURRENCE]
INSERT INTO {{OUTPUT_SCHEMA}}.visit_occurrence (
    visit_occurrence_id,
    person_id,
    visit_concept_id,
    visit_start_date,
    visit_end_date,
    visit_type_concept_id
)

SELECT 
	ROW_NUMBER() OVER (ORDER BY all_visits.person_id, all_visits.start_date) AS visit_occurrence_id,
	all_visits.person_id,
	all_visits.visit_concept_id,
	all_visits.start_date AS visit_start_date,
	COALESCE(all_visits.end_date,all_visits.start_date) AS visit_end_date,
	32879 AS visit_type_concept_id
FROM
(
	SELECT person_id, visit_concept_id, start_date, end_date
	FROM visit_records_wo_overlap
	
	UNION ALL
	
	SELECT person_id, 9201 AS visit_concept_id, start_date, end_date  --note, all overlaps must involve an inpatient visit
	FROM erafied_visit_records
) all_visits
WHERE all_visits.start_date IS NOT NULL
;

/* Create attrition table to show starting point record/person counts and end point record/person_counts,
as well as the number of lopnrs lost due to each exclusion criterion implemented */

DROP TABLE IF EXISTS {{OUTPUT_SCHEMA}}.VISIT_OCCURRENCE_ATTRITION;
CREATE TABLE {{OUTPUT_SCHEMA}}.VISIT_OCCURRENCE_ATTRITION AS

WITH candidate_visit_records AS MATERIALIZED (
	SELECT lopnr AS person_id,
    etl_common.parse_par_date(
            raw_value => sv.indatuma::text,
            partial_date_rule => 'exact'
        ) AS start_date,

    etl_common.parse_par_date(
            raw_value => sv.utdatuma::text,
            partial_date_rule => 'period_end'
        ) AS end_date,
		9201 AS visit_concept_id
	FROM 
		{{INPUT_SCHEMA}}.par_sv sv
		INNER JOIN {{OUTPUT_SCHEMA}}.person
		ON sv.lopnr = person.person_id
	WHERE sv.indatuma <= sv.utdatuma   -- to ensure visit end not before visit start
	    AND sv.indatuma NOT IN ('.', '20030', '18991231')
      AND  sv.indatuma IS NOT NULL
      AND  sv.utdatuma NOT IN ('52320030')
      
	UNION ALL 
	
	SELECT lopnr AS person_id,
      etl_common.parse_par_date(
            raw_value => ov.indatuma::text,
            partial_date_rule => 'midpoint'
        ) AS start_date,
      etl_common.parse_par_date(
            raw_value => ov.indatuma::text,
            partial_date_rule => 'midpoint'
        ) AS end_date,
		9202 AS visit_concept_id
	FROM 
		{{INPUT_SCHEMA}}.par_ov ov
		INNER JOIN {{OUTPUT_SCHEMA}}.person
		ON ov.lopnr = person.person_id
		WHERE ov.indatuma NOT IN (
           '060201',
           '060710',
           '10060113',
           '1320',
           '51200102',
           '22060914',
           '21200601',
           '20600526'
       )
)

SELECT 'Number of records in raw par_sv' AS QC_CATEGORY,
	COUNT(lopnr) AS RECORD_COUNT
FROM {{INPUT_SCHEMA}}.par_sv

UNION ALL

SELECT 'Number of records in raw par_ov' AS QC_CATEGORY,
	COUNT(lopnr) AS RECORD_COUNT
FROM {{INPUT_SCHEMA}}.par_ov

UNION ALL

SELECT 'Number of records in raw par_ov or par_sv' AS QC_CATEGORY,
	SUM(record_count) AS RECORD_COUNT
FROM (
	SELECT COUNT(lopnr) AS record_count
	FROM {{INPUT_SCHEMA}}.par_sv

	UNION ALL
	
	SELECT COUNT(lopnr) AS record_count
	FROM {{INPUT_SCHEMA}}.par_ov
	) t


UNION ALL

SELECT 'Number of persons in raw par_ov or par_sv' AS QC_CATEGORY,
	COUNT(DISTINCT lopnr) AS RECORD_COUNT
FROM (
	SELECT DISTINCT lopnr
	FROM {{INPUT_SCHEMA}}.par_sv

	UNION ALL
	
	SELECT DISTINCT lopnr
	FROM {{INPUT_SCHEMA}}.par_ov
	) t
	

UNION ALL

SELECT 'Number of records in par_sv with invalid person' AS QC_CATEGORY,
	COUNT(lopnr) AS RECORD_COUNT
FROM {{INPUT_SCHEMA}}.par_sv
LEFT JOIN {{OUTPUT_SCHEMA}}.person
ON par_sv.lopnr = person.person_id
WHERE person.person_id IS NULL


UNION ALL

SELECT 'Number of records in par_ov with invalid person' AS QC_CATEGORY,
	COUNT(lopnr) AS RECORD_COUNT
FROM {{INPUT_SCHEMA}}.par_ov
LEFT JOIN {{OUTPUT_SCHEMA}}.person
ON par_ov.lopnr = person.person_id
WHERE person.person_id IS NULL

UNION ALL

SELECT 'Number of persons in raw par_ov or par_sv with invalid person' AS QC_CATEGORY,
	COUNT(DISTINCT lopnr) AS RECORD_COUNT
FROM (
	SELECT DISTINCT lopnr
	FROM {{INPUT_SCHEMA}}.par_sv

	UNION ALL
	
	SELECT DISTINCT lopnr
	FROM {{INPUT_SCHEMA}}.par_ov
	) t
	LEFT JOIN {{OUTPUT_SCHEMA}}.person
	ON t.lopnr = person.person_id
	WHERE person.person_id IS NULL

UNION ALL

SELECT 'Number of records in par_sv with invalid dates (end < start)' AS QC_CATEGORY,
	COUNT(lopnr) AS RECORD_COUNT
FROM {{INPUT_SCHEMA}}.par_sv
WHERE indatuma > utdatuma

UNION ALL

SELECT 'Number of records with overlapping dates' AS QC_CATEGORY,
	COUNT(cvr1.person_id) AS RECORD_COUNT
FROM candidate_visit_records cvr1
	INNER JOIN candidate_visit_records cvr2
ON cvr1.person_id = cvr2.person_id
WHERE (cvr2.start_date < cvr1.end_date AND cvr2.end_date > cvr1.start_date)
	OR (cvr1.start_date < cvr2.end_date AND cvr1.end_date > cvr2.start_date)


UNION ALL

SELECT 'Number of records in VISIT_OCURRENCE' AS QC_CATEGORY,
	COUNT(person_id) AS RECORD_COUNT
FROM {{OUTPUT_SCHEMA}}.visit_occurrence

UNION ALL

SELECT 'Number of outpatient records in VISIT_OCURRENCE' AS QC_CATEGORY,
	COUNT(person_id) AS RECORD_COUNT
FROM {{OUTPUT_SCHEMA}}.visit_occurrence
WHERE visit_concept_id = 9202

UNION ALL

SELECT 'Number of inpatient records in VISIT_OCURRENCE' AS QC_CATEGORY,
	COUNT(person_id) AS RECORD_COUNT
FROM {{OUTPUT_SCHEMA}}.visit_occurrence
WHERE visit_concept_id = 9201


UNION ALL

SELECT 'Number of persons in VISIT_OCURRENCE' AS QC_CATEGORY,
	COUNT(DISTINCT person_id) AS RECORD_COUNT
FROM {{OUTPUT_SCHEMA}}.visit_occurrence

UNION ALL

SELECT 'Number of outpatient persons in VISIT_OCURRENCE' AS QC_CATEGORY,
	COUNT(DISTINCT person_id) AS RECORD_COUNT
FROM {{OUTPUT_SCHEMA}}.visit_occurrence
WHERE visit_concept_id = 9202

UNION ALL

SELECT 'Number of inpatient persons in VISIT_OCURRENCE' AS QC_CATEGORY,
	COUNT(DISTINCT person_id) AS RECORD_COUNT
FROM {{OUTPUT_SCHEMA}}.visit_occurrence
WHERE visit_concept_id = 9201
;

