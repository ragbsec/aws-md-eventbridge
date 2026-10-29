# Cross-Account & Org-Wide EventBridge Bus Sharing

By default this platform's bus is **single-account**: only principals in the
deployer account can publish, and events are consumed only within that account.
Two opt-in, flag-gated features extend it to a shared, multi-project/multi-account
bus. Both are **off by default** (empty variables) and adding them is a proven
no-op until configured.

- **Publishing in** — let OTHER accounts (or a whole AWS Org) `PutEvents` to this bus.
- **Consuming out** — FORWARD matched events from this bus to buses in other accounts/regions.

All variables live on the **two regional roots** (`platform-primary` and
`platform-secondary`) and must be applied with the SAME value to each, so sharing
is symmetric and survives a global-endpoint failover.

---

## 1. Publishing IN — let other accounts send to this bus

### Variables (`platform-primary` + `platform-secondary`)
| Variable | Type | Effect |
|---|---|---|
| `trusted_account_ids` | `list(string)` | Account IDs allowed to `events:PutEvents`. Creates a bus resource policy with `arn:aws:iam::<id>:root` principals. |
| `organization_id` | `string` (`o-xxxx`) | Org-wide access via an `aws:PrincipalOrgID` condition — any principal in the org may publish. |

Either, both, or neither. Empty everywhere = no cross-account publishing (default).

### What it creates
- `aws_cloudwatch_event_bus_policy.sharing` on each regional bus — the resource
  policy granting `events:PutEvents`.
- **Matching KMS statements** concatenated into BOTH regional CMK key policies
  (`kms:Decrypt`, `kms:GenerateDataKey*`, `kms:DescribeKey`) for the same
  accounts/org. **This is mandatory**: the bus is CMK-encrypted, so a foreign
  publisher without KMS access gets `AccessDenied` on `PutEvents`. Sharing the
  bus and sharing the key are done together, automatically.

### Enable it
```bash
# explicit accounts — apply the SAME value to BOTH regional roots
for ROOT in platform-primary platform-secondary; do
  terraform -chdir=$ROOT apply \
    -var 'trusted_account_ids=["111122223333","444455556666"]'
done

# OR org-wide
for ROOT in platform-primary platform-secondary; do
  terraform -chdir=$ROOT apply -var organization_id=o-yu55c2titn
done
```

### The foreign publisher's side
A publisher in account `111122223333` sends to THIS bus's ARN. Their IAM principal
needs `events:PutEvents` on the full bus ARN of this account, e.g.:
```
arn:aws:events:us-east-1:<THIS_ACCOUNT>:event-bus/eb-prod-orders
```
If they use the global endpoint, they also need `awscrt` (SigV4a) — see
`docs/PREDEPLOY_PREFLIGHT_PROMPT.md` and the producer build notes.

---

## 2. Consuming OUT — forward events to other accounts' buses

### Variable (`platform-primary` + `platform-secondary`)
| Variable | Type | Effect |
|---|---|---|
| `forward_to_bus_arns` | `list(string)` | Event bus ARNs (any account/region) to forward matched events to. |

### What it creates (per region)
- `aws_cloudwatch_event_rule.forward` — a rule on this bus matching `source = event_source`.
- `aws_cloudwatch_event_target.forward` — one target per remote bus ARN (`for_each`).
- `aws_iam_role.forward` — the role EventBridge assumes to `events:PutEvents` on
  the remote bus(es).

### Enable it
```bash
for ROOT in platform-primary platform-secondary; do
  terraform -chdir=$ROOT apply \
    -var 'forward_to_bus_arns=["arn:aws:events:us-east-1:111122223333:event-bus/central-hub"]'
done
```

### The TWO-SIDED trust (the common gotcha)
Forwarding is a handshake — both sides must agree:
1. **This account (source)** — the `forward` role above sends. ✅ handled here.
2. **The remote account (target)** — its bus must allow THIS account in its own
   resource policy. The target account runs the **publishing** feature from
   section 1, naming this account in `trusted_account_ids`.
