# Contributing

Thanks for looking into this. A few things keep contributions easy to review
and safe to merge.

## Before you start

- For anything security-sensitive, follow [SECURITY.md](SECURITY.md) instead
  of opening an issue or PR.
- For a feature or behavior change, open an issue first. The design decisions
  in `docs/adr/` are load-bearing — a PR that contradicts one needs the ADR
  conversation before the code.

## Working on the code

```bash
git clone --recurse-submodules https://github.com/Zena-park/token-kit
cd token-kit
npm ci          # solhint
npm run check   # the local gates; CI runs exactly this, plus Slither and Halmos
```

Ground rules the codebase holds itself to:

- Every balance change goes through `_update`; every allowance write goes
  through `_approve`/`_spendAllowance`. New code must not open a path around
  those funnels.
- Module state lives in an ERC-7201 namespace, pinned by
  `test/StorageSlots.t.sol`. Never change a namespace label; add fields only
  at the end of a namespace struct.
- EIP-712 type strings are normative and byte-identical to USDC's. Do not
  touch them.
- New behavior comes with tests, and anything invariant-shaped belongs in
  `test/symbolic/` too.
- Comments explain *why*, not *what*. Match the density and tone of the file
  you are editing.

## Updating dependencies

- The two OpenZeppelin submodules are pinned to one and the same release tag
  (`contracts/foundry.lock` records which, and CI checks the checkout against
  it). Move them together, to a tag, and re-run `npm run check` —
  `test/StorageSlots.t.sol` and `test/presets/Upgradeable.t.sol` are what
  catch a layout change upstream. Dependabot deliberately does not track
  submodules; it follows branch heads.
- `package.json` carries `@openzeppelin/contracts` and
  `@openzeppelin/contracts-upgradeable` pinned to that same release as an
  advisory canary: GitHub's alerts and Dependabot's release bumps fire for
  them, and a bump is the signal to move the submodules -- all three in one
  PR. Nothing compiles against the npm copies: `contracts/foundry.toml` maps
  `@openzeppelin/` to the submodules explicitly, and `node_modules` lives
  outside the Foundry root.
- `forge-std` is test-only and is moved on its own (`forge update
  lib/forge-std` rewrites its `foundry.lock` entry).
- GitHub Actions are pinned to commit SHAs; Dependabot keeps those current.
  The forge release in `ci.yml` is bumped by hand, together with the local
  toolchain. `solc` and `evm_version` are pinned in `foundry.toml`; changing
  either changes every CREATE2 address (see the deploying guide).

## Pull requests

- Keep commits logical and messages in the imperative
  (`feat: ...`, `fix: ...`, `docs: ...`, `test: ...`, `build: ...`).
- CI must be green — `.github/workflows/ci.yml` is the list of what runs on
  every PR.
- Update `CHANGELOG.md` under an `Unreleased` heading when the change is
  user-visible.
