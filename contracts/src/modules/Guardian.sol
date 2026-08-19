// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {TokenBase} from "../core/TokenBase.sol";

/**
 * @title Guardian
 * @notice The blocking role, shared by every module that grants a veto.
 *
 * @dev Why this is a mixin rather than part of the base
 *
 *  Three modules hand a Guardian a veto -- MinterControl over pending Controller
 *  appointments, Seize over scheduled seizures, UpgradeControl over pending
 *  implementation upgrades -- and a preset taking more than one of them must not
 *  declare the role constant twice.
 *
 *  The base would also solve that, but at a cost: `MinimalToken` includes no
 *  vetoable module and would still expose a grantable `GUARDIAN_ROLE` governing
 *  nothing -- the present-and-inert outcome this repository rejects runtime
 *  flags for. A mixin a module opts into carries the role only where it means
 *  something.
 *
 *  It extends `TokenBase` rather than `AccessControlUpgradeable` directly. The
 *  narrower base looks tidier, but it makes `AccessControl` reachable by two
 *  routes in every preset that takes both -- so any override `TokenBase` places
 *  on an AccessControl function, such as the floor under the last admin, becomes
 *  an ambiguity each preset has to re-resolve by hand. One base, one route.
 *
 *  It declares no constructor, so modules inheriting it compose without
 *  ambiguity; the most derived preset supplies `TokenBase`'s.
 *
 * @dev Why one Guardian rather than one per feature
 *
 *  The Guardian is a single operational stance -- someone who can only say no,
 *  and can do it in seconds -- rather than a per-feature permission. Because the
 *  authority is that narrow, a single hot key is an acceptable holder, and a
 *  single hot key is what actually gets used during an incident.
 */
abstract contract Guardian is TokenBase {
    /// @notice Cancels pending actions and freezes things. Creates nothing.
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /**
     * @dev Guardian actions are also open to the admin, so that an issuer who
     *      never appointed a Guardian is not locked out of its own brakes.
     */
    modifier onlyGuardianOrAdmin() {
        if (!hasRole(GUARDIAN_ROLE, _msgSender()) && !hasRole(DEFAULT_ADMIN_ROLE, _msgSender())) {
            revert AccessControlUnauthorizedAccount(_msgSender(), GUARDIAN_ROLE);
        }
        _;
    }
}
