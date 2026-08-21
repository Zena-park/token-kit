// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Helpers} from "../helpers/Helpers.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {UpgradeableEip3009Token} from "../../src/presets/upgradeable/UpgradeableEip3009Token.sol";
import {Eip3009Token} from "../../src/presets/Eip3009Token.sol";
import {UpgradeControl} from "../../src/modules/UpgradeControl.sol";
import {TokenBase} from "../../src/core/TokenBase.sol";
import {MinterControl} from "../../src/modules/issuance/MinterControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @dev A stand-in for a later version. Adds a function the first one lacks so
///      an upgrade is observable, and changes nothing about storage.
contract UpgradeableEip3009TokenV2 is UpgradeableEip3009Token {
    constructor(uint8 d) UpgradeableEip3009Token(d) {}

    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev An implementation that reaches for this kit's own identity initializer
///      through a reinitializer, which is how a later version would otherwise
///      get a second chance at it.
contract IdentityRewriter is UpgradeableEip3009Token {
    constructor(uint8 d) UpgradeableEip3009Token(d) {}

    function rewriteIdentity(string memory n, string memory s) external reinitializer(2) {
        __TokenBase_init(n, s, msg.sender);
    }
}

/// @dev An implementation that re-runs the standard ERC-20 initializer -- the
///      ordinary way an upgrade would touch the token's identity by accident.
contract ReinitializingToken is UpgradeableEip3009Token {
    constructor(uint8 d) UpgradeableEip3009Token(d) {}

    function reinit(string memory n, string memory s) external reinitializer(2) {
        __ERC20_init(n, s);
    }
}

contract UpgradeableTest is Helpers {
    UpgradeableEip3009Token token;
    address implementation;

    address admin = makeAddr("admin");
    address guardian = makeAddr("guardian");
    address minter = makeAddr("minter");
    address holder = makeAddr("holder");
    address attacker = makeAddr("attacker");

    function setUp() public {
        implementation = address(new UpgradeableEip3009Token(6));

        // The proxy constructor runs the initializer, so there is no window in
        // which an uninitialized token is sitting on chain.
        ERC1967Proxy proxy = new ERC1967Proxy(
            implementation,
            abi.encodeCall(TokenBase.initializeToken, ("Test Token", "TEST", address(this)))
        );
        token = UpgradeableEip3009Token(address(proxy));
        token.initializeAdmin(admin);

        // Read the role first: a prank is consumed by the next call, and every
        // read here goes through the proxy as a real call.
        bytes32 guardianRole = token.GUARDIAN_ROLE();
        vm.prank(admin);
        token.grantRole(guardianRole, guardian);

        grantMint(token, admin, minter);
        vm.prank(minter);
        token.mint(holder, 1000 * UNIT);
    }

    // ---------------------------------------------------------------
    // The proxy behaves like the token
    // ---------------------------------------------------------------

    function test_proxy_carries_the_token_state() public view {
        assertEq(token.name(), "Test Token");
        assertEq(token.symbol(), "TEST");
        assertEq(token.decimals(), 6);
        assertEq(token.balanceOf(holder), 1000 * UNIT);
    }

    function test_implementation_slot_points_at_the_implementation() public view {
        bytes32 slot = vm.load(address(token), ERC1967Utils.IMPLEMENTATION_SLOT);
        assertEq(address(uint160(uint256(slot))), implementation);
    }

    /// @dev A bare implementation must not be usable as a token in its own right.
    function test_the_implementation_itself_cannot_be_initialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        TokenBase(implementation).initializeToken("Hijack", "HJK", address(this));
    }

    /**
     * @dev `_disableInitializers` covers the initializers, but the admin
     *      handover is not one -- it has its own flag, because it is meant to
     *      run after initialization. The issuer check is what closes it here
     *      too: an implementation is never initialized, so it names no issuer,
     *      and no caller can match one.
     *
     *      Nothing reachable on a bare implementation moves a real balance
     *      today. It would the moment one gained a `delegatecall`, and an
     *      implementation carrying an owner is a finding an auditor has to
     *      chase down every time.
     */
    function test_the_implementation_cannot_be_given_an_owner() public {
        assertEq(TokenBase(implementation).issuer(), address(0));

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(TokenBase.NotIssuer.selector, attacker, address(0)));
        TokenBase(implementation).initializeAdmin(attacker);

        assertFalse(IAccessControl(implementation).hasRole(bytes32(0), attacker));
    }

    /**
     * @dev What matures has to be what was announced. `upgradeToAndCall`
     *      delegatecalls into the new implementation with `data` before it
     *      returns, so `data` is code running against this token's storage and
     *      this token's authority -- an arbitrary state change, atomic with the
     *      swap. Scheduling the address alone would show an observer a
     *      candidate they could read, then hand them a payload they had never
     *      seen.
     */
    function test_an_unannounced_payload_cannot_ride_along_with_an_upgrade() public {
        address v2 = address(new UpgradeableEip3009TokenV2(6));
        bytes memory payload = abi.encodeCall(IAccessControl.grantRole, (bytes32(0), attacker));
        bytes32 announced = token.upgradeId(v2, "");
        bytes32 actual = token.upgradeId(v2, payload);

        vm.prank(admin);
        token.scheduleUpgrade(v2, "");
        vm.warp(block.timestamp + token.UPGRADE_DELAY());

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpgradeControl.NoScheduledUpgrade.selector, actual));
        token.upgradeToAndCall(v2, payload);

        assertFalse(token.hasRole(bytes32(0), attacker));

        // The announced upgrade is untouched and still applies.
        assertEq(token.scheduledUpgrade(announced), uint48(block.timestamp));
        vm.prank(admin);
        token.upgradeToAndCall(v2, "");
        assertEq(UpgradeableEip3009TokenV2(address(token)).version(), 2);
    }

    // ---------------------------------------------------------------
    // The upgrade is scheduled, delayed and vetoable
    // ---------------------------------------------------------------

    function test_upgrade_requires_a_schedule() public {
        address v2 = address(new UpgradeableEip3009TokenV2(6));
        bytes32 id = token.upgradeId(v2, "");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpgradeControl.NoScheduledUpgrade.selector, id));
        token.upgradeToAndCall(v2, "");
    }

    function test_upgrade_waits_out_the_delay_then_applies() public {
        address v2 = address(new UpgradeableEip3009TokenV2(6));
        uint256 delay = token.UPGRADE_DELAY();

        vm.prank(admin);
        token.scheduleUpgrade(v2, "");

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                UpgradeControl.UpgradeNotReady.selector, uint48(block.timestamp + delay)
            )
        );
        token.upgradeToAndCall(v2, "");

        vm.warp(block.timestamp + delay);
        vm.prank(admin);
        token.upgradeToAndCall(v2, "");

        assertEq(UpgradeableEip3009TokenV2(address(token)).version(), 2);
    }

    /// @dev The property the delay exists for: balances and roles survive, so a
    ///      holder who watched the announcement is looking at the same token.
    function test_state_survives_the_upgrade() public {
        address v2 = address(new UpgradeableEip3009TokenV2(6));

        vm.prank(admin);
        token.scheduleUpgrade(v2, "");
        vm.warp(block.timestamp + token.UPGRADE_DELAY());
        vm.prank(admin);
        token.upgradeToAndCall(v2, "");

        assertEq(token.balanceOf(holder), 1000 * UNIT);
        assertEq(token.name(), "Test Token");
        assertEq(token.decimals(), 6);
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(token.isMinter(minter));
        assertEq(token.totalSupply(), 1000 * UNIT);
    }

    /// @dev Decimals silently reprice every balance and the name is part of the
    ///      EIP-712 domain, so an upgrade that changed either would invalidate
    ///      outstanding signatures. A routine upgrade must leave both alone.
    function test_identity_survives_an_upgrade() public {
        bytes32 identityBefore = token.identityHash();
        bytes32 domainBefore = token.domainSeparator();
        address v2 = address(new UpgradeableEip3009TokenV2(6));

        vm.prank(admin);
        token.scheduleUpgrade(v2, "");
        vm.warp(block.timestamp + token.UPGRADE_DELAY());
        vm.prank(admin);
        token.upgradeToAndCall(v2, "");

        assertEq(token.identityHash(), identityBefore);
        assertEq(token.domainSeparator(), domainBefore);
        assertEq(token.name(), "Test Token");
        assertEq(token.symbol(), "TEST");
        assertEq(token.decimals(), 6);
    }

    /// @dev Identity is read from this kit's own namespace, so re-running the
    ///      standard ERC-20 initializer writes slots nothing reads. It does not
    ///      make identity unchangeable -- an implementation that targeted the
    ///      namespace directly still could -- but it stops the change that would
    ///      otherwise happen without anyone writing it down.
    function test_rerunning_the_erc20_initializer_does_not_rewrite_identity() public {
        bytes32 identityBefore = token.identityHash();
        address hostile = address(new ReinitializingToken(6));

        bytes memory data = abi.encodeCall(ReinitializingToken.reinit, ("Hijacked", "HJK"));

        vm.prank(admin);
        token.scheduleUpgrade(hostile, data);
        vm.warp(block.timestamp + token.UPGRADE_DELAY());
        vm.prank(admin);
        token.upgradeToAndCall(hostile, data);

        assertEq(token.name(), "Test Token");
        assertEq(token.symbol(), "TEST");
        assertEq(token.identityHash(), identityBefore);
    }

    /// @dev Decimals is an immutable in the implementation, so there is no slot
    ///      for an upgrade to rewrite. Changing it would take a new
    ///      implementation deployed with a different constructor argument.
    function test_decimals_has_no_storage_to_rewrite() public {
        // A later version built with different decimals is a different
        // implementation, and the difference is in its constructor arguments.
        address wrong = address(new UpgradeableEip3009TokenV2(18));
        assertEq(UpgradeableEip3009TokenV2(wrong).decimals(), 18);

        // Upgrading to the correctly built one leaves decimals alone.
        address v2 = address(new UpgradeableEip3009TokenV2(6));
        vm.prank(admin);
        token.scheduleUpgrade(v2, "");
        vm.warp(block.timestamp + token.UPGRADE_DELAY());
        vm.prank(admin);
        token.upgradeToAndCall(v2, "");

        assertEq(token.decimals(), 6);
    }

    /// @dev One implementation, many proxies: each token has its own storage
    ///      and admin, but they all read decimals out of the shared code. Two
    ///      tokens that disagree on decimals therefore cannot share one.
    function test_proxies_share_an_implementation_but_not_state() public {
        ERC1967Proxy second = new ERC1967Proxy(
            implementation,
            abi.encodeCall(TokenBase.initializeToken, ("Second", "SEC", address(this)))
        );
        UpgradeableEip3009Token other = UpgradeableEip3009Token(address(second));
        other.initializeAdmin(attacker);

        // Separate identity, separate balances, separate admin.
        assertEq(other.name(), "Second");
        assertEq(other.balanceOf(holder), 0);
        assertEq(token.balanceOf(holder), 1000 * UNIT);
        assertTrue(other.hasRole(other.DEFAULT_ADMIN_ROLE(), attacker));
        assertFalse(token.hasRole(token.DEFAULT_ADMIN_ROLE(), attacker));

        // Shared decimals, because it comes from the implementation's code.
        assertEq(other.decimals(), token.decimals());

        // A token wanting different decimals needs its own implementation.
        address eighteen = address(new UpgradeableEip3009Token(18));
        assertTrue(eighteen != implementation);
        assertEq(UpgradeableEip3009Token(eighteen).decimals(), 18);
    }

    /// @dev The EIP-712 domain name and `name()` read the same slot, so a token
    ///      cannot report one name while verifying signatures against another.
    function test_the_domain_name_tracks_the_token_name() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(token.name())),
                keccak256(bytes("1")),
                block.chainid,
                address(token)
            )
        );
        assertEq(token.domainSeparator(), expected);
    }

    function test_identity_cannot_be_initialized_again() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        token.initializeToken("Hijacked", "HJK", address(this));
    }

    /// @dev A reinitializer is the one route that gets past `initializer`, so
    ///      identity setup refuses on its own terms as well.
    function test_a_reinitializer_cannot_reset_identity() public {
        address hostile = address(new IdentityRewriter(6));

        bytes memory data = abi.encodeCall(IdentityRewriter.rewriteIdentity, ("Hijacked", "HJK"));

        vm.prank(admin);
        token.scheduleUpgrade(hostile, data);
        vm.warp(block.timestamp + token.UPGRADE_DELAY());

        vm.prank(admin);
        vm.expectRevert(TokenBase.AlreadyInitialized.selector);
        token.upgradeToAndCall(hostile, data);

        assertEq(token.name(), "Test Token");
    }

    function test_guardian_vetoes_a_scheduled_upgrade() public {
        address v2 = address(new UpgradeableEip3009TokenV2(6));
        uint256 delay = token.UPGRADE_DELAY();
        // Read the id first: a prank is consumed by the next call, and this is
        // a real call through the proxy.
        bytes32 id = token.upgradeId(v2, "");

        vm.prank(admin);
        token.scheduleUpgrade(v2, "");

        vm.prank(guardian);
        token.cancelUpgrade(id);

        vm.warp(block.timestamp + delay);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpgradeControl.NoScheduledUpgrade.selector, id));
        token.upgradeToAndCall(v2, "");
    }

    /// @dev One announcement buys one upgrade. Rolling back to a previous
    ///      implementation has to be announced and waited out like any other.
    function test_a_schedule_is_consumed_by_its_upgrade() public {
        address v2 = address(new UpgradeableEip3009TokenV2(6));
        uint256 delay = token.UPGRADE_DELAY();
        bytes32 id = token.upgradeId(v2, "");

        vm.prank(admin);
        token.scheduleUpgrade(v2, "");
        vm.warp(block.timestamp + delay);

        vm.startPrank(admin);
        token.upgradeToAndCall(v2, "");

        vm.expectRevert(abi.encodeWithSelector(UpgradeControl.NoScheduledUpgrade.selector, id));
        token.upgradeToAndCall(v2, "");
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // Authority
    // ---------------------------------------------------------------

    function test_only_admin_may_schedule_or_apply() public {
        address v2 = address(new UpgradeableEip3009TokenV2(6));
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();

        vm.prank(attacker);
        expectUnauthorized(attacker, adminRole);
        token.scheduleUpgrade(v2, "");

        vm.prank(admin);
        token.scheduleUpgrade(v2, "");
        vm.warp(block.timestamp + token.UPGRADE_DELAY());

        vm.prank(attacker);
        expectUnauthorized(attacker, adminRole);
        token.upgradeToAndCall(v2, "");
    }

    /// @dev The Guardian blocks and creates nothing, here as everywhere else.
    function test_guardian_cannot_schedule_an_upgrade() public {
        address v2 = address(new UpgradeableEip3009TokenV2(6));
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();

        vm.prank(guardian);
        expectUnauthorized(guardian, adminRole);
        token.scheduleUpgrade(v2, "");
    }

    // ---------------------------------------------------------------
    // Bricking
    // ---------------------------------------------------------------

    /// @dev UUPS puts the upgrade logic in the implementation, so upgrading to
    ///      something that lacks it would freeze the proxy forever. The
    ///      ERC-1822 check is what stops that.
    function test_cannot_upgrade_to_a_non_upgradeable_implementation() public {
        address notUups = address(new Eip3009Token("Immutable", "IMM", 6, address(this)));
        uint256 delay = token.UPGRADE_DELAY();

        vm.prank(admin);
        token.scheduleUpgrade(notUups, "");
        vm.warp(block.timestamp + delay);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ERC1967Utils.ERC1967InvalidImplementation.selector, notUups)
        );
        token.upgradeToAndCall(notUups, "");

        // Still working, still on the original implementation.
        assertEq(token.balanceOf(holder), 1000 * UNIT);
    }

    // ---------------------------------------------------------------
    // Interaction with the rest of the kit
    // ---------------------------------------------------------------

    /// @dev The upgrade path does not bypass the issuance ceiling while it is
    ///      pending -- only a completed upgrade could, which is the point of
    ///      making it visible first.
    function test_a_pending_upgrade_does_not_lift_the_mint_ceiling() public {
        address v2 = address(new UpgradeableEip3009TokenV2(6));

        uint256 remaining = token.minterAllowance(minter);

        vm.prank(admin);
        token.scheduleUpgrade(v2, "");

        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(
                MinterControl.MintAllowanceExceeded.selector, type(uint256).max, remaining
            )
        );
        token.mint(holder, type(uint256).max);
    }

    /// @dev The delay exists so holders and the Guardian can read the candidate
    ///      and react. A schedule with no end turns that one reading into
    ///      standing permission, against a token that has since changed and an
    ///      audience that has stopped watching. Re-announcing costs a day.
    function test_a_matured_upgrade_expires() public {
        address v2 = address(new UpgradeableEip3009TokenV2(6));
        bytes32 id = token.upgradeId(v2, "");

        vm.prank(admin);
        token.scheduleUpgrade(v2, "");
        uint48 eta = token.scheduledUpgrade(id);

        vm.warp(uint256(eta) + token.UPGRADE_WINDOW() + 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpgradeControl.UpgradeExpired.selector, eta));
        token.upgradeToAndCall(v2, "");

        // The token is untouched and a fresh announcement still works.
        assertEq(token.balanceOf(holder), 1000 * UNIT);
        vm.prank(admin);
        token.scheduleUpgrade(v2, "");
        vm.warp(block.timestamp + token.UPGRADE_DELAY());
        vm.prank(admin);
        token.upgradeToAndCall(v2, "");
        assertEq(UpgradeableEip3009TokenV2(address(token)).version(), 2);
    }

    // ---------------------------------------------------------------
    // Call context and value
    // ---------------------------------------------------------------

    /// @dev The bare implementation cannot be upgraded in place: its schedule
    ///      is empty and, having no admin, can never be filled, so the
    ///      override refuses before OpenZeppelin's `onlyProxy` check would.
    function test_the_implementation_refuses_an_upgrade_called_directly() public {
        address v2 = address(new UpgradeableEip3009TokenV2(6));
        bytes32 id = token.upgradeId(v2, "");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpgradeControl.NoScheduledUpgrade.selector, id));
        UpgradeControl(implementation).upgradeToAndCall(v2, "");
    }

    function test_an_upgrade_refuses_ether() public {
        address v2 = address(new UpgradeableEip3009TokenV2(6));

        vm.prank(admin);
        token.scheduleUpgrade(v2, "");
        vm.warp(block.timestamp + token.UPGRADE_DELAY());

        vm.deal(admin, 1 ether);
        vm.prank(admin);
        vm.expectRevert(UpgradeControl.ValueNotAccepted.selector);
        token.upgradeToAndCall{value: 1 wei}(v2, "");
    }

    function test_cancelling_an_unknown_upgrade_reverts() public {
        bytes32 id = keccak256("nothing");
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(UpgradeControl.NoScheduledUpgrade.selector, id));
        token.cancelUpgrade(id);
    }
}
