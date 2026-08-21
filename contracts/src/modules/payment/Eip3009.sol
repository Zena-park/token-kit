// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {TokenBase} from "../../core/TokenBase.sol";
import {IEip3009} from "../../interfaces/IEip3009.sol";

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
 * @dev Why each function comes in two forms
 *
 *  The spec's `(v, r, s)` triple is what every integration built before
 *  contract signers existed calls; a `bytes signature` is what an ERC-1271
 *  account needs, since its signature does not fit in 65 bytes. USDC's
 *  FiatTokenV2_2 added the second form without removing the first, and
 *  `IEip3009` declares both so the selectors an x402 client or wallet SDK
 *  compiled against USDC all dispatch here. The triple packs into the bytes
 *  form and shares everything after that.
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
abstract contract Eip3009 is TokenBase, IEip3009 {
    // ---------------------------------------------------------------
    // Type hashes
    //
    // These are the literal EIP-3009 type strings hashed as-is, which makes them
    // byte-identical to USDC's. Together with the two entry-point forms, an x402
    // client or facilitator built against USDC works against this token with no
    // changes.
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
    // Errors
    // ---------------------------------------------------------------

    error AuthorizationNotYetValid();
    error AuthorizationExpired();
    error AuthorizationAlreadyUsed();
    error CallerMustBePayee();

    // ---------------------------------------------------------------

    /// @inheritdoc IEip3009
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
    ) public {
        _transferWithAuthorization(
            TRANSFER_WITH_AUTHORIZATION_TYPEHASH,
            from,
            to,
            value,
            validAfter,
            validBefore,
            nonce,
            signature
        );
    }

    /// @notice Spec form of {transferWithAuthorization}. EOA signers only.
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
    ) external {
        transferWithAuthorization(
            from, to, value, validAfter, validBefore, nonce, _packSignature(v, r, s)
        );
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
    ) public {
        if (to != _msgSender()) revert CallerMustBePayee();
        _transferWithAuthorization(
            RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
            from,
            to,
            value,
            validAfter,
            validBefore,
            nonce,
            signature
        );
    }

    /// @notice Spec form of {receiveWithAuthorization}. EOA signers only.
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
    ) external {
        receiveWithAuthorization(
            from, to, value, validAfter, validBefore, nonce, _packSignature(v, r, s)
        );
    }

    /// @notice Burn an unspent authorization so it can never be submitted.
    function cancelAuthorization(address authorizer, bytes32 nonce, bytes memory signature) public {
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

    /// @notice Spec form of {cancelAuthorization}. EOA signers only.
    function cancelAuthorization(address authorizer, bytes32 nonce, uint8 v, bytes32 r, bytes32 s)
        external
    {
        cancelAuthorization(authorizer, nonce, _packSignature(v, r, s));
    }

    // ---------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------

    /// @dev The two authorization types hash the same six fields under
    ///      different type strings, so a signature for one never satisfies the
    ///      other; which one is being checked is the only thing the callers
    ///      differ on once the payee check has passed.
    function _transferWithAuthorization(
        bytes32 typehash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) private {
        if (block.timestamp <= validAfter) revert AuthorizationNotYetValid();
        if (block.timestamp >= validBefore) revert AuthorizationExpired();

        Eip3009Storage storage $ = _eip3009Storage();
        if ($.authorizationStates[from][nonce]) revert AuthorizationAlreadyUsed();

        _requireValidSignature(
            from,
            keccak256(abi.encode(typehash, from, to, value, validAfter, validBefore, nonce)),
            signature
        );

        $.authorizationStates[from][nonce] = true;
        emit AuthorizationUsed(from, nonce);
        _transfer(from, to, value);
    }
}
