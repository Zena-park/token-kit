// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Helpers} from "../helpers/Helpers.sol";
import {PermitToken} from "../../src/presets/PermitToken.sol";
import {MinterControl} from "../../src/modules/issuance/MinterControl.sol";
import {TokenBase} from "../../src/core/TokenBase.sol";

contract MinterControlTest is Helpers {
    PermitToken token;

    address admin = makeAddr("admin");
    address guardian = makeAddr("guardian");
    address controller = makeAddr("controller");
    address minter = makeAddr("minter");
    address attacker = makeAddr("attacker");
    address user = makeAddr("user");

    function setUp() public {
        vm.startPrank(admin);
        token = new PermitToken("Test Token", "TEST", 6, admin);
        token.initializeAdmin(admin);
        token.grantRole(token.GUARDIAN_ROLE(), guardian);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // The central property
    // ---------------------------------------------------------------

    /// @dev A Minter mints but cannot widen its own budget. Arbitrary issuance
    ///      therefore needs two separate keys.
    function test_a_minter_cannot_raise_its_own_allowance() public {
        grantMint(token, admin, minter, 100 * UNIT);

        vm.prank(minter);
        vm.expectRevert(MinterControl.NotAController.selector);
        token.incrementMinterAllowance(1_000_000 * UNIT);
    }

    /// @dev The remaining budget at the moment of compromise is the whole loss,
    ///      and anyone can read it on chain beforehand.
    function test_a_leaked_minter_key_is_capped_at_the_remaining_budget() public {
        grantMint(token, admin, minter, 100 * UNIT);

        vm.prank(minter);
        token.mint(attacker, 100 * UNIT);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(MinterControl.MintAllowanceExceeded.selector, 1, 0));
        token.mint(attacker, 1);

        assertEq(token.totalSupply(), 100 * UNIT);
    }

    /// @dev A drawdown budget, not a rate limit: it never refills on its own.
    function test_the_budget_does_not_refill_over_time() public {
        grantMint(token, admin, minter, 100 * UNIT);

        vm.prank(minter);
        token.mint(user, 100 * UNIT);

        vm.warp(block.timestamp + 365 days);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(MinterControl.MintAllowanceExceeded.selector, 1, 0));
        token.mint(user, 1);
    }

    /// @dev Burning must not refund the budget, or a leaked key could cycle
    ///      mint-burn-mint forever inside a budget that never decreases.
    function test_burning_does_not_refund_the_budget() public {
        grantMint(token, admin, minter, 100 * UNIT);

        vm.startPrank(minter);
        token.mint(minter, 100 * UNIT);
        token.burn(100 * UNIT);

        vm.expectRevert(abi.encodeWithSelector(MinterControl.MintAllowanceExceeded.selector, 1, 0));
        token.mint(user, 1);
        vm.stopPrank();
    }

    /// @dev Both issuance entry points refuse a zero amount, matching
    ///      `SimpleMinter` -- a zero-value mint or redemption is a bug in the
    ///      caller, not an event worth emitting.
    function test_zero_amount_mint_and_burn_are_refused() public {
        grantMint(token, admin, minter, 100 * UNIT);

        vm.startPrank(minter);
        vm.expectRevert(TokenBase.ZeroAmount.selector);
        token.mint(user, 0);

        vm.expectRevert(TokenBase.ZeroAmount.selector);
        token.burn(0);
        vm.stopPrank();
    }

    /// @dev The separation is only real if one key cannot hold both ends. A
    ///      Controller that is its own Minter could raise its own budget and
    ///      then spend it.
    function test_a_controller_cannot_be_its_own_minter() public {
        vm.prank(admin);
        vm.expectRevert(MinterControl.ControllerCannotBeItsMinter.selector);
        token.scheduleController(minter, minter);
    }

    /// @dev Two Controllers over one Minter would let either refill a budget the
    ///      other set, and removing one would deactivate the Minter the other is
    ///      still managing.
    function test_a_minter_cannot_have_two_controllers() public {
        address second = makeAddr("second-controller");

        vm.prank(admin);
        token.scheduleController(controller, minter);
        vm.warp(block.timestamp + token.CONTROLLER_DELAY());
        token.executeController(controller);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(MinterControl.MinterAlreadyManaged.selector, minter));
        token.scheduleController(second, minter);
    }

    /// @dev Scheduling and executing are a day apart, so the check has to hold
    ///      at execution too -- another appointment can land in between.
    function test_a_conflicting_appointment_is_caught_at_execution() public {
        address second = makeAddr("second-controller");

        vm.startPrank(admin);
        token.scheduleController(controller, minter);
        token.scheduleController(second, minter); // both scheduled before either lands
        vm.stopPrank();

        vm.warp(block.timestamp + token.CONTROLLER_DELAY());
        token.executeController(controller);

        vm.expectRevert(abi.encodeWithSelector(MinterControl.MinterAlreadyManaged.selector, minter));
        token.executeController(second);
    }

    // ---------------------------------------------------------------
    // Timelock on structural change
    // ---------------------------------------------------------------

    function test_appointing_a_controller_takes_a_day() public {
        vm.prank(admin);
        token.scheduleController(controller, minter);

        assertEq(token.controllerToMinter(controller), address(0));

        vm.expectRevert(
            abi.encodeWithSelector(
                MinterControl.ControllerNotReady.selector,
                uint48(block.timestamp + token.CONTROLLER_DELAY())
            )
        );
        token.executeController(controller);

        vm.warp(block.timestamp + token.CONTROLLER_DELAY());
        token.executeController(controller);

        assertEq(token.controllerToMinter(controller), minter);
    }

    /// @dev Scheduling was the privileged act; the wait has already been served.
    function test_anyone_may_execute_a_matured_appointment() public {
        vm.prank(admin);
        token.scheduleController(controller, minter);
        vm.warp(block.timestamp + token.CONTROLLER_DELAY());

        vm.prank(attacker);
        token.executeController(controller);

        assertEq(token.controllerToMinter(controller), minter);
    }

    function test_only_admin_may_schedule() public {
        vm.prank(attacker);
        expectUnauthorized(attacker, bytes32(0));
        token.scheduleController(controller, minter);
    }

    // ---------------------------------------------------------------
    // Guardian: blocks only
    // ---------------------------------------------------------------

    function test_guardian_vetoes_a_pending_appointment() public {
        vm.prank(admin);
        token.scheduleController(controller, minter);

        vm.prank(guardian);
        token.cancelController(controller);

        vm.warp(block.timestamp + token.CONTROLLER_DELAY());
        vm.expectRevert(
            abi.encodeWithSelector(MinterControl.NoPendingController.selector, controller)
        );
        token.executeController(controller);
    }

    function test_guardian_freezes_minting_immediately() public {
        grantMint(token, admin, minter, 1000 * UNIT);

        vm.prank(guardian);
        token.freezeMinting();

        vm.prank(minter);
        vm.expectRevert(MinterControl.MintingIsFrozen.selector);
        token.mint(user, UNIT);
    }

    /// @dev Fast to stop, deliberate to resume.
    function test_guardian_cannot_unfreeze() public {
        vm.prank(guardian);
        token.freezeMinting();

        vm.prank(guardian);
        expectUnauthorized(guardian, bytes32(0));
        token.unfreezeMinting();

        vm.prank(admin);
        token.unfreezeMinting();
        assertFalse(token.mintingFrozen());
    }

    /// @dev A Guardian can only ever say no -- it holds no issuing power.
    function test_guardian_cannot_mint_or_appoint() public {
        vm.prank(guardian);
        vm.expectRevert(MinterControl.NotAController.selector);
        token.configureMinter(1000 * UNIT);

        vm.prank(guardian);
        expectUnauthorized(guardian, bytes32(0));
        token.scheduleController(attacker, attacker);
    }

    // ---------------------------------------------------------------
    // Revocation is immediate
    // ---------------------------------------------------------------

    function test_removing_a_controller_also_cuts_its_minter() public {
        address ctrl = grantMint(token, admin, minter, 1000 * UNIT);

        vm.prank(admin);
        token.removeController(ctrl);

        assertFalse(token.isMinter(minter));
        assertEq(token.minterAllowance(minter), 0);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(MinterControl.NotAMinter.selector, minter));
        token.mint(user, UNIT);
    }

    function test_controller_lowers_the_budget_instantly() public {
        address ctrl = grantMint(token, admin, minter, 1000 * UNIT);

        vm.prank(ctrl);
        token.decrementMinterAllowance(900 * UNIT);

        assertEq(token.minterAllowance(minter), 100 * UNIT);
    }

    /// @dev Lowering past zero clamps rather than underflowing.
    function test_lowering_past_zero_clamps() public {
        address ctrl = grantMint(token, admin, minter, 100 * UNIT);

        vm.prank(ctrl);
        token.decrementMinterAllowance(type(uint256).max);

        assertEq(token.minterAllowance(minter), 0);
    }

    /// @dev Increment and decrement agree: neither touches a deactivated
    ///      Minter, whose budget removal already zeroed.
    function test_a_removed_minters_budget_cannot_be_adjusted() public {
        address ctrl = grantMint(token, admin, minter, 100 * UNIT);

        vm.startPrank(ctrl);
        token.removeMinter();

        vm.expectRevert(abi.encodeWithSelector(MinterControl.NotAMinter.selector, minter));
        token.decrementMinterAllowance(UNIT);

        vm.expectRevert(abi.encodeWithSelector(MinterControl.NotAMinter.selector, minter));
        token.incrementMinterAllowance(UNIT);
        vm.stopPrank();
    }

    /// @dev Deposits are real time; raising the budget must not wait a day.
    function test_controller_raises_the_budget_instantly() public {
        address ctrl = grantMint(token, admin, minter, 100 * UNIT);

        vm.prank(ctrl);
        token.incrementMinterAllowance(900 * UNIT);

        assertEq(token.minterAllowance(minter), 1000 * UNIT);

        vm.prank(minter);
        token.mint(user, 1000 * UNIT);
        assertEq(token.balanceOf(user), 1000 * UNIT);
    }

    /// @dev Anyone may execute a matured appointment, so without a window one
    ///      the issuer scheduled and then thought better of stays live forever
    ///      -- and a Controller is the key that sets mint budgets.
    function test_a_matured_appointment_expires() public {
        address lateController = makeAddr("late-controller");
        address lateMinter = makeAddr("late-minter");

        vm.prank(admin);
        token.scheduleController(lateController, lateMinter);
        (, uint48 eta) = token.pendingController(lateController);

        vm.warp(uint256(eta) + token.CONTROLLER_WINDOW() + 1);
        vm.expectRevert(abi.encodeWithSelector(MinterControl.ControllerExpired.selector, eta));
        token.executeController(lateController);

        assertEq(token.controllerToMinter(lateController), address(0));
    }
}
