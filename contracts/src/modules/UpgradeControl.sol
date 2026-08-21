// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {TokenBase} from "../core/TokenBase.sol";
import {Guardian} from "./Guardian.sol";

/**
 * @title UpgradeControl
 * @notice Makes a token upgradeable, and puts the upgrade itself behind a delay
 *         and a veto.
 *
 * @dev Why upgradeability at all
 *
 *  A fiat-backed issuer generally cannot ship a token whose bugs are unfixable,
 *  and the capability is not hypothetical: USDC gained EIP-3009 in one
 *  implementation upgrade and ERC-1271 signature support in another. A token
 *  frozen at its first version would have neither.
 *
 * @dev Why the upgrade is delayed and vetoable
 *
 *  An upgrade key can replace the implementation with one that ignores the mint
 *  budget, skips the blacklist, or moves balances outright, so an unconstrained
 *  upgrade key voids every other control in this kit -- MinterControl's ceiling
 *  included.
 *
 *  It therefore gets the same treatment as the rest: schedule, wait, and let the
 *  Guardian cancel. A holder can see a pending upgrade and leave before it takes
 *  effect.
 *
 * @dev Where this departs from USDC
 *
 *  USDC uses a transparent proxy: the upgrade lives in the proxy and answers to
 *  a proxy admin held outside the token. This module is UUPS instead -- the
 *  upgrade logic lives in the implementation.
 *
 *  The difference is the veto. A transparent proxy authorises upgrades against a
 *  single admin address held in one of its own slots; it has no notion of roles.
 *  Scheduling by `DEFAULT_ADMIN_ROLE` and cancelling by `GUARDIAN_ROLE` means
 *  reading AccessControl's mapping, and the code that understands that mapping
 *  is in the implementation.
 *
 *  A proxy would have to either replicate AccessControl's storage layout and
 *  read the slots itself, which breaks silently if the implementation ever
 *  changes how roles are stored, or call back into the implementation to ask.
 *  Putting the upgrade in the implementation makes `hasRole` an ordinary
 *  internal call.
 *
 *  The cost is that the upgrade function is itself part of what gets replaced.
 *  Point the proxy at an implementation that has no upgrade function and there
 *  is no way to point it anywhere else again: the proxy has none of its own, and
 *  neither does the code it now runs. A transparent proxy cannot reach that
 *  state, because its upgrade function is in the proxy.
 *
 *  ERC-1822 is the guard. An implementation exposes `proxiableUUID()` returning
 *  the slot it reads the implementation address from, and OpenZeppelin's
 *  `UUPSUpgradeable` calls it on the candidate before switching: a candidate
 *  that does not answer is rejected as not-UUPS, and one that answers with a
 *  different slot is rejected as incompatible. Reusing that is the reason this
 *  builds on `UUPSUpgradeable` rather than writing the mechanism again.
 */
