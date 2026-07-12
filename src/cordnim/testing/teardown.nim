## Aggregated teardown assertions for the scripted testing components.
##
## A `TeardownReport` collects the outstanding-work complaints from every
## scripted transport, Gateway driver, and running REST client used by a test,
## then fails once with a combined diagnostic. This catches unconsumed scripted
## REST responses and Gateway events, unexpected requests, unmatched sends,
## unfinished receives, running REST clients, queued or in-flight requests, and
## live cancellation groups.

import std/strutils

import cordnim/rest

import ./scripted_gateway
import ./scripted_rest

type
  TeardownReport* = object ## Accumulated outstanding-work diagnostics.
    problems*: seq[string] ## One entry per detected leak.

func initTeardownReport*(): TeardownReport =
  ## Creates an empty teardown report.
  TeardownReport()

proc check*(report: var TeardownReport, transport: ScriptedRestTransport,
            label = "rest") =
  ## Adds any unexpected requests or unconsumed responses from a REST transport.
  if transport.isNil:
    report.problems.add(label & ": scripted REST transport is nil")
    return
  for failure in transport.recordedFailures():
    report.problems.add(label & ": " & failure)
  if transport.pendingCount != 0:
    report.problems.add(label & ": " & $transport.pendingCount &
      " unconsumed scripted responses")

proc check*(report: var TeardownReport, driver: ScriptedGatewayDriver,
            label = "gateway") =
  ## Adds any unconsumed events or unmatched sends from a Gateway driver.
  if driver.isNil:
    report.problems.add(label & ": scripted Gateway driver is nil")
    return
  for failure in driver.sendFailures():
    report.problems.add(label & ": " & failure)
  if driver.unmetSendExpectations != 0:
    report.problems.add(label & ": " & $driver.unmetSendExpectations &
      " unmet send expectations")
  if driver.pendingEventCount != 0:
    report.problems.add(label & ": " & $driver.pendingEventCount &
      " unconsumed scripted events")
  if driver.unfinishedReceiveCount != 0:
    report.problems.add(label & ": " & $driver.unfinishedReceiveCount &
      " unfinished receive operations")

proc check*(report: var TeardownReport, client: ChronosRestClient,
            label = "rest-client") =
  ## Adds lifecycle and scheduler work reported by a REST client.
  if client.isNil:
    report.problems.add(label & ": REST client is nil")
    return
  if client.isRunning:
    report.problems.add(label & ": REST client is still running")
  if client.queuedCount != 0:
    report.problems.add(label & ": " & $client.queuedCount &
      " queued requests")
  if client.inFlightCount != 0:
    report.problems.add(label & ": " & $client.inFlightCount &
      " in-flight requests")
  if client.activeCancellationGroupCount != 0:
    report.problems.add(label & ": " & $client.activeCancellationGroupCount &
      " live cancellation groups")

func isClean*(report: TeardownReport): bool =
  ## Reports whether no outstanding work was detected.
  report.problems.len == 0

proc assertClean*(report: TeardownReport) =
  ## Raises `AssertionDefect` listing every outstanding-work problem found.
  if report.problems.len != 0:
    raise newException(AssertionDefect,
      "teardown detected outstanding work: " & report.problems.join("; "))
