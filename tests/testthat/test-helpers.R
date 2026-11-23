test_that("load_csv_xlsx_or_stop loads CSV and applies column names", {
  csv_path <- tempfile(fileext = ".csv")
  writeLines(c("Name,Age,City", "Michele,32,Milano", "Valentina,29,Torino"), csv_path)

  df <- load_csv_xlsx_or_stop(csv_path, sep = ",", col_names = c("Name", "Age", "City"))

  expect_equal(names(df), c("Name", "Age", "City"))
  expect_equal(df$Name, c("Michele", "Valentina"))
  expect_equal(df$Age, c(32, 29))
  expect_equal(df$City, c("Milano", "Torino"))
  expect_equal(nrow(df), 2)
})

test_that("read_sql_file reads SQL text and preserves newlines", {
  sql_path <- tempfile(fileext = ".sql")
  writeLines(c("SELECT 1;", "SELECT 2;"), sql_path)

  sql <- read_sql_file(sql_path)

  expect_match(sql, "SELECT 1;\\nSELECT 2;")
})

test_that("replace_sql_placeholders substitutes placeholders", {
  sql <- "SELECT * FROM {{SCHEMA}}.person WHERE year = {{YEAR}};"

  replaced <- replace_sql_placeholders(sql, list(SCHEMA = "omop54", YEAR = "2024"))

  expect_equal(replaced, "SELECT * FROM omop54.person WHERE year = 2024;")
})

test_that("list_sql_files only returns sorted .sql files", {
  dir_path <- tempfile(pattern = "sql_dir_")
  dir.create(dir_path)

  file.create(file.path(dir_path, "b.sql"))
  file.create(file.path(dir_path, "a.sql"))
  file.create(file.path(dir_path, "notes.txt"))

  sql_files <- list_sql_files(dir_path)

  expect_equal(basename(sql_files), c("a.sql", "b.sql"))
})

render_sql_from_lines <- function(lines, ...) {
  sql_path <- tempfile(fileext = ".sql")
  writeLines(lines, sql_path)

  run_sql_file(
    con = NULL,
    file_path = sql_path,
    ...
  )
}

test_that("run_sql_file handles table-driven dry-run scenarios", {
  scenarios <- list(
    list(
      name = "replacement and block removal with comment stripping",
      lines = c(
        "SELECT * FROM {{SCHEMA}}.person;",
        "-- TESTBLOCK_START",
        "SELECT * FROM should_be_removed;",
        "-- TESTBLOCK_END",
        "-- inline comment should be removed"
      ),
      args = list(
        replacements = list(SCHEMA = "omop54"),
        block_conditions = list(TESTBLOCK = TRUE),
        dry_run = TRUE
      ),
      must_have = c("omop54.person"),
      must_not_have = c("should_be_removed", "inline comment")
    ),
    list(
      name = "placeholder kept when replacements are empty",
      lines = c("SELECT * FROM {{SCHEMA}}.person;"),
      args = list(
        replacements = list(),
        dry_run = TRUE
      ),
      must_have = c("{{SCHEMA}}"),
      must_not_have = character(0)
    ),
    list(
      name = "function block condition removes block",
      lines = c(
        "SELECT 1;",
        "-- TESTBLOCK_START",
        "SELECT * FROM blocked;",
        "-- TESTBLOCK_END"
      ),
      args = list(
        replacements = list(FLAG = "remove"),
        block_conditions = list(TESTBLOCK = function(repl) repl$FLAG == "remove"),
        dry_run = TRUE
      ),
      must_have = c("SELECT 1"),
      must_not_have = c("blocked")
    ),
    list(
      name = "function block condition keeps block",
      lines = c(
        "SELECT 1;",
        "-- TESTBLOCK_START",
        "SELECT * FROM blocked;",
        "-- TESTBLOCK_END"
      ),
      args = list(
        replacements = list(FLAG = "keep"),
        block_conditions = list(TESTBLOCK = function(repl) repl$FLAG == "remove"),
        dry_run = TRUE
      ),
      must_have = c("blocked"),
      must_not_have = character(0)
    ),
    list(
      name = "missing block markers do not fail",
      lines = c("SELECT * FROM no_markers;"),
      args = list(
        block_conditions = list(TESTBLOCK = TRUE),
        dry_run = TRUE
      ),
      must_have = c("no_markers"),
      must_not_have = character(0)
    ),
    list(
      name = "comments preserved when stripping disabled",
      lines = c(
        "SELECT 1;",
        "-- keep this comment"
      ),
      args = list(
        strip_line_comments = FALSE,
        dry_run = TRUE
      ),
      must_have = c("-- keep this comment"),
      must_not_have = character(0)
    )
  )

  for (scenario in scenarios) {
    rendered <- do.call(
      render_sql_from_lines,
      c(list(lines = scenario$lines), scenario$args)
    )

    for (txt in scenario$must_have) {
      expect_true(grepl(txt, rendered, fixed = TRUE), info = scenario$name)
    }

    for (txt in scenario$must_not_have) {
      expect_false(grepl(txt, rendered, fixed = TRUE), info = scenario$name)
    }
  }
})

test_that("run_sql_directory returns NULL on empty directory in dry_run mode", {
  dir_path <- tempfile(pattern = "empty_sql_dir_")
  dir.create(dir_path)

  result <- run_sql_directory(con = NULL, dir_path = dir_path, dry_run = TRUE)

  expect_null(result)
})

test_that("run_sql_file errors when SQL file does not exist", {
  missing_file <- file.path(tempdir(), "definitely_missing_file.sql")

  expect_error(
    run_sql_file(con = NULL, file_path = missing_file, dry_run = TRUE),
    regexp = "SQL file not found"
  )
})
