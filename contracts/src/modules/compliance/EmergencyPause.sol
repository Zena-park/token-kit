// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {TokenBase} from "../../core/TokenBase.sol";

/**
 * @title EmergencyPause
 * @notice Halts all token movement. The blunt instrument, kept blunt on purpose.
 *
 * @dev Why the pauser is a narrow role
 *
 *  Incidents are measured in minutes and multisig signature collection in hours.
 *  Because this role can only stop things -- it cannot mint, move, or reassign
 *  anything -- a single hot key is an acceptable holder, and a single hot key is
 *  what actually gets pressed in time.
 *
 *  Resuming is the admin's, not the pauser's. Stopping is the action that has
 *  to be fast; lifting a pause mid-incident is exactly what a leaked pauser key
 *  would do with the power, so the hot key does not get it. This is the same
 *  asymmetry as the issuance freeze: Guardian freezes, admin unfreezes.
 *
 * @dev What a pause does and does not reach
 *
 *  Enforced in `_update`, so every transfer, mint and burn stops, including
 *  signature-based ones and anything Permit2 pulls. Raising an allowance is
 *  halted too -- it is standing permission to move funds the moment the pause
 *  lifts.
 *
 *  Deliberately outside its reach: *revocation*. Cancelling a signature or
 *  zeroing an allowance moves no balance, and a pause is exactly the situation
 *  in which a holder most needs to revoke. See the Eip3009 module.
 *
 *  Also note that a pause does not undo. It buys time to decide; it does not
 *  recover anything already moved. Sizing the blast radius is the issuance
 *  module's job, not this one's.
 */
abstract contract EmergencyPause is TokenBase, PausableUpgradeable {
    /// @notice Emergency stop. Narrow enough for a single key.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Only the admin resumes. Fast to stop, deliberate to restart.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @dev Every balance change funnels through here.
    function _update(address from, address to, uint256 value)
        internal
        virtual
        override
        whenNotPaused
    {
        super._update(from, to, value);
    }

    /// @dev Raising an allowance is halted; lowering one stays open -- see the
    ///      revocation note above, and `TokenBase._isAllowanceRaise` for the
    ///      boundary. The `_spendAllowance` write-back (`emitEvent` false) is
    ///      not re-checked: the spend it belongs to is already stopped in
    ///      `_update`.
    function _approve(address owner, address spender, uint256 value, bool emitEvent)
        internal
        virtual
        override
    {
        if (_isAllowanceRaise(owner, spender, value, emitEvent)) _requireNotPaused();
        super._approve(owner, spender, value, emitEvent);
    }
}
