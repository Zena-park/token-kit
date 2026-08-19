# Security policy

## Status

**This code has not been externally audited.** It carries its own review
record — [docs/security-review.md](docs/security-review.md) covers a full
manual pass, the Foundry test suite, the Halmos symbolic properties, and a
clean Slither run — but a self-review is not an audit. Do not put real value
behind these contracts without an independent audit of the exact commit you
deploy.

## What goes where

Almost everything belongs in the open:

| Kind | Channel |
|---|---|
| Feature requests, questions, design discussion | Public issue |
| Ordinary bugs — wrong docs, flaky test, gas regression | Public issue |
| Code contributions | Public PR — see [CONTRIBUTING.md](CONTRIBUTING.md) |
| **Exploitable vulnerabilities** | **Private report first** — see below |

The one private-first category exists because tokens deployed from this code
cannot be hot-fixed: the immutable presets can never be patched, and even the
upgradeable ones enforce a 1-day upgrade delay. A vulnerability posted
publicly before a fix exists is an exploit recipe against every deployment
for at least that long.

## Reporting a vulnerability

Report privately through
[GitHub Security Advisories](https://github.com/Zena-park/token-kit/security/advisories/new)
— the "Report a vulnerability" button on this repository's Security tab. That flow
supports collaboration: you can be invited to a private fork to work on the
fix together, and the advisory — with your credit — is published once the fix
is out. Private-first means the publication is delayed, not that it never
happens.

What to include, as far as you can:

- the affected contract and function,
- the conditions under which the issue is reachable (roles held, state
  required),
- a proof of concept — a failing Foundry test is ideal.

You should receive an acknowledgement within a few days.

## Scope

In scope: everything under `contracts/src/`.

Out of scope: the vendored dependencies under `contracts/lib/` (report those
upstream to OpenZeppelin or foundry-rs), the deploy script, tests, and
documentation typos — those are all fine as public issues.

## Supported versions

Only the latest release is supported. There are no deployed instances
maintained by this repository; issuers deploy and operate their own tokens.
