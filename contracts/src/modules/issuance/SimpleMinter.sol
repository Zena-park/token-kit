// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {TokenBase} from "../../core/TokenBase.sol";

/**
 * @title SimpleMinter
 * @notice One role, unlimited mint. The plain option.
 *
 * @dev Scope
 *
 *  Testnets, internal ledgers and closed-loop points. Also applicable where one
 *  custodian holds every key, since MinterControl's separation depends on the
 *  Controller and the Minter being held apart.
 *
 * @dev What it does not do
 *
 *  There is no ceiling: a leaked MINTER_ROLE key mints without bound, and the
 *  loss is capped only by how fast someone notices. It carries no timelock and
 *  no guardian. MinterControl is the alternative, and its header sets out the
 *  comparison.
 */
abstract contract SimpleMinter is TokenBase {
    /// @notice May mint and burn without limit.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Mint to an arbitrary address.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (amount == 0) revert ZeroAmount();
        _mint(to, amount);
    }

    /// @notice Burn from own balance.
    function burn(uint256 amount) external onlyRole(MINTER_ROLE) {
        if (amount == 0) revert ZeroAmount();
        _burn(_msgSender(), amount);
    }
}
