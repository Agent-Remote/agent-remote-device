# Local Claude and network isolation evidence

Production activation requires runtime evidence from externally managed sensors. Source scans,
application logs, and an application-created marker do not prove isolation.

The release test Mac must run an Endpoint Security sensor and a Network Extension content filter
that are deployed independently of Agent Remote Device. The file sensor must watch all normalized
Claude data prefixes listed by `scripts/verify-isolation-evidence.rb`. The network sensor must use
controlled DNS, attribute every connection to its signed source process, and report the requested
hostname, TLS state, destination port, and dropped-event count. Both sensors must identify the
three fixed bundle identifiers and their Team ID and executable hashes.

Export the bounded JSON evidence without file contents, credentials, DNS payloads, or GUI data,
then verify it against the exact release archive digest and every approved control-plane hostname:

```sh
ruby scripts/verify-isolation-evidence.rb \
  --evidence isolation-evidence.json \
  --artifact-sha256 "$APP_ARCHIVE_SHA256" \
  --team-id "$TEAM_IDENTIFIER" \
  --allow-host control.example.com
```

The verifier rejects sensor gaps, incomplete process identity, local Claude path access,
connections from the UI or GUI executor, non-TLS traffic, and every destination outside the exact
allowlist. Passing the verifier does not install or activate the required system network policy;
that policy remains a separate MDM/Network Extension release gate.

## Runtime activation proof

The Network Broker also requires a live proof before sending an allowed approval to the control
plane and again before establishing its relay. The proof comes from the privileged mach service
configured in the signed Broker `Info.plist`; development builds leave that configuration empty and
therefore cannot activate device control. The service is owned and deployed by the MDM/Network
Extension operator, not by Agent Remote Device, Claude, MCP input, or the project workspace.

For each check the Broker sends a fresh 32-byte challenge. The attestor returns an Ed25519-signed
payload that binds the challenge, Apple Team ID, Broker bundle identifier, deployment policy ID,
and the exact single allowed control-plane hostname. The payload also includes ISO 8601 observation
and expiry times, `network_extension` enforcement, enabled state, an allowed-destination probe, an
unauthorized-destination blocked probe, and an Anthropic-destination blocked result. A blocked
probe must be decided inside the Network Extension before a packet leaves the Mac. Proofs older
than 30 seconds, valid for more than 60 seconds, or not returned within five seconds are rejected.

Both the signed payload and its envelope use JSON with exact fields. `Data` values use standard
base64 as defined by Swift `Codable`; the detached Ed25519 signature covers the raw `payload` bytes,
not a reserialized object. The production build pins the attestor mach service, raw 32-byte public
key, and policy ID through protected release environment values.

This live challenge prevents a project process from substituting or replaying an application-made
marker. It does not replace the external sensor export above, the raw `outbound-policy` release
evidence archive, or independent verification that the deployed Network Extension actually
implements signature-bound filtering.
