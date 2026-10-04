# PowerBridge protocol v1

HTTPS only. Pairing contains a lowercase SHA-256 fingerprint of the DER leaf certificate and a 32-byte hex HMAC key. The native client accepts that exact pinned leaf, rejects redirects, and uses an ephemeral URLSession.

`GET /v1/status` requires authentication and an empty body. Returns `name`, `os`, `role`, `dry_run`, `uptime` (companion process seconds, not OS uptime), `boot_targets`, nullable `pending`, and `history`.

`POST /v1/action` accepts a JSON object with only:

```json
{"action":"shutdown","delay":10,"target":"windows"}
```

PC actions: `shutdown`, `restart`, `boot`, `cancel`. Relay action: `wake`. `boot` means restart and requires `target`. Target is `""`, `linux`, or `windows`; it must be locally mapped when nonempty. Delays must be integer 5–3600 seconds. Body limit: 4096 bytes. Power operations are queued in memory until the deadline. Cancel is serialized with execution under one lock.

All requests include:

- `X-PB-Time`: UNIX seconds, 10 decimal digits; max clock difference 60 seconds.
- `X-PB-Nonce`: 16 random bytes as 32 lowercase hexadecimal characters.
- `X-PB-Signature`: lowercase HMAC-SHA256.

Signed UTF-8 text (newlines between fields, no final newline):

```text
METHOD
/path
TIMESTAMP
NONCE
SHA256_OF_RAW_BODY_HEX
```

JSON serialization need not match across implementations: sign the exact bytes sent. Repeated authenticated nonces are rejected under a thread lock and retained for 125 seconds; the cache is bounded and process-local. TLS is required in addition to HMAC. No CORS enrollment, plaintext fallback, or untrusted certificate bypass.

Interoperability vector:

- Secret: 32 zero bytes (`00` repeated 32 times).
- Method: `POST`; path: `/v1/action`.
- Timestamp: `1700000000`; nonce: `11111111111111111111111111111111`.
- Body: `{"action":"shutdown","delay":10,"target":""}`.
- HMAC: `7787f86186ff393c381bee4cade135ce9cc6b5c17596a15b818ec628fe146a2d`.

HTTP codes: 200 accepted/status, 400 invalid input, 401 auth/clock/replay rejection, 404 unknown route, 413 body too large, 500 operation failure. An accepted action is not evidence it has executed; inspect pending status and activity. A TLS timeout after a POST may leave an accepted pending action; do not retry blindly.
