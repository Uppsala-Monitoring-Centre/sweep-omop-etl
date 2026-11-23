source("R/utils/logging.R")

library(DBI)
library(logger)
library(readxl)
library(tools)

# col_names: NULL = take the names from the file's header row.
# as_text: read every column as text, so long identifiers (e.g. NPLID) are not
# turned into numbers (which loses digits or gives scientific notation).
load_csv_xlsx_or_stop <- function(path, sep, col_names = NULL, as_text = FALSE) {
  if (!file.exists(path)) {
    log_error("CSV or XLSX file not found: {path}")
    stop(sprintf("CSV or XLSX file not found: %s", path))
  }

  if (file_ext(path) == "xlsx") {
    df <- read_excel(
      path,
      col_names = if (is.null(col_names)) TRUE else col_names,
      col_types = if (as_text) "text" else NULL
    )
  } else if (file_ext(path) == "csv") {
    # col.names must only be passed when given: col.names = NULL makes
    # read.csv ignore the header and fail with "more columns than column names"
    args <- list(file = path, sep = sep)
    if (!is.null(col_names)) args$col.names <- col_names
    if (as_text) args$colClasses <- "character"
    df <- do.call(read.csv, args)
  } else {
    log_error("Unsupported file format: {path}")
    stop(sprintf("Unsupported file format: %s", path))
  }

  df
}

# Read Socialstyrelsen's ICD-10-SE code list (tab-separated, UTF-8 with BOM, Swedish
# column names) and return the three columns used by the ICD-10-SE mapping:
# kod, titel and kodniva_kodspecifikation, all as text.
load_icd10se_codes_or_stop <- function(path) {
  if (!file.exists(path)) {
    log_error("ICD-10-SE code list not found: {path}")
    stop(sprintf("ICD-10-SE code list not found: %s", path))
  }

  df <- utils::read.delim(
    path,
    sep = "\t",
    quote = "\"",
    colClasses = "character",
    fileEncoding = "UTF-8-BOM",
    check.names = FALSE,
    na.strings = character(0)
  )

  # Source column names (non-ASCII letters written as escapes)
  source_cols <- c(
    kod = "Kod",
    titel = "Titel",
    kodniva_kodspecifikation = "Kodniv\u00e5 - kodspecifikation"
  )
  missing <- setdiff(source_cols, names(df))
  if (length(missing) > 0) {
    log_error("ICD-10-SE code list {path} lacks columns: {paste(missing, collapse = ', ')}")
    stop(sprintf("ICD-10-SE code list %s lacks columns: %s", path, paste(missing, collapse = ", ")))
  }

  df <- df[, unname(source_cols)]
  names(df) <- names(source_cols)
  df
}

# Read the project's TPR/LISA mapping file (semicolon-separated, UTF-8) and check it
# before loading: all expected columns present, integer columns numeric, and each
# source_variable_description + source_code pair unique (07_grunduppgifter_lisa_to_observation.sql
# joins on that pair, so a duplicate would duplicate observations).
load_lisa_tpr_map_or_stop <- function(path) {
  if (!file.exists(path)) {
    log_error("TPR/LISA mapping file not found: {path}")
    stop(sprintf("TPR/LISA mapping file not found: %s", path))
  }

  df <- utils::read.csv(
    path,
    sep = ";",
    colClasses = "character",
    fileEncoding = "UTF-8",
    na.strings = "",
    check.names = FALSE
  )

  expected_cols <- c(
    "data_holder", "data_source", "source_variable", "source_variable_description", "data_type",
    "source_code", "value_source_value", "observation_source_value", "observation_concept_id",
    "value_as_concept_id", "value_as_number", "value_as_string"
  )
  missing <- setdiff(expected_cols, names(df))
  if (length(missing) > 0) {
    log_error("TPR/LISA mapping file {path} lacks columns: {paste(missing, collapse = ', ')}")
    stop(sprintf("TPR/LISA mapping file %s lacks columns: %s", path, paste(missing, collapse = ", ")))
  }
  df <- df[, expected_cols]

  key <- paste(df$source_variable_description, df$source_code, sep = " | ")
  duplicated_keys <- unique(key[duplicated(key)])
  if (length(duplicated_keys) > 0) {
    log_error("TPR/LISA mapping file {path} has duplicate codes: {paste(duplicated_keys, collapse = '; ')}")
    stop(sprintf(
      "TPR/LISA mapping file %s has duplicate description + code pairs: %s",
      path, paste(duplicated_keys, collapse = "; ")
    ))
  }

  for (col in c("observation_concept_id", "value_as_concept_id", "value_as_number")) {
    values <- df[[col]]
    not_integer <- !is.na(values) & !grepl("^-?[0-9]+$", values)
    if (any(not_integer)) {
      stop(sprintf(
        "TPR/LISA mapping file %s: column %s has non-integer values: %s",
        path, col, paste(unique(values[not_integer]), collapse = ", ")
      ))
    }
    df[[col]] <- as.integer(values)
  }

  df
}

