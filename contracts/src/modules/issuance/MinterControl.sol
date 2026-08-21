// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {TokenBase} from "../../core/TokenBase.sol";
import {Guardian} from "../Guardian.sol";

/**
 * @title MinterControl
 * @notice Four-tier issuance authority -- Owner, Controller, Minter, Guardian --
 *         with a budgeted mint allowance, a timelock on structural changes, and
 *         a Guardian who can only ever say no.
 *
 * @dev Why not just a MINTER_ROLE
 *
 *  A leaked mint key mints without limit. A multisig raises the number of keys
 *  an attacker needs but sets no ceiling, and it does not cover a signer
 *  approving a transaction that is not what they were shown. `pause` stops
 *  further movement without undoing what was already minted.
 *
 *  The ceiling is therefore enforced on chain, in the issuance path itself.
 *
 * @dev The organizing rule: an operational key cannot widen its own authority
 *
 *   Owner --appoint (timelock)--> Controller --set allowance (instant)--> Minter
 *                                                                          |
 *                        Guardian --cancel / freeze (instant)--------------+
 *
 *  The Minter mints but cannot raise its own allowance; only the Controller can.
 *  Minting arbitrarily therefore requires two distinct keys, and the contract
 *  enforces that they are distinct: an address is a Controller or a Minter,
 *  never both -- so it cannot be appointed over itself, cannot be appointed
 *  over the account that manages it, and no Minter can have two Controllers.
 *
 *  | Key leaked      | Damage                                            |
 *  |-----------------|---------------------------------------------------|
 *  | Minter only     | Up to the remaining allowance, and no further      |
 *  | Controller only | Can raise allowance but cannot mint                |
 *  | Both            | Unbounded -- so they belong in different custody.  |
 *  |                 | One address can never hold both ends; two keys     |
 *  |                 | in one custody is the remaining operational risk.  |
 *
 * @dev The allowance is a drawdown budget, not a rate limit
 *
 *      minterAllowance[minter] -= amount;   // spent on each mint, never refills
 *
 *  A daily rate limit refills every day, so an attacker mints the limit every
 *  day forever and total damage is unbounded. A drawdown budget makes the
 *  remaining balance the ceiling, and anyone can read it on chain.
 *
 *  It also matches the business: issuance backs a reserve deposit. The natural
 *  unit is "as much as was deposited", not "so much per day".
 *
 * @dev The timelock sits on structure, not on amounts
 *
 *  Reserve deposits arrive in real time. Telling a customer who wired funds to
 *  wait a day is not a workable product, so raising an allowance is immediate.
 *
 *  Becoming a Controller is what takes time. Raising an allowance already
 *  requires a Controller key, so the defensive line holds either way.
 *
 *  | Action                    | Timing                        |
 *  |---------------------------|-------------------------------|
 *  | Raise / lower allowance   | Immediate                     |
 *  | Remove a Minter           | Immediate (revocation is fast)|
 *  | Appoint a Controller      | Timelock + Guardian veto      |
 *
 * @dev The Guardian only blocks
 *
 *  It cancels pending appointments and freezes minting. It cannot create
 *  anything. Because the authority is that narrow, it can be a single key -- and
 *  a single key is what you need at 3am, when collecting multisig signatures
 *  takes hours and the incident takes minutes.
 *
 * @dev Relationship to USDC
 *
 *  The Owner / Controller / Minter split follows Circle's FiatToken. The
 *  timelock on Controller appointment and the Guardian are additions; USDC has
 *  neither.
 */
