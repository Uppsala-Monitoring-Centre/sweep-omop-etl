/*

[OBSERVATION_PERIOD] ETL

SWEEP cohort observation window:
- Data lock point: 2024-12-31.
- Data anchoring point: 2005-07-01 (start of lmed)

Observation period start and end logic: 
- Requires [PERSON] and [DEATH] to exist 
- Start = max(2005-07-01, birth year Jan 1, immigration after 2005-07-01)
- End = min(2024-12-31, death date, emigration after 2005-07-01) 
Note: an observation period can technially be zero days (having the same observation period start and end date)
Periods of the same person that overlap, touch, or are separated by a 1-day gap are merged into a single period;
periods with start > end (e.g. clamped by birth year or death date) are dropped.

Assignment of observation periods:
To avoid selection bias, each person is allowed to contribute multiple observation periods. 
Persons who emigrate after 2005-07-01 and later return to Sweden will be assigned non‑overlapping observation periods. 
To correct for administrative inconsistencies in migration records, runs of identical event types are collapsed as follows: 
- For consecutive immigration events, only the latest immigration in the run is kept.
- For consecutive emigration events, only the earliest emigration in the run is kept.
- An emigration and an immigration on the same date are ordered emigration first (left and returned the same day),
  so that residency before that date is never lost.
This ensures a coherent migration sequence before constructing observation periods.
Any additional restrictions on observed follow‑up time can be applied as appropriate when constructing custom cohorts for 
downstream analyses. Although data capture is incomplete when a person is abroad, this data limitation applies to all 
immigrants who entered Sweden after 1 July 2005.

Date handling:
Incomplete dates:
-- partial migration dates (datum with only year or year and month known) are imputed in the direction that never counts
   time abroad as observed: immigrations to the end of the month/year, emigrations to the start of the month/year.
   -> rationale: residency starts no earlier and ends no later than the registered information allows.
-- migration dates without any information (datum = 0; 26 immigrations and 9 emigrations) are discarded.
   -> consequence: an undated emigration is ignored, so the person is considered resident until their next dated
      emigration, death or 2024-12-31; an undated immigration is ignored, so the person is considered abroad until their
      next dated immigration.
-- death dates (dodsdat in dors and doddatum in grunduppgifter) are imputed with the end of the month or year (see logic death_date in [DEATH])
   -> rationale: for dates concerning hard endpoints imputing to end of month/year is preferable to preserve valid event ordering and avoid erroneously censoring persons too early.

Potential data quality issue:
- observation_period_start > observation_period_end

*/

TRUNCATE {{OUTPUT_SCHEMA}}.observation_period;

-- clean dors data (dismiss records with _AVI_ and R999 codes (no death certificate) for duplicate lopnrs)
-- DROP TABLE IF EXISTS cleaned_dors;
-- CREATE TEMP TABLE cleaned_dors AS
-- SELECT *
-- FROM (
--     SELECT
--         t.*,
--         ROW_NUMBER() OVER (
--             PARTITION BY lopnr
--             ORDER BY
--                 CASE WHEN ulorsak IN ('_AVI_', 'R999') THEN 1 ELSE 0 END
--         ) AS rn
--     FROM {{INPUT_SCHEMA}}.dors t
-- ) x
-- WHERE rn = 1;

-- read and parse migration data: impute partial dates (immigration to end, emigration to start of the known period)
-- and discard events without any date information (parse_par_date returns NULL for them)
WITH raw_events AS (
    SELECT
        lopnr,
        posttyp,
        event_date
    FROM (
        SELECT
            lopnr,
            posttyp,
            etl_common.parse_par_date(
                raw_value => datum::text,
                partial_date_rule => CASE WHEN posttyp = 'Utv' THEN 'period_start' ELSE 'period_end' END
            ) AS event_date
        FROM {{INPUT_SCHEMA}}.migrationer
    ) parsed
    WHERE event_date IS NOT NULL
),

-- identify previous migration event type (utv/inv) per lopnr
events_with_prev AS (
    SELECT
        lopnr,
        posttyp,
        event_date,
        LAG(posttyp) OVER (PARTITION BY lopnr ORDER BY event_date, CASE WHEN posttyp = 'Utv' THEN 0 ELSE 1 END) AS prev_type
    FROM raw_events
),

