// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {
    ERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Blacklist} from "./Blacklist.sol";
import {Guardian} from "../Guardian.sol";

/**
 * @title Seize
 * @notice Moves tokens out of a frozen account. Scheduled, delayed, vetoable.
 *
 * @dev This is stronger than USDC
 *
 *  USDC can freeze an address but cannot move its balance. (Its `rescueERC20`
 *  sounds similar but is unrelated -- that recovers *other* tokens sent to the
 *  contract by mistake.) This module is a power to take someone's balance.
 *
 *  Requiring the target to already be blacklisted is what keeps ordinary holders
 *  out of reach: freezing is a separate act, by a separate role, on the public
 *  record, and seizure can only follow it.
 *
 * @dev The controls, and what each is for
 *
 *  | Control                | Stops                                        |
 *  |------------------------|----------------------------------------------|
 *  | Blacklisted target only| Seizing from an ordinary holder              |
 *  | One day delay          | A single compromised key acting instantly    |
 *  | Guardian veto          | A scheduled seizure the issuer disowns       |
 *  | Event on schedule      | It happening unobserved                      |
 *
 * @dev A seizure crosses the same gates as any other transfer
 *
 *  `executeSeize` moves the balance through `_update`, so whatever compliance
 *  modules the preset includes still apply -- including the pause. A seizure is
 *  therefore blocked while the token is paused, and the Guardian's veto is not
 *  the only thing that can stop one.
 *
 *  This holds whatever order the modules appear in a preset's inheritance list:
 *  every override in the chain runs, so `whenNotPaused` is evaluated wherever
 *  `EmergencyPause` sits. Order decides only which check reverts first when more
 *  than one would.
 *
 * @dev Known limitation -- the destination is arbitrary
 *
 *  A leaked RESCUER key can schedule a seizure to its own address. Ordinary
 *  holders are safe, since only blacklisted accounts can be targeted; the
 *  exposure is that sanctioned funds reach an attacker instead of the authority.
 *
 *  The only defenses are the delay and the veto, and both depend on someone
 *  watching the `SeizeScheduled` event. That is a real operational assumption,
 *  written here rather than left implicit.
 *
 *  A tighter bound would fix the destination at deployment, which is possible
 *  where the receiving address is known in advance.
 */
