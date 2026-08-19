// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {
    ERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {TokenBase} from "../../core/TokenBase.sol";
import {Eip3009} from "../../modules/payment/Eip3009.sol";
import {Eip2612} from "../../modules/payment/Eip2612.sol";
import {MinterControl} from "../../modules/issuance/MinterControl.sol";
import {EmergencyPause} from "../../modules/compliance/EmergencyPause.sol";
import {Seize} from "../../modules/compliance/Seize.sol";
import {UpgradeControl} from "../../modules/UpgradeControl.sol";

/**
 * @title UpgradeableFullToken
 * @notice FullToken behind a proxy: every payment, issuance and compliance
 *         module, plus a scheduled, delayed and vetoable upgrade path.
 *
 * @dev Two powers stack here
 *
 *  `Seize` can move a frozen holder's balance. `UpgradeControl` can replace the
 *  code that decides who may be frozen and what a seizure requires. An admin
 *  holding both can, over two delays, reach any state this token can represent.
 *
 *  Both are delayed and both are vetoable by the Guardian, so each step is
 *  visible before it takes effect. Neither is prevented.
 *
 * @dev Deployment
 *
 *  An implementation, not a token. Deploy behind an ERC-1967 proxy and call
 *  `initializeToken` then `initializeAdmin` on the proxy -- see
 *  docs/deploying.md.
 */
contract UpgradeableFullToken is
    TokenBase,
    Eip3009,
    Eip2612,
    MinterControl,
    // Seize extends Blacklist -- listing both would force this contract to
    // re-resolve the bypass hook that Seize exists to override.
    Seize,
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
    // EmergencyPause's single-slot check first, then the blacklist's. `Seize`
    // stands in for `Blacklist`, being the contract that resolves it.
    // -----------------------------------------------------------------

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, Seize, EmergencyPause)
    {
        super._update(from, to, value);
    }

    function _approve(address owner, address spender, uint256 value, bool emitEvent)
        internal
        override(ERC20Upgradeable, Seize, EmergencyPause)
    {
        super._approve(owner, spender, value, emitEvent);
    }

    function _spendAllowance(address owner, address spender, uint256 value)
        internal
        override(ERC20Upgradeable, Seize)
    {
        super._spendAllowance(owner, spender, value);
    }
}
