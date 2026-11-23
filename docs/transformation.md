# ETL Transformation Rules

This page summarizes the implemented transformation behavior. The detailed field-level mapping is maintained in [SWEEP_ETL_specification.xlsx](SWEEP_ETL_specification.xlsx); SQL under `sql/omop/` is the executable source of truth.

## Execution order

The core orchestrator runs these 14 SQL files in order:

1. [`00_create_functions.sql`](../sql/omop/00_create_functions.sql) - create shared parsing and vocabulary-mapping functions.
2. [`01_grunduppgifter_to_person.sql`](../sql/omop/01_grunduppgifter_to_person.sql) - build `person`.
3. [`02_grunduppgifter_and_dors_to_death.sql`](../sql/omop/02_grunduppgifter_and_dors_to_death.sql) - build `death`.
4. [`03_tpr_and_dors_to_observation_period.sql`](../sql/omop/03_tpr_and_dors_to_observation_period.sql) - build `observation_period`.
5. [`04_par_to_visit_occurrence.sql`](../sql/omop/04_par_to_visit_occurrence.sql) - build `visit_occurrence`.
6. [`05_lmed_to_drug_exposure.sql`](../sql/omop/05_lmed_to_drug_exposure.sql) - build `drug_exposure`.
7. [`06a_parsv_to_condition_measurement_procedure_observation.sql`](../sql/omop/06a_parsv_to_condition_measurement_procedure_observation.sql) - route inpatient events.
8. [`06b_parov_to_condition_measurement_procedure_observation.sql`](../sql/omop/06b_parov_to_condition_measurement_procedure_observation.sql) - route outpatient events.
9. [`06c_dors_to_condition_measurement_procedure_observation.sql`](../sql/omop/06c_dors_to_condition_measurement_procedure_observation.sql) - route death-related events.
10. [`06d_can_to_condition_measurement_procedure_observation.sql`](../sql/omop/06d_can_to_condition_measurement_procedure_observation.sql) - route cancer events.
11. [`07_grunduppgifter_lisa_to_observation.sql`](../sql/omop/07_grunduppgifter_lisa_to_observation.sql) - add demographic and socioeconomic observations.
12. [`08_drug_era.sql`](../sql/omop/08_drug_era.sql) - build `drug_era`.
13. [`09_condition_era.sql`](../sql/omop/09_condition_era.sql) - build `condition_era`.
14. [`10_metadata.sql`](../sql/omop/10_metadata.sql) - populate `cdm_source` metadata.

The orchestrator and its input/output declarations are in [`R/orchestrators/03_omop_orchestrator.R`](../R/orchestrators/03_omop_orchestrator.R). CDM and standard-vocabulary setup, external-vocabulary setup, and index/foreign-key creation are separate orchestrator stages, not steps in this SQL list.

## Person and cohort anchor

Implemented in [`01_grunduppgifter_to_person.sql`](../sql/omop/01_grunduppgifter_to_person.sql).

The transformation starts with `grunduppgifter` and requires both an eligible `lmed` record and evidence of observation after the cohort anchor date, 2005-07-01. It excludes non-drug `lmed` categories (`otyp` H/L/A and `varutyp` HA/OV), invalid sex, birth years outside 1900-2024, reused or invalid personal identifiers, coordination numbers, and deaths dated on or before 2005-07-01. It also applies plausibility checks so birth precedes the applicable study, death, or emigration endpoint and the latest immigration does not follow death or the 2024-12-31 data lock point.

`person` is the downstream population anchor. Event transformations join to it so they do not add people excluded from this table.

## Death

Implemented in [`02_grunduppgifter_and_dors_to_death.sql`](../sql/omop/02_grunduppgifter_and_dors_to_death.sql).

The earliest parsed death date from `grunduppgifter` or `dors` is used for people in `person`. Partial year or month dates are imputed to the end of the known period, and deaths after the 2024-12-31 data lock point are excluded. When duplicate `dors` rows exist, rows with `_AVI_` or `R999` underlying-cause codes are deprioritized. An ICD-10 cause code is mapped through OMOP concept relationships to a standard concept when available; the original cause code is retained as the source value.

## Observation periods

Implemented in [`03_tpr_and_dors_to_observation_period.sql`](../sql/omop/03_tpr_and_dors_to_observation_period.sql).

Partial migration dates are imputed in the direction that never counts time abroad as observed: immigrations to the last day and emigrations to the first day of the known month or year. Migration events without any date information (`0`) are discarded; an undated emigration is therefore ignored, and the person is considered resident until their next dated emigration, death, or the data lock point. An emigration and an immigration of the same person on the same date are ordered emigration first (left and returned the same day). Migration events are then cleaned by collapsing consecutive events of the same type (keeping the latest immigration or earliest emigration in each run). The `person` transformation applies the same date handling and ordering when selecting people observed after the anchor date.

People are treated as resident at the 2005-07-01 anchor date when a residency interval covers it, when they have no migration history, or when their first migration event is an emigration after the anchor date, whether or not they later return. The resulting residency intervals are bounded by the 2005-07-01 anchor, birth year, emigration, death, and 2024-12-31 data lock point. Intervals of the same person that overlap, share a day, or are separated by a single day are merged; intervals separated by more than one day remain separate periods. Periods with a start after their end are discarded.

