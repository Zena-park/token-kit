// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {
    ERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {TokenBase} from "../../core/TokenBase.sol";
import {Eip2612} from "../../modules/payment/Eip2612.sol";
import {MinterControl} from "../../modules/issuance/MinterControl.sol";
import {Blacklist} from "../../modules/compliance/Blacklist.sol";
import {EmergencyPause} from "../../modules/compliance/EmergencyPause.sol";
import {UpgradeControl} from "../../modules/UpgradeControl.sol";

/**
 * @title UpgradeablePermitToken
 * @notice PermitToken behind a proxy: the same modules, plus an upgrade path
 *         that is scheduled, delayed and vetoable.
 *
 * @dev What upgradeability costs the holder
 *
 *  Every guarantee the other modules make holds only for the current
 *  implementation. A new one can ignore the mint budget or the blacklist,
 *  including on the `transferFrom` calls Permit2 makes when it settles a
 *  payment. `UpgradeControl` adds a delay and a Guardian veto so the change is
 *  visible before it binds, but the admin key can eventually change any rule
 *  this token enforces.
 *
 *  The immutable `PermitToken` is the alternative, at the cost of being unable
 *  to fix a bug.
 *
 * @dev Deployment
 *
 *  An implementation, not a token. Deploy behind an ERC-1967 proxy and call
 *  `initializeToken` then `initializeAdmin` on the proxy -- see
 *  docs/deploying.md.
 */
contract UpgradeablePermitToken is
    TokenBase,
    Eip2612,
    MinterControl,
    Blacklist,
    EmergencyPause,
    UpgradeControl
{
    /**
     * @dev Decimals is a constructor argument because it belongs in the
     *      implementation's code rather than in a proxy's storage. One
     *      implementation therefore serves any number of tokens that agree on
     *      it, and cannot be shared by tokens that do not.
     *
     *      The body also locks this contract so it cannot be initialized and
     *      used as a token in its own right.
     */
    constructor(uint8 decimals_) TokenBase(decimals_) {
        _disableInitializers();
    }

    // -----------------------------------------------------------------
    // Funnel resolution. Solidity makes the most derived contract name every
    // base that overrides a shared hook, so each gated funnel appears once
    // here as a pass-through; `super` runs the chain right to left --
    // EmergencyPause's single-slot check first, then Blacklist's.
    // -----------------------------------------------------------------

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, Blacklist, EmergencyPause)
    {
        super._update(from, to, value);
    }

    function _approve(address owner, address spender, uint256 value, bool emitEvent)
        internal
        override(ERC20Upgradeable, Blacklist, EmergencyPause)
    {
        super._approve(owner, spender, value, emitEvent);
    }

    function _spendAllowance(address owner, address spender, uint256 value)
        internal
        override(ERC20Upgradeable, Blacklist)
    {
        super._spendAllowance(owner, spender, value);
    }
}
