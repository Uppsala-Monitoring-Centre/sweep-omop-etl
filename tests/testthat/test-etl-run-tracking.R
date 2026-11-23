test_that("build_cdm_etl_reference uses tag plus short commit when tag is present", {
  ref <- build_cdm_etl_reference(
    git_commit = "abcdef1234567890",
    git_tag = "v1.2.3"
  )

  expect_equal(ref, "v1.2.3 (abcdef1)")
})

test_that("build_cdm_etl_reference falls back to short commit when tag is missing", {
  ref <- build_cdm_etl_reference(
    git_commit = "abcdef1234567890",
    git_tag = NA_character_
  )

  expect_equal(ref, "abcdef1")
})

test_that("CDM ETL reference placeholder is rendered into metadata SQL", {
  sql_path <- tempfile(fileext = ".sql")
  writeLines(
    c(
      "INSERT INTO x VALUES ('{{CDM_ETL_REFERENCE}}');"
    ),
    sql_path
  )

  rendered <- run_sql_file(
    con = NULL,
    file_path = sql_path,
    replacements = list(CDM_ETL_REFERENCE = "v1.2.3 (abcdef1)"),
    dry_run = TRUE
  )

  expect_true(grepl("v1.2.3 (abcdef1)", rendered, fixed = TRUE))
  expect_false(grepl("{{CDM_ETL_REFERENCE}}", rendered, fixed = TRUE))
})

test_that("tracking table creates and migrates vocabulary metadata columns", {
  statements <- character()
  local_mocked_bindings(
    dbExecute = function(conn, statement, ...) {
      statements <<- c(statements, statement)
      0L
    },
    .package = "DBI"
  )

  table_id <- ensure_etl_runs_table(DBI::ANSI(), "metadata")

  expect_equal(table_id, '"metadata"."etl_runs"')
  expect_true(any(grepl("ADD COLUMN IF NOT EXISTS ext_vocab_schema TEXT", statements, fixed = TRUE)))
  expect_true(any(grepl("ADD COLUMN IF NOT EXISTS ext_vocab_load_id BIGINT", statements, fixed = TRUE)))
  expect_true(any(grepl("ADD COLUMN IF NOT EXISTS athena_vocabulary_version TEXT", statements, fixed = TRUE)))
})

test_that("Athena release is read from the output schema and stored for the run", {
  query <- NULL
  update <- NULL
  local_mocked_bindings(
    dbGetQuery = function(conn, statement, ...) {
      query <<- statement
      data.frame(vocabulary_version = "v5.0 20261101")
    },
    dbExecute = function(conn, statement, params, ...) {
      update <<- list(statement = statement, params = params)
      1L
    },
    .package = "DBI"
  )

  version <- record_athena_version(DBI::ANSI(), '"metadata"."etl_runs"', 42L, "omop")

  expect_equal(version, "v5.0 20261101")
  expect_match(query, '"omop"."vocabulary"', fixed = TRUE)
  expect_match(query, "vocabulary_id = 'None'", fixed = TRUE)
  expect_equal(update$params, list("v5.0 20261101", 42L))
})

test_that("missing, empty, or duplicate Athena releases fail without updating tracking", {
  versions <- character()
  updated <- FALSE
  local_mocked_bindings(
    dbGetQuery = function(conn, statement, ...) data.frame(vocabulary_version = versions),
    dbExecute = function(conn, statement, ...) {
      updated <<- TRUE
      1L
    },
    .package = "DBI"
  )

  for (value in list(character(), NA_character_, "  ", c("v1", "v2"))) {
    versions <- value
    expect_error(
      record_athena_version(DBI::ANSI(), '"metadata"."etl_runs"', 42L, "omop"),
      "Expected exactly one non-empty Athena release"
    )
  }
  expect_false(updated)
})

test_that("CDM metadata reads the Athena release from the output vocabulary", {
  rendered <- run_sql_file(
    con = NULL,
    file_path = file.path(project_root, "sql", "omop", "10_metadata.sql"),
    replacements = list(
      OUTPUT_SCHEMA = "omop",
      CDM_ETL_REFERENCE = "abc1234"
    ),
    dry_run = TRUE
  )

  expect_match(rendered, "vocabulary_version", fixed = TRUE)
  expect_match(rendered, "FROM omop.vocabulary", fixed = TRUE)
  expect_match(rendered, "WHERE vocabulary_id = 'None'", fixed = TRUE)
  expect_false(grepl("{{", rendered, fixed = TRUE))
})