abstract contract MinterControl is TokenBase, Guardian {
    // ---------------------------------------------------------------
    // Roles
    // ---------------------------------------------------------------

    /// @dev The Guardian who cancels appointments and freezes minting comes
    ///      from the Guardian mixin, shared with any other vetoable module.

    /// @notice Delay before an appointed Controller takes effect.
    uint256 public constant CONTROLLER_DELAY = 1 days;

    /// @notice How long a matured appointment stays executable before it lapses.
    /// @dev Anyone may execute a matured appointment, so without a window an
    ///      appointment the issuer scheduled and then forgot about stays live
    ///      indefinitely -- and a Controller is the key that sets mint budgets.
    ///      The admin is expected to be present when its own appointment lands.
    uint256 public constant CONTROLLER_WINDOW = 7 days;

    // ---------------------------------------------------------------
    // State
    // ---------------------------------------------------------------

    /// @custom:storage-location erc7201:token-kit.storage.MinterControl
    struct MinterControlStorage {
        /// @dev Controller to the Minter it manages. One each.
        mapping(address controller => address minter) controllerToMinter;
        /// @dev The reverse, so a Minter cannot end up with two Controllers.
        mapping(address minter => address controller) minterToController;
        /// @dev Whether an account may mint.
        mapping(address minter => bool) isMinter;
        /// @dev Remaining mint budget. Spent on every mint, never refilled.
        mapping(address minter => uint256) minterAllowance;
        /// @dev Scheduled Controller appointments.
        mapping(address controller => PendingController) pendingController;
        /// @dev Guardian's freeze. While true, nothing can be minted.
        bool mintingFrozen;
    }

    struct PendingController {
        address minter;
        uint48 eta; // 0 = nothing pending
    }

    /// @dev `internal` so test/StorageSlots.t.sol can pin it to its label.
    bytes32 internal constant _MINTER_CONTROL_STORAGE =
        0x1e2ec5cd51882b577c73af022df6730b84f6c528fa9e0a18aee7279d11078400;

    function _minterControlStorage() private pure returns (MinterControlStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _MINTER_CONTROL_STORAGE
        }
    }

    // ---------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------

    /// @notice The Minter a Controller manages, or zero if not a Controller.
    function controllerToMinter(address controller) public view returns (address) {
        return _minterControlStorage().controllerToMinter[controller];
    }

    /// @notice Whether an account may mint.
    function isMinter(address minter) public view returns (bool) {
        return _minterControlStorage().isMinter[minter];
    }

    /// @notice Remaining mint budget for an account.
    function minterAllowance(address minter) public view returns (uint256) {
        return _minterControlStorage().minterAllowance[minter];
    }

    /// @notice A scheduled Controller appointment, if any.
    function pendingController(address controller) external view returns (address, uint48) {
        PendingController memory p = _minterControlStorage().pendingController[controller];
        return (p.minter, p.eta);
    }

    /// @notice Whether minting is frozen.
    function mintingFrozen() public view returns (bool) {
        return _minterControlStorage().mintingFrozen;
    }

    // ---------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------

    event ControllerScheduled(address indexed controller, address indexed minter, uint48 eta);
    event ControllerExecuted(address indexed controller, address indexed minter);
    event ControllerCanceled(address indexed controller);
    event ControllerRemoved(address indexed controller, address indexed minter);

    event MinterConfigured(address indexed controller, address indexed minter, uint256 allowance);
    event MinterAllowanceIncremented(
        address indexed minter, uint256 increment, uint256 newAllowance
    );
    event MinterAllowanceDecremented(
        address indexed minter, uint256 decrement, uint256 newAllowance
    );
    event MinterRemoved(address indexed controller, address indexed minter);

    event MintingFrozen(address indexed guardian);
    event MintingUnfrozen();

    // ---------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------

    error NotAController();
    error ControllerAlreadyAssigned(address controller);
    error MinterAlreadyManaged(address minter);
    error ControllerCannotBeItsMinter();
    error AddressAlreadyPaired(address account);
    error NoPendingController(address controller);
    error ControllerNotReady(uint48 eta);
    error ControllerExpired(uint48 eta);
    error MintingIsFrozen();
    error NotAMinter(address account);
    error MintAllowanceExceeded(uint256 requested, uint256 remaining);

    // ---------------------------------------------------------------

    /// @dev Returns the caller's Minter, reverting if the caller is not a
    ///      Controller. Used instead of a modifier so the slot is read once --
    ///      a modifier would check it and the body would then read it again.
    function _callerMinter() private view returns (address minter) {
        minter = _minterControlStorage().controllerToMinter[_msgSender()];
        if (minter == address(0)) revert NotAController();
    }

    /// @dev As above, but the Minter must also be active. The budget funnels
    ///      sit on this so the mirror of `_deactivateMinter`'s invariant -- a
    ///      removed Minter's budget is not addressable -- holds in one place.
    ///      `configureMinter` is the deliberate exception: it is the call that
    ///      activates.
    function _activeCallerMinter() private view returns (address minter) {
        minter = _callerMinter();
        if (!_minterControlStorage().isMinter[minter]) revert NotAMinter(minter);
    }

    // ---------------------------------------------------------------
    // Mint / burn
    // ---------------------------------------------------------------

    /// @notice Mint against a reserve deposit. Draws down the Minter's budget.
    function mint(address to, uint256 amount) external {
        _consumeMintAllowance(_msgSender(), amount);
        _mint(to, amount);
    }

    /**
     * @notice Burn own balance against a redemption.
     * @dev Does not refund the mint allowance. Burning is not a mint permission,
     *      and refunding it would let a leaked Minter key mint-burn-mint forever
     *      within a budget that never actually decreases.
     */
    function burn(uint256 amount) external {
        _requireActiveMinter(_msgSender(), amount);
        _burn(_msgSender(), amount);
    }

    // ---------------------------------------------------------------
    // Appointing a Controller -- timelock plus veto
    // ---------------------------------------------------------------

    /// @notice Schedule an appointment. Takes effect after CONTROLLER_DELAY.
    function scheduleController(address controller, address minter)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (controller == address(0) || minter == address(0)) revert ZeroAddress();
        _requireAppointable(controller, minter);

        MinterControlStorage storage $ = _minterControlStorage();
        uint48 eta = SafeCast.toUint48(block.timestamp + CONTROLLER_DELAY);
        $.pendingController[controller] = PendingController(minter, eta);
        emit ControllerScheduled(controller, minter, eta);
    }

    /// @notice Anyone may execute a matured appointment -- scheduling it was the
    ///         privileged act, and the waiting period has already been served.
    ///         Executable for CONTROLLER_WINDOW after that, then it lapses.
    function executeController(address controller) external {
        MinterControlStorage storage $ = _minterControlStorage();
        PendingController memory p = $.pendingController[controller];
        if (p.eta == 0) revert NoPendingController(controller);
        if (block.timestamp < p.eta) revert ControllerNotReady(p.eta);
        if (block.timestamp > p.eta + CONTROLLER_WINDOW) revert ControllerExpired(p.eta);

        // Re-checked here, not only at scheduling: the two are a day apart and
        // another appointment can land in between.
        _requireAppointable(controller, p.minter);

        $.controllerToMinter[controller] = p.minter;
        $.minterToController[p.minter] = controller;
        delete $.pendingController[controller];
        emit ControllerExecuted(controller, p.minter);
    }

    /// @notice Guardian veto over a pending appointment.
    function cancelController(address controller) external onlyGuardianOrAdmin {
        MinterControlStorage storage $ = _minterControlStorage();
        if ($.pendingController[controller].eta == 0) revert NoPendingController(controller);
        delete $.pendingController[controller];
        emit ControllerCanceled(controller);
    }

    /// @notice Remove a Controller, and with it the Minter it manages.
    /// @dev Immediate. Revocation never waits. Pending appointments are not
    ///      touched: one scheduled over the freed Minter before this call, and
    ///      still inside its window, becomes executable again. Clearing them
    ///      here would need a by-Minter index of pending Controllers -- many
    ///      may be pending over one Minter, so a set with removal on every
    ///      schedule, execute and cancel, not a slot -- for a case that is
    ///      not inconsistent state: what revives is an appointment the admin
    ///      announced, re-checked at execution, that the Guardian can cancel.
    ///      An admin freeing a Minter scans `ControllerScheduled` for it.
    function removeController(address controller) external onlyRole(DEFAULT_ADMIN_ROLE) {
        MinterControlStorage storage $ = _minterControlStorage();
        address minter = $.controllerToMinter[controller];
        if (minter == address(0)) revert NotAController();

        delete $.controllerToMinter[controller];
        delete $.minterToController[minter];
        _deactivateMinter(minter);

        emit ControllerRemoved(controller, minter);
    }

    // ---------------------------------------------------------------
    // A Controller manages its own Minter -- all immediate
    // ---------------------------------------------------------------

    /// @notice Activate the caller's Minter and set its budget.
    function configureMinter(uint256 allowance) external {
        address minter = _callerMinter();
        MinterControlStorage storage $ = _minterControlStorage();
        $.isMinter[minter] = true;
        $.minterAllowance[minter] = allowance;
        emit MinterConfigured(_msgSender(), minter, allowance);
    }

    /// @notice Raise the budget. Immediate -- it tracks reserve deposits.
    function incrementMinterAllowance(uint256 increment) external {
        if (increment == 0) revert ZeroAmount();
        address minter = _activeCallerMinter();

        MinterControlStorage storage $ = _minterControlStorage();
        uint256 updated = $.minterAllowance[minter] + increment;
        $.minterAllowance[minter] = updated;
        emit MinterAllowanceIncremented(minter, increment, updated);
    }

    /// @notice Lower the budget. Immediate -- it is a way of cutting risk.
    function decrementMinterAllowance(uint256 decrement) external {
        if (decrement == 0) revert ZeroAmount();
        address minter = _activeCallerMinter();

        MinterControlStorage storage $ = _minterControlStorage();
        uint256 current = $.minterAllowance[minter];
        uint256 updated = decrement >= current ? 0 : current - decrement;
        $.minterAllowance[minter] = updated;
        // The clamp means the applied decrease can be smaller than requested;
        // the event records what actually happened to the budget.
        emit MinterAllowanceDecremented(minter, current - updated, updated);
    }

    /// @notice Deactivate the caller's Minter immediately.
    function removeMinter() external {
        address minter = _callerMinter();
        _deactivateMinter(minter);
        emit MinterRemoved(_msgSender(), minter);
    }

    // ---------------------------------------------------------------
    // Guardian -- blocking only
    // ---------------------------------------------------------------

    /// @notice Freeze all minting immediately.
    function freezeMinting() external onlyGuardianOrAdmin {
        _minterControlStorage().mintingFrozen = true;
        emit MintingFrozen(_msgSender());
    }

    /// @notice Only the admin lifts the freeze. Fast to stop, deliberate to resume.
    function unfreezeMinting() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _minterControlStorage().mintingFrozen = false;
        emit MintingUnfrozen();
    }

    // ---------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------

    /**
     * @dev The conditions that keep issuance authority split.
     *
     *      A Controller that is also its own Minter could raise its own budget
     *      and then spend it, which is the one thing this module exists to
     *      prevent. Two Controllers over one Minter would mean either of them
     *      can refill a budget the other set, and removing one would silently
     *      deactivate the Minter the other is still managing.
     *
     *      The last two checks close the indirect form of the first. With A
     *      managing B, appointing B over A would let each key refill the
     *      budget the other spends -- one custody holding both ends of two
     *      pairs is the same failure as one key holding both ends of one.
     *      The rule enforced is stronger than "no cycle": an address is a
     *      Controller or a Minter, never both, so a chain A -> B -> C is
     *      refused too. A chain concentrates authority even where it widens
     *      nobody's own budget, and a graph walk is not on-chain work.
     */
    function _requireAppointable(address controller, address minter) private view {
        if (controller == minter) revert ControllerCannotBeItsMinter();

        MinterControlStorage storage $ = _minterControlStorage();
        if ($.controllerToMinter[controller] != address(0)) {
            revert ControllerAlreadyAssigned(controller);
        }
        if ($.minterToController[minter] != address(0)) {
            revert MinterAlreadyManaged(minter);
        }
        if ($.minterToController[controller] != address(0)) {
            revert AddressAlreadyPaired(controller);
        }
        if ($.controllerToMinter[minter] != address(0)) {
            revert AddressAlreadyPaired(minter);
        }
    }

    /// @dev Revocation always zeroes the budget with it. Kept in one place
    ///      because "removal leaves nothing mintable" is the invariant the
    ///      module's whole threat model rests on.
    function _deactivateMinter(address minter) private {
        MinterControlStorage storage $ = _minterControlStorage();
        $.isMinter[minter] = false;
        $.minterAllowance[minter] = 0;
    }

    /**
     * @dev The guards `mint` and `burn` share: a zero amount is refused before
     *      anything is read, then the caller must be an active Minter. The
     *      freeze is deliberately not here -- it stops issuance, and burning
     *      against a redemption must stay possible while minting is frozen.
     */
    function _requireActiveMinter(address minter, uint256 amount) private view {
        if (amount == 0) revert ZeroAmount();
        if (!_minterControlStorage().isMinter[minter]) revert NotAMinter(minter);
    }

    /**
     * @dev Draw down the budget. It does not refill -- restoring it takes a
     *      Controller. The remaining balance at the moment a key leaks is
     *      therefore the maximum loss, and it is publicly readable.
     */
    function _consumeMintAllowance(address minter, uint256 amount) internal {
        MinterControlStorage storage $ = _minterControlStorage();
        _requireActiveMinter(minter, amount);
        if ($.mintingFrozen) revert MintingIsFrozen();

        uint256 remaining = $.minterAllowance[minter];
        if (amount > remaining) revert MintAllowanceExceeded(amount, remaining);

        $.minterAllowance[minter] = remaining - amount;
    }
}
