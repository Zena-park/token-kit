// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MinimalToken} from "../../src/presets/MinimalToken.sol";
import {FullToken} from "../../src/presets/FullToken.sol";

/**
 * @dev Symbolic properties, run by halmos (`halmos.toml` targets `.*Symbolic.*`).
 *
 *      These verify state-machine invariants over all inputs rather than the
 *      sampled inputs the unit tests use. Signature-based paths (EIP-2612,
 *      EIP-3009) are deliberately absent: ecrecover is beyond practical
 *      symbolic scope, and the unit tests cover them concretely.
 *
 *      The pattern throughout: perform the operation under try/catch, and
 *      assert what must hold on every path where it succeeds. A revert is
 *      always an acceptable outcome; an accepting path that violates the
 *      property is the bug.
 */
contract MinimalTokenSymbolic is Test {
    MinimalToken token;

    address internal admin = address(0xA11CE);
    address internal minter = address(0xB0B);
    address internal holder = address(0xCA51);

    function setUp() public {
        token = new MinimalToken("Sym", "SYM", 6, address(this));
        token.initializeAdmin(admin);

        bytes32 minterRole = token.MINTER_ROLE();
        vm.prank(admin);
        token.grantRole(minterRole, minter);

        vm.prank(minter);
        token.mint(holder, 1e30);
    }

    /// @notice A transfer can never change the total supply.
    function check_transfer_preserves_totalSupply(address to, uint256 amount) public {
        uint256 supplyBefore = token.totalSupply();
        vm.prank(holder);
        try token.transfer(to, amount) {
            assert(token.totalSupply() == supplyBefore);
        } catch {}
    }

    /// @notice A successful transfer moves exactly `amount`, no more, no less.
    function check_transfer_moves_exact_amounts(address to, uint256 amount) public {
        vm.assume(to != holder);
        uint256 fromBefore = token.balanceOf(holder);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(holder);
        try token.transfer(to, amount) {
            assert(token.balanceOf(holder) == fromBefore - amount);
            assert(token.balanceOf(to) == toBefore + amount);
        } catch {}
    }

    /// @notice `transferFrom` can never move more than was approved, and a
    ///         finite allowance is drawn down by exactly the amount spent.
    function check_transferFrom_spends_allowance(
        address spender,
        address to,
        uint256 approved,
        uint256 amount
    ) public {
        vm.assume(spender != holder);
        vm.prank(holder);
        token.approve(spender, approved);

        vm.prank(spender);
        try token.transferFrom(holder, to, amount) {
            assert(amount <= approved);
            if (approved != type(uint256).max) {
                assert(token.allowance(holder, spender) == approved - amount);
            } else {
                assert(token.allowance(holder, spender) == type(uint256).max);
            }
        } catch {}
    }

    /// @notice Nobody without MINTER_ROLE can ever mint.
    function check_mint_requires_role(address caller, address to, uint256 amount) public {
        vm.prank(caller);
        try token.mint(to, amount) {
            assert(token.hasRole(token.MINTER_ROLE(), caller));
        } catch {}
    }

    /// @notice The last admin can neither renounce nor be revoked, by anyone.
    function check_last_admin_cannot_be_removed(address caller) public {
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();

        vm.prank(admin);
        try token.renounceRole(adminRole, admin) {
            assert(false);
        } catch {}

        vm.prank(caller);
        try token.revokeRole(adminRole, admin) {
            assert(false);
        } catch {}

        assert(token.hasRole(adminRole, admin));
    }
}

