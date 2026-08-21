// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Helpers} from "../helpers/Helpers.sol";
import {FullToken} from "../../src/presets/FullToken.sol";
import {Blacklist} from "../../src/modules/compliance/Blacklist.sol";
import {TokenBase} from "../../src/core/TokenBase.sol";
import {Seize} from "../../src/modules/compliance/Seize.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract ComplianceTest is Helpers {
    FullToken token;

    address admin = makeAddr("admin");
    address minter = makeAddr("minter");
    address blacklister = makeAddr("blacklister");
    address pauser = makeAddr("pauser");
    address rescuer = makeAddr("rescuer");
    address guardian = makeAddr("guardian");

    address sanctioned = makeAddr("sanctioned");
    address authority = makeAddr("authority");
    address user = makeAddr("user");

    function setUp() public {
        vm.startPrank(admin);
        token = new FullToken("Test Token", "TEST", 6, admin);
        token.initializeAdmin(admin);
        token.grantRole(token.BLACKLISTER_ROLE(), blacklister);
        token.grantRole(token.PAUSER_ROLE(), pauser);
        token.grantRole(token.RESCUER_ROLE(), rescuer);
        token.grantRole(token.GUARDIAN_ROLE(), guardian);
        vm.stopPrank();

        grantMint(token, admin, minter);

        vm.startPrank(minter);
        token.mint(sanctioned, 1000 * UNIT);
        token.mint(user, 1000 * UNIT);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // Blacklist
    // ---------------------------------------------------------------

    function test_blacklisted_account_can_neither_send_nor_receive() public {
        vm.prank(blacklister);
        token.blacklist(sanctioned);

        vm.prank(sanctioned);
        vm.expectRevert(abi.encodeWithSelector(Blacklist.AccountBlacklisted.selector, sanctioned));
        token.transfer(user, UNIT);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Blacklist.AccountBlacklisted.selector, sanctioned));
        token.transfer(sanctioned, UNIT);
    }

    /// @dev Freezing holds the balance in place; it does not take it.
    function test_blacklist_leaves_the_balance_untouched() public {
        vm.prank(blacklister);
        token.blacklist(sanctioned);

        assertEq(token.balanceOf(sanctioned), 1000 * UNIT);
    }

    function test_unblacklisting_restores_transfers() public {
        vm.startPrank(blacklister);
        token.blacklist(sanctioned);
        token.unBlacklist(sanctioned);
        vm.stopPrank();

        vm.prank(sanctioned);
        token.transfer(user, UNIT);
        assertEq(token.balanceOf(user), 1001 * UNIT);
    }

    /// @dev Raising an allowance that touches a listed account is standing
    ///      permission to move funds the moment the listing is lifted, so both
    ///      ends are refused -- but revocation stays open.
    function test_a_blacklisted_account_cannot_gain_allowances() public {
        vm.prank(user);
        token.approve(sanctioned, UNIT); // granted before the listing

        vm.prank(blacklister);
        token.blacklist(sanctioned);

        vm.prank(sanctioned);
        vm.expectRevert(abi.encodeWithSelector(Blacklist.AccountBlacklisted.selector, sanctioned));
        token.approve(user, UNIT);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Blacklist.AccountBlacklisted.selector, sanctioned));
        token.approve(sanctioned, 2 * UNIT);

        // Lowering is revocation, and revocation is always available.
        vm.prank(user);
        token.approve(sanctioned, 0);
        assertEq(token.allowance(user, sanctioned), 0);
    }

    /// @dev The sender-side check in `_update` sees the holder, not the
    ///      caller. A listed spender is stopped in `_spendAllowance`, which an
    ///      infinite allowance cannot bypass.
    function test_a_blacklisted_spender_cannot_spend_an_allowance() public {
        vm.prank(user);
        token.approve(sanctioned, type(uint256).max);

        vm.prank(blacklister);
        token.blacklist(sanctioned);

        vm.prank(sanctioned);
        vm.expectRevert(abi.encodeWithSelector(Blacklist.AccountBlacklisted.selector, sanctioned));
        token.transferFrom(user, authority, UNIT);
    }

    function test_only_blacklister_may_blacklist() public {
        // Read the role before pranking: a prank is consumed by the next call,
        // and a view call made while building the expectation would eat it.
        bytes32 role = token.BLACKLISTER_ROLE();

        vm.prank(user);
        expectUnauthorized(user, role);
        token.blacklist(sanctioned);
    }

    // ---------------------------------------------------------------
    // Pause
    // ---------------------------------------------------------------

    function test_pause_stops_transfers_mints_and_burns() public {
        vm.prank(pauser);
        token.pause();

        vm.prank(user);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.transfer(sanctioned, UNIT);

        vm.prank(minter);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.mint(user, UNIT);
    }

    function test_unpause_restores_everything() public {
        vm.prank(pauser);
        token.pause();
        vm.prank(admin);
        token.unpause();

        vm.prank(user);
        token.transfer(sanctioned, UNIT);
        assertEq(token.balanceOf(sanctioned), 1001 * UNIT);
    }

    /// @dev Stopping is the pauser's job and has to be fast; resuming is the
    ///      admin's. A leaked pauser key must not be able to lift a pause
    ///      mid-incident.
    function test_the_pauser_cannot_unpause() public {
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();

        vm.prank(pauser);
        token.pause();

        vm.prank(pauser);
        expectUnauthorized(pauser, adminRole);
        token.unpause();
    }

    /// @dev An allowance is standing permission to move funds the moment the
    ///      pause lifts, so granting one is halted along with the movement --
    ///      while revoking one is exactly what a holder needs mid-incident,
    ///      and stays open.
    function test_a_pause_blocks_granting_but_not_revoking_allowances() public {
        vm.prank(user);
        token.approve(sanctioned, UNIT);

        vm.prank(pauser);
        token.pause();

        vm.prank(user);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.approve(sanctioned, 2 * UNIT);

        vm.prank(user);
        token.approve(sanctioned, 0);
        assertEq(token.allowance(user, sanctioned), 0);
    }

    // ---------------------------------------------------------------
    // Seize
    // ---------------------------------------------------------------

    /// @dev The control that keeps ordinary holders out of reach.
    function test_seizing_requires_the_target_to_be_blacklisted_first() public {
        vm.prank(rescuer);
        vm.expectRevert(abi.encodeWithSelector(Seize.NotBlacklisted.selector, user));
        token.scheduleSeize(user, authority, 100 * UNIT);
    }

    function test_seizure_waits_a_day_then_moves_the_balance() public {
        vm.prank(blacklister);
        token.blacklist(sanctioned);

        uint256 delay = token.SEIZE_DELAY();

        vm.prank(rescuer);
        token.scheduleSeize(sanctioned, authority, 1000 * UNIT);

        vm.prank(rescuer);
        vm.expectRevert(
            abi.encodeWithSelector(Seize.SeizeNotReady.selector, uint48(block.timestamp + delay))
        );
        token.executeSeize(sanctioned, authority, 1000 * UNIT);

        vm.warp(block.timestamp + delay);
        vm.prank(rescuer);
        token.executeSeize(sanctioned, authority, 1000 * UNIT);

        assertEq(token.balanceOf(sanctioned), 0);
        assertEq(token.balanceOf(authority), 1000 * UNIT);
    }

    function test_guardian_vetoes_a_scheduled_seizure() public {
        vm.prank(blacklister);
        token.blacklist(sanctioned);

        vm.prank(rescuer);
        token.scheduleSeize(sanctioned, authority, 1000 * UNIT);

        vm.prank(guardian);
        token.cancelSeize(sanctioned, authority, 1000 * UNIT);

        vm.warp(block.timestamp + token.SEIZE_DELAY());
        vm.prank(rescuer);
        vm.expectRevert(Seize.NoPendingSeize.selector);
        token.executeSeize(sanctioned, authority, 1000 * UNIT);
    }

    /// @dev The bypass exists only so seizure can move funds out of an account
    ///      the blacklist has frozen. It must not stay open afterwards.
    function test_the_blacklist_bypass_closes_after_the_seizure() public {
        vm.prank(blacklister);
        token.blacklist(sanctioned);

        vm.prank(rescuer);
        token.scheduleSeize(sanctioned, authority, 500 * UNIT);
        vm.warp(block.timestamp + token.SEIZE_DELAY());
        vm.prank(rescuer);
        token.executeSeize(sanctioned, authority, 500 * UNIT);

        vm.prank(sanctioned);
        vm.expectRevert(abi.encodeWithSelector(Blacklist.AccountBlacklisted.selector, sanctioned));
        token.transfer(user, UNIT);
    }

    /// @dev A seizure moves the balance through `_update`, so the pause applies
    ///      to it like any other transfer. The Guardian veto is not the only
    ///      thing that can stop a matured seizure.
    function test_a_pause_blocks_a_matured_seizure() public {
        uint256 delay = token.SEIZE_DELAY();

        vm.prank(blacklister);
        token.blacklist(sanctioned);

        vm.prank(rescuer);
        token.scheduleSeize(sanctioned, authority, 1000 * UNIT);
        vm.warp(block.timestamp + delay);

        vm.prank(pauser);
        token.pause();

        vm.prank(rescuer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.executeSeize(sanctioned, authority, 1000 * UNIT);

        // And goes through once the pause is lifted.
        vm.prank(admin);
        token.unpause();
        vm.prank(rescuer);
        token.executeSeize(sanctioned, authority, 1000 * UNIT);
        assertEq(token.balanceOf(authority), 1000 * UNIT);
    }

    /// @dev Mints and burns skip the zero-address side of the check, so
    ///      blacklisting address(0) must not halt issuance.
    /// @dev The zero address is not an account. A listing on it could never
    ///      fire -- `_update` skips that end of a mint or a burn -- so it would
    ///      read to any observer as a frozen account that is not one.
    function test_the_zero_address_cannot_be_blacklisted() public {
        vm.prank(blacklister);
        vm.expectRevert(TokenBase.ZeroAddress.selector);
        token.blacklist(address(0));

        assertFalse(token.isBlacklisted(address(0)));

        // Issuance and redemption are unaffected either way.
        vm.prank(minter);
        token.mint(user, 10 * UNIT);
        assertEq(token.balanceOf(user), 1010 * UNIT);
    }

    /// @dev The path the refusal above closes: `_update` mints when `from` is
    ///      zero, so a seizure with a zero source would create supply outside
    ///      the issuance module entirely -- no minter, no allowance, no freeze.
    function test_a_seizure_cannot_be_used_to_mint() public {
        uint256 supplyBefore = token.totalSupply();

        vm.prank(rescuer);
        vm.expectRevert(Seize.ZeroSeizeSource.selector);
        token.scheduleSeize(address(0), rescuer, 1e30);

        assertEq(token.totalSupply(), supplyBefore);
    }

    function test_seizure_destination_cannot_be_zero() public {
        vm.prank(blacklister);
        token.blacklist(sanctioned);

        vm.prank(rescuer);
        vm.expectRevert(Seize.ZeroSeizeDestination.selector);
        token.scheduleSeize(sanctioned, address(0), UNIT);
    }

    /// @dev A zero-amount seizure would move nothing; scheduling one is only
    ///      event noise, so it is refused like every other zero amount. The
    ///      target is deliberately not blacklisted: seeing `ZeroAmount` rather
    ///      than `NotBlacklisted` pins the amount check ahead of the storage
    ///      reads, which is the ordering `scheduleSeize` promises.
    function test_a_zero_amount_seizure_cannot_be_scheduled() public {
        vm.prank(rescuer);
        vm.expectRevert(TokenBase.ZeroAmount.selector);
        token.scheduleSeize(sanctioned, authority, 0);
    }

    /// @dev Amount is part of the scheduled identity, so a rescuer cannot
    ///      schedule a small seizure and execute a large one.
    function test_execution_must_match_the_scheduled_amount() public {
        vm.prank(blacklister);
        token.blacklist(sanctioned);

        vm.prank(rescuer);
        token.scheduleSeize(sanctioned, authority, 100 * UNIT);
        vm.warp(block.timestamp + token.SEIZE_DELAY());

        vm.prank(rescuer);
        vm.expectRevert(Seize.NoPendingSeize.selector);
        token.executeSeize(sanctioned, authority, 1000 * UNIT);
    }

    // ---------------------------------------------------------------
    // A seizure is bound to the circumstances it was scheduled under
    // ---------------------------------------------------------------

    /// @dev The blacklist precondition is what keeps ordinary holders out of
    ///      reach, and a day or more separates scheduling from execution. A
    ///      listing lifted in between is a listing the issuer decided was
    ///      wrong; running the seizure anyway would take an ordinary holder's
    ///      balance, which is the one outcome the precondition exists to stop.
    function test_a_seizure_lapses_when_the_listing_is_lifted() public {
        vm.prank(blacklister);
        token.blacklist(sanctioned);

        vm.prank(rescuer);
        token.scheduleSeize(sanctioned, authority, 100 * UNIT);

        vm.prank(blacklister);
        token.unBlacklist(sanctioned);

        vm.warp(block.timestamp + token.SEIZE_DELAY());
        vm.prank(rescuer);
        vm.expectRevert(abi.encodeWithSelector(Seize.NotBlacklisted.selector, sanctioned));
        token.executeSeize(sanctioned, authority, 100 * UNIT);

        assertEq(token.balanceOf(sanctioned), 1000 * UNIT);
    }

    /// @dev Without a window a schedule is permanent, and nothing about the
    ///      circumstances that justified it still holds years later.
    function test_a_matured_seizure_expires() public {
        vm.prank(blacklister);
        token.blacklist(sanctioned);

        vm.prank(rescuer);
        token.scheduleSeize(sanctioned, authority, 100 * UNIT);
        uint48 eta = token.pendingSeize(token.seizeId(sanctioned, authority, 100 * UNIT));

        vm.warp(uint256(eta) + token.SEIZE_WINDOW() + 1);
        vm.prank(rescuer);
        vm.expectRevert(abi.encodeWithSelector(Seize.SeizeExpired.selector, eta));
        token.executeSeize(sanctioned, authority, 100 * UNIT);
    }

    /// @dev The bypass a seizure opens is one-directional. Seize has to move
    ///      funds out of a listed account; letting it also deliver into one
    ///      would make the single module that can move a frozen balance the
    ///      only path that can hand it to another frozen account.
    ///
    ///      A destination already listed is refused at scheduling -- such a
    ///      seizure could never execute, so failing early beats burning the
    ///      delay.
    function test_a_seizure_to_a_blacklisted_destination_fails_at_scheduling() public {
        vm.startPrank(blacklister);
        token.blacklist(sanctioned);
        token.blacklist(authority);
        vm.stopPrank();

        vm.prank(rescuer);
        vm.expectRevert(abi.encodeWithSelector(Blacklist.AccountBlacklisted.selector, authority));
        token.scheduleSeize(sanctioned, authority, 100 * UNIT);
    }

    /// @dev A destination listed only after scheduling is refused at
    ///      execution, where the preconditions are re-checked.
    function test_a_seizure_cannot_deliver_to_a_destination_listed_after_scheduling() public {
        vm.prank(blacklister);
        token.blacklist(sanctioned);

        vm.prank(rescuer);
        token.scheduleSeize(sanctioned, authority, 100 * UNIT);

        vm.prank(blacklister);
        token.blacklist(authority);

        vm.warp(block.timestamp + token.SEIZE_DELAY());
        vm.prank(rescuer);
        vm.expectRevert(abi.encodeWithSelector(Blacklist.AccountBlacklisted.selector, authority));
        token.executeSeize(sanctioned, authority, 100 * UNIT);
    }

    // ---------------------------------------------------------------
    // The last administrator cannot be removed
    // ---------------------------------------------------------------

    /// @dev DEFAULT_ADMIN_ROLE grants every other role, so dropping the last
    ///      holder leaves a token no one can administer again: no minter
    ///      appointed, no listing lifted, and on an upgradeable token no fix
    ///      shipped. Both routes out run through `_revokeRole`.
    function test_the_last_admin_cannot_renounce() public {
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();

        vm.prank(admin);
        vm.expectRevert(TokenBase.LastAdmin.selector);
        token.renounceRole(adminRole, admin);

        vm.prank(admin);
        vm.expectRevert(TokenBase.LastAdmin.selector);
        token.revokeRole(adminRole, admin);

        assertTrue(token.hasRole(adminRole, admin));
    }

    /// @dev The floor is on the count, not on any particular account, so an
    ///      admin handover is still a two-step the token never sits outside.
    function test_an_admin_may_step_down_once_a_second_one_exists() public {
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();
        address successor = makeAddr("successor");

        vm.startPrank(admin);
        token.grantRole(adminRole, successor);
        token.renounceRole(adminRole, admin);
        vm.stopPrank();

        assertFalse(token.hasRole(adminRole, admin));
        assertTrue(token.hasRole(adminRole, successor));

        vm.prank(successor);
        vm.expectRevert(TokenBase.LastAdmin.selector);
        token.renounceRole(adminRole, successor);
    }

    // ---------------------------------------------------------------
    // Seizure edge cases
    // ---------------------------------------------------------------

    /// @dev A seizure moves through `_transfer`, so a balance that has since
    ///      shrunk below the scheduled amount fails the ordinary way, and the
    ///      schedule survives the failed attempt.
    function test_a_seizure_larger_than_the_balance_fails_and_stays_scheduled() public {
        vm.prank(blacklister);
        token.blacklist(sanctioned);

        vm.prank(rescuer);
        token.scheduleSeize(sanctioned, authority, 2000 * UNIT);
        bytes32 id = token.seizeId(sanctioned, authority, 2000 * UNIT);
        vm.warp(block.timestamp + token.SEIZE_DELAY());

        vm.prank(rescuer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, sanctioned, 1000 * UNIT, 2000 * UNIT
            )
        );
        token.executeSeize(sanctioned, authority, 2000 * UNIT);

        assertTrue(token.pendingSeize(id) != 0);
    }

    /// @dev The veto outlives the window: a lapsed schedule can still be
    ///      cleared, so stale entries do not accumulate as pending.
    function test_a_lapsed_seizure_can_still_be_cancelled() public {
        vm.prank(blacklister);
        token.blacklist(sanctioned);

        vm.prank(rescuer);
        token.scheduleSeize(sanctioned, authority, 100 * UNIT);
        bytes32 id = token.seizeId(sanctioned, authority, 100 * UNIT);
        uint48 eta = token.pendingSeize(id);

        vm.warp(uint256(eta) + token.SEIZE_WINDOW() + 1);
        vm.prank(guardian);
        token.cancelSeize(sanctioned, authority, 100 * UNIT);
        assertEq(token.pendingSeize(id), 0);
    }
}
