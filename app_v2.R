# app_v2.R
#
# DynaRoute v2 dashboard. Demonstrates: customer click -> geofence -> current
# conditions -> dynamic graph weights -> route calculation -> queue
# prediction -> live queue -> best outlet -> expected delivery time.
#
# Only loads existing .rds files -- never downloads OSM data or regenerates
# anything. app.R and app_live.R are untouched and unaffected by this file.
#
# Reactive design (see R/07 and R/08 for the underlying logic):
#   customer_point <- reactiveVal(NULL)   -- set once, on click, nothing else
#   result <- reactive({ ... })           -- depends on customer_point(),
#                                             input$hour, and live_state(), so
#                                             it recomputes automatically when
#                                             ANY of those change, including
#                                             just moving the hour slider with
#                                             no new click.
# No separate click_lng()/click_lat() reactives are used, avoiding the
# stale-reactive bug from the earlier version.

library(shiny)
library(leaflet)
library(sf)
library(leaflet.extras)
library(sfnetworks)
library(tidygraph)
library(dplyr)

source("R/00_predict_helpers.R")
source("R/06_conditions.R")
source("R/07_geofence.R")
source("R/08_dynamic_scoring_v2.R")

# DBI/RPostgres are only needed for the optional live layer.
live_pkgs_available <- tryCatch({
  source("R/09_live_queue.R")
  TRUE
}, error = function(e) FALSE)

# ---- Load existing data -- never regenerated here ---------------------------
city_network <- readRDS("city_network.rds")
outlets      <- readRDS("outlets.rds")
hostel_node  <- readRDS("hostel_node.rds")
demand_model <- readRDS("demand_model.rds")
order_coords <- tryCatch(readRDS("order_coords_clustered.rds"), error = function(e) NULL)

outlets_ll      <- st_transform(outlets, 4326)
outlet_order_counts <- readRDS("simulated_orders.rds") %>%
  dplyr::count(outlet_id, name = "order_count")

outlets_ll <- outlets_ll %>%
  dplyr::left_join(outlet_order_counts, by = "outlet_id") %>%
  dplyr::mutate(order_count = tidyr::replace_na(order_count, 0))

busyness_palette <- colorNumeric(
  palette = c("#2ECC71", "#F1C40F", "#E74C3C"),
  domain = outlets_ll$order_count
)
service_area    <- build_service_area(city_network)
service_area_ll <- st_transform(service_area, 4326)

ui <- fluidPage(
  titlePanel("DynaRoute — Real-Time Geospatial Routing (dynamic graph demo)"),
  sidebarLayout(
    sidebarPanel(
      sliderInput("hour", "Current Time (hour)", min = 0, max = 23, value = 19, step = 1,
                  animate = animationOptions(interval = 1500)),
      checkboxInput("show_heatmap", "Show demand heatmap", value = FALSE),
      hr(),
      h4("Current Conditions"),
      textOutput("traffic_text"),
      textOutput("weather_text"),
      hr(),
      h4("Customer"),
      verbatimTextOutput("customer_text"),
      hr(),
      h4("Best Outlet"),
      verbatimTextOutput("best_outlet_text"),
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
      h4("Routing Debug"),
      verbatimTextOutput("debug_panel"),
      hr(),
      helpText("Click anywhere on the map to place a customer.")
    ),
    mainPanel(
      leafletOutput("map", height = 700)
    )
  )
)

