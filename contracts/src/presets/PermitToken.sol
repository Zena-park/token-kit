// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {
    ERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {TokenBase} from "../core/TokenBase.sol";
import {Eip2612} from "../modules/payment/Eip2612.sol";
import {MinterControl} from "../modules/issuance/MinterControl.sol";
import {Blacklist} from "../modules/compliance/Blacklist.sol";
import {EmergencyPause} from "../modules/compliance/EmergencyPause.sol";

/**
 * @title PermitToken
 * @notice Bounded issuance authority and sanctions switches. The token itself
 *         implements one signature scheme, EIP-2612 `permit`; payments settle
 *         through Permit2.
 *
 * @dev The argument for this preset
 *
 *  Every signature scheme written into the token is code the issuer maintains
 *  and an auditor reviews. Permit2 already does the job for every ERC-20, and
 *  x402 names it as the universal transfer method, so this token is payable
 *  through the standard flow with only `permit` implemented here.
 *
 *  `permit` is what removes the one-time approval transaction: the x402 proxy's
 *  `settleWithPermit` sets the Permit2 allowance from a signature, so a first
 *  payment costs the holder no gas. The allowance stays revocable.
 *
 *  Front-running protection lives in Permit2 rather than in the token. Permit2
 *  binds the spender into the signature and the x402 proxy binds the recipient
 *  through a witness, which is the guarantee `receiveWithAuthorization` provides
 *  inside a token that implements EIP-3009.
 *
 * @dev The argument against it
 *
 *  Permit2 must be deployed on the target chain, and each holder signs a permit
 *  before their first payment. A Permit2-routed payment also costs more gas than
 *  a direct EIP-3009 call, which matters for micropayments.
 *
 *  The full comparison, including which one to pick, is in
 *  docs/adr/001-eip3009-vs-permit2.md.
 */
contract PermitToken is TokenBase, Eip2612, MinterControl, Blacklist, EmergencyPause {
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
