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
    avg_prep_time_min = round(runif(n(), 4, 10), 1)
  ) %>%
  select(outlet_id, avg_prep_time_min, geometry)

# ---- 2. Mark one "hostel" node with a curfew ------------------------------
hostel_node <- nodes_sf %>% slice_sample(n = 1) %>%
  mutate(location_id = "HOSTEL_1", curfew_hour = 20)  # no deliveries after 8 PM

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

  tibble(
    hour = hour,
    n_orders = baseline_n + hostel_n,
    from_hostel = hostel_n > 0
  )
}

demand_by_hour <- map_dfr(hours, simulate_hour)

# Expand into individual simulated orders, each assigned a random outlet and
# a queue length that roughly tracks how busy that hour is.
orders <- demand_by_hour %>%
  rowwise() %>%
  mutate(order_list = list(
    tibble(
      hour = hour,
      outlet_id = sample(outlets$outlet_id, n_orders, replace = TRUE),
      queue_length_at_order = rpois(n_orders, lambda = max(1, n_orders / 2))
    )
  )) %>%
  pull(order_list) %>%
  bind_rows() %>%
  mutate(day = "sim_day_1")

# ---- 4. Save everything ----------------------------------------------------
saveRDS(outlets, "outlets.rds")
saveRDS(hostel_node, "hostel_node.rds")
saveRDS(orders, "simulated_orders.rds")

message("Simulated ", nrow(orders), " orders across ", n_outlets, " outlets.")
message("Hostel curfew hour: ", hostel_node$curfew_hour, ":00")
