# DynaRoute: Real-Time Geospatial Routing

A small, end-to-end R project that decides **which outlet should fulfil a delivery order** —
not the nearest one, but the one that will actually get there fastest, once queue length and
time-of-day demand are taken into account.

> "Closest outlet" is not always "best outlet."

## The idea

Apps like Swiggy or Zomato usually have 2–3 outlets that could serve any given order. Picking
whichever is physically nearest ignores two things that matter a lot in practice:

1. **Load.** A nearby outlet with 14 orders queued will deliver slower than a farther outlet
   that's nearly idle.
2. **Time-based demand patterns.** A location like a college hostel can be the busiest point in
   the whole network at 9 PM, and completely unreachable after an 8 PM curfew.

This project models the city as a **dynamic weighted graph** and assigns each order to the
outlet with the lowest *expected* delivery time — not the shortest distance.

```
expected_time = travel_time + (queue_length × avg_prep_time)
```

## Project structure

```
dynaroute/
├── README.md
├── requirements.R              # installs every package used below
├── R/
│   ├── 01_build_network.R      # pulls OSM road data, builds the graph (sfnetworks)
│   ├── 02_simulate_orders.R    # fakes outlets + a stream of orders for demo purposes
│   ├── 03_demand_model.R       # predicts per-outlet queue length by hour/day (tidymodels)
│   ├── 04_dynamic_scoring.R    # the scoring function + best-outlet assignment logic
│   └── 05_demand_clusters.R    # DBSCAN hotspot detection over order locations
└── app.R                       # Shiny + leaflet dashboard tying it all together
```

## Tech stack

| Package | Role |
|---|---|
| `osmdata` + `sf` | Pull real road/map data for the city |
| `sfnetworks` | Build the graph, run routing (Dijkstra / A*) |
| `tidymodels` | Predict per-outlet demand & queue length |
| `dbscan` | Detect geographic demand hotspots |
| `shiny` + `leaflet` | Interactive map dashboard |
| `dplyr`, `purrr`, `lubridate` | Data wrangling glue |

Everything above is R. There is **no Kafka/Flink dependency in the core project** — a
background-script + `reactivePoll()` pattern is used to simulate a live order stream instead.
(A real Kafka/Redpanda producer → Postgres → Shiny-subscriber layer is a documented *optional*
extension, not a requirement — see the project write-up.)

## Setup

```r
# 1. Install dependencies (one-time)
source("requirements.R")

# 2. Build the road network for your chosen city
source("R/01_build_network.R")

# 3. Generate simulated outlets + orders
source("R/02_simulate_orders.R")

# 4. Train the demand model
source("R/03_demand_model.R")

# 5. Run the dashboard
shiny::runApp("app.R")
```

By default the scripts pull the road network around **Vellore, Tamil Nadu** — change the
`place_name` variable at the top of `01_build_network.R` to point at any other city OpenStreetMap
recognizes.

## How the pieces fit together

1. **Build the network** — outlets and delivery areas become graph nodes; roads become edges,
   initially weighted by travel time.
2. **Learn demand patterns** — a model predicts each outlet's queue length by hour and day,
   including hard constraints such as delivery curfews.
3. **Reweight dynamically** — edge weights are recalculated from travel time *and* live queue
   length, not distance alone.
4. **Assign the best outlet** — for every order, every reachable outlet is scored and the
   lowest-expected-time one is chosen.
5. **Display it** — a Shiny/leaflet dashboard shows the live map, a time slider, and a demand
   heatmap toggle.

## Notes

- The order/outlet data here is **simulated** for demo purposes — there's no real order history
  behind this out of the box. Swap `R/02_simulate_orders.R` for a real dataset if you have one.
- `03_demand_model.R` uses a simple model on purpose (easy to explain in a viva); swapping in a
  fancier `tidymodels` spec is a drop-in change.
- This is a course project, not a production system — see the write-up for an honest discussion
  of what would be needed to make it deployment-ready.