read_sql_file <- function(file_path) {
  if (!file.exists(file_path)) {
    stop(sprintf("SQL file not found: %s", file_path))
  }

  paste(readLines(file_path, warn = FALSE), collapse = "\n")
}

replace_sql_placeholders <- function(sql_text, replacements = list()) {
  if (length(replacements) == 0) {
    return(sql_text)
  }

  for (nm in names(replacements)) {
    placeholder <- paste0("{{", nm, "}}")
    sql_text <- gsub(placeholder, replacements[[nm]], sql_text, fixed = TRUE)
  }

  sql_text
}

# executes SQL and adds the entire SQL text to the error
# message if an error occurs. The default error message may
# not contain the entire SQL text.
run_sql <- function(con, sql_text) {
  tryCatch(
    DBI::dbExecute(con, sql_text),
    error = function(e) {
      stop(
        sprintf(
          "SQL execution failed with error %s when running this SQL: `%s`.",
          conditionMessage(e),
          sql_text
        ),
        call. = FALSE
      )
    }
  )
}

run_sql_file <- function(con,
                         file_path,
                         replacements = list(),
                         block_conditions = list(),
                         strip_line_comments = TRUE,
                         split_statements = TRUE,
                         dry_run = FALSE) {
  log_info("Running SQL file: {file_path}")

  sql_text <- read_sql_file(file_path)
  sql_text <- replace_sql_placeholders(sql_text, replacements)

  if (length(block_conditions) > 0) {
    for (block_name in names(block_conditions)) {
      condition <- block_conditions[[block_name]]
      should_remove <- if (is.function(condition)) {
        isTRUE(condition(replacements))
      } else {
        isTRUE(condition)
      }

      if (should_remove) {
        pattern <- sprintf("(?s)-- %s_START.*?-- %s_END", block_name, block_name)
        sql_text <- gsub(pattern, "", sql_text, perl = TRUE)
      }
    }
  }

  if (strip_line_comments) {
    # Strip -- line comments before splitting so semicolons in comments do not
    # create extra statements.
    sql_text <- gsub("--[^\n]*", "", sql_text)
  }

  if (dry_run) {
    log_warn("Dry run enabled. SQL not executed for: {file_path}")
    return(invisible(sql_text))
  }

  if (split_statements) {
    stmts <- strsplit(sql_text, ";", fixed = TRUE)[[1L]]
    stmts <- trimws(stmts)
    stmts <- stmts[nzchar(stmts)]
    for (stmt in stmts) {
      run_sql(con, stmt)
    }
  } else {
    run_sql(con, sql_text)
  }
  invisible(TRUE)
}

list_sql_files <- function(dir_path) {
  if (!dir.exists(dir_path)) {
    stop(sprintf("Directory does not exist: %s", dir_path))
  }

  files <- list.files(
    path = dir_path,
    pattern = "\\.sql$",
    full.names = TRUE
  )

  sort(files)
}

run_sql_directory <- function(con, dir_path, replacements = list(), dry_run = FALSE) {
  sql_files <- list_sql_files(dir_path)

  if (length(sql_files) == 0) {
    log_warn("No SQL files found in: {dir_path}")
    return(invisible(NULL))
  }

  for (file_path in sql_files) {
    run_sql_file(con, file_path, replacements = replacements, dry_run = dry_run)
  }

  invisible(TRUE)
}

# Schema names are pasted into SQL text through {{...}} placeholders, so only
# plain identifiers are accepted.
validate_schema <- function(x) {
  if (!grepl("^[A-Za-z_][A-Za-z0-9_]*$", x)) {
    stop("Invalid schema name: ", x, call. = FALSE)
  }
  x
}
