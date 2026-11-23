# Data Quality and Open Issues

This page records quality rules, validation expectations, and unresolved issues for the SWEEP ETL. The detailed field-level rules are maintained in [SWEEP_ETL_specification.xlsx](SWEEP_ETL_specification.xlsx), while executable checks and transformations are in the SQL files.

## Quality principles

The ETL should make exclusions and imputations explicit, preserve source values where possible, and record enough metadata to reproduce a run. A mapping is not complete until its business rationale, fallback behavior, and known limitations are documented.

## Population checks

The `person` table is the population anchor. Review the following checks after each ETL run:

- number of source persons and number retained in `person`;
- counts removed for invalid sex, birth year, personal identifiers, coordination numbers, and implausible dates;
- number of people with and without medication records;
- number of people with death or migration records;
- consistency of person identifiers across downstream tables.

The ETL logs row counts and run status in the metadata tracking tables. Attrition tables are also created for selected transformations, including drug exposure.

## Date checks

Review date parsing and endpoint behavior for:

- partial or invalid dates in registry sources;
- death dates imputed to the end of a month or year;
- observation-period start and end dates;
- inpatient and outpatient admission dates;
- drug exposure end dates;
- events beyond the `2024-12-31` data lock point;
- events outside a person's observation period.

The mapping register should state whether an invalid date is excluded, imputed, or retained as a source value.

## Duplicate and overlap checks

Known or required checks include:

- duplicate death records, including `_AVI_` and `R999` records;
- repeated source records for the same person, drug, and dispensing date;
- overlapping observation periods;
- overlapping or duplicate visit records;
- repeated clinical events within a visit;
- uniqueness of generated OMOP identifiers.

Overlapping, same-day, and one-day-apart observation periods of the same person are merged. The observation-period attrition table counts people with overlapping or adjacent periods, which should both be zero; a regression test for the merge is still missing.

## Vocabulary checks

Review:

- proportion of source diagnosis codes mapped to standard concepts;
- proportion of drug codes mapped to standard Drug concepts;
- domain compatibility of selected concepts;
- count of records assigned concept ID `0`;
- changes in mapping coverage between vocabulary releases;
- preservation of original source codes.

Vocabulary assets and their release dates should be recorded with each production ETL release.

## Clinical-event checks

The clinical event transformations route records among `condition_occurrence`, `measurement`, `procedure_occurrence`, and `observation`. Validate that:

- every routed record has a valid person;
- the selected target domain agrees with the concept domain;
- source diagnosis, external-cause, death, and cancer codes are retained where expected;
- the workbook documents all four output tables, including measurement and procedure occurrence;
- event dates are within the appropriate observation period.

## Open issues from the mapping register

Current items requiring confirmation or implementation include:

- review the death-date precedence and incomplete-date imputation strategy;
- add a regression test for the merging of overlapping and adjacent observation periods;
- confirm the source fields used for observation attributes;
- review VARUNR-to-RxNorm mappings and future NPL-ID integration;
- refine drug exposure end dates when duration or dose information is incomplete;
- revise invalid-date handling for clinical events;
- confirm use of HDIA when diagnosis fields are missing;
- decide whether ICD-10 mappings should use direct OMOP vocabulary relationships;
- add dedicated workbook coverage for measurement and procedure occurrence.

## Validation commands

Run the unit tests with:

```r
testthat::test_dir("tests/testthat")
```

Run the orchestrator smoke tests with:

```r
Rscript -e "testthat::test_file('tests/testthat/test-orchestrators-smoke.R')"
```

The smoke configuration requires the external mapping CSV files configured in `config/settings.smoke.yaml`.
