// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {
    ERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {TokenBase} from "../core/TokenBase.sol";
import {Eip3009} from "../modules/payment/Eip3009.sol";
import {Eip2612} from "../modules/payment/Eip2612.sol";
import {MinterControl} from "../modules/issuance/MinterControl.sol";
import {Blacklist} from "../modules/compliance/Blacklist.sol";
import {EmergencyPause} from "../modules/compliance/EmergencyPause.sol";

/**
 * @title Eip3009Token
 * @notice The x402 payments profile: native EIP-3009 plus EIP-2612, with
 *         bounded issuance authority and sanctions switches.
 *
 * @dev The argument for this preset
 *
 *  x402 lists EIP-3009 first and calls it the simplest and the only truly
 *  gasless method, because settlement is a single call to the token with no
 *  external contract in the path. If the token is being issued specifically to
 *  be paid with, implementing the recommended method is the straightforward
 *  choice, and it is what USDC, PYUSD and EURC all do.
 *
 *  Random `bytes32` nonces let one holder have many payments in flight at once,
 *  which is the normal case for an agent calling several paid APIs in parallel.
 *  Signature verification goes through ERC-1271, so passkey smart accounts can
 *  pay without ever holding gas.
 *
 *  EIP-2612 rides along for the wider ecosystem -- routers and vaults probe for
 *  `permit`, and it costs one module to be legible to them.
 *
 * @dev The argument against it
 *
 *  It is more code inside the token: three external functions, three type
 *  hashes, and a nonce mapping that the issuer maintains and an auditor reviews.
 *  PermitToken gets a comparable result with none of it.
 *
 *  See docs/adr/001-eip3009-vs-permit2.md.
 *
 * @dev Note on including both payment modules
 *
 *  EIP-3009 and EIP-2612 keep separate nonce spaces -- a random-nonce map and a
 *  counter -- and neither can spend the other's authorizations. Enabling both is
 *  safe; it just means two ways to be paid.
 */
contract Eip3009Token is TokenBase, Eip3009, Eip2612, MinterControl, Blacklist, EmergencyPause {
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
