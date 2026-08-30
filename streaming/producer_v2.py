"""
producer_v2.py

Generates DynaRoute order events with a full schema and publishes them to a
NEW Kafka topic "orders_v2" -- this never collides with the original
producer.py / "orders_raw" topic, so both can coexist.

Two phases:
  1. HISTORICAL BURST -- quickly replays one full synthetic day (hour 0-23)
     with a realistic demand curve, so there's history in the topic/database
     before anything "live" happens.
  2. LIVE STREAM -- continues generating events in real time using a
     compressed clock (1 real minute = 1 simulated hour), so a demo shows
     the hostel curfew and demand shifts within a few minutes.

Usage:
    pip install -r requirements.txt
    python producer_v2.py
"""

import json
import random
import time
import uuid
from datetime import datetime, timedelta

from kafka import KafkaProducer

TOPIC = "orders_v2"
BOOTSTRAP_SERVERS = ["localhost:9092"]

OUTLETS = ["O1", "O2", "O3", "O4", "O5", "O6"]
HOSTEL_CURFEW_HOUR = 20
MINUTES_PER_SIM_HOUR = 1.0

TRAFFIC_LEVELS = {
    range(0, 7): "Low", range(7, 11): "High", range(11, 17): "Moderate",
    range(17, 22): "Very High", range(22, 24): "Low",
}
WEATHER_CONDITIONS = ["Clear", "Cloudy", "Light Rain", "Heavy Rain"]
WEATHER_WEIGHTS = [0.55, 0.25, 0.15, 0.05]

# A couple of outlets are naturally busier than others, and one is favored
# during the hostel's evening spike -- mirrors the pattern used in
# R/02_simulate_orders.R so the live stream is consistent with the trained
# demand model instead of contradicting it.
BASE_OUTLET_WEIGHTS = [2, 3, 1, 2, 1, 1]
HOSTEL_OUTLET_WEIGHTS = [1, 4, 1, 1, 1, 1]

producer = KafkaProducer(
    bootstrap_servers=BOOTSTRAP_SERVERS,
    value_serializer=lambda v: json.dumps(v).encode("utf-8"),
)


def traffic_level_for_hour(hour):
    for hour_range, level in TRAFFIC_LEVELS.items():
        if hour in hour_range:
            return level
    return "Low"


def demand_lambda_for_hour(hour):
    # morning low, lunch higher, evening high, late night low
    if 0 <= hour < 6:
        return 1
    if 6 <= hour < 10:
        return 3
    if 10 <= hour < 14:
        return 6        # lunch
    if 14 <= hour < 17:
        return 3
    if 17 <= hour < HOSTEL_CURFEW_HOUR:
        return 9        # evening + hostel spike window
    if HOSTEL_CURFEW_HOUR <= hour < 23:
        return 4
    return 1


def make_event(hour, is_historical, sim_timestamp):
    is_hostel_window = 18 <= hour < HOSTEL_CURFEW_HOUR
    weights = HOSTEL_OUTLET_WEIGHTS if is_hostel_window else BASE_OUTLET_WEIGHTS
    outlet_id = random.choices(OUTLETS, weights=weights)[0]

    weather = random.choices(WEATHER_CONDITIONS, weights=WEATHER_WEIGHTS)[0]
    traffic = traffic_level_for_hour(hour)

    return {
        "order_id": str(uuid.uuid4())[:8],
        "timestamp": sim_timestamp.isoformat(),
        "outlet_id": outlet_id,
        "customer_lat": round(13.0827 + random.uniform(-0.05, 0.05), 5),
        "customer_lon": round(80.2707 + random.uniform(-0.05, 0.05), 5),
        "hour": hour,
        "queue_length": random.randint(1, 15),
        "prep_time": round(random.uniform(5, 9), 1),
        "weather": weather,
        "traffic_level": traffic,
        "is_historical": is_historical,
    }


def run_historical_burst():
    print("Producer: sending historical burst (one full synthetic day)...")
    now = datetime.utcnow()
    for hour in range(24):
        n_events = max(1, int(demand_lambda_for_hour(hour) * random.uniform(0.7, 1.3)))
        sim_timestamp = now - timedelta(hours=(24 - hour))
        for _ in range(n_events):
            event = make_event(hour, is_historical=True, sim_timestamp=sim_timestamp)
            producer.send(TOPIC, value=event)
    producer.flush()
    print("Historical burst sent.")


def run_live_stream():
    print(f"Producer: live stream started. 1 real minute = {MINUTES_PER_SIM_HOUR} sim hour(s).")
    print(f"Hostel curfew hits at simulated hour {HOSTEL_CURFEW_HOUR}:00.")
    start_time = time.time()
    while True:
        elapsed_min = (time.time() - start_time) / 60
        hour = int((elapsed_min / MINUTES_PER_SIM_HOUR) % 24)
        event = make_event(hour, is_historical=False, sim_timestamp=datetime.utcnow())
        producer.send(TOPIC, value=event)
        print(f"[sim {hour:02d}:00] {event}")
        time.sleep(random.uniform(1, 3))


if __name__ == "__main__":
    run_historical_burst()
    run_live_stream()
