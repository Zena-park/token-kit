// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/**
 * @title IEip2612
 * @notice EIP-2612 `permit`, plus the ERC-1271 extension.
 *
 * @dev `IERC20Permit` is the EIP as OpenZeppelin declares it: `permit` with
 *      the `(v, r, s)` triple, `nonces`, and `DOMAIN_SEPARATOR`. The `bytes
 *      signature` overload is the same extension, for the same reason, as the
 *      one `IEip3009` declares. Integrators compile against this file.
 */
interface IEip2612 is IERC20Permit {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        bytes memory signature
    ) external;
}
