# Installs every package used across the project.
# Run this once before anything else: source("requirements.R")

pkgs <- c(
  "sf",            # spatial data
  "osmdata",       # download OpenStreetMap data
  "sfnetworks",    # spatial graphs + routing
  "tidygraph",     # graph manipulation (sfnetworks depends on this)
  "tidymodels",    # demand / queue-length prediction model
  "dbscan",        # density-based clustering for demand hotspots
  "dplyr",         # data wrangling
  "purrr",         # functional helpers
  "lubridate",     # date/time handling
  "shiny",         # dashboard
  "leaflet",       # interactive maps
  "leaflet.extras",# heatmap layer for leaflet
  "DBI",           # database connection (used by the live/Kafka layer)
  "RPostgres"      # Postgres driver (used by the live/Kafka layer)
  "httr",
  "jsonlite",
)

installed <- rownames(installed.packages())
to_install <- setdiff(pkgs, installed)

if (length(to_install) > 0) {
  install.packages(to_install)
} else {
  message("All required packages are already installed.")
}
