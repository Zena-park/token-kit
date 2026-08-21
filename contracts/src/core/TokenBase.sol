// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {
    ERC20Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {
    EIP712Upgradeable
} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/**
 * @title TokenBase
 * @notice The part every preset shares: an ERC-20 with roles, a configurable
 *         decimals value, an EIP-712 domain, and a one-shot admin handover.
 *
 * @dev Why the initializer form even for tokens deployed without a proxy
 *
 *  The kit ships both immutable presets and proxy presets. Written twice -- a
 *  constructor tree and an initializer tree -- every module would exist in two
 *  versions and each fix would have to land in both.
 *
 *  Instead everything is built on the upgradeable base contracts, and the
 *  immutable presets call the initializers from their own constructor. They stay
 *  immutable: no proxy, no delegatecall, no upgrade path. They simply set their
 *  state through a function rather than through inline constructor assignment.
 *
 *  Name and symbol move into storage because a proxy's storage cannot be
 *  written by an implementation's constructor. Decimals does not: see `_DECIMALS`.
 *
 * @dev Why the admin is handed over separately
 *
 *  A CREATE2 address is derived from the init code, so anything in it is baked
 *  into the address.
 *
 *   - name, symbol and the issuer differ per issuer but not per chain. They
 *     belong in the address: two different issuers *should* land on two
 *     addresses. Decimals is fixed in the implementation's code, so it reaches
 *     the address through the implementation rather than through this call.
 *   - admin may legitimately differ per chain -- a different multisig on an L2
 *     than on mainnet. Putting it in would split the address.
 *
 *  So `initializeAdmin` is separate from token setup, on both paths, and only
 *  the issuer named in the init code may call it. That is what keeps the
 *  separation from being a race for anyone watching the mempool, or for anyone
 *  replaying the same init code and salt on a chain the issuer has not reached
 *  yet. Deployment and handover still belong in one broadcast, and the result
 *  still has to be checked. See docs/deploying.md.
 *
 * @dev Why the EIP-712 domain lives here
 *
 *  Per EIP-712 a domain identifies the contract, so a token with three signature
 *  schemes must have exactly one domain separator. Holding it in the base also
 *  keeps the payment modules independent: if each inherited `EIP712` itself,
 *  enabling two at once would fail to compile.
 *
 * @dev Why signature checks use SignatureChecker rather than ecrecover
 *
 *  A passkey-based ERC-4337 account signs with P-256. `ecrecover` only recovers
 *  secp256k1 keys, so such an account could never authorize a transfer.
 *  SignatureChecker dispatches to ECDSA for EOAs and to ERC-1271 for contract
 *  accounts, covering both.
 *
 *  This is also why the payment modules take a `bytes signature` alongside the
 *  `(v, r, s)` triple the EIPs define: a contract signature does not fit in 65
 *  bytes. The triple stays because it is what the EIPs define and what
 *  integrations written against them call; the bytes form is the extension.
 *
 * @dev Storage
 *
 *  State is held in an ERC-7201 namespace rather than in sequential slots. In a
 *  kit where a preset is an inheritance list, sequential slots would make the
 *  layout a function of module composition -- so adding a module to a preset
 *  would shift the storage of every module after it and make existing
 *  deployments un-upgradeable. A namespace pins each module's state to a slot
 *  derived from its own name, independent of what it is combined with.
 */
