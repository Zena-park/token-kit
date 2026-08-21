# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `Eip3009`: the `(v, r, s)` functions EIP-3009 defines --
  `transferWithAuthorization`, `receiveWithAuthorization`,
  `cancelAuthorization` -- alongside the existing `bytes` forms, which are the
  ERC-1271 extension. Both are declared in the new `IEip3009` interface, the
  file integrators compile against. Integrations written against the EIP's
  selectors now dispatch instead of reverting.
- `TokenBase._packSignature`: the one place a `(v, r, s)` triple is laid out
  as the 65-byte signature the verifier takes; `Eip2612` uses it too.

- `test/script/Deploy.t.sol`: the deploy script now has a test suite --
  address prediction for immutable tokens and proxies, issuer == broadcaster,
  implementation reuse keyed by preset and decimals, the finished proxy's
  `initializeToken` being closed, and the checks on an explicit
  implementation.

### Changed

- `MinterControl`: an address is a Controller or a Minter, never both, in any
  pairing -- the indirect form of self-management (A manages B, B manages A)
  is refused with `AddressAlreadyPaired`, at scheduling and at execution.
  `removeController` leaving pending appointments in place is now documented
  (ADR-003), with the operating procedure.
- `UpgradeControl.upgradeToAndCall` refuses ether with `ValueNotAccepted`; the
  proxy has no way to return it.
- `Eip2612` header documents the standard permit front-run property and the
  try/catch an integrator should use.
- Tests: ERC-1271 rejections (disowning account, non-ERC-1271 code), a zero
  `permit` owner, EIP-3009 window endpoints, `permit` under a pause, seizure
  against a shrunk balance, cancelling a lapsed seizure, Minter
  re-activation, the revived-appointment case, the bare implementation
  refusing an upgrade; symbolic properties for the allowance-raise boundary
  under a pause and a listing. The ERC-1271 test mock answers a bad signature
  with the failure value instead of reverting, as a real account does.
- CI: actions pinned to commit SHAs and forge to an exact release;
  `foundry.lock` records all three libraries; Dependabot no longer tracks
  submodules (see CONTRIBUTING.md).
- `Deploy.s.sol`: an explicit `existingImplementation` that is empty, not
  UUPS, or not a kit token now fails as `NotAnImplementation` instead of a
  bare revert from whichever probe it did not answer. `docs/deploying.md` and
  the script header now describe the issuer as read off the broadcast, which
  is what the script has done since `vm.readCallers` was adopted.
- Runtime sizes grew by 0.7 KB on the presets that include `Eip3009`; the
  README tables and `docs/gas.md` carry the new numbers.

## [0.1.0] - 2026-08-19

Initial release.

### Added

- `TokenBase`: ERC-20 core with ERC-7201 namespaced storage, a single EIP-712
  domain, ERC-1271-capable signature verification, an issuer-gated one-shot
  admin handover, and a floor under the last admin.
- Payment modules: EIP-2612 `permit` (both `(v,r,s)` and `bytes` forms) and
  EIP-3009 transfer/receive/cancel with USDC-identical type hashes.
- Issuance modules: `MinterControl` (Owner/Controller/Minter split, drawdown
  mint budget, timelocked appointments, Guardian veto, mint freeze) and
  `SimpleMinter`.
- Compliance modules: `Blacklist`, `EmergencyPause`, and `Seize`
  (scheduled, delayed, Guardian-vetoable).
- `UpgradeControl`: UUPS upgrades behind a 1-day delay, 7-day execution
  window, and Guardian veto.
- Presets: `MinimalToken`, `PermitToken`, `Eip3009Token`, `FullToken`, and
  upgradeable implementations of the latter three.
- Deterministic CREATE2 deploy script with deployer-scoped salts.
- The Foundry test suite, Halmos symbolic properties, Slither and solhint
  configurations, and a security review record
  ([docs/security-review.md](docs/security-review.md)).
- Documentation: five ADRs, a deployment runbook, and measured gas costs.

[0.1.0]: https://github.com/Zena-park/token-kit/releases/tag/v0.1.0
