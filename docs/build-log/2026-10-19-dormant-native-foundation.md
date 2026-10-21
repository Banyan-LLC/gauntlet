# Dormant original-owner native foundation

Stage 2 adds process-native and generic owned-work definitions extracted from 63dbc50992ce0ad792382900666440e95d7178bd. Production entry points retain their existing library. Only fresh isolated test children load gauntlet-review/scripts/dormant-native.ps1; loading defines functions without creating registries or compiling native types.

The complete worker pack stays in one AST and preserves each definition's source-file metadata during bootstrap. Process-stable registries retain original objects and refuse shape changes. Optional producer lookup examines loaded functions only; absent filesystem context is read directly from session state. The two filesystem context helpers preserve inherited deadlines without acquiring filesystem resources. Native held-source, filesystem, authentication and directory-custody declarations remain assigned to stage 3.

Both CLR helpers require a public readable static string SourceIdentity, exact lowercase SHA256 syntax and ordinal equality against the complete current template. Different already-loaded source refuses, including the production GauntletLive.Native type; matching repeat initialization is idempotent. Stage 3 must compose and test native source in fresh processes. It cannot extend a loaded type or introduce a loader exception.

## Ownership, acceptance and failure evidence

The original entry deadline covers creation, configuration, compilation, invocation, observation and disposal. Startup publication and generic completion use the original owner lock; no lock is held over I/O or waits. Final generic and native-facade publication fences reject expired acceptance after DTO construction. Expiry remains irreversible, while later settlement may reconcile the same retained resources physically.

The immutable six-field actual native receipt remains separate from aggregate acceptance. Actual native results are published inside the original CLR call before pipeline stop can discard its return. A successful native receipt cannot authorize aggregate success while its original pipeline, output, stop task or cancellation cohort remains unresolved.

Native faults have five scalar fields and at most two secondary faults. Projection preserves the actual primary, earliest distinct secondary and actual owning deadline under saturation. Generic projection likewise keeps independent worker, stop, disposal and cancellation failures. Pre-native initialization failure has no invented native receipt. Faulted cleanup retains original custody and fences later admission.

## Stream and native bounds

An explicitly owned success collection refuses unexpected success output before storage. All six diagnostic streams are guarded before bootstrap. Admission allows 4 KiB per record, 32 KiB cumulatively per channel and 64 KiB cumulatively across channels. Collections clear synchronously; bounded structural fault DTOs replace raw diagnostics. Separate capacity accounting allows 16 KiB per channel and 128 KiB in aggregate for collector storage and diagnostic construction. It does not confine the worker's heap or the transitive producer/runtime graph borrowed during a callback.

The first stream refusal requests one stop on the original pipeline and signals the same original native job. Explicit retained registrations link caller and stream cancellation without waiting for an in-flight callback during disposal. An unsuccessful unregister remains unresolved until its exact callback finishes; source disposal and native/generic retirement require actual settlement. Pipeline, output and stream-guard disposal are independent attempts in the original retained disposal task.

Native capture retains at most 4 MiB combined raw output. A separate 16 MiB storage budget covers stdin encoding, fixed capture chunks and overlapping decoded output. Stdin UTF-8 input is limited to 1 MiB before encoding. Filled chunks avoid fragmentation-dependent allocation and full-buffer copies. Overflow and cancellation signal the original job immediately; callbacks never wait for a cleanup-held job lock.

UTF-8 counting and writing both consume decoder state across chunk boundaries, including final replacement of incomplete sequences. A fixed, charged character scratch buffer bounds counting storage; final publication requires the written character count to match exactly. Isolated regressions compare ordinal text and UTF-8 bytes for every multibyte split, malformed input, final flush, empty output and embedded NULs through direct capture and both actual process pipes.

Native execution reserves one quarter of its initial remaining time, capped at five seconds, for retirement within the same absolute deadline. Every independent cleanup or termination operation requires admission before expiry. An admitted Windows call may finish later; that cannot authorize another operation or late acceptance. Original tasks, streams, handles and dependent attribute-list allocations remain in bounded unresolved custody until physical retirement is confirmed. Checked closure preserves failed original handles, and cleanup errors cannot overwrite earlier causes.

## Fault projection and isolated controls

Projection uses fixed CLR access to bounded stored primitive fields. Identifiers use a bounded ASCII grammar; numeric causes, hashes and recursive depth remain bounded. Generic, element and nested type shapes refuse before name formatting. Exact object-array delegate arguments avoid PowerShell type formatting and enumeration, including framework Exception.Data. Overridden getters, dictionary key methods and PowerShell instance members cannot supply projection callbacks. Mutable diagnostic Data and information tags are bounded again during enumeration. These guarantees concern the projection boundary, rather than arbitrary process-wide metadata changes during unrelated bootstrap.

Test scratch custody uses no-follow component opens, create-only leaves, retained original parent/leaf handles, original-handle disposition and strict removal verification. Lookup errors and substituted entries refuse while preserving original and independent cleanup errors. Each independent native or managed I/O admission and final publication checks the original deadline; cross-owner validation checks both clocks. Potentially blocking external-handle capture runs inside the original retained task after exact stream enrollment. Expiry retains unattempted resources independently of later settlement.

Process controls retain exact job, process and inherited-pipe identity. Descendant observation requires explicit exit evidence before accepting an unavailable start time and independently disposes acquired process objects. Readiness uses original retained events or authenticated pipe peers instead of unheld pathname messages. Timed creation and disposal scenarios run in separate fresh children; a creation barrier that consumes its deadline cannot manufacture later retirement to admit another scenario.

Run the isolated pack with pwsh -NoProfile -File tests/test-dormant-native.ps1, and complete current-runtime CI with pwsh -NoProfile -File tests/run-tests.ps1. New isolated tests must also pass on official PowerShell 7.2. The inherited complete-floor failures in unchanged production HashData(Stream) and Regex.Count helpers are deferred for dormant stages 2–3 only and must be fixed before activation; this waives no new regression or complete current-runtime check.

## Activation boundary

Transport, security, filesystem, reader, manifest, receipt-writer and candidate-discovery integration tests stay with their actual activation stages. This extraction changes no production fingerprint, installer, profile, proof or live gate and supplies no activation certificate. Reassembly must account for every preserved function/native hunk and remove the temporary dormant copy. A production module alternative requires complete source holds, fingerprints, copy inventories, proof identity, design and review; this dormant extraction does not approve that choice.
