# SWEEP OMOP ETL

This site documents the ETL pipeline (R orchestrators with SQL logic) that maps Swedish register data, delivered by Socialstyrelsen (SoS) and Statistics Sweden (SCB), into the OMOP Common Data Model.

## Where to start

- [Mapping overview](Documentation_Mapping.md): architecture, execution order, configuration, and the main mapping decisions.
- [Purpose](purpose.md): why the ETL exists, its source data, study population, observation window, and intended use.
- [Transformation rules](transformation.md): how each source is transformed into OMOP tables, including dependencies, exclusions, date handling, and clinical-event routing.
- [Vocabulary mappings](vocabulary.md): Athena, ICD-10, SNOMED, VARUNR, RxNorm, and custom mapping assets.
- [Data quality](data_quality.md): validation expectations, attrition checks, known defects, and open mapping questions.
- [Mapping register](mapping_register.md): the field-level mappings for every OMOP table, from the ETL specification workbook.
- [Releases](RELEASES.md): version-specific release details and verification information.

## Sources of truth

The SQL files are the executable source of truth. The [specification workbook](SWEEP_ETL_specification.xlsx) holds the row-level mapping register, and these pages explain the decisions and how the transformations relate. Where they differ, the SQL wins.

The code is on [GitHub](https://github.com/Uppsala-Monitoring-Centre/sweep-omop-etl).
