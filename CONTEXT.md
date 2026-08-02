# Operation Execution

This context receives named operations and tracks their execution through completion.

## Language

**Operation**:
A uniquely identified unit of work with a name, body, lifecycle state, result, and stable hash.
_Avoid_: Job, task

**Operation Body**:
The caller-supplied JSON value that contains an operation's input.
_Avoid_: Payload, parameters

**Operation Result**:
The JSON value produced when an operation succeeds or fails.
_Avoid_: Response, output body

**Operation State**:
The operation's current lifecycle position: new, submitted, running, succeeded, or failed.
_Avoid_: Status

**Terminal State**:
A succeeded or failed state after which an operation has a result.
_Avoid_: Completed state

**Operation Hash**:
A stable fingerprint of an operation's name and body used to identify the requested work.
_Avoid_: Body hash, checksum
