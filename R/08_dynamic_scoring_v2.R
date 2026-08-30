# R/08_dynamic_scoring_v2.R
#
# The "dynamic graph" engine. Builds on the same city_network.rds used
# everywhere else in the project, but instead of a fixed travel_time_min per
# edge, it recomputes each edge's CURRENT travel time from:
#
#   current_travel_time_min = base_travel_time_min * traffic_factor * weather_factor
#
# and marks edges near the hostel as effectively blocked once its curfew
# hour is reached. The routing/assignment logic then uses these CURRENT
# weights, so the exact same physical road network can produce different
# travel times -- and therefore a different best outlet -- depending on the
# hour, current traffic, and current weather.
#
# This file does NOT modify or replace R/04_dynamic_scoring.R. It is a
# parallel, self-contained engine used only by app_v2.R, so app.R and
# app_live.R keep working exactly as before.

library(sf)
library(sfnetworks)
library(tidygraph)
library(dplyr)

source("R/00_predict_helpers.R")
source("R/06_conditions.R")
source("R/07_geofence.R")

BLOCKED_EDGE_WEIGHT   <- 1e6   # effectively "infinite" for a single edge
BLOCKED_OUTLET_SCORE  <- 1e7   # effectively "infinite" for a whole outlet
HOSTEL_BLOCK_RADIUS_M <- 350   # edges within this distance of the hostel are
                                # treated as curfew-affected once curfew hits

# ---- Step 1: recompute every edge's current travel time --------------------
# Returns a NEW network object -- never mutates city_network.rds on disk.
update_dynamic_network <- function(network, hour, traffic_factor, weather_factor,
                                    hostel_point = NULL, curfew_hour = NULL) {
  edges_sf <- network %>% activate("edges") %>% st_as_sf()

  blocked <- rep(FALSE, nrow(edges_sf))
  if (!is.null(hostel_point) && !is.null(curfew_hour) && hour >= curfew_hour) {
    edge_midpoints <- st_centroid(edges_sf$geometry)
    dist_to_hostel <- as.numeric(st_distance(edge_midpoints, hostel_point))
    blocked <- dist_to_hostel < HOSTEL_BLOCK_RADIUS_M
  }

  current_travel_time_min <- if_else(
    blocked,
    BLOCKED_EDGE_WEIGHT,
    edges_sf$travel_time_min * traffic_factor * weather_factor
  )

  network %>%
    activate("edges") %>%
    mutate(
      base_travel_time_min = edges_sf$travel_time_min,
      traffic_factor = traffic_factor,
      weather_factor = weather_factor,
      blocked = blocked,
      current_travel_time_min = current_travel_time_min
    )
}

# ---- Step 2: travel time and route path on the CURRENT network -------------
get_current_travel_time_min <- function(network, from_point, to_point) {
  path <- sfnetworks::st_network_paths(
    network, from = from_point, to = to_point, weights = "current_travel_time_min"
  )
  edge_ids <- path$edge_paths[[1]]
  if (length(edge_ids) == 0) return(0)  # same node / negligible distance

  edges_sf <- network %>% activate("edges") %>% st_as_sf()
  sum(edges_sf$current_travel_time_min[edge_ids])
}

get_route_line <- function(network, from_point, to_point) {
  path <- sfnetworks::st_network_paths(
    network, from = from_point, to = to_point, weights = "current_travel_time_min"
  )
  edge_ids <- path$edge_paths[[1]]
  if (length(edge_ids) == 0) return(NULL)

  edges_sf <- network %>% activate("edges") %>% st_as_sf()
  edges_sf$geometry[edge_ids] %>% st_union() %>% st_line_merge()
}

# ---- Step 3: assign the best outlet using current conditions ---------------
# customer_point_4326: the raw click, in lon/lat (EPSG:4326)
# service_area: polygon from build_service_area(), same CRS as customer_point_4326
# live_queue_lookup: optional function(outlet_id) -> extra queue count from
#                     the Kafka stream (see R/09_live_queue.R). NULL if the
#                     streaming layer isn't running -- the app must still work.
assign_best_outlet_dynamic <- function(customer_point_4326, hour,
                                        network, outlets_df, model,
                                        hostel_pt, curfew_hour,
                                        service_area = NULL,
                                        live_queue_lookup = NULL) {

  # --- geofence check ---------------------------------------------------
  if (!is.null(service_area) && !is_within_service_area(customer_point_4326, service_area)) {
    return(list(status = "outside_service_area"))
  }

  customer_point <- st_transform(customer_point_4326, st_crs(network))

  # --- hostel curfew check (customer's own location) --------------------
  dist_to_hostel <- as.numeric(st_distance(customer_point, hostel_pt))
  if (dist_to_hostel < HOSTEL_BLOCK_RADIUS_M && hour >= curfew_hour) {
    return(list(status = "hostel_curfew"))
  }

  # --- current conditions -------------------------------------------------
  traffic <- get_traffic_state(hour)
  weather <- get_weather_state()
  dyn_network <- update_dynamic_network(
    network, hour, traffic$factor, weather$factor,
    hostel_point = hostel_pt, curfew_hour = curfew_hour
  )

  # --- score every outlet on the CURRENT graph -----------------------------
  scored <- outlets_df %>%
    rowwise() %>%
    mutate(
      travel_time_min = get_current_travel_time_min(dyn_network, geometry, customer_point),
      predicted_queue = predict_queue_length(model, outlet_id, hour) +
        (if (!is.null(live_queue_lookup)) live_queue_lookup(outlet_id) else 0),
      expected_time_min = if (travel_time_min >= BLOCKED_EDGE_WEIGHT) {
        BLOCKED_OUTLET_SCORE
      } else {
        travel_time_min + (predicted_queue * avg_prep_time_min)
      }
    ) %>%
    ungroup() %>%
    arrange(expected_time_min)

  best <- scored %>% slice(1)

  if (best$expected_time_min >= BLOCKED_OUTLET_SCORE) {
    return(list(status = "no_outlet_reachable"))
  }

  best_outlet_geom <- outlets_df$geometry[outlets_df$outlet_id == best$outlet_id]
  route_line <- get_route_line(dyn_network, best_outlet_geom, customer_point)

  list(
    status = "ok",
    chosen_outlet = best$outlet_id,
    expected_time_min = round(best$expected_time_min, 1),
    traffic = traffic,
    weather = weather,
    route_line_projected = route_line,  # in network's CRS -- transform before drawing
    all_scores = scored %>%
      transmute(
        outlet_id,
        travel_time_min = round(travel_time_min, 1),
        predicted_queue = round(predicted_queue, 1),
        expected_time_min = round(expected_time_min, 1),
        status = if_else(expected_time_min >= BLOCKED_OUTLET_SCORE, "Blocked", "Available")
      )
  )
}
