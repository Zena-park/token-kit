// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {
    ERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {TokenBase} from "../core/TokenBase.sol";
import {Eip3009} from "../modules/payment/Eip3009.sol";
import {Eip2612} from "../modules/payment/Eip2612.sol";
import {MinterControl} from "../modules/issuance/MinterControl.sol";
import {EmergencyPause} from "../modules/compliance/EmergencyPause.sol";
import {Seize} from "../modules/compliance/Seize.sol";

/**
 * @title FullToken
 * @notice Every payment, issuance and compliance module at once. Immutable --
 *         upgradeability is the one thing not turned on here.
 *
 * @dev What enabling everything means
 *
 *  Two payment schemes mean two independent ways to authorize a transfer and two
 *  sets of signature semantics for a wallet to handle. Seize is a power to take
 *  a balance.
 *
 *  PermitToken and Eip3009Token are the narrower starting points.
 *  UpgradeableFullToken is the same composition behind a proxy.
 *
 * @dev On enabling both payment modules together
 *
 *  They are independent: EIP-3009 spends random nonces and EIP-2612 spends a
 *  counter. Neither can consume the other's authorization, and both ultimately
 *  move funds through `_update`, so the compliance modules apply to each.
 *  Payments routed through Permit2 arrive as ordinary `transferFrom` calls and
 *  cross the same gates.
 */
contract FullToken is
    TokenBase,
    Eip3009,
    Eip2612,
    MinterControl,
    // Seize extends Blacklist -- listing both would force this contract to
    // re-resolve the bypass hook that Seize exists to override.
    Seize,
    EmergencyPause
{
    /// @dev Immutable deployment: no proxy, no upgrade path. The initializer
    ///      runs here instead of on a proxy, and can never run again.
    ///      `issuer_` is who may later hand over the admin; see
    ///      {TokenBase-initializeAdmin} for why it is in the init code.
    constructor(string memory name_, string memory symbol_, uint8 decimals_, address issuer_)
        TokenBase(decimals_)
        initializer
    {
        __TokenBase_init(name_, symbol_, issuer_);
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
