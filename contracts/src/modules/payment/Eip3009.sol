// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {TokenBase} from "../../core/TokenBase.sol";

/**
 * @title Eip3009
 * @notice EIP-3009 "Transfer With Authorization". The holder signs; anyone may
 *         submit. The holder needs no gas and no prior approval.
 *
 * @dev What this buys you
 *
 *  The x402 payment protocol names EIP-3009 as its recommended EVM transfer
 *  method: a facilitator submits the buyer's signature and pays the gas, so a
 *  first-time buyer with an empty wallet can still pay. Without it the buyer
 *  must send an approval transaction first, and that transaction needs gas.
 *
 * @dev Why the nonce is random bytes32 rather than a counter
 *
 *  Only "spent or not" is recorded, so authorizations have no ordering. Two
 *  payments signed by the same holder can settle concurrently and in any order.
 *
 *  A sequential nonce would serialize them: an agent calling three paid APIs in
 *  parallel would have two of the three revert.
 *
 * @dev Why both `transferWithAuthorization` and `receiveWithAuthorization`
 *
 *  `transferWithAuthorization` can be submitted by anyone. That is fine when the
 *  payee is an ordinary address, and it is what makes the flow permissionless.
 *
 *  It breaks down when the payee is a contract that must do work in the same
 *  transaction -- splitting a fee, marking an order settled. ERC-20 has no
 *  receive hook, so the contract's code does not run when tokens arrive. A third
 *  party who lifts the signature out of the mempool can push the funds in
 *  without ever calling the settlement function, leaving the money stranded and
 *  the order unpaid, with the nonce burned so the real call now reverts.
 *
 *  `receiveWithAuthorization` requires `to == msg.sender`, so the transfer can
 *  only happen from inside the payee's own function. Receive and settle become
 *  one atomic step.
 *
 *  Shipping only the first of the pair is worse than shipping neither: contracts
 *  that detect `transferWithAuthorization` reasonably assume its partner exists.
 *
 * @dev Interaction with the compliance modules
 *
 *  These functions carry no `whenNotPaused` modifier of their own. Every balance
 *  change routes through `_update`, which is where the EmergencyPause and Blacklist
 *  modules apply their checks -- adding the modifier here would be a second,
 *  redundant check on the same path.
 *
 *  `cancelAuthorization` moves no balance and is reachable while paused, so a
 *  holder can revoke a leaked signature during an incident.
 */
abstract contract Eip3009 is TokenBase {
    // ---------------------------------------------------------------
    // Type hashes
    //
    // These are the literal EIP-3009 type strings hashed as-is, which makes them
    // byte-identical to USDC's. An x402 client or facilitator built against USDC
    // works against this token with no changes.
    // ---------------------------------------------------------------

    // The EIP-712 type string is normative -- wrapping it makes it hard to diff
    // solhint-disable max-line-length
    /// @dev keccak256("TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH =
        0x7c7c6cdb67a18743f49ec6fa9b35f50d52ed05cbed4cc592e13b44501c1a2267;

    /// @dev keccak256("ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)")
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8;
    // solhint-enable max-line-length

    /// @dev keccak256("CancelAuthorization(address authorizer,bytes32 nonce)")
    bytes32 public constant CANCEL_AUTHORIZATION_TYPEHASH =
        0x158b0a9edf7a828aad02f63cd515c68ef2f50ba807396f6d12842833a1597429;

    // ---------------------------------------------------------------
    // State
    // ---------------------------------------------------------------

    /// @custom:storage-location erc7201:token-kit.storage.Eip3009
    struct Eip3009Storage {
        /// @dev authorizer => nonce => spent. Random nonces, so order is irrelevant.
        mapping(address => mapping(bytes32 => bool)) authorizationStates;
    }

    /// @dev `internal` so test/StorageSlots.t.sol can pin it to its label.
    bytes32 internal constant _EIP3009_STORAGE =
        0x376e2525eb084a17e0d03585b0401d8bffad8bafdce80424ebb8c64ca6a4ad00;

    function _eip3009Storage() private pure returns (Eip3009Storage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _EIP3009_STORAGE
        }
    }

    // ---------------------------------------------------------------
    // Events / errors
    // ---------------------------------------------------------------

    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);
    event AuthorizationCanceled(address indexed authorizer, bytes32 indexed nonce);

    error AuthorizationNotYetValid();
    error AuthorizationExpired();
    error AuthorizationAlreadyUsed();
    error CallerMustBePayee();

    // ---------------------------------------------------------------

    /// @notice Whether an authorization has been spent or cancelled.
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool) {
        return _eip3009Storage().authorizationStates[authorizer][nonce];
    }

    /**
     * @notice Execute a transfer on behalf of the signer. Any caller.
     * @dev Recipient and amount are covered by the signature, so the submitter
     *      can pay the gas but cannot redirect the funds.
     */
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external {
        _requireValidAuthorization(from, nonce, validAfter, validBefore);
        _requireValidSignature(
            from,
            keccak256(
                abi.encode(
                    TRANSFER_WITH_AUTHORIZATION_TYPEHASH,
                    from,
                    to,
                    value,
                    validAfter,
                    validBefore,
                    nonce
                )
            ),
            signature
        );

        _markAuthorizationAsUsed(from, nonce);
        _transfer(from, to, value);
    }

    /**
     * @notice As above, but only the payee may submit it.
     * @dev Lets a contract receive and act in one transaction, and denies a
     *      third party the chance to deliver the funds outside that path.
     */
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external {
        if (to != _msgSender()) revert CallerMustBePayee();

        _requireValidAuthorization(from, nonce, validAfter, validBefore);
        _requireValidSignature(
            from,
            keccak256(
                abi.encode(
                    RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
                    from,
                    to,
                    value,
                    validAfter,
                    validBefore,
                    nonce
                )
            ),
            signature
        );

        _markAuthorizationAsUsed(from, nonce);
        _transfer(from, to, value);
    }

    /// @notice Burn an unspent authorization so it can never be submitted.
    function cancelAuthorization(address authorizer, bytes32 nonce, bytes memory signature)
        external
    {
        if (_eip3009Storage().authorizationStates[authorizer][nonce]) {
            revert AuthorizationAlreadyUsed();
        }

        _requireValidSignature(
            authorizer,
            keccak256(abi.encode(CANCEL_AUTHORIZATION_TYPEHASH, authorizer, nonce)),
            signature
        );

        _eip3009Storage().authorizationStates[authorizer][nonce] = true;
        emit AuthorizationCanceled(authorizer, nonce);
    }

    // ---------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------

    function _requireValidAuthorization(
        address authorizer,
        bytes32 nonce,
        uint256 validAfter,
        uint256 validBefore
    ) private view {
        if (block.timestamp <= validAfter) revert AuthorizationNotYetValid();
        if (block.timestamp >= validBefore) revert AuthorizationExpired();
        if (_eip3009Storage().authorizationStates[authorizer][nonce]) {
            revert AuthorizationAlreadyUsed();
        }
    }

    function _markAuthorizationAsUsed(address authorizer, bytes32 nonce) private {
        _eip3009Storage().authorizationStates[authorizer][nonce] = true;
        emit AuthorizationUsed(authorizer, nonce);
    }
}
