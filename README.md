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

## Setup

```r
# 1. Install dependencies (one-time)
source("requirements.R")

# 2. Build the road network for your chosen city
source("R/01_build_network.R")     # real OSM data (needs internet)
# or, for a fast offline test network:
source("R/dev_synthetic_network.R")

# 3. Regenerate everything downstream of the network you just built —
#    outlets/hostel are sampled directly FROM the current network's nodes,
#    so this step must always run again after rebuilding the network, or
#    the two will silently go out of sync.
source("R/02_simulate_orders.R")
source("R/03_demand_model.R")
source("R/05_demand_clusters.R")
```

Or run the non-streaming pipeline in one go with `Rscript run_pipeline.R` (real OSM data) or
`Rscript run_pipeline.R --fast` (instant synthetic network). See `TESTING.md` for expected output
at each stage.

By default `01_build_network.R` pulls the road network around **Chennai, Tamil Nadu** — change
`place_name` at the top of that file for any other city OpenStreetMap recognizes.

## Running the dashboards

**`app_v2.R` — the main dashboard**, showing the full dynamic-graph demo: live traffic/weather
factors, a service-area geofence, the hostel curfew, a routed polyline along the real road
network, a full per-outlet comparison table, and (if the streaming layer is running) live
Kafka-driven queue data. Two pages — **Dashboard** for a quick assignment result, **Analytics**
for the full outlet-by-outlet comparison at the selected location.

```r
shiny::runApp("app_v2.R")
```

Works fully without Docker/Kafka running — live order counts just show as zero/offline until the
streaming layer is up. Diagnose a rejected location any time with:
```r
source("R/07_geofence.R")
service_area_debug_info(readRDS("city_network.rds"))
```

**`app.R`** — the original static/simulated-data dashboard (v1 scoring logic, no traffic/weather).
**`app_live.R`** — v1 dashboard reading from the original Kafka stream.

## Running the live streaming layer (optional)

```bash
cd streaming
docker compose up -d              # start Redpanda + Postgres
pip install -r requirements.txt

python producer_v2.py             # terminal 1
python consumer_v2.py             # terminal 2
```

`producer_v2.py` generates order arrivals using a **Poisson distribution** with an hour-dependent
rate (λ) — the standard statistical model for random, independent arrivals like walk-in
customers — so busier hours genuinely produce more frequent orders, not just a fixed random
range. It also uses a compressed clock (1 real minute ≈ 1 simulated hour), so the hostel curfew
and demand shifts show up within minutes instead of a real 24 hours.

`consumer_v2.py` writes into a `live_orders` Postgres table, which `R/09_live_queue.R` reads —
this is what lets new Kafka events raise an outlet's effective queue length live, which can
change which outlet gets recommended without any new customer click.

To stop everything: `Ctrl+C` the producer/consumer, then `docker compose down` in `streaming/`.

## How the dynamic graph works

1. **Build the network** — outlets and delivery areas become graph nodes; roads become edges,
   initially weighted by distance-based travel time.
2. **Current conditions** — traffic (hour-driven, synthetic) and weather (live from Open-Meteo,
   with a safe fallback) are fetched fresh on every query.
3. **Reweight the graph** — every edge's current travel time is recalculated as
   `base_travel_time × traffic_factor × weather_factor`; edges near the hostel get an effectively
   infinite weight once its curfew hour hits.
4. **Route + score every outlet** — for the customer's location, every reachable outlet is scored
   on `expected_time = current_travel_time + (predicted_queue + live_queue_boost) × avg_prep_time`.
5. **Assign + display** — the lowest-scoring outlet is chosen, its real route is drawn on the map,
   and the full comparison is available on the Analytics page.

## Notes

- Order/outlet data is **simulated** — there's no real order history behind this out of the box.
- `03_demand_model.R` uses a deliberately simple model (easy to explain in a viva); swapping in a
  fancier `tidymodels` spec is a drop-in change.
- The `streaming/` layer is real — actual Redpanda broker, actual producer/consumer, actual
  Postgres — kept optional/separable so the graded core (`app_v2.R`) never depends on it.
- Rebuilding `city_network.rds` (either script) invalidates `outlets.rds`/`hostel_node.rds`/
  `demand_model.rds` until `02` → `03` → `05` are re-run — see `TESTING.md`.
- This is a course project, not a production system.

## Credits

Built collaboratively — core routing/prediction pipeline, dynamic graph engine, geofencing, and
dashboard UI, with a Kafka streaming layer and Poisson-based order simulation contributed as a
joint extension.
