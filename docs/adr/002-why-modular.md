# Modules and presets, not runtime flags

## Context

The kit has to produce tokens that differ: with and without a mint ceiling, with
and without seizure, with either payment scheme, both, or none. Solidity has no
conditional compilation, so "only include what was asked for" needs a mechanism.

## Options

**Runtime flags.** One contract with every feature and booleans to switch them
off. Rejected outright: the unused code still deploys, still has to be audited,
and still presents its selectors. The whole point of letting an issuer decline a
feature is that the feature is then absent. A flag makes it present and inert,
which is the opposite result.

**Diamond (EIP-2535).** Genuinely modular at runtime. Rejected as
disproportionate — it adds a delegatecall layer, shared storage discipline, and
an upgrade surface to a contract whose defining property should be that holders
know what it does. A stablecoin is not the place to spend that complexity budget.

**Presets only.** A fixed menu of concrete combinations. Simple and gas-optimal,
but the menu grows as 2ⁿ, and eight modules do not fit in a menu.

**Code generation.** Emit Solidity for an arbitrary combination, then compile it.
Solves the combinatorial problem completely, at the cost of a build step and
generated source that nobody reviewed line by line.

## Decision

Inheritance modules, with presets as the curated combinations, and code
generation deferred.

Each module is an `abstract contract` extending `TokenBase`. A preset
inherits the modules it wants and resolves the overrides. Nothing is compiled in
that was not asked for, and no runtime indirection is introduced.

Three structural choices make the modules independent of each other:

**The EIP-712 domain lives in the base.** Three modules need a domain separator.
If each inherited `EIP712` itself, enabling two at once would produce two
constructor calls for the same base and fail to compile.

**`GUARDIAN_ROLE` lives in a `Guardian` mixin.** Three modules grant a veto —
`MinterControl`, `Seize` and `UpgradeControl` — and declaring the constant in
more than one would collide in a preset that takes several. Declaring it in
`TokenBase` would also solve the collision, but at a cost: `MinimalToken`
includes no vetoable module and would still expose a grantable role governing
nothing — the present-and-inert outcome this ADR rejects flags for. A mixin a
module opts into carries the role only where it means something.

The mixin extends `TokenBase` rather than `AccessControlUpgradeable` directly.
The narrower base looks tidier, but it would make `AccessControl` reachable by
two routes in every preset taking both — so any override `TokenBase` places on
an AccessControl function, such as the floor under the last admin, becomes an
ambiguity each preset has to re-resolve by hand. One base, one route. The mixin
also declares no constructor, so modules inheriting it compose without
ambiguity; the most derived preset supplies `TokenBase`'s.

**Compliance is enforced in `_update` only.** Every balance change funnels
through it, so a payment module cannot open a path around a compliance check.
This is what makes adding a payment module safe, and it is why the payment
modules carry no `whenNotPaused` of their own.

The bypass hook `_blacklistBypassedFor(address)` is the one place a module reaches into
another. `Blacklist` declares it returning false; `Seize` — which extends
`Blacklist`, because seizing from a non-frozen account is not a thing this kit
allows — overrides it for the duration of its own call. A preset without `Seize`
has no bypass at all.

## Consequences

- A preset must spell out `override(ERC20Upgradeable, Blacklist, EmergencyPause)`
  for `_update`. This is boilerplate, and it is also the place a mistake would be
  visible, which is why it is not hidden.
- The composition test suite exists specifically to catch a gate that stops
  applying when modules are combined. Per-module tests cannot see that.
- Arbitrary combinations outside the shipped presets require writing a small
  contract by hand. Code generation would remove that step and remains the
  obvious next addition.
