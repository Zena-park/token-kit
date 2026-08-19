// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {TokenBase} from "../../core/TokenBase.sol";

/**
 * @title Blacklist
 * @notice Freezes named accounts. A sanctioned address can neither send nor
 *         receive, and its balance stays where it is.
 *
 * @dev Why a licensed issuer ends up with this
 *
 *  An issuer answerable for sanctions screening cannot say "the tokens are on
 *  chain, we cannot do anything". Every fiat-backed stablecoin in production
 *  carries the capability -- USDC, USDT and PYUSD alike -- and the practical
 *  driver is enforcing a sanctions listing, not any single statute.
 *
 *  Note what this module is and is not. It is a switch. It does not make a
 *  token compliant with anything: reserve backing, redemption rights, reporting
 *  and licensing all live outside the contract, and none of them are in this
 *  repository.
 *
 * @dev Why it is enforced in `_update`
 *
 *  `_update` is the single funnel every balance change passes through: plain
 *  transfers, `transferFrom`, signature-based transfers, Permit2 pulls, mints
 *  and burns. Checking here means a new payment module cannot accidentally open
 *  a path around the check, because there is no other path.
 *
 * @dev Limitation
 *
 *  This freezes; it does not confiscate. Funds at a blacklisted address stay
 *  there indefinitely. Moving them requires the Seize module, which is a
 *  materially stronger power.
 */
abstract contract Blacklist is TokenBase {
    /// @notice Freezes and unfreezes accounts.
    bytes32 public constant BLACKLISTER_ROLE = keccak256("BLACKLISTER_ROLE");

    /// @custom:storage-location erc7201:token-kit.storage.Blacklist
    struct BlacklistStorage {
        mapping(address account => bool) blacklisted;
    }

    /// @dev `internal` so test/StorageSlots.t.sol can pin it to its label.
    bytes32 internal constant _BLACKLIST_STORAGE =
        0x0e6a5f9453d4c263f3bf375bdf9171b031421261a80808f9afdee89b3ad4fe00;

    function _blacklistStorage() private pure returns (BlacklistStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _BLACKLIST_STORAGE
        }
    }

    event Blacklisted(address indexed account);
    event UnBlacklisted(address indexed account);

    error AccountBlacklisted(address account);

    function isBlacklisted(address account) public view returns (bool) {
        return _blacklistStorage().blacklisted[account];
    }

    /**
     * @dev The zero address is refused. It is not an account -- nobody holds it,
     *      and `_update` skips it on both sides -- so a listing on it would be a
     *      flag that can never fire. A flag that can never fire is worse than no
     *      flag: it reads to anyone querying this module, on chain or off, as a
     *      frozen account, and it is not one.
     */
    function blacklist(address account) external onlyRole(BLACKLISTER_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        _blacklistStorage().blacklisted[account] = true;
        emit Blacklisted(account);
    }

    function unBlacklist(address account) external onlyRole(BLACKLISTER_ROLE) {
        _blacklistStorage().blacklisted[account] = false;
        emit UnBlacklisted(account);
    }

    /**
     * @dev Escape hatch for the Seize module, which by definition moves tokens
     *      out of a blacklisted account and would otherwise be blocked by the
     *      very check it depends on.
     *
     *      It takes the account it exempts rather than being a bare on/off
     *      switch. A nullary flag would mean "sender checks are off right now",
     *      and every sender would pass for as long as it was raised -- correct
     *      only so long as exactly one transfer happens inside that window,
     *      which is an invariant nothing in the signature carries. Naming the
     *      subject makes the exemption as narrow as it is meant to be.
     *
     *      Default is false, so a preset that does not include Seize has no
     *      bypass at all.
     */
    function _blacklistBypassedFor(address) internal view virtual returns (bool) {
        return false;
    }

    /**
     * @dev Every balance change funnels through here.
     *
     *      The zero-address side of a mint or a burn is skipped: that end of the
     *      transfer is not an account anyone can hold, so reading its flag only
     *      costs an SLOAD on every issuance and redemption. `blacklist` refuses
     *      the zero address for the same reason.
     *
     *      The bypass applies to the sender only. Seize needs to move funds
     *      *out* of a listed account, which is the one direction the check has
     *      to yield on; letting it also deliver *into* one would mean the single
     *      module that can move a frozen balance is also the one path that can
     *      hand it to another frozen account.
     */
    function _update(address from, address to, uint256 value) internal virtual override {
        BlacklistStorage storage $ = _blacklistStorage();
        if (from != address(0) && $.blacklisted[from] && !_blacklistBypassedFor(from)) {
            revert AccountBlacklisted(from);
        }
        if (to != address(0) && $.blacklisted[to]) revert AccountBlacklisted(to);
        super._update(from, to, value);
    }

    /**
     * @dev Raising an allowance that touches a listed account -- either end --
     *      is refused: it is standing permission to move funds the moment the
     *      listing is lifted. Lowering one is always allowed. Revocation is
     *      exactly what a holder needs on learning a spender is compromised,
     *      the same doctrine that keeps `cancelAuthorization` reachable while
     *      paused, and a frozen allowance would otherwise be live in the first
     *      block after an un-listing.
     *
     *      Only raises are screened -- what counts as one, and why the
     *      boundary is strict, is `TokenBase._isAllowanceRaise`. No bypass: a
     *      seizure moves funds by `_transfer` and never touches allowances.
     */
    function _approve(address owner, address spender, uint256 value, bool emitEvent)
        internal
        virtual
        override
    {
        if (_isAllowanceRaise(owner, spender, value, emitEvent)) {
            BlacklistStorage storage $ = _blacklistStorage();
            if ($.blacklisted[owner]) revert AccountBlacklisted(owner);
            if ($.blacklisted[spender]) revert AccountBlacklisted(spender);
        }
        super._approve(owner, spender, value, emitEvent);
    }

    /**
     * @dev A listed spender must not move anyone's funds, and the sender-side
     *      check in `_update` sees only the holder. Checked here rather than
     *      in the `_approve` write-back because an infinite allowance is spent
     *      without ever being written back.
     */
    function _spendAllowance(address owner, address spender, uint256 value)
        internal
        virtual
        override
    {
        if (_blacklistStorage().blacklisted[spender]) revert AccountBlacklisted(spender);
        super._spendAllowance(owner, spender, value);
    }
}
