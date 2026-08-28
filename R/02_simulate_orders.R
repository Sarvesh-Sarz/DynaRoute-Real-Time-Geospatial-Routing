# 02_simulate_orders.R
#
# There's no real order-history dataset behind a course project, so this
# script generates plausible fake data instead:
#   - a handful of outlets scattered across the city
#   - a stream of simulated orders across a day, with a demand spike around
#     a "hostel" location that goes quiet after a curfew hour — this is the
#     pattern the demand model in 03_demand_model.R will learn to recognize.

library(sf)
library(dplyr)
library(lubridate)
library(purrr)

set.seed(42)

city_network <- readRDS("city_network.rds")
nodes_sf <- city_network %>% sfnetworks::activate("nodes") %>% st_as_sf()

# ---- 1. Place outlets ----------------------------------------------------
n_outlets <- 6
outlet_nodes <- nodes_sf %>% slice_sample(n = n_outlets)

outlets <- outlet_nodes %>%
  mutate(
    outlet_id = paste0("O", row_number()),
    # tightened range so one outlet's fixed prep time can't single-handedly
    # dominate the scoring formula regardless of distance or demand
    avg_prep_time_min = round(runif(n(), 6, 8), 1)
  ) %>%
  select(outlet_id, avg_prep_time_min, geometry)

# ---- 2. Mark one "hostel" node with a curfew ------------------------------
hostel_node <- nodes_sf %>% slice_sample(n = 1) %>%
  mutate(location_id = "HOSTEL_1", curfew_hour = 20)  # no deliveries after 8 PM

# Outlets physically closer to the hostel should realistically get more of
# its order volume than outlets across town. Without this, hostel demand is
# spread uniformly across every outlet, the demand model never learns any
# real outlet-specific signal, and assignment ends up driven almost entirely
# by each outlet's fixed avg_prep_time_min instead of location or time.
dist_to_hostel <- as.numeric(sf::st_distance(outlets$geometry, hostel_node$geometry))
proximity_weight <- 1 / (dist_to_hostel + 1)
hostel_outlet_weights <- proximity_weight / sum(proximity_weight)

# ---- 3. Simulate a day of orders ------------------------------------------
# Each order: timestamp, which outlet served it, queue length at that moment.
# Demand is modeled as: baseline random orders everywhere, PLUS a strong
# evening spike from the hostel node that hard-stops at the curfew hour.

hours <- 0:23

simulate_hour <- function(hour) {
  # baseline demand across all outlets
  baseline_n <- rpois(1, lambda = 3)

  # hostel demand: builds up in the evening, cut off completely after curfew
  hostel_n <- if (hour >= 18 && hour < hostel_node$curfew_hour) {
    rpois(1, lambda = 12)
  } else {
    0
  }

  tibble(hour = hour, baseline_n = baseline_n, hostel_n = hostel_n)
}

demand_by_hour <- map_dfr(hours, simulate_hour)

# Expand into individual simulated orders.
# Guarded for n == 0 (a real possibility most hours) — without the guard,
# tibble() errors trying to recycle a scalar `hour` against zero-length
# outlet_id/queue_length vectors.
build_orders <- function(hour, n, outlet_ids, weights, queue_lambda) {
  if (n == 0) {
    return(tibble(hour = integer(0), outlet_id = character(0), queue_length_at_order = integer(0)))
  }
  tibble(
    hour = hour,
    outlet_id = sample(outlet_ids, n, replace = TRUE, prob = weights),
    queue_length_at_order = rpois(n, lambda = queue_lambda)
  )
}

build_hour_orders <- function(hour, baseline_n, hostel_n) {
  # baseline demand: spread uniformly across all outlets (weights = NULL)
  baseline_orders <- build_orders(hour, baseline_n, outlets$outlet_id, NULL, queue_lambda = 2)

  # hostel-driven demand: skewed toward whichever outlets are actually closer
  # to the hostel, and noticeably busier since this is the evening spike
  hostel_orders <- build_orders(hour, hostel_n, outlets$outlet_id, hostel_outlet_weights, queue_lambda = 6)

  bind_rows(baseline_orders, hostel_orders)
}

orders <- demand_by_hour %>%
  rowwise() %>%
  mutate(order_list = list(build_hour_orders(hour, baseline_n, hostel_n))) %>%
  pull(order_list) %>%
  bind_rows() %>%
  mutate(day = "sim_day_1")

# ---- 4. Save everything ----------------------------------------------------
saveRDS(outlets, "outlets.rds")
saveRDS(hostel_node, "hostel_node.rds")
saveRDS(orders, "simulated_orders.rds")

message("Simulated ", nrow(orders), " orders across ", n_outlets, " outlets.")
message("Hostel curfew hour: ", hostel_node$curfew_hour, ":00")
message(
  "Outlet closest to the hostel: ", outlets$outlet_id[which.max(hostel_outlet_weights)],
  " (gets the most hostel-driven demand during the evening spike)"
)
