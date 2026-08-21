// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {TokenBase} from "../../src/core/TokenBase.sol";
import {MinimalToken} from "../../src/presets/MinimalToken.sol";
import {UpgradeablePermitToken} from "../../src/presets/upgradeable/UpgradeablePermitToken.sol";

/// @dev A UUPS implementation that is not one of this kit's tokens: it answers
///      ERC-1822 but has no `decimals()`.
contract ForeignUups is UUPSUpgradeable {
    function _authorizeUpgrade(address) internal override {}
}

/**
 * @dev The deploy script is the one piece of code that decides what ends up
 *      at which address, and a proxy pointed at the wrong code cannot be
 *      repaired afterwards. Foundry's test executor has the canonical CREATE2
 *      deployer at its usual address, so the script runs here unmodified:
 *      `vm.startBroadcast()` records rather than sends, and the account it
 *      broadcasts as is `DEFAULT_SENDER` -- not this test contract, which is
 *      the script's `msg.sender`. The two differing is what lets these tests
 *      tell the issuer the script records apart from the caller it was given.
 */
contract DeployTest is Test {
    Deploy deploy;

    address admin = makeAddr("admin");

    function setUp() public {
        deploy = new Deploy();
    }

    /// @dev Upgradeable entry points share one tail; the tests vary only the
    ///      terms that matter to each.
    function _proxy(string memory name, uint8 decimals, uint96 entropy, address impl)
        private
        returns (address proxy, address implementation)
    {
        return deploy.deployUpgradeablePermitToken(name, name, decimals, admin, entropy, impl);
    }

    // ---------------------------------------------------------------
    // Salt
    // ---------------------------------------------------------------

    /// @dev Deployer in the leading 20 bytes, entropy in the trailing 12: the
    ///      convention CreateX enforces and the plainer deployers rely on.
    function test_salt_puts_the_deployer_in_the_leading_bytes(address deployer, uint96 entropy)
        public
        view
    {
        bytes32 salt = deploy.saltFor(deployer, entropy);
        assertEq(address(bytes20(salt)), deployer);
        assertEq(uint96(uint256(salt)), entropy);
    }

    // ---------------------------------------------------------------
    // Immutable presets
    // ---------------------------------------------------------------

    /// @dev The issuer is the account that broadcast, not the account that
    ///      called the script. The distinction is the whole reason the script
    ///      reads it off the broadcast: a script sender that differed from the
    ///      broadcaster would otherwise bake an issuer nobody holds into the
    ///      address.
    function test_the_issuer_is_the_broadcaster_not_the_script_caller() public {
        address token = deploy.deployMinimalToken("Acme", "ACME", 6, admin, 1);

        assertEq(TokenBase(token).issuer(), DEFAULT_SENDER);
        assertTrue(TokenBase(token).issuer() != address(this));
        assertTrue(deploy.verifyAdmin(token, admin));
        assertFalse(MinimalToken(token).hasRole(bytes32(0), DEFAULT_SENDER), "issuer keeps no role");
    }

    /// @dev The address is a pure function of the deployer, the salt and the
    ///      init code. Recomputing it here from those three inputs is the same
    ///      computation an operator does before reaching a second chain.
    function test_immutable_lands_on_the_predicted_address() public {
        address token = deploy.deployMinimalToken("Acme", "ACME", 6, admin, 1);

        bytes memory initCode = abi.encodePacked(
            type(MinimalToken).creationCode, abi.encode("Acme", "ACME", uint8(6), DEFAULT_SENDER)
        );
        assertEq(
            token, computeCreate2Address(deploy.saltFor(DEFAULT_SENDER, 1), keccak256(initCode))
        );
    }

    /// @dev Every immutable entry point goes through the same plumbing; each
    ///      is exercised once so a constructor drifting from the shared
    ///      `(name, symbol, decimals, issuer)` shape fails here, not on chain.
    function test_every_immutable_preset_deploys() public {
        assertTrue(deploy.verifyAdmin(deploy.deployPermitToken("B", "B", 6, admin, 1), admin));
        assertTrue(deploy.verifyAdmin(deploy.deployEip3009Token("C", "C", 6, admin, 1), admin));
        assertTrue(deploy.verifyAdmin(deploy.deployFullToken("D", "D", 6, admin, 1), admin));
    }

    /// @dev Same issuer, same terms, same salt: the address is taken, and the
    ///      script says so rather than silently returning someone else's token.
    function test_redeploying_the_same_token_fails_loudly() public {
        address token = deploy.deployMinimalToken("Acme", "ACME", 6, admin, 1);

        vm.expectRevert(abi.encodeWithSelector(Deploy.Create2Failed.selector, token));
        deploy.deployMinimalToken("Acme", "ACME", 6, admin, 1);
    }

    // ---------------------------------------------------------------
    // Upgradeable presets
    // ---------------------------------------------------------------

    function test_upgradeable_deploys_a_proxy_pointed_at_a_fresh_implementation() public {
        (address proxy, address impl) = _proxy("Acme", 6, 1, address(0));

        assertEq(address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT)))), impl);
        assertEq(TokenBase(proxy).issuer(), DEFAULT_SENDER);
        assertTrue(deploy.verifyAdmin(proxy, admin));

        // The implementation is locked: it names no issuer and takes no admin.
        assertEq(TokenBase(impl).issuer(), address(0));
        assertFalse(TokenBase(impl).adminInitialized());
    }

    /// @dev The initializer runs inside the proxy constructor, so there is no
    ///      block in which `initializeToken` is open to whoever calls first --
    ///      the race the issuer exists to close.
    function test_a_finished_proxy_cannot_be_initialized_again() public {
        (address proxy,) = _proxy("Acme", 6, 1, address(0));

        vm.prank(makeAddr("squatter"));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        TokenBase(proxy).initializeToken("Hijack", "HJK", makeAddr("squatter"));
    }

    /// @dev The proxy address follows the same formula as an immutable token,
    ///      with the proxy's init code -- implementation plus the
    ///      `initializeToken` call -- in place of the token's.
    function test_proxy_lands_on_the_predicted_address() public {
        (address proxy, address impl) = _proxy("Acme", 6, 7, address(0));

        bytes memory initCode = abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(
                impl, abi.encodeCall(TokenBase.initializeToken, ("Acme", "Acme", DEFAULT_SENDER))
            )
        );
        assertEq(
            proxy, computeCreate2Address(deploy.saltFor(DEFAULT_SENDER, 7), keccak256(initCode))
        );
    }

    /// @dev One implementation per (deployer, preset, decimals). A second
    ///      token that agrees on all three reuses it, and the two proxies keep
    ///      separate storage and separate admins.
    function test_a_second_token_reuses_the_implementation_but_not_the_state() public {
        (address proxyA, address implA) = _proxy("A", 6, 1, address(0));
        (address proxyB, address implB) = _proxy("B", 6, 2, address(0));

        assertEq(implA, implB);
        assertTrue(proxyA != proxyB);
        assertEq(UpgradeablePermitToken(proxyA).name(), "A");
        assertEq(UpgradeablePermitToken(proxyB).name(), "B");
        assertEq(
            UpgradeablePermitToken(proxyA).identityHash()
                == UpgradeablePermitToken(proxyB).identityHash(),
            false
        );
    }

    function test_implementations_are_keyed_by_preset_and_decimals() public {
        (, address six) = _proxy("A", 6, 1, address(0));
        (, address eighteen) = _proxy("B", 18, 2, address(0));
        (, address other) = deploy.deployUpgradeableEip3009Token("C", "C", 6, admin, 3, address(0));

        assertTrue(six != eighteen);
        assertTrue(six != other);
        assertEq(TokenBase(eighteen).decimals(), 18);
    }

    function test_the_full_upgradeable_preset_deploys() public {
        (address proxy,) = deploy.deployUpgradeableFullToken("C", "C", 6, admin, 1, address(0));
        assertTrue(deploy.verifyAdmin(proxy, admin));
    }

    // ---------------------------------------------------------------
    // An explicit implementation is checked before anything is broadcast
    // ---------------------------------------------------------------

    function test_an_explicit_implementation_is_reused_as_given() public {
        (, address impl) = _proxy("A", 6, 1, address(0));

        (address proxy, address used) = _proxy("B", 6, 2, impl);
        assertEq(used, impl);
        assertTrue(deploy.verifyAdmin(proxy, admin));
    }

    /// @dev A proxy pointed at code without an upgrade path can never be
    ///      repointed, and a proxy pointed at someone else's UUPS code is not
    ///      this token. Each wrong kind of address -- empty, not UUPS, UUPS but
    ///      not a kit token -- is refused with the same typed error rather
    ///      than a bare revert from whichever probe it failed to answer.
    function test_a_wrong_implementation_is_refused_with_a_typed_error() public {
        address[3] memory wrong = [
            makeAddr("empty"),
            deploy.deployPermitToken("A", "A", 6, admin, 1),
            address(new ForeignUups())
        ];

        for (uint256 i = 0; i < wrong.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(Deploy.NotAnImplementation.selector, wrong[i]));
            _proxy("B", 6, 2, wrong[i]);
        }
    }

    /// @dev Decimals is read from the implementation's code by every proxy, so
    ///      a mismatch would silently give the new token the wrong decimals.
    function test_an_implementation_with_other_decimals_is_refused() public {
        (, address eighteen) = _proxy("A", 18, 1, address(0));

        vm.expectRevert(abi.encodeWithSelector(Deploy.DecimalsMismatch.selector, 18, 6));
        _proxy("B", 6, 2, eighteen);
    }

    // ---------------------------------------------------------------
    // verifyAdmin
    // ---------------------------------------------------------------

    function test_verify_admin_is_false_for_anyone_else() public {
        address token = deploy.deployMinimalToken("A", "A", 6, admin, 1);
        assertFalse(deploy.verifyAdmin(token, makeAddr("other")));
    }
}
