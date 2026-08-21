# token-kit

[![CI](https://github.com/Zena-park/token-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/Zena-park/token-kit/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

A modular kit for ERC-20 payment tokens — controlled issuance, compliance
switches, and signature-based transfers; immutable or upgradeable, deployed at
a deterministic address on every chain.

The modules follow Circle's FiatToken, which USDC is an instance of: the
Owner / Controller / Minter split, the per-minter mint allowance, the blacklist
and the pause come from there, and the EIP-3009 type hashes are byte-identical to
USDC's, so x402 clients built against USDC work unchanged. Two things FiatToken
does not have are added: a timelock and a Guardian veto on issuance authority,
and the same treatment on the upgrade itself.

FiatToken does not implement a peg, a reserve or a redemption right, and neither
does this. What makes USDC a stablecoin is Circle holding dollars and honouring
redemption, which is an off-chain arrangement; the contract is the other half —
who may mint, how much, who can be frozen, and how a payment is authorised. That
half is what this kit builds.

```
                     ┌──────────────────────────────────────┐
                     │              TokenBase               │
                     │   ERC-20 · roles · EIP-712 domain    │
                     └──────────────────┬───────────────────┘
                                        │
            ┌───────────────┬───────────┴────────┬──────────────────┐
            │               │                    │                  │
      ┌─────▼─────┐   ┌─────▼──────┐      ┌──────▼─────┐     ┌──────▼─────┐
      │  payment  │   │  issuance  │      │ compliance │     │  (yours)   │
      ├───────────┤   ├────────────┤      ├────────────┤     └────────────┘
      │ EIP-3009  │   │ MinterCtl  │      │ Blacklist  │
      │ EIP-2612  │   │ SimpleMint │      │ Pause      │
      │           │   │            │      │ Seize      │
      └───────────┘   └────────────┘      └────────────┘
            │               │                    │
            └───────────────┴────────┬───────────┘
                                     │
                 ┌───────────────────┴───────────────────┐
                 │                                       │
      ┌──────────▼───────────┐             ┌─────────────▼──────────┐
      │  immutable presets   │             │  upgradeable presets   │
      │  Minimal · Permit    │             │  + UpgradeControl,     │
      │  Eip3009 · Full      │             │  behind ERC-1967 proxy │
      └──────────────────────┘             └────────────────────────┘
```

## Quick start

```bash
git clone --recurse-submodules https://github.com/Zena-park/token-kit
cd token-kit/contracts
forge test
```

```bash
forge script script/Deploy.s.sol:Deploy \
  --sig 'deployEip3009Token(string,string,uint8,address,uint96)' \
  'Acme Won' 'AKRW' 6 $ADMIN 1 \
  --rpc-url $RPC --sender $DEPLOYER --broadcast
```

Every preset has its own entry point — `deployMinimalToken`,
`deployPermitToken`, `deployFullToken`, and `deployUpgradeable*` variants —
with the same arguments. `--sender` must be the broadcasting key: it becomes
the issuer, the only account that can hand the token to its admin. The full
runbook, including the upgradeable path, is in
[docs/deploying.md](docs/deploying.md).

## Using as a library

To compose your own preset in your own Foundry project rather than deploying
one of the shipped ones:

```bash
forge install Zena-park/token-kit
```

Put the remappings in a `remappings.txt` at your project root (or in the
`remappings` array of your `foundry.toml`). The kit's modules import
OpenZeppelin through its own vendored submodules, so no separate install is
needed. (The two `@openzeppelin` lines mirror `contracts/foundry.toml`'s own
remappings, re-rooted under `lib/token-kit/`.)

```
token-kit/=lib/token-kit/contracts/src/
@openzeppelin/contracts/=lib/token-kit/contracts/lib/openzeppelin-contracts/contracts/
@openzeppelin/contracts-upgradeable/=lib/token-kit/contracts/lib/openzeppelin-contracts-upgradeable/contracts/
```

Then a preset is an inheritance list plus the funnel resolution:

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {TokenBase} from "token-kit/core/TokenBase.sol";
import {Eip2612} from "token-kit/modules/payment/Eip2612.sol";
import {SimpleMinter} from "token-kit/modules/issuance/SimpleMinter.sol";
import {EmergencyPause} from "token-kit/modules/compliance/EmergencyPause.sol";

contract MyToken is TokenBase, Eip2612, SimpleMinter, EmergencyPause {
    constructor(string memory name_, string memory symbol_, uint8 decimals_, address issuer_)
        TokenBase(decimals_)
        initializer
    {
        __TokenBase_init(name_, symbol_, issuer_);
    }

    // Each module that gates a funnel is named once; `super` runs the chain.
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, EmergencyPause)
    {
        super._update(from, to, value);
    }

    function _approve(address owner, address spender, uint256 value, bool emitEvent)
        internal
        override(ERC20Upgradeable, EmergencyPause)
    {
        super._approve(owner, spender, value, emitEvent);
    }
}
```

The shipped presets in `contracts/src/presets/` are the reference for which
overrides each module combination needs — the compiler names every base that
must be resolved, so a missing one is a build error, not a silent gap. Why
the design composes this way is
[docs/adr/002-why-modular.md](docs/adr/002-why-modular.md). Pin the latest
release tag (see [CHANGELOG.md](CHANGELOG.md)) rather than tracking `main`.

## Modules

Each module is an independent `abstract contract`. A preset inherits the ones it
wants and resolves the overrides.

| Module | Group | What it adds | What it costs |
|---|---|---|---|
| `Eip3009` | payment | Signature transfers with random `bytes32` nonces; any caller submits and pays the gas. The EIP's `(v, r, s)` functions plus a `bytes` form for ERC-1271 signers | Three functions in two forms each, three type hashes and a nonce map in the token |
| `Eip2612` | payment | `permit` — allowance by signature; the EIP's `(v, r, s)` form plus a `bytes` form for ERC-1271 signers (`IEip2612`) | Sequential nonces; concurrent authorizations collide |
| `MinterControl` | issuance | Owner / Controller / Minter / Guardian, drawdown mint budget, timelocked appointments; an address is a Controller or a Minter, never both | Two custodies to run |
| `SimpleMinter` | issuance | One role, unlimited mint | No ceiling |
| `Blacklist` | compliance | Freeze an account in both directions | Issuer holds censorship power |
| `EmergencyPause` | compliance | Stop all movement | A single key can halt the token |
| `Seize` | compliance | Move a frozen balance after a delay, subject to veto | Destination is arbitrary; USDC has no equivalent |
| `Guardian` | shared | The veto role the scheduling modules share | — |
| `UpgradeControl` | upgrade | Scheduled, delayed, vetoable implementation upgrade | The admin can eventually change any rule the token enforces |

All balance movement funnels through `_update`, so the compliance modules apply
to every payment path, including Permit2 pulls, which arrive as ordinary
`transferFrom` calls.

## Presets

Immutable — no proxy, no upgrade path, no admin upgrade key:

| Preset | Payment | Issuance | Compliance | Runtime size |
|---|---|---|---|---|
| `MinimalToken` | — | SimpleMinter | — | 6.5 KB |
| `PermitToken` | EIP-2612 | MinterControl | Blacklist, Pause | 13.3 KB |
| `Eip3009Token` | EIP-3009, EIP-2612 | MinterControl | Blacklist, Pause | 14.9 KB |
| `FullToken` | EIP-3009, EIP-2612 | MinterControl | Blacklist, Pause, Seize | 16.4 KB |

Upgradeable — implementations for an ERC-1967 proxy, adding `UpgradeControl` to
the same composition:

| Preset | Same modules as | Runtime size |
|---|---|---|
| `UpgradeablePermitToken` | `PermitToken` | 16.1 KB |
| `UpgradeableEip3009Token` | `Eip3009Token` | 17.9 KB |
| `UpgradeableFullToken` | `FullToken` | 19.4 KB |

### What each one can do

| | `MinimalToken` | `PermitToken` | `Eip3009Token` | `FullToken` |
|---|:--:|:--:|:--:|:--:|
| Holder pays without holding gas | — | signs `permit` | signs a transfer | both |
| Several payments in flight at once | — | no, one counter | yes, random nonces | yes |
| Passkey / smart-account payers | — | yes | yes | yes |
| Payee contract acts on receipt | — | — | `receiveWithAuthorization` | yes |
| Ceiling on what a mint key can mint | none | drawdown budget | drawdown budget | drawdown budget |
| Freeze minting in an incident | — | Guardian | Guardian | Guardian |
| Freeze an account | — | yes | yes | yes |
| Halt all movement | — | yes | yes | yes |
| Move a frozen balance | — | — | — | 1 day + veto |
| Replace the code to fix a bug | — | `Upgradeable*` only | `Upgradeable*` only | `Upgradeable*` only |

Each `Upgradeable*` preset does everything its immutable counterpart does, and
adds the last row: an upgrade is scheduled, waits a day, and can be vetoed.
`MinimalToken` has no upgradeable variant.

`MinimalToken` is an ERC-20 with a mint role. It is the reference point for
reading the others rather than a deployment target.

Both payment presets settle through Permit2 or a facilitator without the holder
ever sending an approval transaction, and neither grants a spender an allowance
the holder did not sign for.

### Picking one

| Situation | Preset |
|---|---|
| Testnet, closed loop, internal ledger | `MinimalToken` |
| Payments, smallest amount of signature code in the token | `PermitToken` |
| Payments that settle concurrently, or a contract that must act on receipt | `Eip3009Token` |
| A mandate to move sanctioned balances | `FullToken` |
| Any of the above, with a route to fix a bug | `Upgradeable*` |

## Choosing between the payment profiles

| | `Eip3009Token` | `PermitToken` |
|---|---|---|
| Gasless first payment | Yes | Yes |
| Concurrent payments | Yes, random nonces | Yes, Permit2 nonce bitmap |
| Passkey / ERC-1271 payers | Yes | Yes |
| Signature code in the token | EIP-3009 and EIP-2612 | EIP-2612 only |
| External dependency | None | Permit2, at settlement time |
| Gas per payment | One call to the token | Proxy, Permit2, then `transferFrom` |
| x402 status | Recommended method | Universal fallback method |

Background: [EIP-3009 or Permit2](docs/adr/001-eip3009-vs-permit2.md).

## Deploying

Addresses come from the canonical CREATE2 deployer, so the same salt and init
code give the same address on every chain that has one. Nothing in this
repository has to be deployed first.

```
salt = bytes32(bytes20(deployer)) | bytes32(uint256(entropy))
```

The deployer goes in the leading bytes because a bare salt is
first-come-first-served across chains.

The admin is not part of the init code, so one issuer can use a different
multisig per chain without the token address changing. `initializeAdmin` is
therefore a second transaction on both paths — and only the issuer named in the
init code may make it, which is what keeps that separation from being a race for
anyone watching the mempool or replaying the salt on another chain. The issuer
*is* in the init code, because unlike the admin it is the same everywhere. Send
both in one broadcast, from the issuer key, and verify the result.

Full instructions, including the upgrade procedure and the storage rules that
come with it, are in [docs/deploying.md](docs/deploying.md).

## Tests

All tests passing — `forge test` is the source of truth for the count.

```bash
forge test            # unit and composition
forge lint src        # clean
forge build --sizes   # contract sizes
```

Suites are organised by module, plus a composition suite covering the
combinations, where `_update` is overridden across three modules.

## Design notes

- [EIP-3009 or Permit2](docs/adr/001-eip3009-vs-permit2.md)
- [Modules and presets, not runtime flags](docs/adr/002-why-modular.md)
- [A drawdown budget, a timelock, and a Guardian](docs/adr/003-issuance-controls.md)
- [Keep EIP-712 hashing in Solidity](docs/adr/004-inline-assembly-hashing.md)
- [Upgradeable tokens, and the delay on the upgrade](docs/adr/005-upgradeability.md)
- [Deploying](docs/deploying.md)
- [Gas costs](docs/gas.md)

## Limits

The off-chain half is not here and cannot be: reserve custody, redemption,
attestation and the licence to issue. Deploying this satisfies no regulatory
regime on its own.

## Security

**Not audited**, and nothing here has been deployed to a production network.
The review record is [docs/security-review.md](docs/security-review.md);
what needs an audit, and how to report a vulnerability, is
[SECURITY.md](SECURITY.md).

## Licence

Apache-2.0
