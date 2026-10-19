# Bounded review transport foundation

This change adds the dormant GauntletTransport C# component and its direct fixture. Existing production PowerShell callers continue to use their current execution path; this foundation does not activate a new provider or change security claims, fingerprints, configuration or installation.

The component preserves complete prompt content while enforcing bounded requests, bodies, aggregate traffic and a shared deadline. It validates fixed upstream routes, requires its loopback capability, handles authenticated Responses/SSE exchanges and 401 challenges, and retains typed failures and physical transport-retirement evidence. All terminal compatibility and ownership corrections from the preserved implementation ship together.

The direct test compiles the component and fixture into one assembly. Its upstream seam and clients use in-memory responses and literal loopback traffic; it does not require an account, credentials or a real model call. A missing-implementation run failed as expected before this source was added.

Supported-floor verification exposed raw response headers discarded by .NET 6 typed enumeration. The follow-up validates both raw header collections before typed access and accepts only HTTP 200 for a complete upstream response, retaining the separate bounded 401 recovery path. These header and partial-status corrections extend the preserved implementation; focused fixtures cover both routes and refusal after prior success.

Graceful client retirement now distinguishes terminal delivery from trailing stream bytes. The original owned write must settle before delivery is acknowledged; tail I/O waits for native retirement under the original deadline. Deterministic loopback fixtures cover delayed settlement, coalesced heartbeats, tail errors before retirement, unwritten bytes, original write failures and unsuccessful or missing graceful finish.

The native-disposal fixture now deletes its temporary lease through the original DeleteOnClose handle. A deterministic replacement control verifies that original disposal preserves a later file at the same name; the replacement is also cleaned through its own handle. Existing exclusivity and disposal-failure controls remain intact.

Final transport cleanup now rechecks the original monotonic deadline before disposing the failure signal and when publishing retirement. A retired transport can therefore still fail deadline acceptance. Deterministic actual-clock fixtures withhold only the timer callback, retain timely and prior-failure controls, and preserve typed primary and cleanup causes.

Cancellation classification also reads the original cancellation owner before its notification callback can run. Controlled inline read continuations distinguish that deadline signal from explicit Close and an unrelated cancellation exception, while preserving the original clock and typed cause. Existing stream-timeout assertions retain their budgets and now include failure-only state diagnostics.

Catalog completion is tracked per request after its original body writes, EOF and validation settle. Graceful finish can therefore observe catalog EOF while the original connection cleanup is still returning, without replacing that cleanup or accepting incomplete work. Deterministic controls cover prior inference, a later incomplete catalog, repeated finish, validation failures, late cleanup and the original disposal exception.

Production integration, source-bound calibration and live-stack certification belong to later dependency-safe changes. No global installation, runtime setup or fresh active-stack certification is claimed here.
