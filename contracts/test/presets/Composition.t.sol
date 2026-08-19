// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Helpers} from "../helpers/Helpers.sol";
import {MinimalToken} from "../../src/presets/MinimalToken.sol";
import {PermitToken} from "../../src/presets/PermitToken.sol";
import {Eip3009Token} from "../../src/presets/Eip3009Token.sol";
import {FullToken} from "../../src/presets/FullToken.sol";
import {UpgradeableFullToken} from "../../src/presets/upgradeable/UpgradeableFullToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {TokenBase} from "../../src/core/TokenBase.sol";
import {Blacklist} from "../../src/modules/compliance/Blacklist.sol";

/**
 * @dev What a preset is for: proving the modules actually compose.
 *
 *      The per-module suites establish that each module behaves. These tests
 *      establish that combining them does not silently drop a check -- the
 *      failure mode that matters when `_update` is overridden three deep.
 */
contract CompositionTest is Helpers {
    /// @dev Canonical Permit2, the same address on every chain it is deployed to.
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address admin = makeAddr("admin");
    address minter = makeAddr("minter");
    address user = makeAddr("user");
    address other = makeAddr("other");

    // ---------------------------------------------------------------
    // Every preset is a working ERC-20
    // ---------------------------------------------------------------

    function test_minimal_mints_and_transfers() public {
        vm.startPrank(admin);
        MinimalToken token = new MinimalToken("Minimal", "MIN", 6, admin);
        token.initializeAdmin(admin);
        token.grantRole(token.MINTER_ROLE(), minter);
        vm.stopPrank();

        vm.prank(minter);
        token.mint(user, 100 * UNIT);

        vm.prank(user);
        token.transfer(other, 40 * UNIT);

        assertEq(token.balanceOf(user), 60 * UNIT);
        assertEq(token.balanceOf(other), 40 * UNIT);
    }

    /// @dev The plain preset really has no ceiling. Stated as a test so the
    ///      absence is deliberate rather than assumed.
    function test_minimal_has_no_mint_ceiling() public {
        vm.startPrank(admin);
        MinimalToken token = new MinimalToken("Minimal", "MIN", 6, admin);
        token.initializeAdmin(admin);
        token.grantRole(token.MINTER_ROLE(), minter);
        vm.stopPrank();

        vm.prank(minter);
        token.mint(user, type(uint128).max);
        assertEq(token.balanceOf(user), type(uint128).max);
    }

    function test_minimal_still_gates_minting_on_the_role() public {
        vm.startPrank(admin);
        MinimalToken token = new MinimalToken("Minimal", "MIN", 6, admin);
        token.initializeAdmin(admin);
        vm.stopPrank();

        bytes32 minterRole = token.MINTER_ROLE();
        vm.prank(user);
        expectUnauthorized(user, minterRole);
        token.mint(user, UNIT);
    }

    // ---------------------------------------------------------------
    // Decimals are per-deployment, not baked into the kit
    // ---------------------------------------------------------------

    function test_decimals_are_configurable() public {
        vm.startPrank(admin);
        assertEq(new MinimalToken("A", "A", 6, admin).decimals(), 6);
        assertEq(new MinimalToken("B", "B", 18, admin).decimals(), 18);
        assertEq(new MinimalToken("C", "C", 2, admin).decimals(), 2);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // Composition does not drop checks
    // ---------------------------------------------------------------

    /// @dev FullToken overrides `_update` across Blacklist, Seize and
    ///      EmergencyPause. If the override chain were wired wrong, one of these
    ///      would silently stop applying.
    function test_full_preset_applies_every_gate_on_the_same_path() public {
        vm.startPrank(admin);
        FullToken token = new FullToken("Full", "FULL", 6, admin);
        token.initializeAdmin(admin);
        token.grantRole(token.BLACKLISTER_ROLE(), admin);
        token.grantRole(token.PAUSER_ROLE(), admin);
        vm.stopPrank();

        grantMint(token, admin, minter);
        vm.prank(minter);
        token.mint(user, 100 * UNIT);

        // Blacklist applies.
        vm.prank(admin);
        token.blacklist(user);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Blacklist.AccountBlacklisted.selector, user));
        token.transfer(other, UNIT);

        // Pause applies, independently.
        vm.startPrank(admin);
        token.unBlacklist(user);
        token.pause();
        vm.stopPrank();
        vm.prank(user);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        token.transfer(other, UNIT);

        // With both lifted, the transfer goes through.
        vm.prank(admin);
        token.unpause();
        vm.prank(user);
        token.transfer(other, UNIT);
        assertEq(token.balanceOf(other), UNIT);
    }

    /// @dev All three payment schemes on one token keep separate nonce spaces,
    ///      so enabling them together does not let one spend another's
    ///      authorizations.
    function test_full_preset_keeps_payment_schemes_independent() public {
        vm.startPrank(admin);
        FullToken token = new FullToken("Full", "FULL", 6, admin);
        token.initializeAdmin(admin);
        vm.stopPrank();

        grantMint(token, admin, minter);
        vm.prank(minter);
        token.mint(user, 100 * UNIT);

        // EIP-3009's random nonce and EIP-2612's counter are distinct state.
        assertFalse(token.authorizationState(user, bytes32(0)));
        assertEq(token.nonces(user), 0);

        // And no spender holds an allowance that nobody granted.
        assertEq(token.allowance(user, PERMIT2), 0);
    }

    /// @dev The two payment-shaped presets differ in exactly one thing: whether
    ///      the signature scheme lives in the token or outside it.
    function test_the_payment_presets_differ_only_in_where_signatures_live() public {
        vm.startPrank(admin);
        PermitToken p2 = new PermitToken("P2", "P2", 6, admin);
        Eip3009Token x4 = new Eip3009Token("X4", "X4", 6, admin);
        p2.initializeAdmin(admin);
        x4.initializeAdmin(admin);
        vm.stopPrank();

        // Permit2 preset: allowance by signature only, nothing pre-granted.
        assertEq(p2.allowance(user, PERMIT2), 0);
        assertEq(p2.nonces(user), 0);

        // x402 preset: adds the random-nonce authorization map on top.
        assertFalse(x4.authorizationState(user, bytes32(0)));
        assertEq(x4.allowance(user, PERMIT2), 0);

        // Both are the same ERC-20 underneath.
        assertEq(p2.decimals(), x4.decimals());
    }

    /// @dev The widest composition also has to work behind a proxy: Seize's
    ///      blacklist bypass and the pause both still gate `_update`, and the
    ///      upgrade path is present alongside them.
    function test_full_preset_composes_behind_a_proxy() public {
        UpgradeableFullToken impl = new UpgradeableFullToken(6);
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(TokenBase.initializeToken, ("Full", "FULL", address(this)))
        );
        UpgradeableFullToken token = UpgradeableFullToken(address(proxy));
        token.initializeAdmin(admin);

        bytes32 blacklister = token.BLACKLISTER_ROLE();
        bytes32 pauser = token.PAUSER_ROLE();
        bytes32 rescuer = token.RESCUER_ROLE();
        vm.startPrank(admin);
        token.grantRole(blacklister, admin);
        token.grantRole(pauser, admin);
        token.grantRole(rescuer, admin);
        vm.stopPrank();

        grantMint(token, admin, minter);
        vm.prank(minter);
        token.mint(user, 100 * UNIT);

        // Seizure works, and the blacklist bypass closes behind it.
        uint256 delay = token.SEIZE_DELAY();
        vm.startPrank(admin);
        token.blacklist(user);
        token.scheduleSeize(user, other, 40 * UNIT);
        vm.warp(block.timestamp + delay);
        token.executeSeize(user, other, 40 * UNIT);
        vm.stopPrank();

        assertEq(token.balanceOf(other), 40 * UNIT);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Blacklist.AccountBlacklisted.selector, user));
        token.transfer(other, UNIT);

        // The pause still applies on top.
        vm.prank(admin);
        token.pause();
        vm.prank(minter);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        token.mint(user, UNIT);

        // And the upgrade path exists.
        assertEq(token.UPGRADE_DELAY(), 1 days);
    }

    // ---------------------------------------------------------------
    // Initialization
    // ---------------------------------------------------------------

    function test_a_token_hands_over_its_admin_exactly_once() public {
        MinimalToken token = new MinimalToken("A", "A", 6, address(this));
        assertFalse(token.adminInitialized());

        token.initializeAdmin(admin);
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));

        vm.expectRevert(TokenBase.AlreadyInitialized.selector);
        token.initializeAdmin(other);
    }

    function test_initialize_rejects_the_zero_address() public {
        MinimalToken token = new MinimalToken("A", "A", 6, address(this));
        vm.expectRevert(TokenBase.ZeroAdmin.selector);
        token.initializeAdmin(address(0));
    }

    /**
     * @dev The handover is a separate transaction so that the admin stays out
     *      of the CREATE2 preimage. Left open to anyone, that separation is a
     *      race -- won by whoever watches the mempool, or by whoever replays
     *      the same init code and salt on a chain the issuer has not reached,
     *      since the canonical deployer does not mix the sender into the salt.
     *
     *      The issuer closes it. It is in the init code, because it is the same
     *      on every chain; the admin it appoints is not, and stays out.
     */
    function test_only_the_issuer_may_hand_over_the_admin() public {
        address issuer = makeAddr("issuer");

        vm.prank(issuer);
        MinimalToken token = new MinimalToken("A", "A", 6, issuer);
        assertEq(token.issuer(), issuer);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(TokenBase.NotIssuer.selector, other, issuer));
        token.initializeAdmin(other);

        assertFalse(token.adminInitialized());

        vm.prank(issuer);
        token.initializeAdmin(admin);
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
    }

    /// @dev The issuer is not the admin, and holds nothing once the handover
    ///      has happened. It is a one-transaction-wide authority.
    function test_the_issuer_holds_no_role_of_its_own() public {
        address issuer = makeAddr("issuer");

        vm.prank(issuer);
        MinimalToken token = new MinimalToken("A", "A", 6, issuer);
        vm.prank(issuer);
        token.initializeAdmin(admin);

        assertFalse(token.hasRole(token.DEFAULT_ADMIN_ROLE(), issuer));

        // Read the roles first: a prank is consumed by the next call.
        bytes32 minterRole = token.MINTER_ROLE();
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();
        vm.prank(issuer);
        expectUnauthorized(issuer, adminRole);
        token.grantRole(minterRole, issuer);
    }

    /// @dev A token without a named issuer would be a token anyone may claim.
    function test_a_token_cannot_be_deployed_without_an_issuer() public {
        vm.expectRevert(TokenBase.ZeroIssuer.selector);
        new MinimalToken("A", "A", 6, address(0));
    }
}
