# Experimental mirror wire contract

All integers in binary packets are unsigned big-endian. A packet is `length:u32`,
then `kind:u8`, then payload. Length includes kind, excludes the four-byte prefix,
and must be 1…8,388,608. Unknown kinds, malformed UTF-8, missing required fields and
invalid payloads close the connection. This revision has no compatibility negotiation.

| Kind | Payload |
| --- | --- |
| 0 | UTF-8 JSON control message |
| 1 | subscription UUID:16 raw bytes, sequence:u64, columns:u32, rows:u32, raw VT bytes |
| 2 | subscription UUID:16 raw bytes, sequence:u64, columns:u32, rows:u32, truncated:u8, UTF-8 text |

Sequence starts at 1. VT grid dimensions are 1…1000. Text dimensions allow zero for
an unspecified test/source grid; production Ghostty sources supply actual sizes.
Truncated is exactly 0 or 1. Empty text is a replacement. JSON frame/textFrame cases
are rejected: frames must use their binary encoding. No Base64 frame content is sent.

Control JSON follows Swift Codable's associated-value enum shape: no-payload list
is `{"list":{}}`; a subscribe is `{"subscribe":{"_0":{"paneID":"UUID",
"representation":"text-v1","intent":"ifFree"}}}`. The enum and payload structs in
`MirrorProtocol.swift` define required fields. Both repositories verify identical
fixed-byte vectors, independent of encode/decode round-trip tests.

Controls: challenge, authenticate, pair, paired, authenticated; list, panes;
subscribe, subscribed, acknowledge, input, refresh; history, historyPage; command,
commandResult, commandReceipt; failure, ended, ping, pong. There is no private
Agent-state or private submission control. Command envelopes preserve the public
CLI JSON and UUID request ID. See the feature documentation for command scope.

The `launch-profile` capability permits Profile-backed background tab creation.
`launch-shell` additionally permits a background `create tab` with no `launch`
field. Neither capability permits arbitrary initial Shell input. Mac clients gate
Shell creation on `launch-shell`; existing Profile requests remain unchanged.
The remote `list` command result adds optional `data.worktrees`, using the same
worktree fields as `data.items[].worktree`, to include known worktrees without
terminal panes. Clients without that field can still use worktrees from `items`.

## Authentication and lifecycle

TLS uses ECDHE-PSK with ChaCha20-Poly1305. Enrollment uses identity `pair` and the
normalized temporary code. Runtime connections use the device UUID identity and
32 random secret bytes. No plain-PSK legacy suite is enabled.

TLS PSK membership alone is not treated as a device identity. Host sends its stable
hostID and a fresh 32-byte nonce. Device proves its secret using HMAC-SHA256 over
UTF-8 `device:HOST_UUID:DEVICE_UUID:` followed by nonce bytes. Enrollment proves the
code over `pair:HOST_UUID:DEVICE_NAME:` plus nonce. UUID strings use the Foundation
uppercase canonical spelling. Proofs are Base64 Data fields in control JSON.
Different purpose, Host, identity or nonce cannot reuse a proof.

Before proof validation only authentication/enrollment and connection heartbeats
are accepted. Enrollment persists Host-generated device ID/key before replying;
the window is consumed before another peer can enroll. Client saves before closing
the enrollment connection and reconnecting with its device credential. Host names
are display metadata, never identity. Authentication has a five-second deadline.
Failure accounting and pending TLS pools are bounded. No secret is logged.

A subscribed connection has exactly one lease. Every input, ACK, history request,
refresh and targeted command must match it. Takeover revokes the previous connection.
Delayed commands recheck authorization immediately before delivery. A command result
is not a terminal/frame acknowledgement. One unacknowledged frame per subscriber
bounds backpressure; an ACK must exactly match its outstanding sequence.

History ID/offset refer to one frozen snapshot, with fixed total and capture time.
Pages cannot overlap, skip or exceed the total byte budget. Heartbeats run every
two seconds; eight seconds without inbound traffic ends an established connection.

## Interactive Agent input

A Host advertising `agent-input` accepts structured `agentsInput` with the same
`{pane, prompt}` payload as `agentsDispatch`. The pane must be a UUID owned by the
current authenticated subscription. The command is routed as `agents.input`; it
uses the shared Agent readiness and guarded paste/Enter path without creating or
mutating task dispatch records or injecting completion instructions. `text-v1`
remains the mobile representation. `agentsDispatch` retains its automation semantics.

Success has `command: "agents.input"`, schema `prowl.cli.agents.input.v1`, and
`data.input` containing UTF-8 `bytes`, `characters`, `source`, and
`trailing_enter_sent`. Clients verify the submitted byte count and Enter flag before
clearing that draft revision. Failed/uncertain delivery retains the draft;
`SEND_FAILED` is uncertain, not permission to replay. Existing request-ID deduplication
and `commandReceipt` recovery apply. A missing `agent-input` capability requires a
Host update; clients must not silently fall back to `agentsDispatch` or raw input.

## QR enrollment payload (version 1)

The QR carries UTF-8 JSON, not a URL or a transport message:

```json
{"type":"prowl-mirror-pairing","version":1,"address":"192.168.1.20","port":7880,"code":"ABCDEFGH","expiresAt":1800000060}
```

`address` is a numeric IPv4/IPv6 address reachable from the phone, never a wildcard
or loopback. `port` is an integer in 1...65535. `code` uses the existing eight-symbol
normalized pairing alphabet. `expiresAt` is an integer Unix time in seconds.
Scanners accept at most 2048 UTF-8 bytes, reject invalid/expired payloads and create
a fresh connection without a saved credential. Host still enforces expiry and
single use. The payload is not persisted or logged; transport authentication and
credential storage are unchanged. Version 1 is generated by Host and parsed by
both mobile apps. Cameras are not required for manual enrollment.
