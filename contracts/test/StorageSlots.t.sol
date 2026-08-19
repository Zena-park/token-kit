// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SlotDerivation} from "@openzeppelin/contracts/utils/SlotDerivation.sol";
import {UpgradeableFullToken} from "../src/presets/upgradeable/UpgradeableFullToken.sol";

/**
 * @dev Each namespace constant must equal the ERC-7201 derivation of its label.
 *      A mismatch would put a module's state at an address nothing else agrees
 *      on, and would only show up as silently missing storage.
 *
 *      The derivation comes from OpenZeppelin rather than being written out
 *      again here. A local copy of the formula would be checking six constants
 *      against a second implementation of the very thing under test -- and if
 *      the copy were wrong, all six would agree with it.
 *
 *      The constants are read out of the contracts through the harness below,
 *      not retyped here. A literal copied into this file would still pass after
 *      a module's constant drifted -- the test would pin the copy, not the
 *      contract.
 */
contract SlotSurface is UpgradeableFullToken {
    constructor() UpgradeableFullToken(6) {}

    function tokenBaseSlot() external pure returns (bytes32) {
        return _TOKEN_BASE_STORAGE;
    }

    function blacklistSlot() external pure returns (bytes32) {
        return _BLACKLIST_STORAGE;
    }

    function seizeSlot() external pure returns (bytes32) {
        return _SEIZE_STORAGE;
    }

    function minterControlSlot() external pure returns (bytes32) {
        return _MINTER_CONTROL_STORAGE;
    }

    function eip3009Slot() external pure returns (bytes32) {
        return _EIP3009_STORAGE;
    }

    function upgradeControlSlot() external pure returns (bytes32) {
        return _UPGRADE_CONTROL_STORAGE;
    }
}

contract StorageSlotsTest is Test {
    SlotSurface surface = new SlotSurface();

    function test_namespace_constants_match_their_labels() public view {
        assertEq(SlotDerivation.erc7201Slot("token-kit.storage.TokenBase"), surface.tokenBaseSlot());
        assertEq(SlotDerivation.erc7201Slot("token-kit.storage.Blacklist"), surface.blacklistSlot());
        assertEq(SlotDerivation.erc7201Slot("token-kit.storage.Seize"), surface.seizeSlot());
        assertEq(
            SlotDerivation.erc7201Slot("token-kit.storage.MinterControl"),
            surface.minterControlSlot()
        );
        assertEq(SlotDerivation.erc7201Slot("token-kit.storage.Eip3009"), surface.eip3009Slot());
        assertEq(
            SlotDerivation.erc7201Slot("token-kit.storage.UpgradeControl"),
            surface.upgradeControlSlot()
        );
    }
}