abstract contract TokenBase is
    Initializable,
    ERC20Upgradeable,
    AccessControlUpgradeable,
    EIP712Upgradeable
{
    // ---------------------------------------------------------------
    // Errors
    //
    // Shared by more than one module. Two sibling modules declaring the same
    // error would collide in a preset that takes both, so anything general
    // enough to recur belongs here.
    // ---------------------------------------------------------------

    error AlreadyInitialized();
    error ZeroAdmin();
    error ZeroIssuer();
    error NotIssuer(address caller, address issuer);
    error LastAdmin();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidSignature();

    // ---------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------

    /// @custom:storage-location erc7201:token-kit.storage.TokenBase
    struct TokenBaseStorage {
        string name;
        string symbol;
        bool identitySet;
        /// @dev The only account that may call `initializeAdmin`. Baked into
        ///      the CREATE2 preimage; see the note above.
        address issuer;
        /**
         * @dev How many accounts hold DEFAULT_ADMIN_ROLE. Maintained so the
         *      last one cannot be removed, and doubling as the record of
         *      whether the handover has happened -- `initializeAdmin` is the
         *      only way to reach the first admin, since `grantRole` needs an
         *      existing one, and the floor below means the count never returns
         *      to zero. A separate `adminInitialized` flag would be the same
         *      fact stored twice, and two facts can disagree.
         */
        uint64 adminCount;
    }

    /// @dev ERC-7201: keccak256(abi.encode(uint256(keccak256(LABEL)) - 1))
    ///      & ~bytes32(uint256(0xff)). Checked against the label in
    ///      test/StorageSlots.t.sol.
    bytes32 internal constant _TOKEN_BASE_STORAGE =
        0xbe40f0ffb339e3c1c1941c67e8680243b30103272a40521747a46d94980f4200;

    function _tokenBaseStorage() private pure returns (TokenBaseStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _TOKEN_BASE_STORAGE
        }
    }

    /**
     * @dev Decimals lives in the implementation's bytecode, not in storage.
     *
     *      Immutables are read from the code being executed, and under a proxy
     *      that is the implementation's code -- so a proxy gets this value
     *      without there being any slot to overwrite. Changing decimals then
     *      requires deploying an implementation with a different constructor
     *      argument, which is visible in its verified source rather than in a
     *      storage write.
     *
     *      The cost is that one implementation can only be shared by tokens
     *      that agree on decimals. For payment tokens that is nearly always six.
     */
    uint8 private immutable _DECIMALS;

    /**
     * @param decimals_ Minor unit count. Six is the usual choice for a payment
     *        token (it matches USDC) even for currencies with no minor unit of
     *        their own: zero decimals cannot express sub-unit pricing, which
     *        rules out micropayments.
     */
    constructor(uint8 decimals_) {
        _DECIMALS = decimals_;
    }

    // ---------------------------------------------------------------
    // Initialization
    // ---------------------------------------------------------------

    /**
     * @param name_ Token name. Also the EIP-712 domain name, so it is fixed for
     *              the life of the contract -- signatures are bound to it.
     * @param symbol_ Token symbol.
     *
     * @dev Refuses to run a second time even under a `reinitializer`, which is
     *      otherwise the ordinary way a later version would reach an
     *      initializer again.
     */
    // solhint-disable-next-line func-name-mixedcase
    function __TokenBase_init(string memory name_, string memory symbol_, address issuer_)
        internal
        onlyInitializing
    {
        TokenBaseStorage storage $ = _tokenBaseStorage();
        if ($.identitySet) revert AlreadyInitialized();
        if (issuer_ == address(0)) revert ZeroIssuer();

        __EIP712_init(name_, "1");

        $.identitySet = true;
        $.name = name_;
        $.symbol = symbol_;
        $.issuer = issuer_;
    }

    /**
     * @notice Set up the token. Callable once, and only on a proxy -- an
     *         immutable preset does this from its constructor instead.
     */
    function initializeToken(string memory name_, string memory symbol_, address issuer_)
        external
        initializer
    {
        __TokenBase_init(name_, symbol_, issuer_);
    }

    /**
     * @notice Hand the contract to its administrator. Callable once, by the
     *         issuer named at deployment.
     *
     * @dev Deliberately separate from token setup so the admin stays out of the
     *      CREATE2 preimage, letting one issuer use a different multisig per
     *      chain without the token address splitting.
     *
     *      The caller check is what makes that separation safe. Without it the
     *      grant is a race: anyone watching the mempool -- or watching a
     *      deployment on one chain and replaying the same init code and salt on
     *      another, since the canonical CREATE2 deployer does not mix the sender
     *      into the salt -- lands `initializeAdmin` first and owns the token.
     *
     *      Note what is in the preimage and what is not. The issuer is a
     *      long-lived identity that is the same on every chain, so binding it
     *      into the address splits nothing; two different issuers *should* reach
     *      two different addresses, exactly as with name and symbol. The admin
     *      is the per-chain multisig, and stays out.
     *
     *      The cost is that losing the issuer key before handover leaves a token
     *      with no admin and no way to appoint one. It is a single call made
     *      immediately after deployment, so the exposure is one transaction
     *      wide; the alternative is leaving the grant open to anyone.
     */
    function initializeAdmin(address admin) external {
        TokenBaseStorage storage $ = _tokenBaseStorage();
        if ($.adminCount != 0) revert AlreadyInitialized();
        if (_msgSender() != $.issuer) revert NotIssuer(_msgSender(), $.issuer);
        if (admin == address(0)) revert ZeroAdmin();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Whether the admin has been handed over.
    function adminInitialized() public view returns (bool) {
        return _tokenBaseStorage().adminCount != 0;
    }

    /**
     * @notice The account entitled to call `initializeAdmin`.
     * @dev Zero on an implementation contract, which is never initialized --
     *      so `initializeAdmin` is unreachable there too, and the implementation
     *      cannot be given an owner by a passer-by.
     */
    function issuer() external view returns (address) {
        return _tokenBaseStorage().issuer;
    }

    // ---------------------------------------------------------------
    // Admin custody
    //
    // AccessControl lets an account drop its own role, and DEFAULT_ADMIN_ROLE is
    // the role that grants every other one. Dropping the last holder -- by
    // `renounceRole`, or by revoking it from the only account that has it --
    // leaves a token no one can ever administer again: no minter can be
    // appointed, no blacklist entry lifted, and on an upgradeable token no fix
    // can be shipped. Both paths run through `_revokeRole`, so the floor is
    // enforced there once rather than at each entry point.
    // ---------------------------------------------------------------

    /// @inheritdoc AccessControlUpgradeable
    function _grantRole(bytes32 role, address account)
        internal
        virtual
        override
        returns (bool granted)
    {
        granted = super._grantRole(role, account);
        if (granted && role == DEFAULT_ADMIN_ROLE) {
            unchecked {
                ++_tokenBaseStorage().adminCount;
            }
        }
    }

    /// @inheritdoc AccessControlUpgradeable
    function _revokeRole(bytes32 role, address account)
        internal
        virtual
        override
        returns (bool revoked)
    {
        revoked = super._revokeRole(role, account);
        if (revoked && role == DEFAULT_ADMIN_ROLE) {
            TokenBaseStorage storage $ = _tokenBaseStorage();
            uint64 remaining = $.adminCount;
            if (remaining == 1) revert LastAdmin();
            unchecked {
                $.adminCount = remaining - 1;
            }
        }
    }

    // ---------------------------------------------------------------
    // Identity
    //
    // Name and symbol are read from this contract's own namespace rather than
    // from `ERC20Upgradeable`'s slots, and `__ERC20_init` is never called. A
    // later implementation that re-ran the standard ERC-20 initializer would
    // write slots nothing here reads. Decimals is not here at all; it is in the
    // implementation's code, where there is no slot to write.
    //
    // This does not make identity unchangeable. An implementation that writes
    // this namespace directly still can, because that is what upgradeability
    // means. It makes the change deliberate and legible instead of incidental,
    // and `identityHash` gives an observer something to compare during the
    // delay before an upgrade takes effect.
    // ---------------------------------------------------------------

    /// @inheritdoc ERC20Upgradeable
    function name() public view override returns (string memory) {
        return _tokenBaseStorage().name;
    }

    /// @inheritdoc ERC20Upgradeable
    function symbol() public view override returns (string memory) {
        return _tokenBaseStorage().symbol;
    }

    /// @notice Minor units. Fixed in the implementation's code.
    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    /**
     * @dev The EIP-712 domain name reads the same slot `name()` does, so the
     *      two cannot drift apart. Keeping them in separate places is how a
     *      token ends up reporting one name while verifying signatures against
     *      another.
     */
    // solhint-disable-next-line func-name-mixedcase
    function _EIP712Name() internal view override returns (string memory) {
        return _tokenBaseStorage().name;
    }

    /**
     * @notice Digest of everything that must never change.
     *
     * @dev The two fail differently and both matter. A changed decimals value
     *      silently reprices every balance. A changed name changes the EIP-712
     *      domain, invalidating every outstanding EIP-3009 and EIP-2612
     *      signature. Record this before an upgrade is scheduled and compare
     *      after it lands; the delay exists so there is time to.
     */
    function identityHash() external view returns (bytes32) {
        TokenBaseStorage storage $ = _tokenBaseStorage();
        return keccak256(abi.encode($.name, $.symbol, _DECIMALS));
    }

    /// @notice The EIP-712 domain separator signatures are checked against.
    /// @dev Exposed so off-chain signers can reproduce it without guessing.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ---------------------------------------------------------------
    // Shared compliance predicate
    // ---------------------------------------------------------------

    /**
     * @dev Whether an `_approve` write is a user-facing allowance raise --
     *      the one kind of allowance write the compliance modules gate.
     *      `emitEvent` is false only for `_spendAllowance`'s write-back,
     *      which is a spend, not a grant.
     *
     *      The strict comparison is load-bearing. Re-approving the exact
     *      current value grants nothing, and `>=` would turn an idempotent
     *      revocation -- approving zero at zero -- into a revert, closing the
     *      path the compliance modules promise to keep open: a holder must
     *      always be able to revoke, under a pause and under a listing alike.
     *
     *      Shared here so the boundary is decided once. When two modules gate
     *      the same write, each evaluates this; the second allowance read is
     *      warm, the cost of the modules not knowing about each other.
     */
    function _isAllowanceRaise(address owner, address spender, uint256 value, bool emitEvent)
        internal
        view
        returns (bool)
    {
        return emitEvent && value > allowance(owner, spender);
    }

    // ---------------------------------------------------------------
    // Shared signature verification
    // ---------------------------------------------------------------

    /**
     * @dev Hash an EIP-712 struct under this token's domain and verify it.
     *      Accepts both EOA (ECDSA) and contract (ERC-1271) signers.
     */
    function _requireValidSignature(address signer, bytes32 structHash, bytes memory signature)
        internal
        view
    {
        bytes32 digest = _hashTypedDataV4(structHash);
        if (!SignatureChecker.isValidSignatureNow(signer, digest, signature)) {
            revert InvalidSignature();
        }
    }

    /**
     * @dev The spec-form `(v, r, s)` triple in the 65-byte layout the verifier
     *      above takes. The layout is a fact about the verifier, so it is
     *      spelled once here rather than in each module that exposes a spec
     *      form entry point.
     */
    function _packSignature(uint8 v, bytes32 r, bytes32 s) internal pure returns (bytes memory) {
        return abi.encodePacked(r, s, v);
    }
}
