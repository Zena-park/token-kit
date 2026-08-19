# Gas costs

Measured numbers for what deploying and running these tokens costs, so the
choice between presets -- and between EIP-3009 and Permit2 as a payment path --
can rest on figures rather than folklore.

## How these numbers were produced

Everything below comes from the unit and composition suites:

```bash
cd contracts
forge test --gas-report
```

solc 0.8.24, optimizer on at 200 runs, OpenZeppelin v5.1.0 -- the settings in
`foundry.toml`. Expect drift when any of those change; the table is a
snapshot, not a promise. Re-run the command above after touching a module and
compare.

Two caveats when reading gas tables:

- **Cold versus warm storage dominates the spread.** A transfer that touches
  two balances for the first time in a transaction pays ~2,100 gas per cold
  slot more than one that touches warm slots. The Min/Max spread in a
  `--gas-report` row is mostly this, not code paths.
- **A first transfer to an empty account pays for the new slot.** Writing a
  zero balance to non-zero costs 20,000 gas once; topping up an existing
  balance costs 2,900. The "typical" column below assumes existing accounts.

## Deployment

| Contract | Gas | Size (bytes) |
|---|---:|---:|
| MinimalToken | 1,621,978 | 8,324 |
| PermitToken | 3,088,228 | 15,103 |
| Eip3009Token | 3,371,478 | 16,413 |
| FullToken | 3,699,496 | 17,929 |
| UpgradeableEip3009Token (implementation) | 3,864,432 | 17,885 |
| UpgradeableFullToken (implementation) | 4,202,121 | 19,446 |
| ERC1967 proxy | 263,611 | 1,306 |

An upgradeable deployment is the implementation once plus one proxy per token;
a second token of the same preset and decimals reuses the implementation and
pays only the proxy. Every preset is comfortably under the 24,576-byte code
size limit.

One-time setup on top: `initializeAdmin` ~52,000, each `grantRole` ~51,800.

## Moving tokens

Numbers from `Eip3009Token` / `FullToken`; the other presets differ by which
compliance checks sit in `_update` (each blacklist or pause check is one warm
SLOAD, tens of gas, once the slot is warm -- the module composition is not
where the money goes).

| Operation | Typical | Cold-state worst seen |
|---|---:|---:|
| `transfer` | ~29,000 | ~58,500 |
| `transferFrom` (allowance already set) | ~25,000 | -- |
| `approve` | ~31,000 | ~54,300 |
| `transferWithAuthorization` | ~65,000 | ~103,700 |
| `receiveWithAuthorization` | ~41,000 | ~99,200 |
| `permit` (v,r,s) | ~58,000 | ~91,400 |
| `permit` (bytes) | -- | ~96,400 |
| `cancelAuthorization` | ~61,500 | -- |

What the signature paths buy and cost: an EIP-3009 transfer is a plain
transfer plus signature recovery (~3,000), the EIP-712 digest, and one cold
nonce slot write (~22,100 for a fresh random nonce) -- roughly 35,000-45,000
gas over `transfer`, paid by the submitter rather than the holder. `permit`
plus the `transferFrom` it enables costs more in total than one
`transferWithAuthorization`; routing through Permit2 adds a further external
call and Permit2's own allowance accounting on top. That ordering -- EIP-3009
cheapest per payment, Permit2 most expensive -- is the gas half of
[ADR-001](adr/001-eip3009-vs-permit2.md); the other half is who has to deploy
and maintain what.

ERC-1271 signers pay for their wallet's `isValidSignature` on top of every
signature-carrying row (the `permit` (bytes) row above includes a simple
ERC-1271 wallet).

## Issuance and administration

| Operation | Gas |
|---|---:|
| `mint` (existing recipient) | ~74,000-83,000 |
| `burn` | ~27,000-33,000 |
| `configureMinter` | ~70,300 |
| `incrementMinterAllowance` | ~26,000-33,000 |
| `scheduleController` | ~53,700 |
| `executeController` | ~69,200 |
| `blacklist` | ~47,700 |
| `unBlacklist` | ~25,700 |
| `pause` | ~47,200 |
| `unpause` | ~24,000-25,200 |
| `scheduleSeize` | ~54,700 |
| `executeSeize` | ~31,000-74,000 |
| `scheduleUpgrade` | ~55,000-59,300 |
| `upgradeToAndCall` | ~39,000-95,200 |
| `cancelUpgrade` / `cancelSeize` / `cancelController` | ~26,000-31,000 |

These are operator costs, paid rarely; nothing here is on the per-payment
path.

## The proxy overhead

The same operation behind the ERC-1967 proxy costs ~4,900 gas more per
transaction: the cold read of the implementation slot (~2,100), the
delegatecall, and calldata copying. Observed directly: `configureMinter`
70,294 direct vs 75,178 through the proxy; `transfer` 28,931 vs 33,803.
Subsequent calls in the same transaction would pay only the warm ~100. This
is the per-call price of upgradeability, on top of the governance costs in
[ADR-005](adr/005-upgradeability.md).

## On L2s

On rollups the dominant cost of a signature-carrying call is often data, not
execution: `transferWithAuthorization` carries a 65-byte signature plus five
words of arguments as calldata that must be posted to the data-availability
layer. Execution gas as tabled above still applies, but ranking payment
methods on an L2 means measuring calldata bytes too -- which favors EIP-3009's
single direct call over a Permit2 route that carries both a permit and a
transfer in one envelope.
