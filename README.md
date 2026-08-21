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
├── TESTING.md                  # step-by-step checklist to verify each stage
├── run_pipeline.R               # runs the whole non-streaming pipeline in order
├── requirements.R              # installs every package used below
├── R/
│   ├── 00_predict_helpers.R    # shared prediction helper (used by 03 and 04)
│   ├── 01_build_network.R      # pulls OSM road data, builds the graph (sfnetworks)
│   ├── dev_synthetic_network.R # fast offline stand-in network for development/testing
│   ├── 02_simulate_orders.R    # fakes outlets + a stream of orders for demo purposes
│   ├── 03_demand_model.R       # predicts per-outlet queue length by hour/day (tidymodels)
│   ├── 04_dynamic_scoring.R    # the scoring function + best-outlet assignment logic
│   ├── 05_demand_clusters.R    # DBSCAN hotspot detection over order locations
│   └── 06_read_live_orders.R   # reads live queue data from Postgres (streaming layer)
├── app.R                       # core Shiny + leaflet dashboard (static/simulated data)
├── app_live.R                  # LIVE dashboard — scored from the real Kafka stream
└── streaming/                  # optional bonus layer — real Kafka, not required for core
    ├── docker-compose.yml      # spins up Redpanda (Kafka-compatible) + Postgres
    ├── init.sql                # Postgres schema
    ├── producer.py             # simulates live orders, publishes to Kafka topic
    ├── consumer.py             # reads from Kafka, writes into Postgres
    └── requirements.txt        # Python deps for producer.py / consumer.py
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

Or run steps 2-5 in one go with `Rscript run_pipeline.R` (real OSM data) or
`Rscript run_pipeline.R --fast` (instant synthetic network, useful while developing).
See `TESTING.md` for the expected output at each stage and how to isolate a bug if one shows up.

By default the scripts pull the road network around **Vellore, Tamil Nadu** — change the
`place_name` variable at the top of `01_build_network.R` to point at any other city OpenStreetMap
recognizes.

## Running the live Kafka layer (optional)

The core project (`app.R`) works fully with simulated/static data and doesn't need any of this.
The streaming layer below is a real, working producer → Kafka/Redpanda → consumer → Postgres →
Shiny pipeline, kept in `streaming/` so it's clearly separable from the graded core.

```bash
# 1. Start the broker + database
cd streaming
docker compose up -d

# 2. Install Python deps
pip install -r requirements.txt

# 3. In one terminal — start the producer (simulates live orders)
python producer.py

# 4. In another terminal — start the consumer (Kafka -> Postgres)
python consumer.py

# 5. Back in R, from the project root — run the live dashboard
Rscript -e "shiny::runApp('app_live.R')"
```

`producer.py` uses a **compressed clock** — 1 real minute = 1 simulated hour — so you'll see the
hostel curfew kick in within a few minutes of starting it, instead of waiting a real 24 hours.
`app_live.R` polls Postgres every 3 seconds (`reactivePoll()`) and scores outlets using the
*actual* streamed queue lengths instead of the static tidymodels prediction used in `app.R`.

To stop everything: `Ctrl+C` the producer/consumer, then `docker compose down` in `streaming/`.

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
- The `streaming/` layer is real — actual Redpanda (Kafka-compatible) broker, actual producer and
  consumer, actual Postgres — not a mock. It's kept optional/separable because the core R
  pipeline (`app.R`) is what's meant to be graded on the analytics; `app_live.R` is there to prove
  the streaming architecture out for anyone who wants to see it end-to-end.
- This is a course project, not a production system — see the write-up for an honest discussion
  of what would be needed to make it deployment-ready.
