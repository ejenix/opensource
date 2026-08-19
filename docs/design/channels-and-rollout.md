# Design: per-screen channels and staged rollout

**Status:** implemented · **Author:** Ejenix · **Date:** 2026-08-19

Two changes, designed together because they answer one question: **which
devices get which bundle.** Solving them separately means designing the storage
key twice.

---

## Problem 1 — one active bundle per app

The control plane keys the live bundle on `(appId, env)`. There is no
per-screen dimension, so an app with five patchable screens cannot have five
bundles live at once. Promoting one screen replaces whatever was active.

The documented workaround is to register each screen as its own *app id*
(`com.acme.shop.home`, `com.acme.shop.checkout`). It works, and it is wrong:

- the dashboard lists one product as five unrelated apps;
- "app id" no longer means the app, so `--app-id` in `ejenix build` stops
  matching the binary's identity;
- per-app API keys multiply, one per screen;
- it corrupts the mental model for every adopter, on day one.

## Problem 2 — every promote is all-or-nothing

`promote` swings an entire environment to a new bundle for 100% of devices at
once. Crash-loop rollback then heals each device individually — but only *after*
every device has already taken the bad patch. There is no way to expose a patch
to a slice of the fleet, watch, and widen.

---

## The design

### Key on `(appId, channel, env)`

A **channel** is a patchable surface within one app — usually one screen.

```
com.acme.shop  ├─ channel "home"      ├─ env staging     → bundle A
               │                      └─ env production  → bundle B
               └─ channel "checkout"  └─ env production  → bundle C
```

One app id. One signing key. One entry in the dashboard, with its surfaces
underneath.

**Backward compatible by construction.** The channel defaults to `default`, and
the existing route stays as an alias:

| Route | Meaning |
|---|---|
| `/v1/apps/<app>/envs/<env>/active` | channel `default` — unchanged behaviour |
| `/v1/apps/<app>/channels/<ch>/envs/<env>/active` | explicit channel |

Existing installs keep working with no migration: they are all channel
`default`. `Env` gains a `channel` field defaulting to `default`, and the store
key becomes `"$appId/$channel/$name"`.

### Staged rollout by client-side bucketing

`Env` gains two fields:

```dart
final int rolloutPercent;   // 0..100, default 100
final String rolloutSalt;   // stable for the life of this promotion
```

The **device** decides whether it is in the rollout — the server never learns
which devices exist:

```
bucket = fnv1a("$installId:$rolloutSalt") % 100
take the bundle if bucket < rolloutPercent
```

`installId` is a random id generated once per install and stored in
`BundleStore`. It never leaves the device.

This matters for four reasons:

1. **No device telemetry required.** Server-side cohorting would need a device
   registry — identity, storage, and a privacy surface this project does not
   currently have and should not acquire for this.
2. **Deterministic and stable.** A device's bucket does not change between
   launches, so it does not flip in and out of the rollout.
3. **Monotonic widening.** The salt is fixed per promotion, so raising
   5% → 20% strictly *adds* devices. Nobody who had the patch loses it.
4. **It preserves the trust model.** The control plane still only publishes
   facts; it never targets an individual device.

### How rollout interacts with rollback

`rollback` restores the previous bundle **at 100%**. A rollback is an
emergency, and a partial rollback would leave the fleet split precisely when an
operator most needs it whole.

### Why this is the differentiating part

Ejenix already rolls a device back on a crash loop. Combine that with a 5%
rollout and a bad patch is caught by devices that heal themselves *before the
other 95% ever see it*. Neither half is novel alone; together they are.

---

## API

```
POST /v1/apps/<app>/channels/<ch>/envs/<env>/active
     { "bundleId": "...", "rolloutPercent": 5 }     # percent optional, default 100

POST /v1/apps/<app>/channels/<ch>/envs/<env>/rollback
GET  /v1/apps/<app>/channels/<ch>/envs/<env>/active
     → { "activeBundleId": "...", "rolloutPercent": 5, "rolloutSalt": "..." }
```

CLI:

```sh
ejenix promote <id> --channel home --env production --rollout 5
ejenix promote <id> --channel home --env production --rollout 100   # widen
ejenix rollback --channel home --env production
```

Flutter:

```dart
EjenixPatchView(appId: 'com.acme.shop', channel: 'home', env: 'production', ...)
```

`channel` defaults to `default`, so nothing existing changes.

---

## Decisions taken

| Decision | Chosen | Why not the alternative |
|---|---|---|
| Channel vs. more app ids | channel | app id must keep meaning "the app" |
| Bucketing side | client | server-side needs a device registry and telemetry |
| Bucket input | install id + salt | user ids are PII and not always present |
| Rollback percent | always 100 | a partial rollback splits the fleet mid-incident |
| Default channel | `default` | keeps every existing route and install working |

## Deliberately out of scope

Explicit cohorts and allow-lists (beta testers, internal builds), and
region/version targeting. Percentage is the 90% case; cohorts need a device
registry, which is the thing this design avoids.

## Order of work

1. `Env` gains `channel`, `rolloutPercent`, `rolloutSalt`; store re-keys.
2. Routes, with the old route aliased to channel `default`.
3. CLI `--channel` and `--rollout`.
4. Device: install id, bucketing, `channel` on `EjenixPatchView`.
5. Dashboard: surfaces grouped under one app; rollout percent visible.

Steps 1–3 are server-side and independently testable. Step 4 is the only one
that touches the device, and it is backward compatible: a device that does not
send a channel gets `default`, and one that ignores `rolloutPercent` behaves
exactly as today.
