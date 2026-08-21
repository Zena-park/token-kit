// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import {TokenBase} from "../../core/TokenBase.sol";

/**
 * @title Eip2612
 * @notice EIP-2612 `permit`: set an allowance by signature instead of by
 *         transaction. The classic gasless approval.
 *
 * @dev What it enables
 *
 *  The x402 `exact` scheme's Permit2 path has a `settleWithPermit` entry point
 *  on `x402ExactPermit2Proxy` that calls `permit` on the token to set the
 *  Permit2 allowance, then settles. Without this module that entry point is
 *  unavailable and the holder has to send an approval transaction.
 *
 *  The allowance it sets stays revocable, and no spender holds one that the
 *  holder did not grant.
 *
 * @dev Why this is not OpenZeppelin's ERC20Permit
 *
 *  `ERC20Permit` verifies with `ECDSA.recover`, so only EOAs can use it. A
 *  passkey ERC-4337 account signs with P-256 and would be permanently unable to
 *  approve by signature.
 *
 *  This implementation checks signatures through the base's SignatureChecker
 *  path, so contract accounts are accepted via ERC-1271. Both the spec's
 *  `(v, r, s)` form and a `bytes` form are exposed: the triple keeps existing
 *  integrations working, the bytes form is what a contract signature needs.
 *
 * @dev The nonce is sequential, and that is a real limitation
 *
 *  EIP-2612 mandates a counter. Two permits signed by the same holder must be
 *  submitted in order, and if one is dropped the other fails. For approvals this
 *  is tolerable -- they are occasional and usually one-time.
 *
 *  It is not tolerable for payments. An agent paying three APIs at once would
 *  have its concurrent authorizations collide. That is the reason the EIP-3009
 *  module exists alongside this one and uses random `bytes32` nonces instead.
 */
abstract contract Eip2612 is TokenBase, NoncesUpgradeable {
    // solhint-disable-next-line max-line-length
    /// @dev keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")
    bytes32 public constant PERMIT_TYPEHASH =
        0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;

    error PermitExpired(uint256 deadline);

    /// @notice EIP-2612 requires this exact name for the domain separator.
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Spec form. EOA signers only -- a 65-byte signature cannot carry
    ///         an ERC-1271 payload.
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        _permit(owner, spender, value, deadline, _packSignature(v, r, s));
    }

    /// @notice Extended form accepting an arbitrary-length signature, so that
    ///         smart accounts can approve through ERC-1271.
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        bytes memory signature
    ) external {
        _permit(owner, spender, value, deadline, signature);
    }

    function _permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        bytes memory signature
    ) private {
        if (block.timestamp > deadline) revert PermitExpired(deadline);

        _requireValidSignature(
            owner,
            keccak256(
                abi.encode(PERMIT_TYPEHASH, owner, spender, value, _useNonce(owner), deadline)
            ),
            signature
        );

        _approve(owner, spender, value);
    }
}
