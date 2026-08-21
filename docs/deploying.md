# Deploying

Two paths: an immutable token, or an upgradeable one behind a proxy. Both land on
a deterministic address, and neither needs a contract from this repository to be
deployed first.

## Where the address comes from

Forge routes `new C{salt: s}(...)` inside a broadcast through the canonical
CREATE2 deployer. The address is a function of that deployer, the salt and the
init code, so the same three inputs give the same address on every chain the
deployer exists on.

Widely deployed options, in the order most people reach for them:

| Deployer | Address | Note |
|---|---|---|
| Arachnid deterministic deployment proxy | `0x4e59b44847b379578588920cA78FbF26c0B4956C` | Forge's default |
| Safe singleton factory | `0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7` | For chains that reject the pre-EIP-155 transaction the above was deployed with |
| CreateX | `0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed` | Also offers CREATE3 and enforces the salt convention below on chain |

Confirm the one you intend to use is actually deployed on your target chain
before relying on an address matching across chains.

## Salt convention

The deployer does not mix the caller into the salt, so a bare salt is
first-come-first-served: someone who sees a mainnet deployment can take the same
address on an L2 and name themselves admin. Put the deployer in the leading 20
bytes:

```
salt = bytes32(bytes20(deployer)) | bytes32(uint256(entropy))
```

`Deploy.saltFor(deployer, entropy)` builds it. CreateX enforces this on chain —
it rejects a sender that does not match the leading bytes. The plainer deployers
do not enforce it, but the salt remains scoped to the deployer.

## Picking the entry point

One function per preset, all with the same shape:

| Preset | Function |
|---|---|
| `MinimalToken` | `deployMinimalToken(string,string,uint8,address,uint96)` |
| `PermitToken` | `deployPermitToken(string,string,uint8,address,uint96)` |
| `Eip3009Token` | `deployEip3009Token(string,string,uint8,address,uint96)` |
| `FullToken` | `deployFullToken(string,string,uint8,address,uint96)` |
| `UpgradeablePermitToken` | `deployUpgradeablePermitToken(string,string,uint8,address,uint96,address)` |
| `UpgradeableEip3009Token` | `deployUpgradeableEip3009Token(string,string,uint8,address,uint96,address)` |
| `UpgradeableFullToken` | `deployUpgradeableFullToken(string,string,uint8,address,uint96,address)` |

The examples below use the `Eip3009Token` pair; substitute the function for the
preset you chose.

## Immutable

```bash
forge script script/Deploy.s.sol:Deploy \
  --sig 'deployEip3009Token(string,string,uint8,address,uint96)' \
  'Acme Won' 'AKRW' 6 0xAdmin... 1 \
  --rpc-url $RPC --sender $DEPLOYER --broadcast
```

Deployment and `initializeAdmin` go out in one broadcast. They are still two
transactions, but only the **issuer** can make the second one, and the issuer is
the broadcasting key — it goes into the init code, and therefore into the
address. Nobody else can slip in between, on this chain or on one you have not
reached yet.

The issuer is read off the broadcast itself, not off the script's
`msg.sender`, so whichever key signs the deployment transactions is the key
that can hand the token over — there is no way to broadcast from one key and
record another as issuer. The consequence is that the broadcasting key must be
the one you intend to keep until `initializeAdmin` has landed; the script sends
that call in the same broadcast, prints `issuer` alongside `admin set`, and
`verifyAdmin` re-checks the grant at any time.

**Pass `--sender` as the broadcasting key** so that simulation and broadcast
run as the same account and the predicted address printed during simulation is
the one the deployment lands on.

The result has no proxy, no upgrade path and no admin upgrade key. Bugs are
permanent.

## Upgradeable

```bash
forge script script/Deploy.s.sol:Deploy \
  --sig 'deployUpgradeableEip3009Token(string,string,uint8,address,uint96,address)' \
  'Acme Won' 'AKRW' 6 0xAdmin... 1 0x0000000000000000000000000000000000000000 \
  --rpc-url $RPC --sender $DEPLOYER --broadcast
```

The last argument is an existing implementation to reuse, or the zero address to
let the script handle it. Several tokens can share an implementation — each
still gets its own proxy, storage and admin — but only if they agree on
decimals, which lives in the implementation's code rather than in the proxy.

