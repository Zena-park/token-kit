// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {TokenBase} from "../../src/core/TokenBase.sol";
import {MinterControl} from "../../src/modules/issuance/MinterControl.sol";

/**
 * @dev Stands in for a passkey ERC-4337 account.
 *
 *      A real one verifies P-256; what these tests need to establish is only
 *      that the token takes the ERC-1271 path at all, so the check is delegated
 *      to an owner EOA signature.
 */
contract MockSmartAccount is IERC1271 {
    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }

    /// @dev `ECDSA.recover` takes the packed form directly and rejects the
    ///      malleable and zero-address results a raw `ecrecover` returns, which
    ///      is what a real account would want too. Splitting r/s/v by hand here
    ///      would be a second, weaker copy of the code the token already uses.
    function isValidSignature(bytes32 hash, bytes memory signature)
        external
        view
        override
        returns (bytes4)
    {
        if (ECDSA.recover(hash, signature) == owner) {
            return IERC1271.isValidSignature.selector;
        }
        return 0xffffffff;
    }
}

/// @dev Shared signing and setup helpers.
abstract contract Helpers is Test {
    /// @dev One whole unit at 6 decimals, the setting every suite deploys with.
    uint256 internal constant UNIT = 1e6;

    /// @dev Sign an EIP-712 struct hash under a token's domain, in the split
    ///      form the spec-shaped entry points take.
    function signTypedVRS(TokenBase token, uint256 key, bytes32 structHash)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 digest = MessageHashUtils.toTypedDataHash(token.domainSeparator(), structHash);
        (v, r, s) = vm.sign(key, digest);
    }

    /// @dev The same signature packed, which is what the ERC-1271-capable entry
    ///      points take.
    function signTyped(TokenBase token, uint256 key, bytes32 structHash)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = signTypedVRS(token, key, structHash);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Expect the next call to revert as AccessControl-unauthorized.
    ///      Takes the role pre-read so call sites keep the discipline of
    ///      reading it before their prank -- a view call would eat the prank.
    function expectUnauthorized(address account, bytes32 role) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, account, role
            )
        );
    }

    /**
     * @dev Walk the full issuance path: admin appoints a Controller, the delay
     *      passes, the Controller funds a Minter.
     *
     *      The delay is skipped with `vm.warp` but the procedure is not skipped,
     *      because the procedure is the point of the module.
     */
    function grantMint(MinterControl token, address admin, address minter, uint256 allowance)
        internal
        returns (address controller)
    {
        controller =
            address(uint160(uint256(keccak256(abi.encode("ctrl", address(token), minter)))));

        vm.prank(admin);
        token.scheduleController(controller, minter);

        vm.warp(block.timestamp + token.CONTROLLER_DELAY());
        token.executeController(controller);

        vm.prank(controller);
        token.configureMinter(allowance);
    }

    function grantMint(MinterControl token, address admin, address minter)
        internal
        returns (address)
    {
        return grantMint(token, admin, minter, type(uint128).max);
    }
}
