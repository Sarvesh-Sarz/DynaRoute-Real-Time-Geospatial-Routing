

# 1. Install dependencies (one-time)


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
