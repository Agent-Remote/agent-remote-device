# macOS security boundary

The product is split into Approval UI, Network Broker, and GUI Executor processes.
The broker owns device authentication and the fixed outbound endpoint but has no
Screen Recording or Accessibility entitlement. The executor owns TCC-backed GUI
operations but has no arbitrary network client or long-term device credential.
They communicate through a versioned, code-signature-validated XPC interface.
The Approval UI, Network Broker, and GUI Executor set both core-dump resource limits to zero before
loading credentials or session state and exit when that process hardening cannot be applied.

The application bundle identifier is `dev.agentremote.device`. No component reads,
discovers, launches, configures, or communicates with local Claude installations.
Anthropic credential environment variables are excluded from child environments.

Remote Claude lifecycle notifications arrive only through the generation-bound
mutual TLS channel. The Broker treats turn completion as an Executor-only stop so
the existing machine lock remains held. Session termination stops the Executor,
calls the authenticated control-plane stop operation, and only then closes the
relay.

After local approval, the app hides every unapproved application and starts the
global stop, screen-lock, user-switch, sleep, and network-loss monitors before it
asks the Broker to activate the server session or start the relay. Failure at any
point restores application visibility. A local stop observed while activation is
in flight leaves the UI paused and is forwarded as soon as Broker approval
returns; activation completion cannot overwrite that paused state.

Approval UI or Executor XPC invalidation immediately cancels the active relay.
Executor input release is best effort after the Executor becomes unavailable,
but its failure never suppresses the authenticated control-plane abort. The same
ordering applies to user Stop and End Session requests: local cleanup is
attempted first and control-plane revocation is still mandatory.

A trusted remote turn stop pauses only the current turn, not the approved device
session. Its acknowledgement waits for Executor input release and Approval UI
window restoration. Before the next authenticated action, the Broker uses the
same code-signature-checked XPC connection to re-hide unapproved applications,
restart the global safety monitors, and resume the Executor. The first resumed
action must be a new screenshot. Remote session end also waits for Approval UI
cleanup, while the machine lock remains held across the paused turn interval.
All safety-critical Broker calls to the Executor and Approval UI have a local
15-second reply deadline and cancellation handling. A connected XPC peer that
stops replying therefore fails closed in the same way as an invalidated peer.
Relay failure, identity rotation, or Executor loss asks the still-connected
Approval UI to end the current generation and restore applications before the
control-plane abort. Cleanup errors leave the UI in an explicit failed state;
they never suppress control-plane revocation. A replacement generation requires
a new local approval even when the device-session identifier is unchanged.

An allowed approval and relay activation each require a fresh, short-lived Ed25519 proof from the
fixed privileged outbound-policy attestor. The proof binds the signed Broker identity and exact
control-plane hostname to an enabled Network Extension and successful allow/block probes. Missing,
stale, mismatched, disabled, or silent attestors fail closed. The release evidence manifest is not
accepted as a substitute for this current-machine check.

Unsigned Swift Package builds exercise protocol and state-machine code only. A
signed installation on a dedicated test Mac is required to verify Sandbox, XPC,
ScreenCaptureKit, Accessibility, global Esc handling, window exclusion, and TCC
restart behavior.
