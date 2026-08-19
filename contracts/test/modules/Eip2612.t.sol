// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Helpers, MockSmartAccount} from "../helpers/Helpers.sol";
import {Eip3009Token} from "../../src/presets/Eip3009Token.sol";
import {Eip2612} from "../../src/modules/payment/Eip2612.sol";
import {TokenBase} from "../../src/core/TokenBase.sol";

contract Eip2612Test is Helpers {
    Eip3009Token token;

    address admin = makeAddr("admin");
    address minter = makeAddr("minter");
    address spender = makeAddr("spender");

    uint256 holderKey = 0xB0B;
    address holder;

    function setUp() public {
        holder = vm.addr(holderKey);

        vm.startPrank(admin);
        token = new Eip3009Token("Test Token", "TEST", 6, admin);
        token.initializeAdmin(admin);
        vm.stopPrank();

        grantMint(token, admin, minter);

        vm.prank(minter);
        token.mint(holder, 1_000_000 * UNIT);
    }

    function test_typehash_matches_the_spec_string() public view {
        assertEq(
            token.PERMIT_TYPEHASH(),
            keccak256(
                "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
            )
        );
    }

    /// @dev EIP-2612 names this exactly; tooling reads it by name.
    function test_domain_separator_is_exposed_under_the_spec_name() public view {
        assertEq(token.DOMAIN_SEPARATOR(), token.domainSeparator());
    }

    function test_permit_sets_an_allowance_by_signature() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(holderKey, holder, spender, 100 * UNIT, deadline);

        token.permit(holder, spender, 100 * UNIT, deadline, v, r, s);

        assertEq(token.allowance(holder, spender), 100 * UNIT);
        assertEq(token.nonces(holder), 1);
    }

    function test_permit_cannot_be_replayed() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(holderKey, holder, spender, 100 * UNIT, deadline);

        token.permit(holder, spender, 100 * UNIT, deadline, v, r, s);

        // The nonce advanced, so the same signature no longer recovers.
        vm.expectRevert(TokenBase.InvalidSignature.selector);
        token.permit(holder, spender, 100 * UNIT, deadline, v, r, s);
    }

    function test_permit_expires() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(holderKey, holder, spender, 100 * UNIT, deadline);

        vm.warp(deadline + 1);

        vm.expectRevert(abi.encodeWithSelector(Eip2612.PermitExpired.selector, deadline));
        token.permit(holder, spender, 100 * UNIT, deadline, v, r, s);
    }

    function test_permit_rejects_a_tampered_value() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(holderKey, holder, spender, 100 * UNIT, deadline);

        vm.expectRevert(TokenBase.InvalidSignature.selector);
        token.permit(holder, spender, 999 * UNIT, deadline, v, r, s);
    }

    /// @dev The reason this module is not OpenZeppelin's ERC20Permit: a
    ///      contract signature does not fit in (v, r, s), so a passkey account
    ///      could never approve by signature.
    function test_smart_account_can_permit_through_the_bytes_overload() public {
        MockSmartAccount account = new MockSmartAccount(holder);
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig = signTyped(
            token, holderKey, _permitHash(address(account), spender, 100 * UNIT, deadline)
        );

        token.permit(address(account), spender, 100 * UNIT, deadline, sig);

        assertEq(token.allowance(address(account), spender), 100 * UNIT);
    }

    /// @dev A counter, unlike EIP-3009's random nonces. Documented as the reason
    ///      permit is a poor fit for concurrent payments.
    function test_nonces_are_sequential() public {
        uint256 deadline = block.timestamp + 1 hours;

        for (uint256 i = 0; i < 3; ++i) {
            assertEq(token.nonces(holder), i);
            (uint8 v, bytes32 r, bytes32 s) =
                _signPermit(holderKey, holder, spender, (i + 1) * UNIT, deadline);
            token.permit(holder, spender, (i + 1) * UNIT, deadline, v, r, s);
        }

        assertEq(token.nonces(holder), 3);
    }

    /// @dev The one place this suite spells out the Permit field order.
    function _permitHash(address owner, address spender_, uint256 value, uint256 deadline)
        private
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                token.PERMIT_TYPEHASH(), owner, spender_, value, token.nonces(owner), deadline
            )
        );
    }

    function _signPermit(
        uint256 key,
        address owner,
        address spender_,
        uint256 value,
        uint256 deadline
    ) private view returns (uint8 v, bytes32 r, bytes32 s) {
        (v, r, s) = signTypedVRS(token, key, _permitHash(owner, spender_, value, deadline));
    }
}
