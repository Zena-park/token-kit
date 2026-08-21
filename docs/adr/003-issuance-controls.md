# A drawdown budget, a timelock on structure, and a Guardian

## Context

A leaked mint key mints without limit. The usual answers do not bound the loss:

- A multisig helps until enough signers are compromised. The 2025 Bybit incident
  is the case worth studying — the multisig worked as designed and no key leaked,
  yet $1.4B left, because the signers were shown a forged interface and signed a
  genuine transaction. Key protection did not place a ceiling on anything.
- `pause` stops further movement but does not unmint what was minted.

So the ceiling has to be enforced on chain, in the issuance path itself.

## Decision

Four tiers, arranged so that no operational key can widen its own authority.

```
Owner --appoint (timelock)--> Controller --set allowance (instant)--> Minter
                                                                       |
                     Guardian --cancel / freeze (instant)--------------+
```

### The allowance is a drawdown budget, not a rate limit

```solidity
minterAllowance[minter] -= amount;   // spent on each mint, never refills
```

A daily rate limit refills, so an attacker mints the limit every day forever and
total loss is unbounded. A drawdown budget makes the remaining balance the
ceiling, and it is publicly readable before anything goes wrong.

It also matches the business. Issuance backs a reserve deposit, so the natural
unit is "as much as was deposited", not "so much per day".

Be clear about what that does and does not establish. The contract enforces
"no more than the Controller authorised". It does not and cannot enforce "no more
than was actually deposited" — nothing on chain knows what is in the bank. The
budget bounds the damage from a leaked key; it is not proof of backing, and the
link between the allowance and a real deposit is off-chain trust.

Burning does not refund it. If it did, a leaked Minter key could cycle
mint-burn-mint indefinitely inside a budget that never actually decreases.

### The timelock sits on structure, not on amounts

Reserve deposits arrive in real time. Telling a customer who just wired funds to
wait a day is not a workable product, so raising an allowance is immediate.

What takes time is *becoming* a Controller. Raising an allowance already requires
a Controller key, so the defensive line holds either way.

| Action | Timing |
|---|---|
| Raise or lower an allowance | Immediate |
| Remove a Minter or Controller | Immediate — revocation never waits |
| Appoint a Controller | One day, plus Guardian veto |

Executing a matured appointment is open to anyone. Scheduling it was the
privileged act and the waiting period has already been served, so gating
execution would add a liveness dependency without adding a control.

### The Guardian only blocks

It cancels pending appointments and freezes minting. It cannot create anything.
Because the authority is that narrow, a single hot key is an acceptable holder —
and a single hot key is what actually gets pressed during an incident, when
collecting multisig signatures takes hours and the incident takes minutes.

Unfreezing is admin-only. Fast to stop, deliberate to resume.

### What a leaked key costs

| Key | Damage |
|---|---|
| Minter only | Up to the remaining budget, and no further |
| Controller only | Can raise the budget but cannot mint |
| Both | Unbounded — so they belong in different custody |

That last row is the load-bearing operational requirement. The design is only
worth anything if the two keys are actually held separately.

The contract enforces the part of that it can see: an address is a Controller
or a Minter, never both. The direct form — appointing a key over itself — is
the obvious one. The indirect form is A managing B while B manages A: each key
then refills the budget the other spends, and one custody holding both is the
same failure as one key holding both ends of one pair. The same checks run at
scheduling and again at execution, and a Minter with its own appointment
pending as a Controller is refused as well, so a cycle cannot be announced in
two calls and left to whoever executes first. Appointments pending *over* a
Minter are not indexed, so that one shape fails only at execution.

Removing a Controller does not cancel appointments still pending over the
Minter it frees; one inside its window becomes executable again. It was
announced by the admin, it is visible as an event, and the Guardian can cancel
it. An admin removing a Controller scans `ControllerScheduled` for that Minter
first; `pendingController` is keyed by Controller, and several may be pending
over one Minter, which is also why the contract does not clear them itself — a
by-Minter index would be a set with removal on every schedule, execute and
cancel, for a case that is not inconsistent state.

## Alternatives

**A plain `MINTER_ROLE`.** Shipped as `SimpleMinter`, because it is the honest
choice when one custodian will hold every key anyway — the separation buys
nothing then — and for testnets and closed loops. It has no ceiling, and that is
stated rather than softened.

**A timelock on minting itself.** Rejected: it breaks real-time issuance, which
is the product.

## Consequences

- Setting up issuance takes a day, and the test helper walks the full path rather
  than reaching in, because the delay is the point.
- The issuer must run two custodies for the design to hold.
- `GUARDIAN_ROLE` comes from the `Guardian` mixin and is shared with the vetoes
  in `Seize` and `UpgradeControl`, so an issuer appoints one Guardian rather
  than one per feature.
- Relative to USDC's FiatToken, the Owner / Controller / Minter split is the
  same; the timelock and the Guardian are additions.
