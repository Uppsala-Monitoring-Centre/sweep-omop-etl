get_git_value <- function(args, default = NA_character_) {
  tryCatch(
    {
      value <- suppressWarnings(system2("git", args, stdout = TRUE, stderr = FALSE))
      if (length(value) == 0) {
        default
      } else {
        trimws(value[[1L]])
      }
    },
    error = function(e) {
      default
    }
  )
}

get_git_metadata <- function() {
  commit <- get_git_value(c("rev-parse", "HEAD"), default = "unknown")
  branch <- get_git_value(c("rev-parse", "--abbrev-ref", "HEAD"), default = NA_character_)
  tag <- get_git_value(c("describe", "--tags", "--exact-match"), default = NA_character_)
  status <- get_git_value(c("status", "--porcelain"), default = "")

  list(
    commit = commit,
    branch = branch,
    tag = tag,
    is_dirty = nzchar(status)
  )
}

build_cdm_etl_reference <- function(git_commit, git_tag) {
  short_commit <- substr(git_commit, 1L, 7L)

  if (!is.na(git_tag) && nzchar(git_tag)) {
    sprintf("%s (%s)", git_tag, short_commit)
  } else {
    short_commit
  }
}

ensure_etl_runs_table <- function(con, metadata_schema) {
  schema_id <- as.character(DBI::dbQuoteIdentifier(con, metadata_schema))
  table_id <- as.character(DBI::dbQuoteIdentifier(con, DBI::Id(schema = metadata_schema, table = "etl_runs")))

  DBI::dbExecute(con, sprintf("CREATE SCHEMA IF NOT EXISTS %s", schema_id))
  DBI::dbExecute(
    con,
    sprintf(
      "CREATE TABLE IF NOT EXISTS %s (
        run_id BIGSERIAL PRIMARY KEY,
        started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
        finished_at TIMESTAMPTZ,
        status TEXT NOT NULL DEFAULT 'running',
        etl_version TEXT,
        git_commit TEXT NOT NULL,
        git_branch TEXT,
        git_tag TEXT,
        is_dirty BOOLEAN,
        config_path TEXT,
        input_schema TEXT,
        output_schema TEXT,
        ext_vocab_schema TEXT,
        ext_vocab_load_id BIGINT,
        athena_vocabulary_version TEXT,
        run_user TEXT,
        files_processed INTEGER NOT NULL DEFAULT 0,
        successful_files INTEGER NOT NULL DEFAULT 0,
        failed_files INTEGER NOT NULL DEFAULT 0,
        error_message TEXT
      )",
      table_id
    )
  )

  # Migrate existing tables: add new columns if they don't exist
  DBI::dbExecute(
    con,
    sprintf("ALTER TABLE %s ADD COLUMN IF NOT EXISTS git_tag TEXT", table_id)
  )

  DBI::dbExecute(
    con,
    sprintf("ALTER TABLE %s ADD COLUMN IF NOT EXISTS run_user TEXT", table_id)
  )

  DBI::dbExecute(
    con,
    sprintf("ALTER TABLE %s ADD COLUMN IF NOT EXISTS ext_vocab_schema TEXT", table_id)
  )

  DBI::dbExecute(
    con,
    sprintf("ALTER TABLE %s ADD COLUMN IF NOT EXISTS ext_vocab_load_id BIGINT", table_id)
  )

  DBI::dbExecute(
    con,
    sprintf("ALTER TABLE %s ADD COLUMN IF NOT EXISTS athena_vocabulary_version TEXT", table_id)
  )

  table_id
}

start_etl_run <- function(
  con,
  table_id,
  etl_version,
  git_commit,
  git_branch,
  git_tag,
  is_dirty,
  config_path,
  input_schema,
  output_schema,
  ext_vocab_schema
) {
  # Capture the current system user
  run_user <- Sys.info()[["user"]]

  insert_sql <- sprintf(
    "INSERT INTO %s (
      status,
      etl_version,
      git_commit,
      git_branch,
      git_tag,
      is_dirty,
      config_path,
      input_schema,
      output_schema,
      run_user,
      ext_vocab_schema
    ) VALUES (
      'running',
      %s,
      %s,
      %s,
      %s,
      %s,
      %s,
      %s,
      %s,
      %s,
      %s
    ) RETURNING run_id",
    table_id,
    as.character(DBI::dbQuoteString(con, etl_version)),
    as.character(DBI::dbQuoteString(con, git_commit)),
    if (is.na(git_branch)) "NULL" else as.character(DBI::dbQuoteString(con, git_branch)),
    if (is.na(git_tag)) "NULL" else as.character(DBI::dbQuoteString(con, git_tag)),
    if (isTRUE(is_dirty)) "TRUE" else "FALSE",
    as.character(DBI::dbQuoteString(con, config_path)),
    as.character(DBI::dbQuoteString(con, input_schema)),
    as.character(DBI::dbQuoteString(con, output_schema)),
    as.character(DBI::dbQuoteString(con, run_user)),
    as.character(DBI::dbQuoteString(con, ext_vocab_schema))
  )

  DBI::dbGetQuery(con, insert_sql)$run_id[[1L]]
}

record_athena_version <- function(con, table_id, run_id, output_schema) {
  vocabulary_table <- DBI::dbQuoteIdentifier(con, DBI::Id(schema = output_schema, table = "vocabulary"))
  version <- DBI::dbGetQuery(
    con,
    sprintf("SELECT vocabulary_version FROM %s WHERE vocabulary_id = 'None'", vocabulary_table)
  )$vocabulary_version

  if (length(version) != 1L || is.na(version) || !nzchar(trimws(version))) {
    stop("Expected exactly one non-empty Athena release version in vocabulary_id 'None'.", call. = FALSE)
  }

  DBI::dbExecute(
    con,
    sprintf("UPDATE %s SET athena_vocabulary_version = $1 WHERE run_id = $2", table_id),
    params = list(version, run_id)
  )
  version
}

finish_etl_run <- function(
  con,
  table_id,
  run_id,
  status,
  files_processed,
  successful_files,
  failed_files,
  error_message
) {
  update_sql <- sprintf(
    "UPDATE %s
     SET finished_at = now(),
         status = %s,
         files_processed = %d,
         successful_files = %d,
         failed_files = %d,
         error_message = %s
     WHERE run_id = %d",
    table_id,
    as.character(DBI::dbQuoteString(con, status)),
    as.integer(files_processed),
    as.integer(successful_files),
    as.integer(failed_files),
    if (is.null(error_message)) "NULL" else as.character(DBI::dbQuoteString(con, error_message)),
    as.integer(run_id)
  )

  DBI::dbExecute(con, update_sql)
}
