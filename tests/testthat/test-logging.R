test_that("setup_logging creates log directory and returns log file path", {
  log_dir <- file.path(tempdir(), paste0("logs_", as.integer(Sys.time())))

  old_appender <- logger::log_appender()
  old_appender_fn <- if (is.function(old_appender)) {
    old_appender
  } else if (is.list(old_appender) && length(old_appender) >= 1 && is.function(old_appender[[1]])) {
    old_appender[[1]]
  } else {
    logger::appender_console
  }
  old_threshold <- logger::log_threshold()
  old_layout <- logger::log_layout()
  old_keep_source <- getOption("keep.source")
  old_error <- getOption("error")
  old_layout_fn <- if (is.function(old_layout)) {
    old_layout
  } else if (is.list(old_layout) && length(old_layout) >= 1 && is.function(old_layout[[1]])) {
    old_layout[[1]]
  } else {
    logger::layout_glue_generator(format = "[{time}] {level} {msg}")
  }
  on.exit(
    {
      logger::log_appender(old_appender_fn)
      logger::log_threshold(old_threshold)
      logger::log_layout(old_layout_fn)
      options(keep.source = old_keep_source, error = old_error)
    },
    add = TRUE
  )

  log_file <- setup_logging(log_dir = log_dir, prefix = "unit_test")

  expect_true(dir.exists(log_dir))
  expect_match(basename(log_file), "^unit_test_.*\\.log$")
  expect_true(file.exists(log_file))
  expect_true(isTRUE(getOption("keep.source")))
  err_handler <- getOption("error")
  expect_true(is.function(err_handler) || is.language(err_handler))
})

test_that("time_step returns expression result and evaluates once", {
  state <- new.env(parent = emptyenv())
  state$n <- 0

  result <- time_step("increment counter", {
    state$n <- state$n + 1
    state$n * 10
  })

  expect_equal(result, 10)
  expect_equal(state$n, 1)
})

test_that("time_step propagates errors from expression", {
  expect_error(
    time_step("failing step", {
      stop("forced failure")
    }),
    regexp = "forced failure"
  )
})

test_that("global error handler prints stack trace with function name", {
  script <- tempfile(fileext = ".R")
  logging_file <- normalizePath(
    file.path(project_root, "R", "utils", "logging.R"),
    winslash = "/",
    mustWork = TRUE
  )
  on.exit(unlink(script), add = TRUE)

  writeLines(
    c(
      sprintf("source('%s')", gsub("'", "\\\\'", logging_file)),
      "setup_logging(log_dir = tempdir(), prefix = 'stack_trace_test')",
      "inner_boom <- function() {",
      "  stop('message from stop')",
      "}",
      "outer_boom <- function() {",
      "  inner_boom()",
      "}",
      "outer_boom()"
    ),
    con = script
  )

  rscript <- file.path(R.home("bin"), "Rscript")
  output <- suppressWarnings(
    system2(
      command = rscript,
      args = c("--vanilla", script),
      stdout = TRUE,
      stderr = TRUE
    )
  )

  output_text <- paste(output, collapse = "\n")
  expect_match(output_text, r"(Error in inner_boom() : message from stop)", fixed = TRUE)
  expect_match(output_text, r"(================ ERROR STACK TRACE ================)", fixed = TRUE)
  expect_match(output_text, r"(1: outer_boom())", fixed = TRUE)
  expect_match(output_text, r"(2: inner_boom())", fixed = TRUE)
})
