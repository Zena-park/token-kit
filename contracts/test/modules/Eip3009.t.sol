// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Helpers, MockSmartAccount} from "../helpers/Helpers.sol";
import {Eip3009Token} from "../../src/presets/Eip3009Token.sol";
import {Eip3009} from "../../src/modules/payment/Eip3009.sol";
import {IEip3009} from "../../src/interfaces/IEip3009.sol";
import {TokenBase} from "../../src/core/TokenBase.sol";
import {Blacklist} from "../../src/modules/compliance/Blacklist.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract Eip3009Test is Helpers {
    Eip3009Token token;

    address admin = makeAddr("admin");
    address minter = makeAddr("minter");
    address facilitator = makeAddr("facilitator"); // third party paying the gas
    address shop = makeAddr("shop");

    uint256 payerKey = 0xA11CE;
    address payer;

    function setUp() public {
        payer = vm.addr(payerKey);

        vm.startPrank(admin);
        token = new Eip3009Token("Test Token", "TEST", 6, admin);
        token.initializeAdmin(admin);
        vm.stopPrank();

        grantMint(token, admin, minter);

        vm.startPrank(admin);
        token.grantRole(token.BLACKLISTER_ROLE(), admin);
        token.grantRole(token.PAUSER_ROLE(), admin);
        vm.stopPrank();

        vm.prank(minter);
        token.mint(payer, 1_000_000 * UNIT);
    }

    // ---------------------------------------------------------------
    // Compatibility
    // ---------------------------------------------------------------

    /// @dev If these drift from the EIP's, every EIP-3009 client has to special-case us.
    function test_typehashes_match_the_spec_strings() public view {
        assertEq(
            token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(),
            keccak256(
                "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
            )
        );
        assertEq(
            token.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
            keccak256(
                "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
            )
        );
        assertEq(
            token.CANCEL_AUTHORIZATION_TYPEHASH(),
            keccak256("CancelAuthorization(address authorizer,bytes32 nonce)")
        );
    }

    /// @dev Every preset with this module implements `IEip3009`, so what the
    ///      interface declares is what the token dispatches. This pins the
    ///      declaration to the function signatures in the EIP text.
    ///      Overloads cannot be named one at a time in Solidity, so the check
    ///      goes through `type(I).interfaceId` -- the XOR of every selector the
    ///      compiler derives from the declaration -- against the same XOR over
    ///      the expected signatures. A changed parameter type fails here rather
    ///      than in every caller.
    function test_interface_matches_the_eip3009_signatures() public pure {
        // The three functions EIP-3009 defines.
        bytes4 eip = bytes4(
            keccak256(
                "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)"
            )
        )
        ^ bytes4(
            keccak256(
                "receiveWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)"
            )
        ) ^ bytes4(keccak256("cancelAuthorization(address,bytes32,uint8,bytes32,bytes32)"))
        ^ bytes4(keccak256("authorizationState(address,bytes32)"));

        // The ERC-1271 extension, with the signatures the ecosystem uses for it.
        bytes4 extension = bytes4(
            keccak256(
                "transferWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)"
            )
        )
        ^ bytes4(
            keccak256(
                "receiveWithAuthorization(address,address,uint256,uint256,uint256,bytes32,bytes)"
            )
        ) ^ bytes4(keccak256("cancelAuthorization(address,bytes32,bytes)"));

        assertEq(type(IEip3009).interfaceId, eip ^ extension);
    }

    // ---------------------------------------------------------------
    // transferWithAuthorization
    // ---------------------------------------------------------------

    /// @dev The EIP's own form is what an integration written against it
    ///      calls. It must reach the same path as the bytes form: same nonce,
    ///      same event, same transfer.
    function test_transfer_eip_form_moves_funds_and_burns_the_nonce() public {
        bytes32 nonce = keccak256("order-1");
        (uint8 v, bytes32 r, bytes32 s) = _signAuthVRS(
            token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(),
            payerKey,
            payer,
            shop,
            1000 * UNIT,
            0,
            _future(),
            nonce
        );

        vm.prank(facilitator);
        token.transferWithAuthorization(payer, shop, 1000 * UNIT, 0, _future(), nonce, v, r, s);

        assertEq(token.balanceOf(shop), 1000 * UNIT);
        assertTrue(token.authorizationState(payer, nonce));

        // The nonce is shared with the bytes form, so neither can replay the other.
        vm.prank(facilitator);
        vm.expectRevert(Eip3009.AuthorizationAlreadyUsed.selector);
        token.transferWithAuthorization(
            payer, shop, 1000 * UNIT, 0, _future(), nonce, abi.encodePacked(r, s, v)
        );
    }

    function test_transfer_moves_funds_with_a_third_party_paying_gas() public {
        bytes32 nonce = keccak256("order-1");
        bytes memory sig = _signAuth(
            token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(),
            payerKey,
            payer,
            shop,
            1000 * UNIT,
            0,
            _future(),
            nonce
        );

        vm.prank(facilitator);
        token.transferWithAuthorization(payer, shop, 1000 * UNIT, 0, _future(), nonce, sig);

        assertEq(token.balanceOf(shop), 1000 * UNIT);
        assertEq(token.balanceOf(facilitator), 0, "facilitator only paid gas");
        assertTrue(token.authorizationState(payer, nonce));
    }

    function test_transfer_cannot_be_replayed() public {
        bytes32 nonce = keccak256("order-1");
        bytes memory sig = _signAuth(
            token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(),
            payerKey,
            payer,
            shop,
            1000 * UNIT,
            0,
            _future(),
            nonce
        );

        vm.startPrank(facilitator);
        token.transferWithAuthorization(payer, shop, 1000 * UNIT, 0, _future(), nonce, sig);

        vm.expectRevert(Eip3009.AuthorizationAlreadyUsed.selector);
        token.transferWithAuthorization(payer, shop, 1000 * UNIT, 0, _future(), nonce, sig);
        vm.stopPrank();
    }

    /// @dev The submitter pays gas but must not be able to redirect the money.
    function test_submitter_cannot_change_recipient_or_amount() public {
        bytes32 nonce = keccak256("order-1");
        bytes memory sig = _signAuth(
            token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(),
            payerKey,
            payer,
            shop,
            1000 * UNIT,
            0,
            _future(),
            nonce
        );

        vm.prank(facilitator);
        vm.expectRevert(TokenBase.InvalidSignature.selector);
        token.transferWithAuthorization(payer, facilitator, 1000 * UNIT, 0, _future(), nonce, sig);

        vm.prank(facilitator);
        vm.expectRevert(TokenBase.InvalidSignature.selector);
        token.transferWithAuthorization(payer, shop, 9999 * UNIT, 0, _future(), nonce, sig);
    }

    /// @dev Random nonces exist so concurrent payments do not serialize.
    function test_authorizations_settle_in_any_order() public {
        bytes32 n1 = keccak256("a");
        bytes32 n2 = keccak256("b");
        bytes memory s1 = _signAuth(
            token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(),
            payerKey,
            payer,
            shop,
            10 * UNIT,
            0,
            _future(),
            n1
        );
        bytes memory s2 = _signAuth(
            token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(),
            payerKey,
            payer,
            shop,
            20 * UNIT,
            0,
            _future(),
            n2
        );

        vm.startPrank(facilitator);
        token.transferWithAuthorization(payer, shop, 20 * UNIT, 0, _future(), n2, s2);
        token.transferWithAuthorization(payer, shop, 10 * UNIT, 0, _future(), n1, s1);
        vm.stopPrank();

        assertEq(token.balanceOf(shop), 30 * UNIT);
    }

    function test_transfer_respects_the_validity_window() public {
        bytes32 nonce = keccak256("order-1");
        uint256 notYet = block.timestamp + 1 days;
        bytes memory early = _signAuth(
            token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(),
            payerKey,
            payer,
            shop,
            UNIT,
            notYet,
            notYet + 1 days,
            nonce
        );

        vm.prank(facilitator);
        vm.expectRevert(Eip3009.AuthorizationNotYetValid.selector);
        token.transferWithAuthorization(payer, shop, UNIT, notYet, notYet + 1 days, nonce, early);

        uint256 expired = block.timestamp + 100;
        bytes memory late = _signAuth(
            token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(),
            payerKey,
            payer,
            shop,
            UNIT,
            0,
            expired,
            nonce
        );
        vm.warp(expired + 1);

        vm.prank(facilitator);
        vm.expectRevert(Eip3009.AuthorizationExpired.selector);
        token.transferWithAuthorization(payer, shop, UNIT, 0, expired, nonce, late);
    }

    // ---------------------------------------------------------------
    // receiveWithAuthorization
    // ---------------------------------------------------------------

    /// @dev The whole reason the second function exists.
    function test_receive_rejects_anyone_but_the_payee() public {
        bytes32 nonce = keccak256("order-1");
        bytes memory sig = _signAuth(
            token.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
            payerKey,
            payer,
            shop,
            1000 * UNIT,
            0,
            _future(),
            nonce
        );

        vm.prank(facilitator);
        vm.expectRevert(Eip3009.CallerMustBePayee.selector);
        token.receiveWithAuthorization(payer, shop, 1000 * UNIT, 0, _future(), nonce, sig);

        vm.prank(shop);
        token.receiveWithAuthorization(payer, shop, 1000 * UNIT, 0, _future(), nonce, sig);
        assertEq(token.balanceOf(shop), 1000 * UNIT);
    }

    /// @dev The two functions hash different type strings, so a signature for
    ///      one must not satisfy the other.
    function test_transfer_signature_does_not_work_for_receive() public {
        bytes32 nonce = keccak256("order-1");
        bytes memory sig = _signAuth(
            token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(),
            payerKey,
            payer,
            shop,
            1000 * UNIT,
            0,
            _future(),
            nonce
        );

        vm.prank(shop);
        vm.expectRevert(TokenBase.InvalidSignature.selector);
        token.receiveWithAuthorization(payer, shop, 1000 * UNIT, 0, _future(), nonce, sig);
    }

    // ---------------------------------------------------------------
    // cancelAuthorization
    // ---------------------------------------------------------------

    function test_cancel_burns_an_unspent_authorization() public {
        bytes32 nonce = keccak256("order-1");
        bytes memory transferSig = _signAuth(
            token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(),
            payerKey,
            payer,
            shop,
            1000 * UNIT,
            0,
            _future(),
            nonce
        );
        bytes memory cancelSig = signTyped(
            token,
            payerKey,
            keccak256(abi.encode(token.CANCEL_AUTHORIZATION_TYPEHASH(), payer, nonce))
        );

        vm.prank(facilitator);
        token.cancelAuthorization(payer, nonce, cancelSig);

        vm.prank(facilitator);
        vm.expectRevert(Eip3009.AuthorizationAlreadyUsed.selector);
        token.transferWithAuthorization(payer, shop, 1000 * UNIT, 0, _future(), nonce, transferSig);
    }

    function test_cancel_eip_form_burns_an_unspent_authorization() public {
        bytes32 nonce = keccak256("order-1");
        (uint8 v, bytes32 r, bytes32 s) = signTypedVRS(
            token,
            payerKey,
            keccak256(abi.encode(token.CANCEL_AUTHORIZATION_TYPEHASH(), payer, nonce))
        );

        vm.prank(facilitator);
        token.cancelAuthorization(payer, nonce, v, r, s);
        assertTrue(token.authorizationState(payer, nonce));

        // Cancelling twice, in either form, is refused.
        vm.prank(facilitator);
        vm.expectRevert(Eip3009.AuthorizationAlreadyUsed.selector);
        token.cancelAuthorization(payer, nonce, abi.encodePacked(r, s, v));
    }

    /// @dev Revoking a leaked signature is exactly what a holder needs during an
    ///      incident, so it is deliberately reachable while paused.
    function test_cancel_still_works_while_paused() public {
        bytes32 nonce = keccak256("order-1");
        bytes memory cancelSig = signTyped(
            token,
            payerKey,
            keccak256(abi.encode(token.CANCEL_AUTHORIZATION_TYPEHASH(), payer, nonce))
        );

        vm.prank(admin);
        token.pause();

        vm.prank(facilitator);
        token.cancelAuthorization(payer, nonce, cancelSig);
        assertTrue(token.authorizationState(payer, nonce));
    }

    // ---------------------------------------------------------------
    // Smart accounts
    // ---------------------------------------------------------------

    /// @dev A passkey account cannot be verified with ecrecover; this is the
    ///      case SignatureChecker exists for.
    function test_erc1271_smart_account_can_authorize() public {
        MockSmartAccount account = new MockSmartAccount(payer);

        vm.prank(minter);
        token.mint(address(account), 100 * UNIT);

        bytes32 nonce = keccak256("order-1");
        bytes memory sig = _signAuth(
            token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(),
            payerKey,
            address(account),
            shop,
            50 * UNIT,
            0,
            _future(),
            nonce
        );

        vm.prank(facilitator);
        token.transferWithAuthorization(address(account), shop, 50 * UNIT, 0, _future(), nonce, sig);

        assertEq(token.balanceOf(shop), 50 * UNIT);
    }

    // ---------------------------------------------------------------
    // Interaction with compliance modules
    // ---------------------------------------------------------------

    /// @dev The modules gate `_update`, so a signature path cannot route around
    ///      them. This is the property that makes adding a payment module safe.
    function test_blacklist_and_pause_still_apply_to_signature_transfers() public {
        bytes32 nonce = keccak256("order-1");
        bytes memory sig = _signAuth(
            token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(),
            payerKey,
            payer,
            shop,
            UNIT,
            0,
            _future(),
            nonce
        );

        vm.prank(admin);
        token.blacklist(payer);

        vm.prank(facilitator);
        vm.expectRevert(abi.encodeWithSelector(Blacklist.AccountBlacklisted.selector, payer));
        token.transferWithAuthorization(payer, shop, UNIT, 0, _future(), nonce, sig);

        vm.startPrank(admin);
        token.unBlacklist(payer);
        token.pause();
        vm.stopPrank();

        vm.prank(facilitator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.transferWithAuthorization(payer, shop, UNIT, 0, _future(), nonce, sig);
    }

    // ---------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------

    function _future() private view returns (uint256) {
        return block.timestamp + 1 hours;
    }

    /// @dev The one place this suite spells out the authorization field order.
    function _authHash(
        bytes32 typehash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(typehash, from, to, value, validAfter, validBefore, nonce));
    }

    /// @dev Split form, for the entry points the EIP defines.
    function _signAuthVRS(
        bytes32 typehash,
        uint256 key,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) private view returns (uint8 v, bytes32 r, bytes32 s) {
        return signTypedVRS(
            token, key, _authHash(typehash, from, to, value, validAfter, validBefore, nonce)
        );
    }

    /// @dev Packed form, for the ERC-1271-capable entry points.
    function _signAuth(
        bytes32 typehash,
        uint256 key,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) private view returns (bytes memory) {
        return signTyped(
            token, key, _authHash(typehash, from, to, value, validAfter, validBefore, nonce)
        );
    }
}
