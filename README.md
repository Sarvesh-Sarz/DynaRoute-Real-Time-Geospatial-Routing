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
