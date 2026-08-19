# Design: fleet observability without a device registry

**Status:** proposed · **Author:** Ejenix · **Date:** 2026-08-19

---

## The problem

An operator cannot answer the first question they will ever ask:

> I promoted a patch an hour ago. Is it working?

The device→server channel is **read-only**. A device fetches
`/v1/apps/<app>/envs/<env>/active`, downloads a bundle, and reports nothing.
The server counts requests, uploads, and activations — none of which say
whether a patch *ran*.

Today the honest answer to "is this patch failing in the field" is: you find
out when a user complains. Staged rollout limits the blast radius to 5%, which
is a real improvement, but it does not let you *see* the 5%.

## The constraint that shapes everything

Staged rollout was built so that **the control plane never learns which devices
exist**. The server publishes a percentage and a salt; each install hashes its
own local id and decides for itself. There is no device registry, nothing is
reported back, and the README sells that as a property.

Naive telemetry destroys exactly that. "Report your install id and status" is a
device registry with extra steps — and it would turn an update channel into a
tracking channel for every adopter downstream, including ones who never asked
for analytics.

So the design goal is not "add telemetry". It is:

> Let an operator see fleet health **without the server being able to identify,
> count, or follow any individual install.**

---

## The design

### Aggregate counters, no identity

A device POSTs a **counter delta**, never an event and never an identifier:

```
POST /v1/apps/<app>/channels/<ch>/envs/<env>/telemetry
{
  "bundleId": "01a01aec-…",
  "outcome":  "updated" | "healthy" | "rolledBack" | "incompatible" | "rejected",
  "sdkVersion": "2.1.0"
}
```

What is deliberately **not** in that payload:

| Excluded | Why |
|---|---|
| install id | the thing that would make it a registry |
| device model, OS build | a fingerprint by another name |
| IP-derived anything | the server must not retain what the transport reveals |
| timestamps finer than the bucket | timing is an identifier at high resolution |
| free-text error strings | patches render user data; an error can carry it |

The server keeps **counts per `(app, channel, env, bundleId, outcome)`** and
nothing else. There is no row per device, so there is nothing to join, leak, or
subpoena.

### What that buys

```
bundle 01a01aec  updated 4,812   healthy 4,790   rolledBack 22   incompatible 0
bundle 01a01ae0  updated   118   healthy   too   rolledBack  0   incompatible 0
```

An operator can now answer:

- Is the new patch reaching devices? (`updated` climbing)
- Is it *working*? (`healthy` tracking `updated`)
- Is it failing? (`rolledBack` climbing → widen no further, or roll back)
- Is it unrunnable on older builds? (`incompatible` → a capability floor problem)

That is enough to run a staged rollout with eyes open, and it is the whole
point: **a 5% canary whose failures you can see** beats a 5% canary you cannot.

### Off by default, and honest about it

`EjenixPatchView(telemetry: TelemetryMode.off)` is the default. An adopter opts
in explicitly:

```dart
EjenixPatchView(telemetry: TelemetryMode.aggregate, …)
```

Defaulting this on would enrol every adopter's users in reporting they never
agreed to, and would make the privacy claim in the README false for anyone who
did not read this page. A feature that quietly changes what an app sends is not
a feature an adopter can vouch for to their own users.

### Why counters are safe where events are not

An event stream with enough fields becomes a fingerprint even without an id —
`(sdkVersion, outcome, arrival time)` narrows a population fast. Counters do
not, because the server never holds the tuple: it holds a number that went up.

Two properties keep it that way:

1. **The device batches.** Deltas are sent on the next check, not on the event,
   so arrival time is decoupled from occurrence time.
2. **The server stores no request-level record.** Increment and discard. There
   is no log to correlate later, which also means there is nothing to get wrong
   in retention policy.

---

## What this does not give you

Stated plainly, because the gap matters when someone is debugging at 2am:

- **No per-device history.** You cannot ask "what happened on *this* phone".
  That is the trade, and it is the point.
- **No stack traces.** A patch renders user data; an error string can carry it.
  The `outcome` enum is deliberately closed.
- **No delivery guarantee.** Counters are best-effort. A device that never comes
  back reports nothing, so `updated` is a floor, not a census.
- **No "how many devices do I have".** Counts are of *outcomes*, not installs. A
  device that updates twice counts twice. If you need a fleet size, that is a
  product analytics question and belongs in your own app, with your own consent
  flow — not in your update channel.

---

## Order of work

1. `TelemetryMode` on `EjenixPatchView`, default `off`.
2. Device: accumulate counter deltas in `BundleStore`, flush on the next check,
   drop silently on failure — telemetry must never affect whether a patch runs.
3. Server: `POST …/telemetry`, aggregate into `(bundle, outcome) -> count`.
4. Dashboard: per-bundle outcome columns beside the rollout percentage.
5. Docs: state exactly what is sent, and that it is off unless enabled.

Step 2 carries the one rule that must not be broken: **a telemetry failure is
never a patch failure.** It is fire-and-forget, off the critical path, and
bounded — an unreachable endpoint must cost nothing but a dropped counter.