contract FullTokenSymbolic is Test {
    FullToken token;

    address internal admin = address(0xA11CE);
    address internal controller = address(0xC0);
    address internal minter = address(0xB0B);
    address internal holder = address(0xCA51);
    address internal blacklister = address(0xBAD);
    address internal pauser = address(0xFA);
    address internal rescuer = address(0x2E5);

    function setUp() public {
        token = new FullToken("Sym", "SYM", 6, address(this));
        token.initializeAdmin(admin);

        vm.startPrank(admin);
        token.grantRole(token.BLACKLISTER_ROLE(), blacklister);
        token.grantRole(token.PAUSER_ROLE(), pauser);
        token.grantRole(token.RESCUER_ROLE(), rescuer);
        token.scheduleController(controller, minter);
        vm.stopPrank();

        vm.warp(block.timestamp + token.CONTROLLER_DELAY());
        token.executeController(controller);

        vm.prank(controller);
        token.configureMinter(1e30);
        vm.prank(minter);
        token.mint(holder, 1e24);
    }

    /// @notice A mint can never exceed the budget, and always draws it down
    ///         by exactly the minted amount.
    function check_mint_cannot_exceed_budget(uint256 budget, address to, uint256 amount) public {
        vm.prank(controller);
        token.configureMinter(budget);

        vm.prank(minter);
        try token.mint(to, amount) {
            assert(amount != 0);
            assert(amount <= budget);
            assert(token.minterAllowance(minter) == budget - amount);
        } catch {}
    }

    /// @notice A blacklisted account can never send, whatever the destination.
    function check_blacklisted_sender_cannot_send(address to, uint256 amount) public {
        vm.prank(blacklister);
        token.blacklist(holder);

        vm.prank(holder);
        try token.transfer(to, amount) {
            assert(false);
        } catch {}
    }

    /// @notice A blacklisted account can never receive, whatever the sender.
    function check_blacklisted_recipient_cannot_receive(address to, uint256 amount) public {
        vm.assume(to != address(0));
        vm.prank(blacklister);
        token.blacklist(to);

        vm.prank(holder);
        try token.transfer(to, amount) {
            assert(false);
        } catch {}
    }

    /// @notice While paused, no transfer and no mint can succeed.
    function check_pause_blocks_all_movement(address to, uint256 amount) public {
        vm.prank(pauser);
        token.pause();

        vm.prank(holder);
        try token.transfer(to, amount) {
            assert(false);
        } catch {}

        vm.prank(minter);
        try token.mint(to, amount) {
            assert(false);
        } catch {}
    }

    /// @notice While minting is frozen, no mint can succeed for any input.
    function check_freeze_blocks_minting(address to, uint256 amount) public {
        vm.prank(admin);
        token.freezeMinting();

        vm.prank(minter);
        try token.mint(to, amount) {
            assert(false);
        } catch {}
    }

    /// @notice A seizure can only ever be scheduled against a blacklisted
    ///         account -- ordinary holders are out of reach.
    function check_cannot_schedule_seize_on_unlisted(address from, address to, uint256 amount)
        public
    {
        vm.prank(rescuer);
        try token.scheduleSeize(from, to, amount) {
            assert(token.isBlacklisted(from));
            assert(!token.isBlacklisted(to));
        } catch {}
    }

    /// @notice A seizure that was never scheduled can never execute.
    function check_cannot_execute_unscheduled_seize(address from, address to, uint256 amount)
        public
    {
        vm.prank(rescuer);
        try token.executeSeize(from, to, amount) {
            assert(false);
        } catch {}
    }

    // ---------------------------------------------------------------
    // Controller / Minter structure
    //
    // The invariants MinterControl's whole threat model rests on: authority
    // stays split (no key can widen its own), assignments are 1:1, structural
    // change waits out the timelock, and revocation leaves nothing mintable.
    // ---------------------------------------------------------------

    /// @notice Any appointment that can be scheduled keeps the authority
    ///         split: nonzero ends, controller distinct from its minter, and
    ///         neither end already taken.
    function check_schedule_enforces_authority_split(address c, address m) public {
        vm.prank(admin);
        try token.scheduleController(c, m) {
            assert(c != address(0) && m != address(0));
            assert(c != m);
            assert(token.controllerToMinter(c) == address(0));
            // setUp's minter is already managed, so it can never be `m`.
            assert(m != minter);
        } catch {}
    }

    /// @notice A minter that already has a controller can never be scheduled
    ///         under a second one, whoever that would be.
    function check_no_second_controller_over_a_managed_minter(address c2) public {
        vm.prank(admin);
        try token.scheduleController(c2, minter) {
            assert(false);
        } catch {}
    }

    /// @notice An assigned controller can never be scheduled over another
    ///         minter, whichever that would be.
    function check_a_controller_cannot_be_reassigned(address m2) public {
        vm.prank(admin);
        try token.scheduleController(controller, m2) {
            assert(false);
        } catch {}
    }

    /// @notice An appointment executes only inside [delay, delay + window],
    ///         and lands exactly as scheduled.
    function check_appointment_respects_timelock_and_window(uint64 delta) public {
        address c2 = address(0xC2);
        address m2 = address(0xD2);
        vm.prank(admin);
        token.scheduleController(c2, m2);

        vm.warp(block.timestamp + delta);
        try token.executeController(c2) {
            assert(delta >= token.CONTROLLER_DELAY());
            assert(delta <= token.CONTROLLER_DELAY() + token.CONTROLLER_WINDOW());
            assert(token.controllerToMinter(c2) == m2);
        } catch {}
    }

    /// @notice A vetoed appointment can never execute, at any later time.
    function check_canceled_appointment_cannot_execute(uint64 delta) public {
        address c2 = address(0xC2);
        address m2 = address(0xD2);
        vm.startPrank(admin);
        token.scheduleController(c2, m2);
        token.cancelController(c2);
        vm.stopPrank();

        vm.warp(block.timestamp + delta);
        try token.executeController(c2) {
            assert(false);
        } catch {}
    }

    /// @notice No key can raise its own budget: whoever manages to raise an
    ///         allowance, the budget raised is never their own.
    function check_no_key_can_raise_its_own_budget(address caller, uint256 increment) public {
        vm.prank(caller);
        try token.incrementMinterAllowance(increment) {
            assert(token.controllerToMinter(caller) != caller);
            assert(caller != minter);
        } catch {}
    }

    /// @notice Removing a controller leaves its minter with no authority and
    ///         no budget -- nothing remains mintable through it.
    function check_removing_controller_leaves_nothing_mintable(address to, uint256 amount)
        public
    {
        vm.prank(admin);
        token.removeController(controller);

        assert(!token.isMinter(minter));
        assert(token.minterAllowance(minter) == 0);

        vm.prank(minter);
        try token.mint(to, amount) {
            assert(false);
        } catch {}
    }
}
