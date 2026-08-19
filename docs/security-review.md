# token-kit Security Review

- **Scope**: entire `contracts/` working tree (new repository, pre-first-commit) · Solidity 0.8.24 · ~2,834 lines of source
- **Verdict**: **no critical or high-severity vulnerabilities found**

A full manual review of every module in this modular stablecoin token kit found no
security defect requiring a fix. The known stablecoin attack patterns are
systematically closed off at the design level, and every residual risk is a
design trade-off explicitly documented in the code and docs.

| Metric | Result |
|---|---|
| Foundry tests | 103 / 103 passing (7 suites) |
| Halmos symbolic properties | 19 / 19 verified |
| Slither (75 detectors) | 0 findings |
| Secret / key exposure | none |
| Source files reviewed | 18 |

## Findings by attack vector

### Initialization and privilege takeover — safe

- Immutable presets initialize in the constructor under `initializer`, so they can
  never be re-initialized. Upgradeable implementations are locked with
  `_disableInitializers()` (`UpgradeableFullToken.sol:57`).
- `initializeAdmin` is callable only by the issuer baked into the CREATE2 init
  code (`TokenBase.sol:233-239`) — closing both the mempool front-run and the
  cross-chain replay path to admin takeover.
- The Deploy script runs `initializeToken` atomically as the proxy's constructor
  data. The risk of deploying a proxy with empty data is explicitly warned about
  in `docs/deploying.md`.
- Removal or renouncement of the last admin is blocked (the `LastAdmin` floor in
  `_revokeRole`), verified by tests.

### Signature modules — EIP-2612 / EIP-3009 — safe

- Single EIP-712 domain; replay protection (random nonce burning plus a
  sequential counter) and validity-window checks match USDC's semantics exactly.
  Cross-chain replay is blocked by the chainId in the domain.
- The `to == msg.sender` check in `receiveWithAuthorization` solves the contract
  payee front-running problem.
- `cancelAuthorization` remains callable while paused — the path to revoke a
  leaked signature stays open.
- Smart-account signatures via ERC-1271 are supported, and a failed signature
  does not consume a nonce.

### Compliance — Blacklist / Pause / Seize — safe

- Every balance change passes through the single `_update` funnel — signature
  transfers and Permit2-routed transfers cannot bypass it.
- The allowance boundary (`_isAllowanceRaise`) blocks only *raises* and always
  permits revocation, applied consistently across both modules.
- Seize's blacklist bypass opens only for the sender side of the account being
  seized, only for the duration of the call. OZ ERC-20 has no receive hooks, so
  there is no reentrancy path into that window.
- Preconditions are re-checked at execution — an account whose listing has been
  lifted cannot be seized.

### Issuance control — MinterControl — safe

- The Controller/Minter separation invariants (no self-management, 1:1 mapping)
  are checked at both scheduling and execution — a single leaked key cannot mint
  beyond the remaining budget.
- `burn` does not refund the mint budget, blocking the mint-burn-mint loop.
- The Guardian freeze is immediate while unfreezing is admin-only — the correct
  asymmetry, so a leaked hot key cannot lift the freeze.

### Upgrades — UUPS + timelock — safe

- The upgrade id commits to both the implementation address and `data` — exactly
  what was announced executes, exactly once.
- One-day delay + seven-day execution window + Guardian veto. The ERC-1822 check
  prevents bricking the proxy with a non-upgradeable implementation.
- Execution authority is limited by the `DEFAULT_ADMIN_ROLE` check in
  `_authorizeUpgrade`.

### Deploy script — safe

- The issuer is derived from the broadcast key, and the salt carries the
  deployer's 20-byte prefix — blocking cross-chain address squatting.
- Reusing an existing implementation is validated up front via `proxiableUUID()`
  and `decimals()`.
- The ERC-7201 storage slot constants are pinned to their labels by
  `test/StorageSlots.t.sol` using OZ `SlotDerivation` — preventing storage
  relocation accidents across upgrades.

## Residual risks — accepted by design, documented

1. **A leaked RESCUER key can direct a seizure to an arbitrary address.** Only
   blacklisted accounts can be targeted, but seized funds could reach an attacker.
   The only defenses are the delay and the Guardian veto, both of which assume
   someone is watching the `SeizeScheduled` event (stated in `Seize.sol:46-57`).
   An event alerting pipeline is genuinely required in operation.
2. **Losing the issuer key before handover leaves a token with no admin,
   permanently.** The exposure window is one transaction (`initializeAdmin`
   immediately after deployment), so this is acceptable — but the deployment
   procedure must be followed.
3. **The admin of an upgradeable preset can eventually change any rule the token
   enforces.** A documented, inherent trade-off. A multisig plus a standing
   Guardian is the assumed operating model.

## Minor observations (no security impact)

- The repository shipped a `halmos.toml` (targeting `.*Symbolic.*` contracts)
  but no symbolic tests existed to match. A suite of 19 properties was added
  during this review in `test/symbolic/TokenSymbolic.t.sol`; all verify. The
  AGPL-3.0 `halmos-cheatcodes` submodule was later found to be unused (halmos
  derives symbolic inputs from test parameters directly) and was removed in the
  license review, leaving the repository uniformly Apache-2.0. Signature-based paths
  (EIP-2612 / EIP-3009) are deliberately excluded — ecrecover is beyond
  practical symbolic scope and the unit tests cover them concretely.
- The implementation contract's salt (`keccak256(abi.encode(issuer, decimals))`)
  does not follow the documented "leading 20 bytes = deployer" convention, but
  since a CREATE2 address commits to the init code, front-running it merely
  places the identical code — harmless.
- The script is hard-wired to forge-std's `CREATE2_FACTORY` (Arachnid) while the
  docs also mention CreateX and others — supporting deployment through CreateX
  would take separate work. For now this is a documentation nuance only.
- Two informational observations from a follow-up pass were fixed rather than
  recorded: repo-local code mixed bare `msg.sender` with the `_msgSender()` the
  inherited OpenZeppelin code uses (normalized to `_msgSender()` throughout
  `src/` — no behavioral change, no forwarder exists), and `scheduleSeize`
  accepted a zero amount (now refused with `ZeroAmount`, checked at the
  scheduling gate only since the seize id commits to the amount; covered by
  `test_a_zero_amount_seizure_cannot_be_scheduled`). All 103 tests, Halmos
  19/19, and Slither 0-findings re-verified after the change; hot-path gas is
  unchanged and the guardian-modifier paths got marginally cheaper.

## Methodology

| Step | Detail |
|---|---|
| Full manual review | 1 core, 9 modules, 7 presets, and the Deploy script — all 18 source files read in full |
| Dynamic verification | `forge test` — all 103 tests across 7 suites passing (including ERC-7201 slot pinning) |
| Symbolic verification | Halmos over `test/symbolic/TokenSymbolic.t.sol` — 19 properties verified: supply preservation, exact balance/allowance accounting, mint role and budget bounds, blacklist send/receive blocking, pause totality, mint freeze, seize preconditions, and the Controller/Minter structure (authority split, 1:1 mapping, timelock + veto, revocation leaves nothing mintable) |
| Static analysis | Slither, 75 detectors — 0 findings |
| Secret scan | private key / mnemonic pattern scan — no exposure |
| Docs cross-check | `docs/deploying.md` and 5 ADRs — code matches the documented threat model |

---

Review performed by Claude Code (Fable 5)
