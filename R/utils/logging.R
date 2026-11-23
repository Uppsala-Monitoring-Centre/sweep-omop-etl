library(logger)

setup_logging <- function(log_dir = "logs", prefix = "run", level = INFO) {
  if (!dir.exists(log_dir)) {
    dir.create(log_dir, recursive = TRUE)
  }

  options(keep.source = TRUE)
  options(error = function() {
    cat("\n================ ERROR STACK TRACE ================\n")
    traceback(2)
    cat("===================================================\n")
  })

  log_file <- file.path(
    log_dir,
    paste0(prefix, "_", format(Sys.time(), "%Y-%m-%d_%H-%M-%S"), ".log")
  )

  log_layout(layout_glue_generator(
    format = "[{time}] {level} {msg}"
  ))

  log_appender(appender_tee(log_file))
  log_threshold(level)

  log_info("Logging initialized")
  log_info("Log file: {log_file}")

  log_file
}

time_step <- function(step_name, expr) {
  start <- Sys.time()
  log_info("START: {step_name}")

  result <- force(expr)

  elapsed <- round(as.numeric(difftime(Sys.time(), start, units = "secs")), 2)
  log_info("END: {step_name} - elapsed {elapsed} seconds")

  result
}
