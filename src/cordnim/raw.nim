## Lossless access to the pinned stable Discord HTTP API schema.
##
## Generated models retain their source JSON so fields, enum values, and flag
## bits unknown to this Cordnim revision survive round trips. Generated route
## descriptors provide checked path rendering and token-free rate-limit keys.
## The semantic registry records corrections that the upstream OpenAPI shape
## cannot express. Preview operations stay outside this import.

import ./raw/stable

export stable

runnableExamples:
  let descriptors = semanticDescriptorsForSchema("SnowflakeType")
  doAssert descriptors.len == 1
  doAssert descriptors[0].semantic == SemanticKind.Snowflake
