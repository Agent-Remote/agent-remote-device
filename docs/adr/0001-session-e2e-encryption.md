# ADR 0001: Nested TLS 1.3 for device-session end-to-end encryption

Status: accepted for implementation; independent security review required for production.

## Context

The control plane authenticates both peers and relays bounded frames, but must not
observe screenshots, input, clipboard data, or window contents. The cryptographic
construction must have maintained Swift and Rust implementations and must not be a
project-specific cipher or handshake.

## Decision

Each peer first establishes normal TLS 1.3 to the configured agent-remote relay.
The relay then transports an opaque byte stream containing a second TLS 1.3
connection whose only endpoints are the macOS Network Broker and the managed Rust
MCP proxy.

- Swift uses Network.framework TLS; Rust uses rustls 0.23.
- Both peers generate a P-256 ephemeral signing key and self-signed certificate for
  each device-session generation.
- Authenticated one-time connection material contains the expected SHA-256 SPKI
  digest for the opposite peer, the complete session binding, an expiry, and a
  random 256-bit connection secret. The secret is passed in the inner TLS exporter
  context and verified before application frames are accepted.
- After the TLS handshake, each peer sends one fixed 34-byte exporter-confirmation
  record. Its HMAC-SHA-256 binds the exporter output to the protocol version, sender
  role, generation, and device-session UUID. Each side verifies the opposite role's
  record in constant time before accepting the first application frame. The raw
  exporter output is never transmitted.
- The inner connection is TLS 1.3 only with AES-256-GCM or ChaCha20-Poly1305 suites
  offered by the platform libraries. Certificate trust roots and hostnames are not
  consulted; exact SPKI pin comparison is mandatory.
- Application frames additionally carry `generation`, a strictly increasing
  `monotonic_sequence`, request ID, and screenshot generation. This is the replay
  window: exactly the next sequence is accepted and no previous-generation frame
  is accepted.
- Reconnection increments `generation`, creates new certificates and connection
  material, and never replays an unacknowledged action.
- The maximum generation lifetime is 15 minutes. The control-plane lease can be
  shorter and always wins. Keys and plaintext buffers are memory-only and released
  when the generation stops.

TLS supplies nonces and record-key rotation according to RFC 8446. The application
does not derive record nonces or encryption keys.

## Security boundary

The trusted control plane can authorize sessions and replace connection material;
it is part of the documented trusted computing base. Nested TLS prevents plaintext
from entering relay request handling, structured logs, persistence, and backups. It
does not defend against a malicious control-plane administrator actively issuing a
replacement peer identity.

## Release gate

Production capability remains disabled until an independent review verifies the
Network.framework and rustls pinning implementations, exporter binding, certificate
generation, memory lifetime, downgrade resistance, and cross-language vectors.
