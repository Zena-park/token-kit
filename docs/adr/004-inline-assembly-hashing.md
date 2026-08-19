# Keep EIP-712 struct hashing in Solidity

## Context

`forge lint` raises `asm-keccak256` on every EIP-712 struct hash in this
repository, suggesting inline assembly instead:

```solidity
keccak256(
    abi.encode(TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)
)
```

`abi.encode` allocates and copies into memory before hashing. Writing the words
directly with `mstore` avoids the copy.

## Decision

Keep the Solidity form, and disable the lint globally in `foundry.toml` with the
reasoning recorded rather than silenced.

An EIP-712 struct hash is the single most error-prone construct here. The field
order and count must match the type string exactly; if they do not, nothing
reverts and nothing is caught by a type checker — the signature simply fails to
recover, or worse, recovers a different message than the signer believed they
were approving. In the Solidity form the fields are listed in order next to the
type hash, so the code can be diffed against the type string by eye. In the
assembly form they become offsets, and the property most needing review becomes
the property hardest to review.

## On the gas figure

The saving is on the order of 131 gas per hash against a payment costing
roughly 95,800 — about 0.1%. The figure is indicative rather than measured in
this repository; an issuer for whom per-payment gas genuinely dominates should
re-measure rather than inherit it. If it proved to be an order of magnitude
larger, this decision would deserve revisiting; at 0.1% it does not.

## Consequences

- The lint is disabled repository-wide rather than per line, so a new module
  written in the same style does not have to re-argue it.
- If a future module hashes in a hot loop rather than once per authorization,
  the trade changes and this ADR should be reopened with a real measurement
  attached.
