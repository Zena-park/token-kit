// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

/**
 * @title IEip3009
 * @notice The EIP-3009 surface as USDC's FiatTokenV2_2 exposes it: every
 *         function in the spec's `(v, r, s)` form and in a `bytes signature`
 *         form that carries an ERC-1271 contract signature.
 *
 * @dev This is the ABI an x402 client, a wallet SDK or a facilitator compiles
 *      against. A preset that includes the Eip3009 module implements all six,
 *      so an integration built against USDC emits selectors this token
 *      dispatches whichever form it was built with.
 */
interface IEip3009 {
    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);
    event AuthorizationCanceled(address indexed authorizer, bytes32 indexed nonce);

    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);

    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external;

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
        bytes memory signature
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

    // forge fmt joins this onto one line a character past solhint's limit.
    // solhint-disable-next-line max-line-length
    function cancelAuthorization(address authorizer, bytes32 nonce, bytes memory signature) external;

    function cancelAuthorization(address authorizer, bytes32 nonce, uint8 v, bytes32 r, bytes32 s)
        external;
}
