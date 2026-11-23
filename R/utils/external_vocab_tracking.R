stage_external_vocab_files <- function(paths) {
  staged <- character()
  success <- FALSE
  on.exit(if (!success) unlink(staged), add = TRUE)

  source_paths <- vapply(paths, normalizePath, character(1), winslash = "/", mustWork = TRUE)
  for (path in source_paths) {
    copy_path <- tempfile(fileext = paste0(".", tools::file_ext(path)))
    staged <- c(staged, copy_path)
    if (!file.copy(path, copy_path)) {
      stop(sprintf("Could not stage external vocabulary file: %s", path), call. = FALSE)
    }
  }
  names(staged) <- names(paths)
  checksums <- vapply(
    staged,
    function(path) digest::digest(file = path, algo = "sha256", serialize = FALSE),
    character(1)
  )
  success <- TRUE
  list(source_paths = source_paths, staged_paths = staged, checksums = checksums)
}

ensure_ext_vocab_loads_table <- function(con, metadata_schema) {
  schema_id <- as.character(DBI::dbQuoteIdentifier(con, metadata_schema))
  table_id <- as.character(DBI::dbQuoteIdentifier(con, DBI::Id(
    schema = metadata_schema, table = "external_vocab_loads"
  )))
  DBI::dbExecute(con, sprintf("CREATE SCHEMA IF NOT EXISTS %s", schema_id))
  DBI::dbExecute(
    con,
    sprintf(
      "CREATE TABLE IF NOT EXISTS %s (
        load_id BIGSERIAL PRIMARY KEY,
        ext_vocab_schema TEXT NOT NULL,
        started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        finished_at TIMESTAMPTZ,
        status TEXT NOT NULL,
        nplid_path TEXT NOT NULL,
        nplid_sha256 TEXT NOT NULL,
        icd10_path TEXT NOT NULL,
        icd10_sha256 TEXT NOT NULL,
        lisa_tpr_map_path TEXT,
        lisa_tpr_map_sha256 TEXT,
        table_fingerprint TEXT,
        error_message TEXT
      )",
      table_id
    )
  )
  DBI::dbExecute(con, sprintf("ALTER TABLE %s ADD COLUMN IF NOT EXISTS table_fingerprint TEXT", table_id))
  # TPR/LISA mapping file, tracked since it is loaded by 02_setup_ext_vocab.R (empty for older loads)
  DBI::dbExecute(con, sprintf("ALTER TABLE %s ADD COLUMN IF NOT EXISTS lisa_tpr_map_path TEXT", table_id))
  DBI::dbExecute(con, sprintf("ALTER TABLE %s ADD COLUMN IF NOT EXISTS lisa_tpr_map_sha256 TEXT", table_id))
  table_id
}

lock_external_vocab_schema <- function(con, ext_vocab_schema, shared = FALSE) {
  lock_function <- if (shared) "pg_try_advisory_lock_shared" else "pg_try_advisory_lock"
  acquired <- DBI::dbGetQuery(
    con,
    sprintf("SELECT %s(1163150678, hashtext($1)) AS acquired", lock_function),
    params = list(ext_vocab_schema)
  )$acquired[[1L]]
  if (!isTRUE(acquired)) {
    stop(sprintf("External vocabulary schema '%s' is in use by another setup or ETL run.", ext_vocab_schema),
      call. = FALSE
    )
  }
}

start_external_vocab_load <- function(con, table_id, ext_vocab_schema, files) {
  DBI::dbGetQuery(
    con,
    sprintf(
      "INSERT INTO %s (ext_vocab_schema, status, nplid_path, nplid_sha256, icd10_path, icd10_sha256,
                       lisa_tpr_map_path, lisa_tpr_map_sha256)
       VALUES ($1, 'running', $2, $3, $4, $5, $6, $7) RETURNING load_id",
      table_id
    ),
    params = list(
      ext_vocab_schema,
      unname(files$source_paths[["nplid"]]),
      unname(files$checksums[["nplid"]]),
      unname(files$source_paths[["icd10"]]),
      unname(files$checksums[["icd10"]]),
      unname(files$source_paths[["lisa_tpr_map"]]),
      unname(files$checksums[["lisa_tpr_map"]])
    )
  )$load_id[[1L]]
}

ext_vocab_table_fingerprint <- function(con, ext_vocab_schema) {
  tables <- DBI::dbGetQuery(
    con,
    paste(
      "SELECT count(*) AS n, string_agg(c.oid::text, ',' ORDER BY c.relname) AS fingerprint",
      "FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace",
      "WHERE n.nspname = $1 AND c.relkind IN ('r', 'p')",
      "AND c.relname IN ('varunr_to_concept_final', 'icd10_se_who_snomed_map', 'icd10_who_snomed_map',",
      "'lisa_tpr_map')"
    ),
    params = list(ext_vocab_schema)
  )
  if (tables$n[[1L]] != 4L) {
    stop(sprintf("External vocabulary schema '%s' is missing mapping tables.", ext_vocab_schema), call. = FALSE)
  }
  tables$fingerprint[[1L]]
}

finish_external_vocab_load <- function(con, table_id, load_id, status, error_message = NULL, fingerprint = NULL) {
  DBI::dbExecute(
    con,
    sprintf(
      "UPDATE %s SET status = $1, finished_at = now(), error_message = $2, table_fingerprint = $3
       WHERE load_id = $4",
      table_id
    ),
    params = list(
      status,
      if (is.null(error_message)) NA_character_ else error_message,
      if (is.null(fingerprint)) NA_character_ else fingerprint,
      load_id
    )
  )
}

record_external_vocab_load <- function(con, loads_table_id, runs_table_id, run_id, ext_vocab_schema) {
  load <- DBI::dbGetQuery(
    con,
    sprintf(
      "SELECT load_id, status, table_fingerprint FROM %s WHERE ext_vocab_schema = $1 ORDER BY load_id DESC LIMIT 1",
      loads_table_id
    ),
    params = list(ext_vocab_schema)
  )
  if (nrow(load) == 0L) {
    return(NULL)
  }
  if (!identical(load$status[[1L]], "completed")) {
    stop(sprintf(
      "Latest external vocabulary load for schema '%s' has status '%s'; rerun external vocabulary setup.",
      ext_vocab_schema, load$status[[1L]]
    ), call. = FALSE)
  }
  current_fingerprint <- ext_vocab_table_fingerprint(con, ext_vocab_schema)
  if (is.na(load$table_fingerprint[[1L]]) || load$table_fingerprint[[1L]] != current_fingerprint) {
    stop(sprintf(
      "External vocabulary mapping tables for schema '%s' no longer match the recorded load.",
      ext_vocab_schema
    ), call. = FALSE)
  }
  DBI::dbExecute(
    con,
    sprintf("UPDATE %s SET ext_vocab_load_id = $1 WHERE run_id = $2", runs_table_id),
    params = list(load$load_id[[1L]], run_id)
  )
  load$load_id[[1L]]
}
