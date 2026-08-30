# R/07_geofence.R
#
# Defines the delivery service area as the convex hull of every node in the
# road network (with a small buffer), and checks whether a customer point
# actually falls inside it. This stops the app from calculating a delivery
# time for a location that isn't even part of the network -- e.g. clicking
# somewhere outside the city entirely.
#
# Note on units: this project's road network uses an unprojected (lon/lat)
# CRS. Modern sf (>= 1.0) uses the S2 spherical geometry engine by default
# for that kind of coordinate data, which means st_distance()/st_buffer()
# already work in METERS, not degrees -- the same assumption R/04's curfew
# check already relies on. buffer_m below is a real meters value, not a
# degree offset.

library(sf)
library(sfnetworks)
library(dplyr)

# Builds the service-area polygon once. Call this after loading city_network.
# buffer_m: small buffer in meters so points right at the network's edge
# (e.g. an outlet near the boundary) aren't incorrectly rejected.
build_service_area <- function(network, buffer_m = 300) {
  nodes_sf <- network %>% activate("nodes") %>% st_as_sf()
  hull <- nodes_sf %>% st_union() %>% st_convex_hull()
  st_buffer(hull, buffer_m)
}

# Returns TRUE/FALSE for whether a point (same CRS as service_area) is
# within the service area.
is_within_service_area <- function(point, service_area) {
  as.logical(st_within(point, service_area, sparse = FALSE)[1, 1])
}
