// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IERC1822Proxiable} from "@openzeppelin/contracts/interfaces/draft-IERC1822.sol";
import {TokenBase} from "../src/core/TokenBase.sol";
import {MinimalToken} from "../src/presets/MinimalToken.sol";
import {PermitToken} from "../src/presets/PermitToken.sol";
import {Eip3009Token} from "../src/presets/Eip3009Token.sol";
import {FullToken} from "../src/presets/FullToken.sol";
import {UpgradeablePermitToken} from "../src/presets/upgradeable/UpgradeablePermitToken.sol";
import {UpgradeableEip3009Token} from "../src/presets/upgradeable/UpgradeableEip3009Token.sol";
import {UpgradeableFullToken} from "../src/presets/upgradeable/UpgradeableFullToken.sol";

/**
 * @title Deploy
 * @notice Deploys any preset, immutable or upgradeable, at a deterministic
 *         address. One entry point per preset; every preset shares the same
 *         plumbing, so choosing a narrower token never means forking the script.
 *
 * @dev Addresses come from the CREATE2 deployer, not from a contract here
 *
 *  Everything deploys through the canonical deterministic deployer, so the
 *  resulting address depends only on that deployer, the salt and the init code
 *  -- the same three inputs on every chain. Nothing in this repository needs to
 *  be deployed first for that to hold.
 *
 * @dev Salt convention
 *
 *  The deterministic deployer does not mix the caller into the salt, so a salt
 *  used bare is first-come-first-served across chains: someone watching a
 *  mainnet deployment can deploy the same init code at the same address on an
 *  L2. They cannot name themselves admin -- the issuer in the init code decides
 *  that -- but they can spend the address before the issuer reaches the chain.
 *  Put the deployer in the leading 20 bytes:
 *
 *      salt = bytes32(bytes20(deployer)) | bytes32(uint256(entropy))
 *
 *  `saltFor` below builds it. Deployers that enforce this convention on chain
 *  will additionally reject a mismatched sender; deployers that do not still
 *  give a salt nobody else has a reason to guess.
 *
 * @dev Handing over the admin
 *
 *  The admin is deliberately not part of the init code, so that an issuer can
 *  use a different multisig per chain without the token address changing. It is
 *  granted by a separate call.
 *
 *  What closes that second call to everyone else is the issuer: the token
 *  records it at deployment -- it is in the init code, and therefore in the
 *  address -- and only the issuer may call `initializeAdmin`. Broadcasting from
 *  a different key than the one passed as `issuer` leaves a deployed token that
 *  nobody can hand over, so `_report` prints both and `verifyAdmin` confirms the
 *  grant landed.
 */
