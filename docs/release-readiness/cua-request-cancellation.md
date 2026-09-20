# Cua request cancellation

Owner: App/Execution. Scope: M1 and M2 caller-side cancellation. This change does not establish that a dispatched GUI action stops within 500 ms.

The controlled driver test reproduced two failures: a cancelled action remained suspended beyond 500 ms and later returned success, and an already-cancelled action started a driver. The red run is /tmp/perry-cua-cancel-before.log. After the request-boundary fix, all 28 CuaDriverClientTests passed in /tmp/perry-cua-cancel-tests.log on August 31, 2026.

Each pending request now has a cancellation handler keyed by request ID and connection generation. Cancellation removes and resumes that continuation once. A late response has no matching pending entry and cannot replay the action. The timeout task belongs to the suspended request and is cancelled when that request exits, including response, cancellation, timeout, and connection teardown. Already-cancelled execution stops before driver startup. AccessibilityActionRuntime preserves CancellationError rather than wrapping it as a generic execution failure.

Independent review found no double-resume, timeout-lifetime, or cross-generation cancellation defect in this bounded change. The final unsigned Debug app suite passed 242 tests, skipped two live Cua tests, and had zero failures in /tmp/perry-cua-request-final-app.log. No clean-checkout verifier or live worker-stop test was run.

The pinned Cua 0.22.1 direct stdio loop ignores notifications and awaits each call serially. It does not implement request-scoped MCP cancellation. See the pinned [direct loop](https://github.com/trycua/cua/blob/c60ef6ad2db8774fb342938843e2f17f26c68240/libs/cua-driver/rust/crates/cua-driver/src/proxy.rs#L66-L106) and [dispatcher](https://github.com/trycua/cua/blob/c60ef6ad2db8774fb342938843e2f17f26c68240/libs/cua-driver/rust/crates/cua-driver-core/src/server.rs#L876-L945). Perry therefore sends no unsupported cancellation notification and makes no claim that a dispatched effect was undone.

The remaining release work is to isolate workers so one task can terminate its worker without interrupting others, make startup waits cancellable, and prove worker termination within the budget. Existing durable checkpoints must continue to retain uncertain dispatched actions for inspection. The current tests release the delayed fixture after cancellation; they prove prompt waiter release and no replay, not termination of a hung production worker or out-of-order response isolation.
