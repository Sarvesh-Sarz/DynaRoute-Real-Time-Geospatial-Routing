# app_v2.R
#
# DynaRoute v2 dashboard -- demonstrates the actual DYNAMIC graph concept:
# traffic + weather scale edge weights on every query, a service-area
# geofence rejects invalid locations, the hostel curfew blocks nearby edges
# (not just refuses a booking), the winning route is drawn along the real
# network, and (if the streaming layer is running) live Kafka orders raise
# an outlet's effective queue length in real time.
#
# This file is intentionally separate from app.R / app_live.R -- neither of
# those files is touched. Existing .rds files are loaded as-is; nothing is
# regenerated, and the OSM network is NEVER re-downloaded here.
#
# The streaming layer (Kafka/Redpanda + Postgres) is optional. If it isn't
# running, the dashboard automatically falls back to demand-model-only
# predictions and says so clearly in the "Live Stream" panel.

library(shiny)
library(leaflet)
library(sf)
library(sfnetworks)
library(tidygraph)
library(dplyr)

source("R/00_predict_helpers.R")
source("R/06_conditions.R")
source("R/07_geofence.R")
source("R/08_dynamic_scoring_v2.R")

# DBI/RPostgres are only needed for the optional live layer. If they aren't
# installed at all, the app still runs fine in fallback/demo mode.
live_pkgs_available <- tryCatch({
  source("R/09_live_queue.R")
  TRUE
}, error = function(e) FALSE)

# ---- Load existing data -- never regenerated here ---------------------------
city_network <- readRDS("city_network.rds")
outlets      <- readRDS("outlets.rds")
hostel_node  <- readRDS("hostel_node.rds")
demand_model <- readRDS("demand_model.rds")

outlets_ll      <- st_transform(outlets, 4326)
service_area    <- build_service_area(city_network)
service_area_ll <- st_transform(service_area, 4326)

ui <- fluidPage(
  titlePanel("DynaRoute — Real-Time Geospatial Routing (dynamic graph demo)"),
  sidebarLayout(
    sidebarPanel(
      sliderInput("hour", "Current Time (hour)", min = 0, max = 23, value = 19, step = 1,
                  animate = animationOptions(interval = 1500)),
      hr(),
      h4("Current Conditions"),
      textOutput("traffic_text"),
      textOutput("weather_text"),
      hr(),
      h4("Customer"),
      textOutput("service_area_text"),
      hr(),
      h4("Best Outlet"),
      textOutput("best_outlet_text"),
      textOutput("expected_time_text"),
      hr(),
      h4("Outlet Comparison"),
      tableOutput("comparison_table"),
      hr(),
      h4("Dynamic Network Status"),
      tableOutput("network_status_table"),
      hr(),
      h4("Live Stream"),
      textOutput("live_stream_text"),
      hr(),
      helpText("Click anywhere on the map to place a customer.")
    ),
    mainPanel(
      leafletOutput("map", height = 650)
    )
  )
)

server <- function(input, output, session) {

  result <- reactiveVal(NULL)

  # Live stream state, refreshed every few seconds. Safe if streaming isn't running.
  live_state <- reactivePoll(
    4000, session,
    checkFunc = function() Sys.time(),
    valueFunc = function() {
      if (live_pkgs_available && is_streaming_available()) {
        list(available = TRUE, lookup = make_live_queue_lookup(), summary = get_live_stream_summary())
      } else {
        list(available = FALSE, lookup = NULL, summary = list(orders_processed = 0, recent_orders = 0))
      }
    }
  )

  output$map <- renderLeaflet({
    leaflet() %>%
      addTiles() %>%
      addPolygons(data = service_area_ll, color = "#1C7293", weight = 1,
                  fillOpacity = 0.05, group = "service_area") %>%
      addCircleMarkers(data = outlets_ll, label = ~outlet_id,
                        color = "#065A82", radius = 8, fillOpacity = 0.9)
  })

  observeEvent(input$map_click, {
    click <- input$map_click
    pt_ll <- st_sfc(st_point(c(click$lng, click$lat)), crs = 4326)

    leafletProxy("map") %>%
      clearGroup("customer") %>%
      clearGroup("route") %>%
      addCircleMarkers(lng = click$lng, lat = click$lat,
                        group = "customer", color = "black", radius = 6)

    live <- live_state()
    res <- assign_best_outlet_dynamic(
      pt_ll, hour = input$hour,
      network = city_network, outlets_df = outlets, model = demand_model,
      hostel_pt = hostel_node$geometry, curfew_hour = hostel_node$curfew_hour,
      service_area = service_area_ll,
      live_queue_lookup = live$lookup
    )
    result(res)

    if (identical(res$status, "ok") && !is.null(res$route_line_projected)) {
      route_ll <- st_transform(res$route_line_projected, 4326)
      leafletProxy("map") %>%
        addPolylines(data = route_ll, color = "#3FA796", weight = 4, group = "route")
    }
  })

  output$traffic_text <- renderText({
    t <- get_traffic_state(input$hour)
    sprintf("Traffic: %s (factor %.2f)", t$level, t$factor)
  })

  output$weather_text <- renderText({
    w <- get_weather_state()
    sprintf("Weather: %s (factor %.2f, %s)", w$condition, w$factor, w$source)
  })

  output$service_area_text <- renderText({
    res <- result()
    if (is.null(res)) return("No customer placed yet.")
    if (identical(res$status, "outside_service_area")) {
      return("Delivery unavailable: customer is outside the service area.")
    }
    if (identical(res$status, "hostel_curfew")) {
      return("Delivery unavailable — hostel curfew is active.")
    }
    if (identical(res$status, "no_outlet_reachable")) {
      return("No outlet can currently reach this location.")
    }
    "Valid service area."
  })

  output$best_outlet_text <- renderText({
    res <- result()
    if (is.null(res) || !identical(res$status, "ok")) return("—")
    paste("Best Outlet:", res$chosen_outlet)
  })

  output$expected_time_text <- renderText({
    res <- result()
    if (is.null(res) || !identical(res$status, "ok")) return("")
    sprintf("Expected Delivery Time: %.1f minutes", res$expected_time_min)
  })

  output$comparison_table <- renderTable({
    res <- result()
    req(res)
    req(identical(res$status, "ok"))
    res$all_scores
  })

  output$network_status_table <- renderTable({
    t <- get_traffic_state(input$hour)
    w <- get_weather_state()
    tibble::tibble(
      Metric = c("Traffic factor", "Weather factor", "Hostel curfew active"),
      Value = c(
        sprintf("%.2f (%s)", t$factor, t$level),
        sprintf("%.2f (%s)", w$factor, w$condition),
        if (input$hour >= hostel_node$curfew_hour) "Yes" else "No"
      )
    )
  })

  output$live_stream_text <- renderText({
    live <- live_state()
    if (!isTRUE(live$available)) {
      return("Streaming layer not running — using demand-model predictions only (fallback/demo mode).")
    }
    sprintf(
      "Orders processed: %d | New in last %d min: %d",
      live$summary$orders_processed, LIVE_QUEUE_LOOKBACK_MIN, live$summary$recent_orders
    )
  })
}

shinyApp(ui, server)
