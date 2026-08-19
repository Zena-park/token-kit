// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {TokenBase} from "../core/TokenBase.sol";
import {SimpleMinter} from "../modules/issuance/SimpleMinter.sol";

/**
 * @title MinimalToken
 * @notice ERC-20 plus a mint role. Nothing else.
 *
 * @dev Who this is for
 *
 *  Testnets, demos, closed-loop points, and internal ledgers -- anywhere the
 *  token is not a claim on real reserves held for the public.
 *
 *  Named a token rather than a stablecoin because that is all it is, as are the
 *  others: no preset here implements a peg, a reserve or a redemption right, and
 *  naming them for the use case would overstate what the code does.
 *
 *  It is also the reference point for reading the other presets: every feature
 *  they add is a feature someone has to justify, and this is what the token
 *  looks like before any of those arguments are accepted.
 *
 * @dev What is absent, and what that means
 *
 *  No pause, no blacklist -- nothing can be stopped once it is moving.
 *  No mint ceiling -- a leaked key mints without bound.
 *  No signature transfers -- holders need their own gas to move tokens.
 *
 *  For a licensed, fiat-backed issuance every one of those absences is
 *  disqualifying. Use PermitToken or Eip3009Token instead -- though neither is
 *  sufficient for one either. They are necessary, not enough.
 */
contract MinimalToken is TokenBase, SimpleMinter {
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
}