With the zero address, reuse is automatic: the implementation's address is
deterministic in the deployer, the preset and the decimals, so the script
computes it and deploys only if nothing is there yet. Pass an explicit address
only for an implementation deployed outside this script; it is then checked
before anything is broadcast — the address must answer `proxiableUUID()` with
the ERC-1967 implementation slot, and its `decimals()` must match the one
passed — because a proxy pointed at the wrong code cannot be repaired
afterwards. The check cannot see which preset the code was built from, so
matching the implementation to the entry point is on the operator.

The proxy address is the token. The proxy constructor runs `initializeToken`, so
name, symbol and the issuer are set before anyone can call the token — and the
admin arrives in a second transaction that only the issuer can make, exactly as
on the immutable path. Confirm it landed before going further.

The implementation is deployed under a salt derived from the deployer and the
decimals rather than from the token's entropy — the preset reaches the address
through the init code — so tokens that agree on preset and decimals share one
implementation instead of each getting a copy.

Deploy the proxy **with** the `initializeToken` call as its constructor data, as
the script does. A proxy deployed with empty data leaves `initializeToken` open
to whoever calls it first, and that caller names the issuer — which is the very
race the issuer exists to close. On the immutable path there is no equivalent
window, because the constructor is the initializer.

## Upgrading

An upgrade is announced, waited out, and can be vetoed.

```solidity
token.scheduleUpgrade(newImplementation, data);   // DEFAULT_ADMIN_ROLE
// ... UPGRADE_DELAY passes (1 day) ...
token.upgradeToAndCall(newImplementation, data);
```

Both terms are announced, not just the address. `upgradeToAndCall` delegatecalls
into the new implementation with `data` before returning, so `data` is code that
runs against this token's storage and this token's authority. Scheduling the
address alone would announce half of what is about to happen. Pass `""` when
there is no initialization to run, and pass the same bytes to both calls — a
mismatch reverts with `NoScheduledUpgrade`.

The Guardian — or the admin — can cancel while it is pending, using the id the
`UpgradeScheduled` event carries:

```solidity
token.cancelUpgrade(id);                    // GUARDIAN_ROLE or admin
// id == token.upgradeId(newImplementation, data)
```

A schedule is consumed by the upgrade that uses it, so rolling back is announced
and waited out like any other change.

Three things to get right:

**An upgrade must not change name, symbol or decimals.** Decimals silently
reprices every balance, and the name is part of the EIP-712 domain, so changing
it invalidates outstanding EIP-3009 and EIP-2612 signatures.

Decimals is an immutable in the implementation, so build the replacement with the
same constructor argument — a mismatch changes the token's decimals with no
storage write to notice. Name and symbol are in storage and cannot be re-set
through any initializer, but an implementation that writes the namespace directly
still can. Record `identityHash()` before scheduling, compare after the upgrade
lands, and treat a difference as an incident.

**The new implementation must itself be upgradeable.** Upgrade logic lives in the
implementation, so replacing it with one that lacks it freezes the proxy
permanently. The ERC-1822 check rejects that, but do not rely on the check alone
— deploy the new implementation from a preset in `src/presets/upgradeable/`.

**Storage is namespaced, not sequential.** Each module keeps its state in an
ERC-7201 namespace derived from a label, so adding or removing a module between
versions does not shift another module's storage.

The label is the slot. Changing one relocates that module's entire state: an
`Eip3009` label change would leave every spent nonce reading as unspent, making
past authorizations replayable, while the balances stay at the old slot. Keep
labels byte-identical across versions, and add fields to the end of a namespace
struct rather than in the middle. `test/StorageSlots.t.sol` checks each constant
against its label.

## Roles after deployment

The admin holds `DEFAULT_ADMIN_ROLE` and grants everything else:

| Role | Grants the ability to |
|---|---|
| `GUARDIAN_ROLE` | Cancel pending appointments, seizures and upgrades; freeze minting |
| `BLACKLISTER_ROLE` | Freeze and unfreeze accounts |
| `PAUSER_ROLE` | Stop and resume all movement |
| `RESCUER_ROLE` | Schedule and execute seizures (`FullToken` / `UpgradeableFullToken` only) |

Issuance is separate and takes a day: the admin schedules a Controller, the delay
passes, anyone executes the appointment, and the Controller then funds a Minter.
That sequence is deliberate — see
[the issuance controls note](adr/003-issuance-controls.md).

The admin key of an upgradeable token can eventually change any rule the token
enforces. A multisig is the minimum, and the delay only buys observers time to
react; it does not remove the authority.