-- group consecutive same type events (utv/inv) per lopnr in runs
events_with_groups AS (
    SELECT
        lopnr,
        posttyp,
        event_date,
        SUM(
            CASE
                WHEN prev_type IS NULL OR posttyp <> prev_type THEN 1
                ELSE 0
            END
        ) OVER (
            PARTITION BY lopnr
            ORDER BY event_date, CASE WHEN posttyp = 'Utv' THEN 0 ELSE 1 END
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS grp
    FROM events_with_prev
),

-- clean administrative errors in migration sequence, collapse runs of same type events: keep latest inv / earliest utv in a run
cleaned AS (
    SELECT
        lopnr,
        posttyp,
        CASE
            WHEN posttyp = 'Inv' THEN MAX(event_date)
            ELSE MIN(event_date)
        END AS event_date
    FROM events_with_groups
    GROUP BY lopnr, grp, posttyp
),

-- define event to event intervals
intervals0 AS (
    SELECT
        lopnr,
        event_date AS start_date,
        LEAD(event_date) OVER (PARTITION BY lopnr ORDER BY event_date, CASE WHEN posttyp = 'Utv' THEN 0 ELSE 1 END) AS next_date,
        posttyp,
        LEAD(posttyp) OVER (PARTITION BY lopnr ORDER BY event_date, CASE WHEN posttyp = 'Utv' THEN 0 ELSE 1 END) AS next_type
    FROM cleaned
),


-- define first pass residency intervals (from immigration)
valid_intervals0 AS (
    SELECT
        lopnr,
        start_date,
        CASE
            WHEN next_type = 'Utv' THEN next_date
            ELSE DATE '2024-12-31'
        END AS end_date
    FROM intervals0
    WHERE posttyp = 'Inv'
),

-- identify first migration event per lopnr
first_events AS (
    SELECT
        lopnr,
        MIN(CASE WHEN posttyp = 'Inv' THEN event_date END) AS first_inv,
        MIN(CASE WHEN posttyp = 'Utv' THEN event_date END) AS first_utv
    FROM cleaned
    GROUP BY lopnr
),

-- define who is observed/resident on 2005-07-01 (needs synthetic inv), add_synthetic = 1 if lopnr has 
-- i). a residency interval (valid_intervals0) that covers 2005‑07‑01 OR
-- ii). has no migration records at all (assume resident) OR
-- iii). has an emigration after 2005‑07‑01 as first migration event, whatever follows it
--       (so they must have been resident on that date)

present_on_2005 AS (
    SELECT
        p.person_id AS lopnr,
        CASE
            -- Case 1: Has a residency interval covering 2005-07-01
            WHEN EXISTS (
                SELECT 1
                FROM valid_intervals0 v
                WHERE v.lopnr = p.person_id
                  AND v.start_date <= DATE '2005-07-01'
                  AND v.end_date   >  DATE '2005-07-01'
            )
            THEN 1

            -- Case 2: No migration records at all
            WHEN fe.first_inv IS NULL AND fe.first_utv IS NULL
            THEN 1

            -- Case 3: First migration event is an emigration after 2005-07-01, with or without
            -- later immigrations (a same-day immigration counts as later, as in the ordering above)
            WHEN fe.first_utv > DATE '2005-07-01'
             AND (fe.first_inv IS NULL OR fe.first_inv >= fe.first_utv)
            THEN 1

            -- Case 4: First immigration on/before 2005-07-01 AND first emigration after 2005-07-01
            WHEN fe.first_inv IS NOT NULL
             AND fe.first_inv <= DATE '2005-07-01'
             AND fe.first_utv IS NOT NULL
             AND fe.first_utv > DATE '2005-07-01'
            THEN 1

            ELSE 0
        END AS add_synthetic
    FROM {{OUTPUT_SCHEMA}}.person p
    LEFT JOIN first_events fe ON fe.lopnr = p.person_id
),

-- remove pre‑2005 immigration records for lopnrs with synthetic start
cleaned_events AS (
    SELECT
        c.lopnr,
        c.posttyp,
        c.event_date
    FROM cleaned c
    LEFT JOIN present_on_2005 p ON p.lopnr = c.lopnr
    WHERE NOT (
        p.add_synthetic = 1
        AND c.posttyp = 'Inv'
        AND c.event_date < DATE '2005-07-01'
    )
),

-- add synthetic immigration on 2005‑07‑01 if not existing
events_augmented AS (
    SELECT * FROM cleaned_events
    UNION ALL
    SELECT
        p.lopnr,
        'Inv' AS posttyp,
        DATE '2005-07-01' AS event_date
    FROM present_on_2005 p
    WHERE p.add_synthetic = 1
      AND NOT EXISTS (
            SELECT 1
            FROM cleaned_events c
            WHERE c.lopnr = p.lopnr
              AND c.posttyp = 'Inv'
              AND c.event_date = DATE '2005-07-01'
      )
),

