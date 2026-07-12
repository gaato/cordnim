## Scheduling controls shared by handwritten semantic REST operations.
##
## Callers choose deadlines, priority, retry bounds, audit context, and a
## cancellation group. Each operation supplies its own idempotency evidence.

import std/[options, strutils]

import cordnim/rest/request

type ApiCallOptions* = object ## Validated caller-controlled REST scheduling.
  deadlineValue: Option[MonoMillis]
  priorityValue: RequestPriority
  retryPolicyValue: RetryPolicy
  auditReasonValue: Option[string]
  cancellationIdValue: Option[uint64]

func initApiCallOptions*(
    deadline = none(MonoMillis);
    priority = rpNormal;
    retryPolicy = defaultRetryPolicy();
    auditReason = none(string);
    cancellationId = none(uint64)): ApiCallOptions =
  ## Creates scheduling options without exposing operation idempotency.
  let problems = retryPolicy.validate()
  if problems.len != 0:
    raise newException(ValueError, problems.join("; "))
  if deadline.isSome and deadline.get < MonoMillis(0):
    raise newException(ValueError, "REST deadline must not be negative")
  if auditReason.isSome and not auditReason.get.validateAuditReason():
    raise newException(ValueError, "invalid Discord audit log reason")
  ApiCallOptions(
    deadlineValue: deadline,
    priorityValue: priority,
    retryPolicyValue: retryPolicy,
    auditReasonValue: auditReason,
    cancellationIdValue: cancellationId,
  )

func deadline*(options: ApiCallOptions): Option[MonoMillis] =
  ## Returns the latest allowed dispatch instant.
  options.deadlineValue

func priority*(options: ApiCallOptions): RequestPriority =
  ## Returns the scheduler lane selected by the caller.
  options.priorityValue

func retryPolicy*(options: ApiCallOptions): RetryPolicy =
  ## Returns the bounded retry policy selected by the caller.
  options.retryPolicyValue

func auditReason*(options: ApiCallOptions): Option[string] =
  ## Returns the validated Discord audit-log reason, when supplied.
  options.auditReasonValue

func cancellationId*(options: ApiCallOptions): Option[uint64] =
  ## Returns the application cancellation-group identifier, when supplied.
  options.cancellationIdValue

func requestMeta*(options: ApiCallOptions;
                  idempotency: Idempotency): RequestMeta =
  ## Converts validated options using evidence chosen by the semantic operation.
  let problems = options.retryPolicyValue.validate()
  if problems.len != 0:
    raise newException(ValueError,
      "API call options were not initialized: " & problems.join("; "))
  if options.deadlineValue.isSome and
      options.deadlineValue.get < MonoMillis(0):
    raise newException(ValueError, "REST deadline must not be negative")
  if options.auditReasonValue.isSome and
      not options.auditReasonValue.get.validateAuditReason():
    raise newException(ValueError, "invalid Discord audit log reason")
  RequestMeta(
    deadline: options.deadlineValue,
    priority: options.priorityValue,
    retryPolicy: options.retryPolicyValue,
    idempotency: idempotency,
    auditReason: options.auditReasonValue,
    cancellationId: options.cancellationIdValue,
  )
