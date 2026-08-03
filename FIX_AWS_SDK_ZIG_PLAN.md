# Expose DynamoDB Conditional-Failure Items in aws-sdk-zig

## Summary

The request option already exists in the [generated `PutItemInput`](https://github.com/cloudboss/aws-sdk-zig/blob/896cb3984e0b44600520ba6f2e076322d016eb8e/service/dynamodb/put_item.zig). The actual gap is that [`ErrorGenerator`](https://github.com/cloudboss/aws-sdk-zig/blob/896cb3984e0b44600520ba6f2e076322d016eb8e/codegen/smithy-zig-codegen/src/main/kotlin/software/amazon/smithy/zig/generators/ErrorGenerator.kt) discards modeled exception members, while the AWS model already defines `ConditionalCheckFailedException.Item`. Fix this generically for AWS JSON 1.0/1.1 services rather than special-casing DynamoDB.

## Public Interface

- Extend `dynamodb.ConditionalCheckFailedException` with:
  `item: ?[]const aws.map.MapEntry(AttributeValue) = null`.
- Keep `message`, `request_id`, `ServiceError`, and operation return types compatible.
- Returned item data is owned by the diagnostic arena and remains valid until `diagnostic.deinit()`.
- Callers request it with `.return_values_on_condition_check_failure = .all_old` and retrieve it from `.conditional_check_failed_exception.item`, not from `PutItemOutput`.

## Implementation Changes

- Teach `ErrorGenerator` to emit modeled exception members for AWS JSON services, including required imports, documentation, resolved Zig types, defaults, and `json_field_names`. Preserve the existing normalized `message` and synthetic `request_id` fields.
- Update [`AwsJsonProtocol.writeParseErrorResponse`](https://github.com/cloudboss/aws-sdk-zig/blob/896cb3984e0b44600520ba6f2e076322d016eb8e/codegen/smithy-aws-zig-codegen/src/main/kotlin/software/amazon/smithy/zig/aws/protocols/AwsJsonProtocol.kt) to deserialize recognized error bodies into their generated exception type with `aws.json.parseJsonObject`, then populate normalized message/request metadata.
- Preserve existing behavior for unknown error codes and malformed typed payloads: return the existing unknown diagnostic fallback; never swallow allocation failures.
- Regenerate tracked service sources with `make codegen`; do not hand-edit generated DynamoDB files.

## Test Plan

- Extend AWS JSON generator fixtures with an exception containing an `Item` map and assert the generated field, imports, JSON mapping, and typed parser dispatch.
- Extend the existing LocalStack DynamoDB conditional `PutItem` test to request `.all_old`, verify `error.ServiceError`, and assert that `diagnostic.kind.conditional_check_failed_exception.item` contains the original key and hash values.
- Test omission of the option leaves `item == null`, while message/code behavior remains unchanged.
- Verify regeneration and compilation with `make codegen-dynamodb`, `make codegen`, and `make test`.
- Run `make test-integration-localstack SCENARIO=dynamodb`; no live AWS test is required.

## Assumptions

- Scope is AWS JSON 1.0/1.1 modeled exceptions; REST JSON/XML and Query protocols remain unchanged.
- `ReturnValues` and `ReturnValuesOnConditionCheckFailure` remain distinct.
- Retry behavior is unchanged.
- Updating the application's SDK pin and consuming the returned hash are separate follow-up changes.