abstract contract Seize is Blacklist, Guardian {
    /// @notice Schedules and executes seizures.
    bytes32 public constant RESCUER_ROLE = keccak256("RESCUER_ROLE");

    /// @dev The veto belongs to GUARDIAN_ROLE, from the Guardian mixin, shared
    ///      with the issuance module's veto over appointments.

    /// @notice Waiting period between scheduling and executing.
    uint256 public constant SEIZE_DELAY = 1 days;

    /**
     * @notice How long a matured seizure stays executable before it lapses.
     *
     * @dev Without it a schedule is permanent. A seizure raised against an
     *      account that is later un-listed -- because the listing was an error,
     *      or the matter was settled -- would otherwise sit executable
     *      indefinitely, and nothing about the original circumstances would
     *      still hold when someone finally ran it.
     */
    uint256 public constant SEIZE_WINDOW = 7 days;

    /// @custom:storage-location erc7201:token-kit.storage.Seize
    struct SeizeStorage {
        mapping(bytes32 id => uint48 eta) pendingSeize;
        /// @dev The account being seized from, set only while `executeSeize`
        ///      runs, to let that one transfer past the blacklist check it
        ///      would otherwise trip. Holding the account rather than a bare
        ///      flag keeps the exemption to the account it was opened for.
        address seizingFrom;
    }

    /// @dev `internal` so test/StorageSlots.t.sol can pin it to its label.
    bytes32 internal constant _SEIZE_STORAGE =
        0xe93d344f8fe3aa31b6146b5e270d73e3480ba561baeffd772886090551f26500;

    function _seizeStorage() private pure returns (SeizeStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _SEIZE_STORAGE
        }
    }

    /// @notice When a scheduled seizure becomes executable. Zero if none.
    function pendingSeize(bytes32 id) external view returns (uint48) {
        return _seizeStorage().pendingSeize[id];
    }

    event SeizeScheduled(
        bytes32 indexed id, address indexed from, address indexed to, uint256 amount, uint48 eta
    );
    event SeizeExecuted(
        bytes32 indexed id, address indexed from, address indexed to, uint256 amount
    );
    event SeizeCanceled(bytes32 indexed id);

    error NoPendingSeize();
    error SeizeNotReady(uint48 eta);
    error SeizeExpired(uint48 eta);
    error NotBlacklisted(address account);
    error ZeroSeizeSource();
    error ZeroSeizeDestination();

    /**
     * @notice Schedule a seizure. Executable after SEIZE_DELAY, and only for
     *         SEIZE_WINDOW after that.
     *
     * @dev Scheduling the same three terms again simply resets the clock; a
     *      seizure is identified by its terms, so two identical ones cannot be
     *      pending at once and executing one consumes the schedule.
     *
     *      A blacklisted destination is refused up front. The bypass in
     *      `executeSeize` opens for the sender only, so such a seizure could
     *      never execute -- it would sit through the delay and lapse. Failing
     *      here is the same outcome a day earlier.
     *
     *      A zero amount is refused here and only here: the id commits to the
     *      amount, so once scheduling refuses zero no zero-amount schedule can
     *      ever reach `executeSeize` -- a check there would be dead code.
     */
    function scheduleSeize(address from, address to, uint256 amount)
        external
        onlyRole(RESCUER_ROLE)
    {
        if (amount == 0) revert ZeroAmount();
        _requireSeizable(from, to);

        bytes32 id = seizeId(from, to, amount);
        uint48 eta = SafeCast.toUint48(block.timestamp + SEIZE_DELAY);
        _seizeStorage().pendingSeize[id] = eta;
        emit SeizeScheduled(id, from, to, amount, eta);
    }

    /**
     * @notice Carry out a matured seizure.
     *
     * @dev The preconditions are re-checked here, not only at scheduling. The
     *      two are a day or more apart, and a listing lifted in between is a
     *      listing the issuer has decided was wrong -- executing against it
     *      anyway would take an ordinary holder's balance, which is the one
     *      thing the blacklist precondition exists to prevent.
     *
     *      The move goes through `_transfer` rather than `_update` directly.
     *      `_update` treats a zero `from` as a mint, so reaching it unguarded
     *      would put an unbounded issuance path inside the compliance module --
     *      one that no minter, no allowance and no Guardian freeze touches.
     *      `_transfer` refuses both zero ends before it gets there, and still
     *      funnels into the same `_update`, so the pause and the recipient-side
     *      blacklist check apply exactly as before.
     */
    function executeSeize(address from, address to, uint256 amount)
        external
        onlyRole(RESCUER_ROLE)
    {
        bytes32 id = seizeId(from, to, amount);
        SeizeStorage storage $ = _seizeStorage();
        uint48 eta = $.pendingSeize[id];
        if (eta == 0) revert NoPendingSeize();
        if (block.timestamp < eta) revert SeizeNotReady(eta);
        if (block.timestamp > eta + SEIZE_WINDOW) revert SeizeExpired(eta);
        _requireSeizable(from, to);

        delete $.pendingSeize[id];

        $.seizingFrom = from;
        _transfer(from, to, amount);
        delete $.seizingFrom;

        emit SeizeExecuted(id, from, to, amount);
    }

    /// @notice Guardian veto over a scheduled seizure. Available for as long as
    ///         the schedule exists and has not been executed -- including after
    ///         it matures, and after it lapses, where cancelling clears the
    ///         stale entry rather than vetoing anything still executable.
    function cancelSeize(address from, address to, uint256 amount) external onlyGuardianOrAdmin {
        bytes32 id = seizeId(from, to, amount);
        SeizeStorage storage $ = _seizeStorage();
        if ($.pendingSeize[id] == 0) revert NoPendingSeize();
        delete $.pendingSeize[id];
        emit SeizeCanceled(id);
    }

    /**
     * @dev What a seizure requires of its two ends, checked when scheduled and
     *      again when executed -- the same shape as `MinterControl`'s
     *      `_requireAppointable`. Cheap calldata checks come before the
     *      storage reads. The destination check at execution is a fail-fast:
     *      `_update`'s recipient-side check enforces it authoritatively during
     *      the transfer itself.
     */
    function _requireSeizable(address from, address to) private view {
        if (from == address(0)) revert ZeroSeizeSource();
        if (to == address(0)) revert ZeroSeizeDestination();
        if (!isBlacklisted(from)) revert NotBlacklisted(from);
        if (isBlacklisted(to)) revert AccountBlacklisted(to);
    }

    /// @notice The identifier a seizure is scheduled and cancelled under.
    /// @dev All three terms, so a rescuer cannot schedule one seizure and
    ///      execute a different one. Derived in one place because a drift in
    ///      field order would silently make every scheduled seizure
    ///      unexecutable. Public for the same reason `upgradeId` is: observers
    ///      reproduce it rather than re-deriving the preimage.
    function seizeId(address from, address to, uint256 amount) public pure returns (bytes32) {
        return keccak256(abi.encode(from, to, amount));
    }

    /// @dev Opens the sender-side blacklist bypass for the account being seized
    ///      from, for the duration of `executeSeize` only. No other sender is
    ///      exempt even while it is open, and the recipient side never is.
    function _blacklistBypassedFor(address account) internal view virtual override returns (bool) {
        return account == _seizeStorage().seizingFrom;
    }

    /// @dev `Blacklist` and `Guardian` both reach `ERC20Upgradeable`, so the
    ///      chain has to be named once here. It changes nothing: `super` still
    ///      runs `Blacklist`'s check and then the base.
    function _update(address from, address to, uint256 value)
        internal
        virtual
        override(ERC20Upgradeable, Blacklist)
    {
        super._update(from, to, value);
    }

    /// @dev Same diamond, same resolution, for the allowance funnels.
    function _approve(address owner, address spender, uint256 value, bool emitEvent)
        internal
        virtual
        override(ERC20Upgradeable, Blacklist)
    {
        super._approve(owner, spender, value, emitEvent);
    }

    /// @dev Same diamond, same resolution, for the allowance funnels.
    function _spendAllowance(address owner, address spender, uint256 value)
        internal
        virtual
        override(ERC20Upgradeable, Blacklist)
    {
        super._spendAllowance(owner, spender, value);
    }
}
