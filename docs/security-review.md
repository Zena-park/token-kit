# token-kit Security Review

- **Revision reviewed**: [v0.1.1](https://github.com/Zena-park/token-kit/releases/tag/v0.1.1) (2026-08-22) · Solidity 0.8.24 · OpenZeppelin v5.6.1 · ~4,700 lines across `src/` and `script/`
- **Verdict**: **no critical, high or medium finding.** The three low findings of the
  2026-08-21 review and the four low findings of the 2026-08-22 re-review are
  closed in this revision; what remains is the set of design trade-offs listed
  under *Residual risks*.
- **Status**: internal review. **Not audited by a third party.** See
  [SECURITY.md](../SECURITY.md) for what an audit would need to cover and how
  to report a vulnerability.

| Metric at v0.1.1 | Result |
|---|---|
| Foundry tests | 140 / 140 passing (8 suites, including the deploy script) |
| Halmos symbolic properties | 21 / 21 verified |
| Slither (75 detectors) | 0 findings |
| Secret / key exposure | none |
| Source files reviewed | 20 — 1 core, 2 interfaces, 9 modules, 7 presets, 1 script |

## What the review covered

Every file under `contracts/src` and `contracts/script`, read in full; every test
file, read for what it does and does not pin; the README's library-usage
example, compiled and run; CI, Dependabot and submodule configuration. The
review was done twice: once against the tree before any fix, and once against
the tree after the fixes, with three independent adversarial passes over the
diff (signature/ABI surface, access control and state machines, deployment and
supply chain). Neither pass found a regression in the other's fixes.

## Findings by attack vector

### Initialization and privilege takeover

- Immutable presets initialize in the constructor under `initializer` and can
  never be re-initialized. Upgradeable implementations are locked with
  `_disableInitializers()` and name no issuer, so `initializeAdmin` is
  unreachable on them.
- `initializeAdmin` is callable only by the issuer baked into the CREATE2 init
  code (`TokenBase.initializeAdmin`). That closes both the mempool front-run and
  the cross-chain replay of the same init code and salt.
- The deploy script runs `initializeToken` as the proxy's constructor data;
  OpenZeppelin's `ERC1967Proxy` (v5.6) additionally refuses construction with
  empty data, so a proxy cannot exist uninitialized. `test/script/Deploy.t.sol`
  pins that a finished proxy's `initializeToken` is closed.
- The last holder of `DEFAULT_ADMIN_ROLE` can neither renounce nor be revoked
  (`LastAdmin` floor in `_revokeRole`); verified by unit and symbolic tests.

### Signature modules — EIP-2612 / EIP-3009

- One EIP-712 domain per token; the domain name reads the same slot as `name()`.
  Cross-chain replay is blocked by the chain id in the domain.
- EIP-3009 exposes the functions the EIP defines, in the `(v, r, s)` form, and a
  `bytes signature` form for ERC-1271 accounts. Both forms spend the same nonce
  map, so an authorization is spendable once whichever entry point submits it.
  The surface is declared in `IEip3009`; `IEip2612` does the same for `permit`.
  Tests pin the interface declarations to the EIP signatures.
- The validity window is open on both ends (`validAfter < now < validBefore`),
  as in the EIP; the endpoints are tested.
- `receiveWithAuthorization` requires `to == msg.sender` in both forms, so a
  payee contract's settlement cannot be bypassed by a third-party submitter.
- `cancelAuthorization` stays callable while paused, so a leaked signature can be
  revoked during an incident.
- Signature verification goes through `SignatureChecker`: ECDSA for EOAs
  (malleable and zero-address results rejected), a `staticcall` to
  `isValidSignature` for contracts (no reentrancy). A failed verification leaves
  the nonce unspent. A disowning ERC-1271 answer and a revert from code without
  ERC-1271 are both tested as invalid.
- Check-effects-interactions holds: window → nonce → signature → mark spent →
  emit → `_transfer`. There is no external call before the nonce is marked other
  than the `staticcall` above.

### Compliance — Blacklist / Pause / Seize

- Every balance change passes through `_update`; signature transfers and
  Permit2-routed `transferFrom` calls cannot route around it.
- The allowance boundary (`_isAllowanceRaise`) blocks only raises and always
  permits revocation, under a pause and under a listing alike. Symbolic
  properties cover both gates; `permit` is tested to cross the same gate.
- A listed spender is stopped in `_spendAllowance`, which an infinite allowance
  cannot bypass.
- Seize's blacklist bypass opens for the sender side of the account being
  seized, for the duration of `executeSeize` only; there is no hook in the
  transfer path that could run inside that window. Preconditions are re-checked
  at execution, so an account whose listing was lifted cannot be seized; a
  seizure larger than the balance fails and keeps its schedule; a lapsed
  schedule can still be cancelled.

### Issuance control — MinterControl

- An address is a Controller or a Minter, never both, in any pairing: a key
  cannot be appointed over itself, over the account that manages it, or into a
  chain. The checks run at scheduling and again at execution. A Minter with its
  own appointment pending as a Controller is refused too (`PendingAppointment`),
  so a cycle cannot be announced in two calls and left to whoever executes
  first; an appointment pending *over* a Minter is the one shape scheduling
  cannot see, and it fails at execution.
- A single leaked Minter key is bounded by its remaining drawdown budget; `burn`
  does not refund it. A leaked Controller key can raise a budget but cannot
  mint. Symbolic properties cover budget bounds, the authority split and that
  revocation leaves nothing mintable.
- The Guardian freeze is immediate and unfreezing is admin-only, so a leaked hot
  key cannot lift a freeze.

### Upgrades — UUPS + timelock

- The upgrade id commits to both the implementation and `data`, so exactly what
  was announced executes, exactly once. One-day delay, seven-day window,
  Guardian veto; a lapsed schedule must be re-announced.
- `upgradeToAndCall` refuses ether (`ValueNotAccepted`): the proxy has no way to
  return it. The bare implementation cannot be upgraded in place — its schedule
  is empty and it has no admin to fill it.
- The ERC-1822 check rejects a candidate that does not answer as a UUPS
  implementation. It is an accident guard: a candidate that answers correctly
  but has no working upgrade path would still brick the proxy, which is what
  the delay and the veto exist for.
- Storage is ERC-7201-namespaced per module and pinned to its label by
  `test/StorageSlots.t.sol`. The OpenZeppelin contracts inherited here did not
  change a namespace or struct layout between v5.1.0 and v5.6.1; `test/presets/Upgradeable.t.sol`
  checks that identity, balances and roles survive an upgrade.

### Deploy script

- The issuer is read off the broadcast (`vm.readCallers`), so whichever key
  signs the deployment is the key that can hand the token over; the salt
  carries the deployer's 20-byte prefix against cross-chain address squatting.
  Both are pinned by `test/script/Deploy.t.sol`, along with address prediction
  from `(deployer, salt, init code)` and implementation reuse keyed by preset
  and decimals.
- An explicit implementation to reuse is probed before anything is broadcast —
  `proxiableUUID()` and `decimals()`, each behind a `try` — and every wrong
  address fails as `NotAnImplementation`. The check is script-side and cannot
  see which preset the code was built from; that part is the operator's
  assertion.
- CREATE2 addresses are a function of the compiled preset, so they are bound to
  a repository revision (`solc` and `evm_version` are pinned). Addresses
  predicted from v0.1.0 do not match v0.1.1. `docs/deploying.md` says to deploy
  every chain from one recorded tag.

### Supply chain

- GitHub Actions are pinned to commit SHAs; forge to a release; `solc` and
  `evm_version` in `foundry.toml`. `npm run lock:check` enforces that the
  submodule checkout matches `foundry.lock`.
- The two OpenZeppelin submodules sit on one release tag (v5.6.1). Dependabot
  does not track submodules — it follows branch heads — but the same two
  packages are pinned in `package.json` as an advisory canary, so security
  alerts fire; release bumps are ignored. No published OpenZeppelin advisory
  affected v5.1.0 or affects v5.6.1 for the components used here.

## Residual risks — accepted by design, documented

1. **A leaked RESCUER key can direct a seizure to an arbitrary address.** Only
   blacklisted accounts can be targeted, but seized funds could reach an
   attacker. The defenses are the delay and the Guardian veto, both of which
   assume someone watches `SeizeScheduled`. An alerting pipeline is part of
   operating this token.
2. **Losing the issuer key before handover leaves a token with no admin.** The
   window is one transaction — `initializeAdmin` in the same broadcast as the
   deployment — so the procedure in `docs/deploying.md` must be followed.
3. **The admin of an upgradeable preset can eventually change any rule the
   token enforces.** Inherent to upgradeability. A multisig plus a standing
   Guardian is the assumed operating model.
4. **Removing a Controller does not cancel appointments pending over the Minter
   it frees.** One inside its window becomes executable again. It was announced
   by the admin, is re-checked at execution, and the Guardian can cancel it;
   clearing it would need a by-Minter set. Procedure: scan `ControllerScheduled`
   for that Minter before freeing it (ADR-003, `docs/deploying.md`).
5. **A `permit` can be front-run with the same signature.** Standard EIP-2612
   behaviour: the allowance lands as signed and the original call reverts.
   Integrators wrap `permit` in try/catch (noted in the module header).
6. **Two keys in one custody.** The contract makes one *address* holding both
   ends of a pairing impossible; it cannot see whether two addresses are held
   by one organisation. That separation is an operational requirement
   (ADR-003).

## Known limitations (no security impact)

- The implementation's CREATE2 salt (`keccak256(abi.encode(issuer, decimals))`)
  does not use the leading-20-bytes convention. A front-runner can only place
  the identical code at that address, which the script then reuses.
- The script deploys through forge-std's `CREATE2_FACTORY` (Arachnid); CreateX
  and the Safe singleton factory are documented but not wired in.
- Halmos excludes the signature paths: ecrecover is beyond practical symbolic
  scope and the unit tests cover them concretely.

## Review history

| Date | Revision | Outcome |
|---|---|---|
| 2026-08-19 | pre-v0.1.0 | Initial review of the working tree. No critical/high finding. Halmos suite (19 properties) added; the unused AGPL `halmos-cheatcodes` submodule removed; `_msgSender()` normalised; zero-amount seizure refused. |
| 2026-08-21 | `4f4b5c8` | Full audit of source, tests, example and CI. Low 3 — EIP-3009 lacked the EIP's `(v, r, s)` entry points; the deploy script had no tests; CI actions and forge unpinned, lock incomplete. Info 8. Closed in PRs #12–#15. |
| 2026-08-22 | `a0bcad0` | Re-audit of the fixes: no regression. Low 4 — a two-call Controller/Minter cycle could be announced; addresses had moved from v0.1.0 without notice; `evm_version` unpinned; no OpenZeppelin advisory watcher after submodule tracking was dropped. Info 4. Closed in PRs #16, #19, #20. |
| 2026-08-22 | v0.1.1 | OpenZeppelin v5.1.0 → v5.6.1 (#21): no storage, namespace or relevant behavioural change; imports of `Initializable`/`UUPSUpgradeable` repointed to `@openzeppelin/contracts`. Release cut (#22). This document rewritten against the release. |

## Methodology

| Step | Detail |
|---|---|
| Manual review | All 20 source files read in full, twice (before and after fixes); the second pass with three independent adversarial lenses over the diff |
| Dynamic verification | `forge test` — 140 tests across 8 suites (module, composition, upgrade, storage-slot pinning, deploy script) |
| Symbolic verification | Halmos over `test/symbolic/TokenSymbolic.t.sol` — 21 properties: supply preservation, exact balance/allowance accounting, mint role and budget bounds, blacklist send/receive blocking, pause totality, the allowance-raise boundary under a pause and a listing, mint freeze, seize preconditions, and the Controller/Minter structure |
| Static analysis | Slither, 75 detectors — 0 findings |
| Dependency review | OpenZeppelin 5.2–5.6.1 changelogs and the upgradeable storage diff read for the components used; advisory database checked |
| Secret scan | private key / mnemonic patterns over tracked files — none |
| Docs cross-check | `docs/deploying.md`, the five ADRs and the README example against the code |

---

Review performed by Claude Code (Fable 5). Internal review, not an audit.