contract Deploy is Script {
    error NotAnImplementation(address implementation);
    error DecimalsMismatch(uint8 actual, uint8 expected);
    error Create2Failed(address predicted);

    /// @notice Deployer-scoped salt. See the note above.
    function saltFor(address deployer, uint96 entropy) public pure returns (bytes32) {
        return bytes32(uint256(uint160(deployer)) << 96 | uint256(entropy));
    }

    // ---------------------------------------------------------------
    // Immutable presets. No proxy, no upgrade path, no admin upgrade key.
    // ---------------------------------------------------------------

    function deployMinimalToken(
        string memory name,
        string memory symbol,
        uint8 decimals,
        address admin,
        uint96 entropy
    ) public returns (address) {
        return _deployImmutable(
            type(MinimalToken).creationCode, name, symbol, decimals, admin, entropy
        );
    }

    function deployPermitToken(
        string memory name,
        string memory symbol,
        uint8 decimals,
        address admin,
        uint96 entropy
    ) public returns (address) {
        return _deployImmutable(
            type(PermitToken).creationCode, name, symbol, decimals, admin, entropy
        );
    }

    function deployEip3009Token(
        string memory name,
        string memory symbol,
        uint8 decimals,
        address admin,
        uint96 entropy
    ) public returns (address) {
        return _deployImmutable(
            type(Eip3009Token).creationCode, name, symbol, decimals, admin, entropy
        );
    }

    function deployFullToken(
        string memory name,
        string memory symbol,
        uint8 decimals,
        address admin,
        uint96 entropy
    ) public returns (address) {
        return _deployImmutable(
            type(FullToken).creationCode, name, symbol, decimals, admin, entropy
        );
    }

    // ---------------------------------------------------------------
    // Upgradeable presets: an implementation plus an ERC-1967 proxy.
    // The proxy address is what holders use. Reusing one implementation
    // across several tokens is fine and cheaper -- pass a non-zero
    // `existingImplementation` to skip deploying another.
    // ---------------------------------------------------------------

    function deployUpgradeablePermitToken(
        string memory name,
        string memory symbol,
        uint8 decimals,
        address admin,
        uint96 entropy,
        address existingImplementation
    ) public returns (address proxy, address implementation) {
        return _deployUpgradeable(
            type(UpgradeablePermitToken).creationCode,
            name,
            symbol,
            decimals,
            admin,
            entropy,
            existingImplementation
        );
    }

    function deployUpgradeableEip3009Token(
        string memory name,
        string memory symbol,
        uint8 decimals,
        address admin,
        uint96 entropy,
        address existingImplementation
    ) public returns (address proxy, address implementation) {
        return _deployUpgradeable(
            type(UpgradeableEip3009Token).creationCode,
            name,
            symbol,
            decimals,
            admin,
            entropy,
            existingImplementation
        );
    }

    function deployUpgradeableFullToken(
        string memory name,
        string memory symbol,
        uint8 decimals,
        address admin,
        uint96 entropy,
        address existingImplementation
    ) public returns (address proxy, address implementation) {
        return _deployUpgradeable(
            type(UpgradeableFullToken).creationCode,
            name,
            symbol,
            decimals,
            admin,
            entropy,
            existingImplementation
        );
    }

    // ---------------------------------------------------------------
    // Shared plumbing
    // ---------------------------------------------------------------

    /**
     * @dev The broadcasting key becomes the issuer, so it -- and only it -- can
     *      make the `initializeAdmin` call that follows.
     *
     *      The issuer must be the account the transactions actually come from,
     *      which is the broadcast account -- not this script's own msg.sender,
     *      which can differ (keystore, multiple keys, no --sender). Deriving
     *      both the issuer and the salt from the broadcaster makes the
     *      `initializeAdmin` call below provably callable.
     *
     *      Parameterizing on creation code trades the compiler's constructor
     *      check for a convention: every immutable preset takes exactly
     *      `(string name, string symbol, uint8 decimals, address issuer)`, as
     *      encoded here, and every upgradeable implementation takes
     *      `(uint8 decimals)`. A preset that deviates still compiles -- the
     *      failure is a reverted deployment -- so a new preset's constructor
     *      must match before it gets an entry point above.
     */
    function _deployImmutable(
        bytes memory creationCode,
        string memory name,
        string memory symbol,
        uint8 decimals,
        address admin,
        uint96 entropy
    ) private returns (address token) {
        vm.startBroadcast();
        (, address issuer,) = vm.readCallers();

        token = _create2(
            saltFor(issuer, entropy),
            abi.encodePacked(creationCode, abi.encode(name, symbol, decimals, issuer)),
            false
        );
        TokenBase(token).initializeAdmin(admin);
        vm.stopBroadcast();

        _report(token, address(0), issuer, admin);
    }

    function _deployUpgradeable(
        bytes memory implCreationCode,
        string memory name,
        string memory symbol,
        uint8 decimals,
        address admin,
        uint96 entropy,
        address existingImplementation
    ) private returns (address proxy, address implementation) {
        // A wrong address here becomes a proxy running arbitrary code, and a
        // proxy cannot be repointed without the upgrade path that wrong code
        // may not have. Checked before anything is broadcast: the address must
        // identify itself as a UUPS implementation, and its decimals -- an
        // immutable read from the implementation's code by every proxy -- must
        // be the one this token is being deployed with. The check cannot see
        // which preset the code was built from, so an explicit address is the
        // operator asserting that part.
        if (existingImplementation != address(0)) {
            if (
                IERC1822Proxiable(existingImplementation).proxiableUUID()
                    != ERC1967Utils.IMPLEMENTATION_SLOT
            ) revert NotAnImplementation(existingImplementation);

            uint8 actual = TokenBase(existingImplementation).decimals();
            if (actual != decimals) revert DecimalsMismatch(actual, decimals);
        }

        vm.startBroadcast();
        // As in `_deployImmutable`: the issuer and both salts key off the
        // broadcast account, so `initializeAdmin` below cannot be left
        // uncallable by a script sender that differs from the broadcaster.
        (, address issuer,) = vm.readCallers();

        implementation = existingImplementation;
        if (implementation == address(0)) {
            // An implementation carries nothing token-specific, so it is keyed
            // by deployer and decimals rather than by the token's entropy --
            // the preset reaches the address through the init code. If this
            // deployer's earlier run already put one at that address -- a
            // second token of the same preset and decimals -- it is reused
            // rather than collided with; a CREATE2 address holding code
            // derived from this exact init code needs no further validation.
            implementation = _create2(
                keccak256(abi.encode(issuer, decimals)),
                abi.encodePacked(implCreationCode, abi.encode(decimals)),
                true
            );
        }

        // The initializer runs inside the proxy constructor, so the token is
        // never on chain in an uninitialized state.
        proxy = _create2(
            saltFor(issuer, entropy),
            abi.encodePacked(
                type(ERC1967Proxy).creationCode,
                abi.encode(
                    implementation,
                    abi.encodeCall(TokenBase.initializeToken, (name, symbol, issuer))
                )
            ),
            false
        );
        TokenBase(proxy).initializeAdmin(admin);

        vm.stopBroadcast();

        _report(proxy, implementation, issuer, admin);
    }

    /// @dev Deploy through the canonical CREATE2 deployer, which is what
    ///      `new C{salt: s}(...)` compiles to inside a broadcast -- spelled out
    ///      here so the init code can be a parameter rather than a type.
    ///
    ///      With `reuseExisting`, code already at the derived address is
    ///      returned instead of collided with -- only for addresses whose
    ///      occupant is fully determined by this exact init code. Without it,
    ///      an occupied address is a failure: for a fresh token the second
    ///      `initializeAdmin` would reveal the collision anyway, but later and
    ///      less legibly.
    function _create2(bytes32 salt, bytes memory initCode, bool reuseExisting)
        private
        returns (address deployed)
    {
        deployed = computeCreate2Address(salt, keccak256(initCode));
        if (reuseExisting && deployed.code.length != 0) return deployed;
        (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(salt, initCode));
        if (!ok || deployed.code.length == 0) revert Create2Failed(deployed);
    }

    /// @notice Confirms the admin landed where it was meant to.
    function verifyAdmin(address token, address admin) public view returns (bool) {
        TokenBase t = TokenBase(token);
        return t.hasRole(t.DEFAULT_ADMIN_ROLE(), admin) && t.adminInitialized();
    }

    function _report(address token, address implementation, address issuer, address admin)
        private
        view
    {
        console.log("token         ", token);
        if (implementation != address(0)) {
            console.log("implementation", implementation);
        }
        console.log("issuer        ", issuer);
        console.log("admin         ", admin);
        console.log("admin set     ", verifyAdmin(token, admin));
    }
}
