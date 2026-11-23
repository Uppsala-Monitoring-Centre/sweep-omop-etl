test_that("staged files preserve the loaded content and its SHA-256", {
  nplid <- tempfile(fileext = ".csv")
  icd10 <- tempfile(fileext = ".csv")
  on.exit(unlink(c(nplid, icd10)), add = TRUE)
  writeLines("original nplid", nplid)
  writeLines("original icd10", icd10)

  files <- stage_external_vocab_files(c(nplid = nplid, icd10 = icd10))
  on.exit(unlink(files$staged_paths), add = TRUE)
  writeLines("changed later", nplid)

  expect_equal(readLines(files$staged_paths[["nplid"]]), "original nplid")
  expect_equal(files$checksums[["nplid"]], digest::digest(file = files$staged_paths[["nplid"]], algo = "sha256"))
  expect_false(identical(files$checksums[["nplid"]], digest::digest(file = nplid, algo = "sha256")))
  expect_equal(tools::file_ext(files$staged_paths[["icd10"]]), "csv")
})

test_that("load provenance records original paths and staged file checksums", {
  inserted <- NULL
  local_mocked_bindings(
    dbGetQuery = function(conn, statement, params, ...) {
      inserted <<- params
      data.frame(load_id = 7L)
    },
    .package = "DBI"
  )
  files <- list(
    source_paths = c(nplid = "original-nplid.csv", icd10 = "original-icd.csv", lisa_tpr_map = "original-lisa.csv"),
    checksums = c(nplid = "hash1", icd10 = "hash2", lisa_tpr_map = "hash3")
  )

  expect_equal(start_external_vocab_load(DBI::ANSI(), "loads", "vocab", files), 7L)
  expect_equal(
    inserted,
    list("vocab", "original-nplid.csv", "hash1", "original-icd.csv", "hash2", "original-lisa.csv", "hash3")
  )
})

test_that("a completed matching external vocabulary load is linked to the ETL run", {
  updated <- NULL
  local_mocked_bindings(
    dbGetQuery = function(conn, statement, params, ...) {
      if (grepl("pg_catalog.pg_class", statement, fixed = TRUE)) {
        return(data.frame(n = 4L, fingerprint = "11,12,13,14"))
      }
      data.frame(load_id = 7L, status = "completed", table_fingerprint = "11,12,13,14")
    },
    dbExecute = function(conn, statement, params, ...) {
      updated <<- params
      1L
    },
    .package = "DBI"
  )

  expect_equal(record_external_vocab_load(DBI::ANSI(), "loads", "runs", 42L, "vocab"), 7L)
  expect_equal(updated, list(7L, 42L))
})

test_that("untracked, incomplete, and replaced loads are not incorrectly linked", {
  load <- data.frame(load_id = integer(), status = character(), table_fingerprint = character())
  fingerprint <- "11,12,13,14"
  updated <- FALSE
  local_mocked_bindings(
    dbGetQuery = function(conn, statement, params, ...) {
      if (grepl("pg_catalog.pg_class", statement, fixed = TRUE)) {
        return(data.frame(n = 4L, fingerprint = fingerprint))
      }
      load
    },
    dbExecute = function(conn, statement, params, ...) {
      updated <<- TRUE
      1L
    },
    .package = "DBI"
  )

  expect_null(record_external_vocab_load(DBI::ANSI(), "loads", "runs", 42L, "vocab"))
  for (status in c("running", "failed")) {
    load <- data.frame(load_id = 7L, status = status, table_fingerprint = NA_character_)
    expect_error(record_external_vocab_load(DBI::ANSI(), "loads", "runs", 42L, "vocab"), status)
  }
  load <- data.frame(load_id = 7L, status = "completed", table_fingerprint = "different")
  expect_error(record_external_vocab_load(DBI::ANSI(), "loads", "runs", 42L, "vocab"), "no longer match")
  expect_false(updated)
})

test_that("a conflicting external vocabulary lock stops the operation", {
  statements <- character()
  local_mocked_bindings(
    dbGetQuery = function(conn, statement, params, ...) {
      statements <<- c(statements, statement)
      data.frame(acquired = FALSE)
    },
    .package = "DBI"
  )
  expect_error(lock_external_vocab_schema(DBI::ANSI(), "vocab"), "in use")
  expect_error(lock_external_vocab_schema(DBI::ANSI(), "vocab", shared = TRUE), "in use")
  expect_match(statements[[1L]], "pg_try_advisory_lock(", fixed = TRUE)
  expect_match(statements[[2L]], "pg_try_advisory_lock_shared(", fixed = TRUE)
})
