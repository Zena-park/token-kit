// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

/**
 * @title IEip3009
 * @notice EIP-3009 "Transfer With Authorization", plus the ERC-1271 extension.
 *
 * @dev Two groups of functions.
 *
 *  The `(v, r, s)` forms are the functions EIP-3009 itself defines. Their
 *  selectors follow from the signatures in the EIP text, and every integration
 *  written against the EIP -- wallet SDKs, payment facilitators -- calls them.
 *
 *  The `bytes signature` forms are not in the EIP. A contract account signs
 *  through ERC-1271 and its signature does not fit in 65 bytes, so a second
 *  form that takes arbitrary-length bytes is needed for such an account to pay
 *  at all. The signatures used here are the ones FiatTokenV2_2 introduced for
 *  the same purpose, so the ERC-1271 tooling built since then resolves to the
 *  same selectors.
 *
 *  A token implementing this interface is therefore callable by both kinds of
 *  integration. Integrators compile against this file.
 */
interface IEip3009 {
    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);
    event AuthorizationCanceled(address indexed authorizer, bytes32 indexed nonce);

    /// @notice Whether an authorization has been spent or cancelled.
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);

    // ---------------------------------------------------------------
    // EIP-3009
    // ---------------------------------------------------------------

    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function cancelAuthorization(address authorizer, bytes32 nonce, uint8 v, bytes32 r, bytes32 s)
        external;

    // ---------------------------------------------------------------
    // ERC-1271 extension: the same operations with an arbitrary-length signature
    // ---------------------------------------------------------------

    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external;

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external;

    // forge fmt joins this onto one line a character past solhint's limit.
    // solhint-disable-next-line max-line-length
    function cancelAuthorization(address authorizer, bytes32 nonce, bytes memory signature) external;
}
