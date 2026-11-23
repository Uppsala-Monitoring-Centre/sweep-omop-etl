# SWEEP ETL Purpose

## Purpose

This project transforms raw Swedish register data into cleaned and standardized OMOP Common Data Model (CDM) tables. The resulting database is intended to support reproducible epidemiological research and downstream cohort definition using a standardized data model.

Mapping is performed using the OMOP CDM version and vocabulary release available at the time of execution. The specific versions used for each ETL release and run are recorded in the release documentation and ETL metadata to support traceability and reproducibility across data deliveries.

The pipeline is implemented in R and SQL and runs against PostgreSQL. It preserves source identifiers and source values where appropriate while adding OMOP standard concepts, dates, domains, and relationships.

## Data sources

The current ETL uses these source register areas:

- `grunduppgifter`: basic demographic and population information;
- `dors`: cause-of-death information;
- `migrationer`: immigration and emigration events;
- `lmed`: prescribed or dispensed medication records;
- `par_sv`: inpatient care records;
- `par_ov`: outpatient care records;
- `can`: cancer register records.

The source tables are configured through the active YAML settings file. The database schema names can vary by environment and data release.

## Study population and observation window

The SWEEP cohort is anchored at `2005-07-01`, corresponding to the beginning of the medication data used by the pipeline. The current data lock point documented in the mapping register is `2024-12-31`.

The `person` transformation applies eligibility, data-quality, and plausibility constraints. The resulting `person` table is the population anchor for downstream OMOP tables. Other event tables are restricted to people retained in `person` and, where applicable, to their observation periods.

Observation periods may contain more than one interval for a person. This supports people who leave Sweden and later return, while avoiding treating time outside the observed population as observed follow-up.

## Intended use

The output is intended for:

- standardized cohort construction;
- analysis of diagnoses, visits, medications, deaths, and selected patient attributes;
- reproducible research across data releases;
- validation of source-to-OMOP mapping decisions.

The ETL is not a complete statement of study-specific inclusion criteria. Researchers should apply additional cohort restrictions using the documented observation periods and the relevant OMOP concept and source values.

## Scope and limitations

The mapping register is the detailed record of field-level decisions. The SQL files are the executable source of truth. These artifacts must be reviewed together when the transformation changes.

Important limitations currently recorded in the mapping materials include incomplete source dates, possible administrative inconsistencies in migration records, unresolved vocabulary mappings, and follow-up work around drug exposure dates and clinical-event routing.

## Related documentation

- [Mapping overview](Documentation_Mapping.md)
- [Transformation rules](transformation.md)
- [Vocabulary mappings](vocabulary.md)
- [Data quality and open issues](data_quality.md)
- [Detailed mapping register](SWEEP_ETL_specification.xlsx)