server <- function(input, output, session) {

  live_state <- reactive({
    list(
      available = FALSE,
      lookup = NULL,
      summary = list(
        orders_processed = 0,
        recent_orders = 0
      )
    )
  })

  output$map <- renderLeaflet({
    leaflet() %>%
      addTiles() %>%
      addPolygons(data = service_area_ll, color = "#1C7293", weight = 3,
            fillOpacity = 0.15, group = "service_area") %>%
      addCircleMarkers(
        data = outlets_ll,
        label = ~paste0(outlet_id, ": ", order_count, " orders"),
        radius = ~scales::rescale(order_count, to = c(8, 22)),
        color = ~busyness_palette(order_count),
        fillOpacity = 0.85,
        stroke = TRUE, weight = 1
      ) %>%
        addLegend(
          position = "bottomright", pal = busyness_palette, values = outlets_ll$order_count,
          title = "Orders (outlet load)"
        )
  })

  shiny::observeEvent(input$map_click, {

    click <- input$map_click

    leafletProxy("map") %>%
      clearGroup("customer") %>%
      clearGroup("route") %>%
      addCircleMarkers(
        lng = click$lng,
        lat = click$lat,
        group = "customer",
        color = "black",
        radius = 6
      )
  })

  # ---------------------------------------------------------
  # MAIN ROUTING REACTIVE
  # Depends directly on map click + hour slider.
  # No reactiveVal customer_point.
  # No reactiveVal result.
  # ---------------------------------------------------------

  result <- shiny::reactive({

    click <- input$map_click

    req(click)

    customer_point <- st_sfc(
      st_point(
        c(click$lng, click$lat)
      ),
      crs = 4326
    )

    live <- live_state()

    assign_best_outlet_dynamic(
      customer_point,
      hour = input$hour,
      network = city_network,
      outlets_df = outlets,
      model = demand_model,
      hostel_pt = hostel_node$geometry,
      curfew_hour = hostel_node$curfew_hour,
      service_area = service_area_ll,
      live_queue_lookup = live$lookup
    )
  })

  # ---------------------------------------------------------
  # ROUTE
  # ---------------------------------------------------------

  shiny::observe({

    req(input$map_click)

    res <- result()

    leafletProxy("map") %>%
      clearGroup("route")

    if (
      identical(res$status, "ok") &&
      !is.null(res$route_line_projected)
    ) {

      route_ll <- st_transform(
        res$route_line_projected,
        4326
      )

      leafletProxy("map") %>%
        addPolylines(
          data = route_ll,
          color = "#3FA796",
          weight = 4,
          group = "route"
        )
    }
  })

  # ---------------------------------------------------------
  # HEATMAP
  # ---------------------------------------------------------

  shiny::observe({

    if (
      isTRUE(input$show_heatmap) &&
      !is.null(order_coords)
    ) {

      leafletProxy("map") %>%
        clearGroup("heatmap") %>%
          addHeatmap(
  data = order_coords, lng = ~lon, lat = ~lat,
  radius = 25, blur = 20, max = 0.6,
  gradient = c("0.2" = "#0000FF", "0.4" = "#00FFFF", "0.6" = "#7FFF00", "0.8" = "#FFFF00", "1.0" = "#FF0000"),
  group = "heatmap"
)

    } else {

      leafletProxy("map") %>%
        clearGroup("heatmap")
    }
  })

  # ---------------------------------------------------------
  # TRAFFIC
  # ---------------------------------------------------------

  output$traffic_text <- renderText({

    t <- get_traffic_state(input$hour)

    sprintf(
      "Traffic: %s (factor %.2f)",
      t$level,
      t$factor
    )
  })

  # ---------------------------------------------------------
  # WEATHER
  # ---------------------------------------------------------

  output$weather_text <- renderText({

    w <- get_weather_state()

    sprintf(
      "Weather: %s (factor %.2f, %s)",
      w$condition,
      w$factor,
      w$source
    )
  })

  # ---------------------------------------------------------
  # CUSTOMER
  # ---------------------------------------------------------

  output$customer_text <- renderPrint({

    click <- input$map_click

    if (is.null(click)) {

      cat("No customer selected yet.")

      return(invisible())
    }

    cat(
      sprintf(
        "lon = %.5f, lat = %.5f\n",
        click$lng,
        click$lat
      )
    )

    res <- result()

    status_msg <- switch(
      res$status,

      "outside_service_area" =
        "Delivery unavailable: customer is outside the service area.",

      "hostel_curfew" =
        "Delivery unavailable: hostel curfew is active.",

      "no_outlet_reachable" =
        "No outlet can currently reach this location.",

      "ok" =
        "Valid service area.",

      "Unknown status."
    )

    cat(status_msg)
  })

  # ---------------------------------------------------------
  # BEST OUTLET
  # ---------------------------------------------------------

  output$best_outlet_text <- renderPrint({

    req(input$map_click)

    res <- result()

    if (!identical(res$status, "ok")) {

      if (identical(res$status, "outside_service_area")) {
        cat("Delivery unavailable: customer is outside the service area.")
      }

      else if (identical(res$status, "hostel_curfew")) {
        cat("Delivery unavailable: hostel curfew is active.")
      }

      else if (identical(res$status, "no_outlet_reachable")) {
        cat("No outlet can currently reach this location.")
      }

      else {
        cat("Delivery unavailable.")
      }

      return(invisible())
    }

    cat(
      sprintf(
        "Best Outlet: %s\n",
        res$chosen_outlet
      )
    )

    cat(
      sprintf(
        "Expected Time: %.1f min\n\n",
        res$expected_time_min
      )
    )

    cat(
      sprintf(
        "Travel: %.1f min\n",
        res$travel_time_min
      )
    )

    cat(
      sprintf(
        "Queue: %.1f orders (model) + %.1f (live)\n",
        res$predicted_queue,
        res$live_queue_boost
      )
    )

    cat(
      sprintf(
        "Prep contribution: %.1f min\n",
        res$prep_contribution_min
      )
    )

    cat(
      sprintf(
        "Traffic factor: %.2f\n",
        res$traffic$factor
      )
    )

    cat(
      sprintf(
        "Weather factor: %.2f\n",
        res$weather$factor
      )
    ) 
  })

  # ---------------------------------------------------------
  # OUTLET COMPARISON
  # ---------------------------------------------------------

  output$comparison_table <- renderTable({

    req(input$map_click)

    res <- result()

    if (!identical(res$status, "ok")) {
      return(NULL)
    }

    res$all_scores
  })

  # ---------------------------------------------------------
  # NETWORK STATUS
  # ---------------------------------------------------------

  output$network_status_table <- renderTable({

    t <- get_traffic_state(input$hour)
    w <- get_weather_state()

    tibble::tibble(

      Metric = c(
        "Traffic factor",
        "Weather factor",
        "Hostel curfew active"
      ),

      Value = c(

        sprintf(
          "%.2f (%s)",
          t$factor,
          t$level
        ),

        sprintf(
          "%.2f (%s)",
          w$factor,
          w$condition
        ),

        if (
          input$hour >= hostel_node$curfew_hour
        ) {
          "Yes"
        } else {
          "No"
        }
      )
    )
  })

  # ---------------------------------------------------------
  # LIVE STREAM
  # ---------------------------------------------------------

  output$live_stream_text <- renderText({

    live <- live_state()

    if (!isTRUE(live$available)) {

      return(
        "Streaming layer offline — using demand model."
      )
    }

    sprintf(
      "Orders processed: %d | New recently: %d",
      live$summary$orders_processed,
      live$summary$recent_orders
    )
  })

  # ---------------------------------------------------------
  # DEBUG PANEL
  # ---------------------------------------------------------

  output$debug_panel <- renderPrint({

    click <- input$map_click

    if (is.null(click)) {

      cat("No customer selected yet.")

      return(invisible())
    }

    pt <- st_sfc(
      st_point(
        c(click$lng, click$lat)
      ),
      crs = 4326
    )

    coords <- st_coordinates(pt)

    cat(
      sprintf(
        "Customer coordinates: lon=%.5f, lat=%.5f\n",
        coords[1],
        coords[2]
      )
    )

    pt_net <- st_transform(
      pt,
      st_crs(city_network)
    )

    nodes_sf <- city_network %>%
      activate("nodes") %>%
      st_as_sf()

    nearest_idx <- st_nearest_feature(
      pt_net,
      nodes_sf
    )

    dist_m <- as.numeric(
      st_distance(
        pt_net,
        nodes_sf[nearest_idx, ]
      )
    )

    cat(
      sprintf(
        "Nearest network node: #%d, %.0f m away\n",
        nearest_idx,
        dist_m
      )
    )

    res <- result()

    inside <- !identical(
      res$status,
      "outside_service_area"
    )

    cat(
      sprintf(
        "Customer inside service area: %s\n",
        if (inside) "YES" else "NO"
      )
    )

    if (identical(res$status, "ok")) {

      cat(
        sprintf(
          "Selected outlet: %s\n",
          res$chosen_outlet
        )
      )

      cat(
        sprintf(
          "Route found: YES (%d edges)\n",
          res$route_edge_count
        )
      )

    } else {

      cat(
        sprintf(
          "Status: %s\n",
          res$status
        )
      )
    }

    t <- get_traffic_state(
      input$hour
    )

    w <- get_weather_state()

    cat(
      sprintf(
        "Current hour: %d\n",
        input$hour
      )
    )

    cat(
      sprintf(
        "Traffic factor: %.2f\n",
        t$factor
      )
    )

    cat(
      sprintf(
        "Weather factor: %.2f\n",
        w$factor
      )
    )
  })
}

shinyApp(ui, server)
