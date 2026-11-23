args <- commandArgs(trailingOnly = TRUE)

mode <- "fix"
if (length(args) > 0 && args[[1]] %in% c("--check", "--fix")) {
  mode <- sub("^--", "", args[[1]])
  args <- args[-1]
}

# If pre-commit/CI passes file paths, use only those. Otherwise use project R files.
if (length(args) > 0) {
  paths <- args
} else {
  paths <- c("R", "tests")
}

paths <- paths[file.exists(paths)]
paths <- unique(normalizePath(paths, winslash = "/", mustWork = FALSE))

if (length(paths) == 0) {
  message(sprintf("No files or folders found to %s.", if (mode == "check") "format-check" else "format"))
  quit(status = 0)
}

r_files <- unique(unlist(lapply(paths, function(p) {
  if (dir.exists(p)) {
    list.files(p, pattern = "\\.[Rr]$", recursive = TRUE, full.names = TRUE)
  } else if (grepl("\\.[Rr]$", p)) {
    p
  } else {
    character(0)
  }
})))

if (length(r_files) == 0) {
  message(sprintf("No R files found to %s.", if (mode == "check") "format-check" else "format"))
  quit(status = 0)
}

if (mode == "check") {
  result <- tryCatch(
    {
      styler::style_file(r_files, dry = "fail")
      NULL
    },
    error = function(err) err
  )

  if (!is.null(result)) {
    message(conditionMessage(result))
    message(sprintf("Formatting check failed for %d R file(s).", length(r_files)))
    quit(status = 1)
  }

  message(sprintf("Formatting check passed for %d R file(s).", length(r_files)))
} else {
  styler::style_file(r_files)
  message(sprintf("Formatted %d R file(s).", length(r_files)))
}