The `observation_period_attrition` table reports, among other counts, the number of people with overlapping or adjacent (next period starting the day after the end) periods; both are expected to be zero.

## Visits

Implemented in [`04_par_to_visit_occurrence.sql`](../sql/omop/04_par_to_visit_occurrence.sql).

Inpatient (`par_sv`) and outpatient (`par_ov`) records are combined into `visit_occurrence` for people in `person`. Inpatient admission and discharge dates require exact parsing; outpatient visits are treated as single-day visits, with partial dates imputed to the midpoint. Overlapping or subsumed visits are collapsed, and merged visits receive the inpatient visit concept. The SQL comments identify censoring visit end dates at the observation-period end as work to do; the current transformation does not apply that censoring.

## Drug exposure

Implemented in [`05_lmed_to_drug_exposure.sql`](../sql/omop/05_lmed_to_drug_exposure.sql).

Eligible `lmed` rows exclude `otyp` H/L/A and `varutyp` HA/OV and are restricted to people in `person`. A dispensing date must be no later than that person's latest observation-period end date. The current SQL uses the latest period end, rather than checking that the entire exposure falls within one particular observation period.

The exposure starts on `edatum`; its end is calculated from `fddd` (using at least one day) and capped at the latest observation-period end date. `varunr` is mapped through `ext_vocab.varunr_to_concept_final` to standard Drug concepts; unmapped concepts receive ID `0`. The OMOP `drug_source_value` is currently populated from ATC, not VARUNR.

## Clinical event routing

The four scripts require `person` and route records by the target domain of the mapped concept:

- [`06a_parsv_to_condition_measurement_procedure_observation.sql`](../sql/omop/06a_parsv_to_condition_measurement_procedure_observation.sql) - inpatient `par_sv`;
- [`06b_parov_to_condition_measurement_procedure_observation.sql`](../sql/omop/06b_parov_to_condition_measurement_procedure_observation.sql) - outpatient `par_ov`;
- [`06c_dors_to_condition_measurement_procedure_observation.sql`](../sql/omop/06c_dors_to_condition_measurement_procedure_observation.sql) - cause-of-death `dors`;
- [`06d_can_to_condition_measurement_procedure_observation.sql`](../sql/omop/06d_can_to_condition_measurement_procedure_observation.sql) - cancer `can`.

The scripts create a routed intermediate representation and populate `condition_occurrence`, `measurement`, `procedure_occurrence`, or `observation` according to the mapped concept domain. Unmapped codes may be retained in `condition_occurrence` with concept ID `0`; behavior for other unmapped or non-condition domains is defined by each script.

Inpatient and outpatient diagnoses use the custom ICD-10-SE mapping; death causes use the ICD-10 mapping; and cancer codes use the custom ICD-O-3 mapping built from the source ICD-O-10 and SNOMED-10 values. Cancer rows with missing ICD-7 or mapped source values are excluded, and ICD-7 is retained as the OMOP source value. These scripts also apply source-specific date parsing and observation-period end-date filters.

## Demographic and LISA observations

[`07_grunduppgifter_lisa_to_observation.sql`](../sql/omop/07_grunduppgifter_lisa_to_observation.sql) adds country of birth from `grunduppgifter` and county of residence, civil status, education level, and disposable income from LISA to `observation` for people in `person`.

## Era tables

[`08_drug_era.sql`](../sql/omop/08_drug_era.sql) groups standard drug exposures by active ingredient using a 30-day persistence window. [`09_condition_era.sql`](../sql/omop/09_condition_era.sql) groups condition occurrences by condition concept using a 30-day persistence window and excludes condition concept ID `0`. Both scripts cap era end dates at the person's latest observation-period end date.

## Metadata

[`10_metadata.sql`](../sql/omop/10_metadata.sql) populates the `cdm_source` row with the SWEEP source description, ETL reference, CDM version, and vocabulary version.

## Dependencies

Before the core SQL orchestrator runs, the configured CDM schema and standard vocabularies must be initialized and the external vocabulary mappings must be loaded. The normal pipeline then runs:

1. [`01_setup_CDM.R`](../R/orchestrators/01_setup_CDM.R) creates the CDM schema and loads standard vocabularies.
2. [`02_setup_ext_vocab.R`](../R/orchestrators/02_setup_ext_vocab.R) loads external mappings.
3. [`03_omop_orchestrator.R`](../R/orchestrators/03_omop_orchestrator.R) runs the SQL transformations listed above.
4. [`04_indices_FK.R`](../R/orchestrators/04_indices_FK.R) creates indexes and foreign keys.

External vocabulary assets under `sql/external_vocabularies/` are used by drug and clinical-event mapping steps. The LISA step reads the `lisa_tpr_map` table in the configured external vocabulary schema, which `02_setup_ext_vocab.R` loads from `vocabularies/external/tpr_lisa_external_vocab.csv`. The shared SQL functions are created by `00_create_functions.sql` at the start of the core ETL.