-- redefine intervals with augmented events
intervals AS (
    SELECT
        lopnr,
        event_date AS start_date,
        LEAD(event_date) OVER (PARTITION BY lopnr ORDER BY event_date, CASE WHEN posttyp = 'Utv' THEN 0 ELSE 1 END) AS next_date,
        posttyp,
        LEAD(posttyp) OVER (PARTITION BY lopnr ORDER BY event_date, CASE WHEN posttyp = 'Utv' THEN 0 ELSE 1 END) AS next_type
    FROM events_augmented
),

-- define final residency intervals (post augmentation)
valid_intervals AS (
    SELECT
        lopnr,
        start_date,
        CASE
            WHEN next_type = 'Utv' THEN next_date
            ELSE DATE '2024-12-31'
        END AS end_date
    FROM intervals
    WHERE posttyp = 'Inv'
),

-- apply birth, death, and observation window to extract start and end dates for observation periods
final_periods AS (
    SELECT
        v.lopnr AS person_id,
        GREATEST(
            v.start_date,
            DATE '2005-07-01',
            MAKE_DATE(p.year_of_birth, 1, 1)
        ) AS observation_period_start_date,
        LEAST(
            v.end_date,
            COALESCE(d.death_date, DATE '2024-12-31')
        ) AS observation_period_end_date
    FROM valid_intervals v
    JOIN {{OUTPUT_SCHEMA}}.person p ON p.person_id = v.lopnr
    LEFT JOIN {{OUTPUT_SCHEMA}}.death d ON d.person_id = v.lopnr
    WHERE v.end_date > DATE '2005-07-01'
),
-- merge observation periods that are overlapping, touching, or back to back
merged_periods AS (

    WITH periods_with_previous_max AS (
        SELECT
            person_id,
            observation_period_start_date,
            observation_period_end_date,

            MAX(observation_period_end_date) OVER (
                PARTITION BY person_id
                ORDER BY
                    observation_period_start_date,
                    observation_period_end_date
                ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
            ) AS previous_max_end_date

        FROM final_periods

        WHERE observation_period_start_date
              <= observation_period_end_date
    ),

    grouped AS (
        SELECT
            *,

            SUM(
                CASE
                    WHEN previous_max_end_date IS NULL THEN 1

                    WHEN observation_period_start_date >
                         previous_max_end_date + 1
                    THEN 1

                    ELSE 0
                END
            ) OVER (
                PARTITION BY person_id
                ORDER BY
                    observation_period_start_date,
                    observation_period_end_date
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) AS grp

        FROM periods_with_previous_max
    )

    SELECT
        person_id,
        MIN(observation_period_start_date)
            AS observation_period_start_date,
        MAX(observation_period_end_date)
            AS observation_period_end_date

    FROM grouped

    GROUP BY
        person_id,
        grp
)

-- populate table
INSERT INTO {{OUTPUT_SCHEMA}}.observation_period (
    observation_period_id,
    person_id,
    observation_period_start_date,
    observation_period_end_date,
    period_type_concept_id
)
SELECT
    ROW_NUMBER() OVER (ORDER BY person_id, observation_period_start_date),
    person_id,
    observation_period_start_date,
    observation_period_end_date,
    32879
FROM merged_periods;


/* Create attrition table to show starting point record/person counts and end point record/person_counts,
as well as the number of lopnrs lost due to each exclusion criterion implemented */

DROP TABLE IF EXISTS {{OUTPUT_SCHEMA}}.OBSERVATION_PERIOD_ATTRITION;
CREATE TABLE {{OUTPUT_SCHEMA}}.OBSERVATION_PERIOD_ATTRITION AS

SELECT 'Number of persons in PERSON' AS QC_CATEGORY,
	COUNT(DISTINCT person_id) AS RECORD_COUNT
FROM {{OUTPUT_SCHEMA}}.person

UNION ALL

SELECT 'Number of persons in OBSERVATION_PERIOD' AS QC_CATEGORY,
	COUNT(DISTINCT person_id) AS RECORD_COUNT
FROM {{OUTPUT_SCHEMA}}.observation_period

UNION ALL

SELECT 'Number of records in OBSERVATION_PERIOD' AS QC_CATEGORY,
	COUNT(person_id) AS RECORD_COUNT
FROM {{OUTPUT_SCHEMA}}.observation_period

UNION ALL

SELECT 'Number of records in OBSERVATION_PERIOD with start > end' AS QC_CATEGORY,
	COUNT(person_id) AS RECORD_COUNT