3. **Encryption** — forwarding moves the event but does not decrypt payloads
   across the boundary. If the remote bus is CMK-encrypted, the remote account
   manages that key's access for the incoming events.

---

## Topology patterns

**Hub-and-spoke (central events account):**
```
spoke A ─ forward_to_bus_arns ─┐
spoke B ─ forward_to_bus_arns ─┤→  central-hub bus  → central rules/consumers
spoke C ─ forward_to_bus_arns ─┘   (hub runs trusted_account_ids = [A,B,C])
```

**Shared bus, many publishers (same org):**
```
org apps ─ PutEvents ─→  this bus (organization_id = o-xxxx)  → rules/targets
```

---

## Caveats carried from the build

- **SCP interaction** — this account is org-governed (`o-yu55c2titn`). An org-wide
  policy interacts with SCPs; validate with the preflight before relying on it.
- **Schema governance** — once multiple teams/accounts publish, add the
  EventBridge **Schema Registry** so a producer's payload change can't silently
  break consumers. (Still an open maturity item.)
- **Not live-tested** — these were validated and proven no-op when unset, but
  exercising cross-account flow needs a second real account, which the sandbox
  lacks. The resource wiring follows the AWS-native pattern.
---

## Managing the sharing list (enable / add / change / disable)

Under the Option C layout the sharing variables live on **both regional roots**
(`platform-primary` and `platform-secondary`) — apply the SAME value to each so
the two regions stay symmetric (failover can redirect PutEvents to either). Each
operation is a plain `terraform apply`, at initial build OR any time after.
Terraform is declarative, so the list you pass is the FULL desired state:

```bash
# ENABLE (or add the first account) — apply the SAME list to BOTH roots
for ROOT in platform-primary platform-secondary; do
  terraform -chdir=$ROOT apply -var 'trusted_account_ids=["111122223333"]'
done

# ADD / CHANGE — pass the COMPLETE new list (not a delta) to BOTH roots. Accounts
# you drop LOSE access: the bus policy is fully overwritten and the KMS statements
# rebuilt — no orphaned grants.
for ROOT in platform-primary platform-secondary; do
  terraform -chdir=$ROOT apply -var 'trusted_account_ids=["111122223333","444455556666"]'
done

# DISABLE entirely — empty list on BOTH roots. The bus policy and the cross-account
# KMS statements are DESTROYED (bus Policy returns to None, access revoked).
for ROOT in platform-primary platform-secondary; do
  terraform -chdir=$ROOT apply -var 'trusted_account_ids=[]'
done
```

> Keep the value identical across the two roots. The regional roots have their
> own state, so they do not share the variable automatically — a value set on one
> region only shares that region's bus.

Org-wide works the same with `-var organization_id=o-xxxx` (set to `""` to remove).
Forwarding the same with `-var 'forward_to_bus_arns=[...]'` (`[]` to remove).

Verified behavior (live):
- enable → `AllowTrustedAccountsPutEvents` appears on the bus in both regions +
  KMS statements added.
- disable (`[]`) → bus policy destroyed, KMS statements reverted, `Policy = None`.

### IMPORTANT: account IDs must be REAL
KMS validates principals at policy-put time: a non-existent account ID in
`trusted_account_ids` fails the apply with
`MalformedPolicyDocumentException: ... invalid principals` and rolls back (the
EventBridge bus policy alone is laxer, but the paired KMS update is strict). Only
pass account IDs that actually exist. (The EventBridge bus policy does not need
the accounts to pre-exist, but the KMS grant does — and both are applied together.)

### For a long or frequently-changing list
Put the accounts in a tfvars file in EACH regional root instead of `-var` on the
command line (keep the two files identical):
```hcl
# platform-primary/sharing.auto.tfvars  AND  platform-secondary/sharing.auto.tfvars
trusted_account_ids = ["111122223333", "444455556666"]
organization_id     = ""          # or "o-xxxx" for org-wide
forward_to_bus_arns = []
```
Then edit the files and `terraform -chdir=platform-primary apply` /
`terraform -chdir=platform-secondary apply`. A `*.auto.tfvars` file is loaded
automatically, so the list lives in version control, not shell history.
