# EIP-3009 or Permit2

## Context

A payment stablecoin has to let a holder with no gas pay. Something must move
tokens on a signature alone, and there are three ways to arrange it.

## The three options

### EIP-3009

The holder signs a `TransferWithAuthorization` struct; anyone submits it. Nonces
are random `bytes32`, so authorizations have no ordering and several payments can
settle concurrently. x402 lists it first and calls it the simplest and only
truly gasless method. USDC, PYUSD and EURC all implement it.

It comes as a pair. `transferWithAuthorization` may be submitted by anyone, which
is what makes the flow permissionless. That breaks when the payee is a contract
that must act in the same transaction — splitting a fee, marking an order paid —
because ERC-20 has no receive hook. A third party who lifts the signature from
the mempool can push the funds in without calling the settlement function, so the
money arrives, the order does not settle, and the nonce is spent so the real call
now reverts. `receiveWithAuthorization` requires `to == msg.sender`, which
confines the transfer to the payee's own function.

The second function is not decoration; it is the front-running defence. Shipping
only the first would be worse than shipping neither, because contracts that
detect `transferWithAuthorization` reasonably assume its partner exists.

### Permit2

Uniswap's Permit2 does the same job for any ERC-20, from outside the token.
`permitWitnessTransferFrom` binds the spender into the signature and enforces
`msg.sender == spender`; the x402 proxy binds the recipient through a witness.
That is the same guarantee `receiveWithAuthorization` gives, relocated.

Its cost is setup: the holder must `approve(PERMIT2, ...)` once, on chain, paying
gas. This is exactly why USDT-style tokens cannot offer a gasless *first*
payment. This kit removes that transaction with EIP-2612: the holder grants the
Permit2 allowance by `permit` signature — the x402 proxy's `settleWithPermit`
does it inside the settlement call — so the first payment is gasless and the
allowance stays revocable. Baking the approval into the token instead, with an
`allowance` override returning `type(uint256).max` for Permit2, would remove
even the signature, but the resulting allowance is unrevokable: every holder
would trust Permit2 permanently, whether they ever route a payment through it
or not.

### EIP-2612

`permit` sets an allowance by signature. Its nonce is a counter, so two
authorizations from one holder must be submitted in order. Fine for occasional
approvals, wrong for payments — an agent paying three APIs at once would have two
of the three revert.

## What the x402 spec requires

EIP-3009 is not required for x402 compatibility. `x402/specs/schemes/
exact/scheme_exact_evm.md` defines three asset transfer methods:

| Method | Spec's own label |
|---|---|
| EIP-3009 | **Recommended** — simplest, truly gasless |
| Permit2 | **Universal fallback** — works for any ERC-20 |
| ERC-7710 | delegation-based |

A token with no EIP-3009 is payable through x402 via the canonical
`x402ExactPermit2Proxy`. Dropping it costs gas and adds a dependency; it does not
cost compatibility.

## Decision

Ship both as modules, and let the preset decide.

Neither is simply correct. The choice depends on something only the issuer
knows — whether per-payment gas or minimal token surface matters more — which
is the same reason this repository is a kit rather than a token.

- `Eip3009Token` takes EIP-3009 plus EIP-2612.
- `PermitToken` takes EIP-2612 only; payments settle through Permit2, whose
  allowance the holder grants by `permit` signature and can revoke at any time.

Two things follow that are worth stating separately.

**Verification must accept ERC-1271, not just ECDSA.** A passkey ERC-4337 account
signs with P-256, which `ecrecover` cannot recover. Every signature path here
routes through `SignatureChecker`. This is also why `Eip2612` is not
OpenZeppelin's `ERC20Permit` — that implementation is ECDSA-only, so a smart
account could never approve by signature, which matters most precisely for the
accounts that hold no gas.

**A Permit2 allowance does not bypass compliance.** Permit2 moves funds through
this token's `transferFrom`, so pause and blacklist still apply to every
Permit2-initiated transfer; and holding an allowance is not spending it, since
Permit2 still requires a valid signature per transfer.

## Consequences

- Two payment presets to maintain and test rather than one.
- A wallet integrating a token from this kit must read which modules it has —
  from the verified source, or by probing the module selectors it cares about.
- The gas difference between the two paths is asserted here as directional only.
  It has not been measured, and should be before an issuer picks on that basis.
