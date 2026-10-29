# Event Schema Onboarding — Multi-Team Procedure

This platform supports **many app teams, each owning their own event schemas**,
on one shared bus. Schema registration is **data-driven**: the platform module
registers every contract file found in `schemas/`, so onboarding a new team or a
new event is **adding a file + a PR** — no module or Terraform code change.

The sample `OrderPlaced` is just one team's contract. Here is how any team adds theirs.

---

## Model

- One **Schema Registry** per platform (`<name_prefix>-registry`), created when
  `enable_schema_registry = true`.
- One **schema per event contract**, auto-loaded from `schemas/*.json`.
- Schema **name** is derived from the file name, `__` → `@`, matching the
  EventBridge `source@DetailType` convention:
  | File | Registered schema name |
  |---|---|
  | `prod.orders__OrderPlaced.json` | `prod.orders@OrderPlaced` |
  | `payments.billing__PaymentSettled.json` | `payments.billing@PaymentSettled` |
- **Contract tests** (CI `contract-test` stage) validate each team's sample
  events against their schema and block a breaking change.

```
schemas/
├── prod.orders__OrderPlaced.json          # team: orders
├── payments.billing__PaymentSettled.json  # team: payments
├── <yourteam.domain>__<YourEvent>.json    # team: you (onboard here)
└── samples/
    ├── prod.orders__OrderPlaced/
    │   ├── valid-1.json                    # must PASS contract test
    │   └── invalid-1.json                  # must FAIL contract test
    └── <yourteam.domain>__<YourEvent>/
        ├── valid-1.json
        └── invalid-1.json
```

---

## Onboarding procedure (per app team)

1. **Write your contract.** Create `schemas/<source>__<DetailType>.json` as an
   OpenAPI 3 doc with your event under `components.schemas.<DetailType>`. Use
   `required`, `type`, `minimum`, `minLength`, `format`, and
   `additionalProperties: false` to make the contract strict. Copy an existing
   file as a template.

2. **Add sample events** under `schemas/samples/<source>__<DetailType>/`:
   - `valid-*.json` — representative good events (must pass).
   - `invalid-*.json` — events that violate the contract (must be rejected;
     this proves the guard works).

3. **Run the contract test locally** before the PR:
   ```bash
   python3 scripts/contract_test.py validate \
     schemas/<source>__<DetailType>.json \
     schemas/samples/<source>__<DetailType>/valid-1.json
   ```

4. **Open a PR.** The `contract-test` CI stage runs automatically: it lints every
   schema, and for each schema with a samples dir asserts valid-* pass and
   invalid-* fail. A broken or breaking contract fails the pipeline.

5. **Deploy.** On the next platform apply (`enable_schema_registry=true`) your
   schema is registered automatically — the module `for_each`es over the files.
   No Terraform edit; your file IS the input.

6. **Your producer** stamps events with your `Source` and `DetailType`; your
   rule pattern matches them. Consumers can generate code bindings from your
   registered schema (EventBridge console → Schemas → Download code bindings).

7. **Wire your consumer's failure handling.** Schema validation stops *malformed*
   events; it does not stop your handler from throwing on a *valid* event (a bug,
   a downstream outage). Your consumer must have BOTH an EventBridge target DLQ
   (delivery failures) and a Lambda `on_failure` destination (processing failures)
   so no event is silently dropped. The reference `modules/event-application`
   provides both by default (`enable_consumer_on_failure = true`) — see checklist
   item (f) in `docs/SECURITY_AND_ONBOARDING.md` for the full contract.

---

## Changing an existing schema (versioning & compatibility)

- **Backward-compatible change** (add an OPTIONAL field): edit the file, add a
  `valid-*` sample using the new field, PR. The compat check passes.
- **Breaking change** (new required field, removed/retyped field): publish a NEW
  version rather than mutating consumers' contract — e.g.
  `prod.orders__OrderPlaced.v2.json` and a new `DetailType` or a `version` field,
  and migrate consumers before retiring v1. The `contract_test.py compat`
  command flags added-required / removed-property changes as breaking.

```bash
python3 scripts/contract_test.py compat <old_schema.json> <new_schema.json>
```

---

## Cross-account teams

A team in ANOTHER account onboards the same way (their schema file in this repo),
AND their account must be allowed to publish — see `docs/CROSS_ACCOUNT_SHARING.md`
(`trusted_account_ids` / `organization_id`). The schema registry is in the
platform account; remote teams publish to the shared bus and their events are
validated against the registered contract.

---

## Enable the registry

The registry is created in EACH region it should exist in — apply to both
regional roots (keep the flags identical):
```bash
for ROOT in platform-primary platform-secondary; do
  terraform -chdir=$ROOT apply \
    -var enable_schema_registry=true \
    -var enable_schema_discoverer=true   # optional: auto-infer schemas from live events
done
```
`schemas_dir` defaults to `../schemas`; every `*.json` there is registered.
