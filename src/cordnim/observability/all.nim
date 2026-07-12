## Public structured logging and metric recording contracts.
##
## This module exports backend-neutral event values, stable metric names, and
## nil-safe recorder helpers. Cordnim does not select or configure an exporter.

import ./[logging, metrics]

export logging, metrics