abstract contract UpgradeControl is TokenBase, Guardian, UUPSUpgradeable {
    /// @notice Delay between scheduling an upgrade and being able to run it.
    uint256 public constant UPGRADE_DELAY = 1 days;

    /// @notice How long a matured upgrade stays applicable before it lapses.
    /// @dev The delay exists so holders and the Guardian can read the candidate
    ///      and react. A schedule with no end turns that one reading into
    ///      standing permission: an implementation reviewed and left pending can
    ///      be applied a year later, against a token that has changed and an
    ///      audience that has stopped watching. Re-announcing costs a day.
    uint256 public constant UPGRADE_WINDOW = 7 days;

    /// @custom:storage-location erc7201:token-kit.storage.UpgradeControl
    struct UpgradeControlStorage {
        mapping(bytes32 id => uint48 eta) scheduled;
    }

    /// @dev `internal` so test/StorageSlots.t.sol can pin it to its label.
    bytes32 internal constant _UPGRADE_CONTROL_STORAGE =
        0x812e85981ca7b932346612da00e466dce8af15935b1d2719ee0fd7b0bc800600;

    function _upgradeControlStorage() private pure returns (UpgradeControlStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _UPGRADE_CONTROL_STORAGE
        }
    }

    event UpgradeScheduled(
        bytes32 indexed id, address indexed implementation, bytes data, uint48 eta
    );
    event UpgradeCanceled(bytes32 indexed id);

    error NoScheduledUpgrade(bytes32 id);
    error UpgradeNotReady(uint48 eta);
    error UpgradeExpired(uint48 eta);
    error ValueNotAccepted();

    /**
     * @notice The identifier an upgrade is scheduled and cancelled under.
     *
     * @dev Both terms, not just the implementation. `upgradeToAndCall` performs
     *      a delegatecall into the new implementation with `data` before
     *      returning, so `data` is code that runs with this token's storage and
     *      this token's authority -- an arbitrary state change, executed
     *      atomically with the swap.
     *
     *      Keying on the address alone would announce only half of what is about
     *      to happen: an observer watching out the delay would see a candidate
     *      implementation they could read, and then be handed a payload they had
     *      never seen. Both terms in the identifier means what matures is
     *      exactly what was announced.
     */
    function upgradeId(address implementation, bytes memory data) public pure returns (bytes32) {
        return keccak256(abi.encode(implementation, data));
    }

    /// @notice When a scheduled upgrade becomes executable. Zero if none.
    function scheduledUpgrade(bytes32 id) external view returns (uint48) {
        return _upgradeControlStorage().scheduled[id];
    }

    /**
     * @notice Announce an upgrade. Executable after UPGRADE_DELAY.
     * @dev The event is what gives holders and the Guardian the chance to react
     *      before the code changes. `data` is emitted in full rather than
     *      hashed, so reacting does not require reconstructing it.
     */
    function scheduleUpgrade(address implementation, bytes memory data)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (implementation == address(0)) revert ZeroAddress();

        bytes32 id = upgradeId(implementation, data);
        uint48 eta = SafeCast.toUint48(block.timestamp + UPGRADE_DELAY);
        _upgradeControlStorage().scheduled[id] = eta;
        emit UpgradeScheduled(id, implementation, data, eta);
    }

    /// @notice Guardian veto over a pending upgrade, by the id the schedule
    ///         event carries.
    function cancelUpgrade(bytes32 id) external onlyGuardianOrAdmin {
        UpgradeControlStorage storage $ = _upgradeControlStorage();
        if ($.scheduled[id] == 0) revert NoScheduledUpgrade(id);
        delete $.scheduled[id];
        emit UpgradeCanceled(id);
    }

    /**
     * @notice Apply an upgrade that has been announced and has matured.
     *
     * @dev The schedule is checked here rather than in `_authorizeUpgrade`
     *      because `_authorizeUpgrade` is handed only the implementation
     *      address; `data` never reaches it, and `data` is half of what was
     *      announced. Consuming the schedule here means one announcement buys
     *      exactly one upgrade, with exactly the payload it named.
     *
     *      The role check stays in `_authorizeUpgrade`, where OpenZeppelin puts
     *      it and where a reader looks for it, rather than being repeated here.
     *      `super` runs it along with the ERC-1822 check, and still refuses to
     *      run outside a proxy; a caller without the role reverts before
     *      anything this function wrote is kept.
     *
     *      The function is `payable` because the one it overrides is. A token
     *      has no use for ether and no way to send it back out, so any value
     *      that arrived here would sit in the proxy for good; it is refused.
     */
    function upgradeToAndCall(address implementation, bytes memory data) public payable override {
        if (msg.value != 0) revert ValueNotAccepted();

        bytes32 id = upgradeId(implementation, data);
        UpgradeControlStorage storage $ = _upgradeControlStorage();
        uint48 eta = $.scheduled[id];
        if (eta == 0) revert NoScheduledUpgrade(id);
        if (block.timestamp < eta) revert UpgradeNotReady(eta);
        if (block.timestamp > eta + UPGRADE_WINDOW) revert UpgradeExpired(eta);

        delete $.scheduled[id];
        super.upgradeToAndCall(implementation, data);
    }

    /// @dev The schedule is enforced in `upgradeToAndCall`, which is the only
    ///      caller that can see `data`. What is left here is the role check,
    ///      which OpenZeppelin runs after its own ERC-1822 validation.
    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