FROM {{OUTPUT_SCHEMA}}.observation_period
WHERE observation_period_start_date > observation_period_end_date

UNION ALL

-- start and end dates are inclusive: a next period starting on the end date shares a day (overlap),
-- one starting the day after the end date is adjacent; both should have been merged (expected 0)
SELECT
    'Number of persons with overlapping OBSERVATION PERIODS (sharing at least one day)' AS QC_CATEGORY,
    COUNT(DISTINCT person_id) AS RECORD_COUNT
FROM (
    SELECT
        person_id,
        observation_period_end_date,
        LEAD(observation_period_start_date)
            OVER (
                PARTITION BY person_id
                ORDER BY observation_period_start_date, observation_period_id
            ) AS next_start
    FROM {{OUTPUT_SCHEMA}}.observation_period
) x
WHERE next_start <= observation_period_end_date

UNION ALL

SELECT
    'Number of persons with adjacent OBSERVATION PERIODS (next starting the day after the end)' AS QC_CATEGORY,
    COUNT(DISTINCT person_id) AS RECORD_COUNT
FROM (
    SELECT
        person_id,
        observation_period_end_date,
        LEAD(observation_period_start_date)
            OVER (
                PARTITION BY person_id
                ORDER BY observation_period_start_date, observation_period_id
            ) AS next_start
    FROM {{OUTPUT_SCHEMA}}.observation_period
) x
WHERE next_start = observation_period_end_date + 1;


-- /* Create table with lopnrs in grunduppgifter without observation period */

-- DROP TABLE IF EXISTS {{OUTPUT_SCHEMA}}.persons_missing_observation_period;
-- CREATE TABLE {{OUTPUT_SCHEMA}}.persons_missing_observation_period AS
-- SELECT 
--     -- Grunduppgifter 
--     g.lopnr AS lopnr,
--     g.fodelsear,
--     g.doddatum,
--     g.aterpnr,
--     g.felsenpnr,
--     g.samordnr,
--     -- Death table 
--     d.dodsdat,
--     -- Migration table 
--     m.posttyp,
--     m.datum,
--     etl_common.parse_par_date(
--                     raw_value => m.datum::text,
--                     partial_date_rule => 'exact'
--                   ) AS migration_date
-- FROM {{INPUT_SCHEMA}}.grunduppgifter g
-- LEFT JOIN {{OUTPUT_SCHEMA}}.observation_period op
--     ON g.lopnr = op.person_id
-- LEFT JOIN cleaned_dors d
--     ON g.lopnr = d.lopnr
-- LEFT JOIN {{INPUT_SCHEMA}}.migrationer m
--     ON g.lopnr = m.lopnr
-- INNER JOIN (
--     SELECT DISTINCT lopnr
--     FROM {{INPUT_SCHEMA}}.lmed
-- ) l ON g.lopnr = l.lopnr
-- WHERE op.person_id IS NULL
-- ORDER BY g.lopnr, migration_date;


-- /* Create table with lopnrs where observation_period_start_date > observation_period_end_date */

-- DROP TABLE IF EXISTS {{OUTPUT_SCHEMA}}.invalid_observation_periods;
-- CREATE TABLE {{OUTPUT_SCHEMA}}.invalid_observation_periods AS
-- SELECT
--     op.person_id,
--     op.observation_period_start_date,
--     op.observation_period_end_date,
--     -- Grunduppgifter (rename lopnr)
--     g.lopnr AS grund_lopnr,
--     g.fodelsear,
--     g.doddatum,
--     -- Death table (rename lopnr)
--     d.lopnr AS death_lopnr,
--     d.dodsdat,
--     -- Migration table (rename lopnr)
--     m.lopnr AS migration_lopnr,
--     m.posttyp,
--     m.datum
-- FROM {{OUTPUT_SCHEMA}}.observation_period op
-- LEFT JOIN {{INPUT_SCHEMA}}.grunduppgifter g
--     ON op.person_id = g.lopnr
-- LEFT JOIN cleaned_dors d
--     ON op.person_id = d.lopnr
-- LEFT JOIN {{INPUT_SCHEMA}}.migrationer m
--     ON op.person_id = m.lopnr
-- WHERE op.observation_period_start_date > op.observation_period_end_date;

-- /* Create table listing all records for lopns with emigration and immigration after 2005 */

-- DROP TABLE IF EXISTS {{OUTPUT_SCHEMA}}.observation_period_emi_immi_after_2005;

-- WITH raw_events AS (
--     SELECT
--         lopnr,
--         posttyp,
--         etl_common.parse_par_date(
--             raw_value => datum::text,
--             partial_date_rule => 'exact'
--         ) AS event_date
--     FROM {{INPUT_SCHEMA}}.migrationer
-- ),

