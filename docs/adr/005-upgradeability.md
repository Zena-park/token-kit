# Upgradeable tokens, and putting the upgrade behind a delay

## Context

A token that cannot be fixed cannot be shipped by a licensed issuer, and the
capability is not theoretical. USDC gained EIP-3009 in one implementation
upgrade and ERC-1271 signature support in another; a version frozen at its first
release would have neither, and would not be payable through x402 today.

Against that, an upgrade key is the widest authority a token can have. A new
implementation can ignore the mint budget, skip the blacklist, or move balances
outright. Every other control in this kit is conditional on the implementation
staying honest — `MinterControl`'s ceiling on a leaked mint key is worth nothing
if a second key can raise the ceiling.

So the question is not whether to allow upgrades. It is what an upgrade has to go
through.

## Decision

Ship both. `src/presets/` produces immutable tokens; `src/presets/upgradeable/`
produces implementations meant for an ERC-1967 proxy, and adds `UpgradeControl`.

An upgrade is scheduled, waits a day, and can be vetoed by the Guardian — the
same shape as a Controller appointment and a seizure. One announcement buys one
upgrade.

The delay is what makes the ceiling claim honest rather than decorative. A holder
who watched the announcement can leave before the code changes; without it,
"issuance damage is bounded" would be true only until someone sent one
transaction.

### UUPS rather than USDC's transparent proxy

USDC keeps the upgrade in the proxy, answering to a proxy admin held outside the
token. This kit puts it in the implementation.

The reason is the veto. Checking `GUARDIAN_ROLE` means reading the token's roles,
and a transparent proxy would have to call back into its own implementation to
ask who the Guardian is. Keeping the upgrade where the roles already live is less
coupling.

The cost is that upgrading to an implementation without upgrade logic freezes the
proxy forever. OpenZeppelin's `UUPSUpgradeable` guards it with the ERC-1822
`proxiableUUID` check, which is a reason to build on that rather than write the
mechanism again.

### ERC-7201 namespaced storage

A preset is an inheritance list, so with sequential slots the storage layout
would be a function of module composition: adding a module to a preset would
shift the storage of every module after it and make existing deployments
un-upgradeable.

Each module therefore keeps its state in a namespace derived from its own name.
Composition and layout become independent, which is what makes "modular" and
"upgradeable" hold at the same time rather than trading against each other.

### Identity is not left to convention

Circle's FiatToken keeps name, symbol and decimals in ordinary storage set once
by `initialize`, with no setter — and then used upgrades to change two of them.
`initializeV2` takes a new name (`FiatTokenV2.sol`), `initializeV2_2` takes a new
symbol (`FiatTokenV2_2.sol`). Decimals it never touched, but nothing stopped it.

Both are load-bearing. Decimals silently reprices every balance. The name is part
of the EIP-712 domain, so changing it invalidates every outstanding EIP-3009 and
EIP-2612 signature. This kit takes three measures:

- **Decimals is an immutable in the implementation, not a storage slot.**
  Immutables are read from the executing code, which under a proxy is the
  implementation's, so a proxy gets the value with no slot to overwrite.
  Changing it takes a new implementation built with a different constructor
  argument — visible in verified source rather than in a storage write.
- **Identity setup refuses to run twice**, including under a `reinitializer`,
  which is otherwise how a later version reaches an initializer again.
- **The EIP-712 domain name reads the same slot `name()` does.** Held separately
  they drift, and a token that reports one name while verifying signatures
  against another is worse than one that changed its name honestly. FiatTokenV2_2
  reaches the same place by computing its domain separator from the live `name`.

None of this makes identity unchangeable — an implementation that writes the
namespace directly still can, because that is what upgradeability means. It makes
the change deliberate rather than incidental, and `identityHash()` gives an
observer something to compare while the delay runs.

## Consequences

- Name and symbol move into storage, because a proxy's storage cannot be written
  by an implementation's constructor. Decimals does not.
- One implementation can only be shared by tokens that agree on decimals. For
  payment tokens that is nearly always six.
- Every module is built on the upgradeable base contracts, and the immutable
  presets call the initializers from their constructor. They remain immutable:
  no proxy, no delegatecall, no upgrade path.
- Both payment profiles and `FullToken` have upgradeable variants.
  `MinimalToken` is immutable only — it is a reference point for reading the
  other presets, not a deployment target that would need patching.
- An issuer choosing the upgradeable path is asking holders to trust its future
  implementations. The delay and the veto bound that; they do not remove it. The
  immutable presets exist for issuers who would rather be unable to fix a bug
  than able to change the rules.
- Upgrade authority belongs on a multisig. Nothing in the contract enforces that,
  and nothing can.
