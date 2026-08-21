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

### Changed

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
