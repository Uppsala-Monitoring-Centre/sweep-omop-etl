# External vocabulary files

Mapping files maintained by the project and loaded by `R/orchestrators/02_setup_ext_vocab.R`.
Their paths are set under `vocabularies.external` in `config/settings.<env>.yaml`.
Changes to these files go through review like code.

| File | Loaded into | Used by |
|---|---|---|
| `tpr_lisa_external_vocab.csv` | `{ext_vocab_schema}.lisa_tpr_map` | `sql/omop/07_grunduppgifter_lisa_to_observation.sql` |

## `tpr_lisa_external_vocab.csv`

Maps TPR (`grunduppgifter`) and LISA variables to OMOP concepts: country of birth, county of
residence, civil status, education level and disposable income.

- Semicolon-separated, UTF-8, header row, no quoting (values must not contain `;`).
- One row per `source_variable_description` + `source_code`. The pair must be unique: step 07 joins on
  it, so a duplicate would duplicate observations. `02_setup_ext_vocab.R` stops if it finds one.
- `observation_concept_id`, `value_as_concept_id` and `value_as_number` must be integers or empty.

Edit with a text editor rather than Excel: Excel can change the separator or encoding, and its
fill-down can change values (e.g. increment numbers at the end of variable names).

## Not in this folder

External vocabularies produced outside the project stay outside the repository and are read from
the paths in the configuration, e.g. the NPLID to RxNorm mapping file
(`nplid_to_rxnorm_csv_path`) and Socialstyrelsen's ICD-10-SE code list (`icd10se_codes_tsv_path`).

### ICD-10-SE code list

`02_setup_ext_vocab.R` loads the complete ICD-10-SE classification into `{ext_vocab_schema}.icd10se_codes`.
The file is not in the repository: ICD-10 is copyrighted by WHO and the Swedish version by the
Swedish authorities, and no terms allowing redistribution are published.

| | |
|---|---|
| File | Hela klassifikationen ICD-10-SE giltig från 2025-01-01 (tsv) |
| Publisher | Socialstyrelsen (ICD-10-SE is now maintained by E-hälsomyndigheten) |
| Version used | valid from 2025-01-01 (latest `Giltig från` date in the file: 2025) |
| Format | tab-separated, UTF-8 with BOM, quoted values, header row, about 15 MB |
| SHA-256 | `6e41fe028899403d21e6398080e4ab3a71934d6d89d2f6a8cf6396b0a61d6ce7` |
| Config key | `vocabularies.external.icd10se_codes_tsv_path` |

The complete classification is publicly available as a downloadable file, with no access request
needed, from E-hälsomyndigheten's
[Ladda ner filer för klassifikationer](https://samarbetsyta.ehalsomyndigheten.se/spaces/IR2/pages/451267009/Ladda+ner+filer+f%C3%B6r+klassifikationer)
page. A version downloaded from there that differs from the one above will have a different SHA-256;
when you change version, update the table.

Before using a copy, check that its checksum matches the one above (PowerShell:
`Get-FileHash <path>`; Linux/macOS: `sha256sum <path>`). `02_setup_ext_vocab.R` needs the columns
`Kod`, `Titel` and `Kodnivå - kodspecifikation`, and records the path and SHA-256 of the file used in
`external_vocab_loads`.
