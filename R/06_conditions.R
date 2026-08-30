# R/06_conditions.R
#
# "Current conditions" that make the graph dynamic: synthetic traffic
# (driven by hour of day) and live weather (fetched from Open-Meteo, with a
# safe fallback if the API is unreachable). Both return a named multiplier
# that scales an edge's base travel time -- this is what makes the SAME
# road network produce different travel times at different moments, which
# is the core "dynamic graph" idea for the viva.

library(httr)
library(jsonlite)

# ---- Configurable constants (single source of truth) -----------------------
TRAFFIC_FACTORS <- c(Low = 1.00, Moderate = 1.15, High = 1.30, "Very High" = 1.50)
WEATHER_FACTORS <- c(Clear = 1.00, Cloudy = 1.05, "Light Rain" = 1.15, "Heavy Rain" = 1.30)

# City center used as a stand-in point for the weather API call -- one
# weather reading is used city-wide per query, which keeps this simple and
# easy to explain in a viva.
DEFAULT_WEATHER_LAT <- 13.0827
DEFAULT_WEATHER_LON <- 80.2707

# ---- Traffic ----------------------------------------------------------------
# Synthetic real-time traffic, driven by hour of day, with a small amount of
# random jitter so consecutive queries aren't bit-for-bit identical.
get_traffic_state <- function(hour, add_jitter = TRUE) {
  level <- if (hour >= 0 && hour <= 6) {
    "Low"
  } else if (hour >= 7 && hour <= 10) {
    "High"
  } else if (hour >= 11 && hour <= 16) {
    "Moderate"
  } else if (hour >= 17 && hour <= 21) {
    "Very High"
  } else {
    "Low"
  }

  factor <- unname(TRAFFIC_FACTORS[level])
  if (add_jitter) {
    factor <- factor + runif(1, -0.03, 0.03)
  }

  list(level = level, factor = factor)
}

# ---- Weather ------------------------------------------------------------
# Maps Open-Meteo's numeric weather code to one of our four conditions.
# Reference: https://open-meteo.com/en/docs (WMO weather interpretation codes)
map_weather_code <- function(code) {
  if (code == 0) return("Clear")
  if (code %in% c(1, 2, 3)) return("Cloudy")
  if (code %in% c(51, 53, 55, 61, 63, 80)) return("Light Rain")
  if (code %in% c(65, 66, 67, 82, 95, 96, 99)) return("Heavy Rain")
  "Cloudy"  # anything unmapped (fog, snow, etc.) -- treat as a mild default
}

# Fetches live weather for a point. Falls back to a simulated condition if
# the API is unreachable, slow, or returns something unexpected -- the app
# must NEVER crash because of this call.
get_weather_state <- function(lat = DEFAULT_WEATHER_LAT, lon = DEFAULT_WEATHER_LON) {
  result <- tryCatch({
    url <- sprintf(
      "https://api.open-meteo.com/v1/forecast?latitude=%s&longitude=%s&current_weather=true",
      lat, lon
    )
    resp <- httr::GET(url, httr::timeout(5))
    if (httr::status_code(resp) != 200) stop("non-200 response")

    parsed <- jsonlite::fromJSON(httr::content(resp, as = "text", encoding = "UTF-8"))
    code <- parsed$current_weather$weathercode
    condition <- map_weather_code(code)

    list(condition = condition, factor = unname(WEATHER_FACTORS[condition]), source = "live")
  }, error = function(e) {
    # Fallback: simulate a plausible condition so the dashboard still works
    # offline or if Open-Meteo is down. Mostly clear, occasionally rainy.
    condition <- sample(names(WEATHER_FACTORS), 1, prob = c(0.55, 0.25, 0.15, 0.05))
    list(condition = condition, factor = unname(WEATHER_FACTORS[condition]), source = "fallback")
  })

  result
}
