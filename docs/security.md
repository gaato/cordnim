# Security model

cordnim treats Discord credentials and user-controlled payloads as hostile at
every transport boundary.

- HTTP interactions must pass Ed25519 signature verification before JSON
  decoding and must be inside the configured timestamp window. The bounded
  replay cache fails closed; size it for peak traffic across that full window.
- Bot tokens use redacted secret types. Raw route parameters and verified
  interaction JSON may still contain webhook or interaction tokens, so their
  string rendering, scheduler keys, and public errors cross an explicit
  redaction boundary.
- Component routes carry a version, expiry, and HMAC; verification supports key
  rotation without accepting unsigned payloads.
- Mentions default to none. An application must opt into each mention target.
- Request and error logs omit authorization headers and request bodies.
- Webhook body limits are enforced by the HTTP server before application JSON
  decoding. Upload streams expose bounded reads and deterministic destruction;
  multipart transport integration is still tracked as alpha work.
- User tokens and self-bot operation are outside the supported API.

The CLI accepts a local `.env` only as literal key/value input; it never sources
or executes the file. The file is ignored by Git and should be mode `0600` on a
multi-user Unix host. Authorization values and token-bearing webhook paths never
enter scheduler route names or public transport error messages.

HTTP interaction verification fails closed when no Ed25519 provider is linked.
The optional libsodium adapter is enabled with `-d:cordnimSodium`. Persistent
component routes use BearSSL HMAC-SHA-256 and accept retiring verification keys
for rotation, while only the active key signs new routes.

Local permission checks are usability preflights only. Discord's response is the
security authority.

Deferred command and webhook failures can be observed through
`DeferredFailureObserver`. It receives only a failure phase and typed
interaction ID; exception messages remain behind the redaction boundary.