-- events_with_prev AS (
--     SELECT
--         lopnr,
--         posttyp,
--         event_date,
--         LAG(posttyp) OVER (PARTITION BY lopnr ORDER BY event_date) AS prev_type
--     FROM raw_events
-- ),

-- events_with_groups AS (
--     SELECT
--         lopnr,
--         posttyp,
--         event_date,
--         SUM(
--             CASE
--                 WHEN prev_type IS NULL OR posttyp <> prev_type THEN 1
--                 ELSE 0
--             END
--         ) OVER (
--             PARTITION BY lopnr
--             ORDER BY event_date
--             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
--         ) AS grp
--     FROM events_with_prev
-- ),

-- cleaned AS (
--     SELECT
--         lopnr,
--         posttyp,
--         CASE
--             WHEN posttyp = 'Inv' THEN MAX(event_date)
--             ELSE MIN(event_date)
--         END AS event_date
--     FROM events_with_groups
--     GROUP BY lopnr, grp, posttyp
-- ),

-- ordered AS (
--     SELECT
--         lopnr,
--         posttyp,
--         event_date,
--         LEAD(posttyp)  OVER (PARTITION BY lopnr ORDER BY event_date) AS next_type,
--         LEAD(event_date) OVER (PARTITION BY lopnr ORDER BY event_date) AS next_date
--     FROM cleaned
-- ),

-- emi_immi_after_2005 AS (
--     SELECT DISTINCT lopnr
--     FROM ordered
--     WHERE posttyp = 'Utv'
--       AND event_date >= DATE '2005-07-01'
--       AND next_type = 'Inv'
--       AND next_date >= DATE '2005-07-01'
-- )

-- SELECT op.*
-- INTO {{OUTPUT_SCHEMA}}.observation_period_emi_immi_after_2005
-- FROM {{OUTPUT_SCHEMA}}.observation_period op
-- JOIN emi_immi_after_2005 e ON e.lopnr = op.person_id;


-- Create table with lopnrs with overlapping observation periods

DROP TABLE IF EXISTS {{OUTPUT_SCHEMA}}.observation_period_overlaps;
CREATE TABLE {{OUTPUT_SCHEMA}}.observation_period_overlaps AS
WITH ordered AS (
    SELECT
        op.person_id,
        op.observation_period_id,
        op.observation_period_start_date,
        op.observation_period_end_date,
        LEAD(op.observation_period_start_date)
            OVER (
                PARTITION BY op.person_id
                ORDER BY op.observation_period_start_date
            ) AS next_start
    FROM {{OUTPUT_SCHEMA}}.observation_period op
),
overlapping_persons AS (
    SELECT DISTINCT person_id
    FROM ordered
    WHERE next_start IS NOT NULL
      AND next_start < observation_period_end_date + 2
)

SELECT
    op.*,
    m.posttyp,
    m.datum,
    d.dodsdat,
    g.fodelsear,
    g.doddatum,
    g.aterpnr,
    g.felsenpnr,
    g.samordnr
FROM {{OUTPUT_SCHEMA}}.observation_period op
JOIN overlapping_persons p
    ON op.person_id = p.person_id
LEFT JOIN {{INPUT_SCHEMA}}.migrationer m
    ON op.person_id = m.lopnr
LEFT JOIN {{INPUT_SCHEMA}}.dors d
    ON op.person_id = d.lopnr
LEFT JOIN {{INPUT_SCHEMA}}.grunduppgifter g
    ON op.person_id = g.lopnr
ORDER BY
    op.person_id,
    op.observation_period_start_date;

-- Create table with lopnrs having a death record after their last day of observation (to identify edge cases with death occurring following emigration without subsequent immigration)    
    
DROP TABLE IF EXISTS {{OUTPUT_SCHEMA}}.death_after_last_observation;
CREATE TABLE {{OUTPUT_SCHEMA}}.death_after_last_observation AS

WITH max_observation_period AS (
    SELECT
        person_id,
        MAX(observation_period_end_date) AS latest_observation_period_end_date
    FROM {{OUTPUT_SCHEMA}}.observation_period
    GROUP BY person_id
)

SELECT
    d.person_id,
    d.death_date,
    op.latest_observation_period_end_date
FROM {{OUTPUT_SCHEMA}}.death d
INNER JOIN max_observation_period op
    ON op.person_id = d.person_id
WHERE d.death_date > op.latest_observation_period_end_date
ORDER BY
    d.person_id;    
