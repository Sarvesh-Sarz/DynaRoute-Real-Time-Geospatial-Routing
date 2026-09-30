# DynaRoute: Real-Time Geospatial Routing

A small, end-to-end R project that decides **which outlet should fulfil a delivery order** —
not the nearest one, but the one that will actually get there fastest, once traffic, weather,
queue length, and time-of-day demand are all taken into account.

> "Closest outlet" is not always "best outlet."

## The idea

Apps like Swiggy or Zomato usually have several outlets that could serve any given order.
Picking whichever is physically nearest ignores things that matter a lot in practice:

1. **Load.** A nearby outlet with 14 orders queued will deliver slower than a farther outlet
   that's nearly idle.
2. **Current conditions.** The same road takes longer in heavy traffic or rain than it does on a
   clear afternoon.
3. **Time-based hard rules.** A location like a college hostel can be the busiest point in the
   network at 9 PM, and completely unreachable after an 8 PM curfew.

DynaRoute models the city as a **dynamic weighted graph** — edge weights are recalculated on
every query from current traffic and weather, some edges become impassable at certain hours, and
every order is assigned to the outlet with the lowest *expected* delivery time, not the shortest
distance.

```
current_travel_time = base_travel_time × traffic_factor × weather_factor
expected_time = current_travel_time + (predicted_queue + live_queue_boost) × avg_prep_time
```

Classic shortest-path algorithms (Dijkstra, A*) answer "what's the shortest route on a fixed
map." DynaRoute still uses that same algorithm underneath (via `sfnetworks`/`igraph`) — what's
different is that the *graph itself* is rebuilt from live conditions before every single query.

## Project structure

```
dynaroute/
├── README.md
├── TESTING.md
├── run_pipeline.R              # runs the whole non-streaming pipeline in order
├── requirements.R
├── R/
│   ├── 00_predict_helpers.R    # shared prediction helper
│   ├── 01_build_network.R      # pulls real OSM road data, builds the graph
│   ├── dev_synthetic_network.R # fast offline stand-in network for development
│   ├── 02_simulate_orders.R    # simulated outlets + orders (hostel-curfew demand pattern)
│   ├── 03_demand_model.R       # predicts per-outlet queue length by hour (tidymodels)
│   ├── 04_dynamic_scoring.R    # v1 scoring logic (used by app.R / app_live.R)
│   ├── 05_demand_clusters.R    # DBSCAN demand hotspot detection
│   ├── 06_conditions.R         # v2: synthetic traffic + live weather (Open-Meteo)
│   ├── 06_read_live_orders.R   # v1: reads live queue data for app_live.R
│   ├── 07_geofence.R           # v2: service-area check based on real network coverage
│   ├── 08_dynamic_scoring_v2.R # v2: the dynamic graph engine — reweighting, routing, scoring
│   └── 09_live_queue.R         # v2: reads live Kafka-driven queue data from Postgres
├── www/
│   └── dynaroute_theme.css     # dashboard visual theme (v2 UI)
├── app.R                       # v1 dashboard — static/simulated data
├── app_live.R                  # v1 dashboard — scored from the Kafka stream
├── app_v2.R                    # v2 dashboard — the dynamic graph demo (main app)
└── streaming/                  # optional live layer — real Kafka, not required for core
    ├── docker-compose.yml      # Redpanda (Kafka-compatible) + Postgres
    ├── init.sql                # Postgres schema for the v1 stream
    ├── producer.py              # v1 producer
    ├── consumer.py              # v1 consumer
    ├── producer_v2.py           # v2 producer — Poisson-distributed order arrivals per hour
    ├── consumer_v2.py           # v2 consumer — writes into the `live_orders` table
    └── requirements.txt
```

## Tech stack

| Package | Role |
|---|---|
| `osmdata` + `sf` | Pull real road/map data for the city |
| `sfnetworks` + `tidygraph` | Build the graph, run routing (Dijkstra / A*) |
| `tidymodels` | Predict per-outlet demand & queue length |
| `dbscan` | Detect geographic demand hotspots |
| `httr` + `jsonlite` | Live weather (Open-Meteo, no API key needed) |
| `DBI` + `RPostgres` | Read live queue data from the streaming layer (optional) |
| `shiny` + `leaflet` + `leaflet.extras` | Interactive dashboard, heatmap |
| `dplyr`, `tibble` | Data wrangling |

The core project is 100% R. The streaming layer's producer/consumer bridge is Python, since R has
no solid native Kafka client — everything else, including all the routing/scoring logic, is R.
