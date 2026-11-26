// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Rule} from "./Presets.sol";
import {
    PresetCoreStack,
    PresetCoreSorted,
    PresetFreezeStack,
    PresetFreezeSorted,
    PresetClassStack,
    PresetClassSorted,
    PresetBothStack,
    PresetBothSorted,
    PresetBothStackTight,
    PresetBothSortedTight,
    PresetAcceptStack,
    PresetAcceptSorted,
    PresetAllStack,
    PresetAllSorted,
    PresetCoreConsolStack,
    PresetCoreConsolSorted,
    PresetFreezeConsolStack,
    PresetFreezeConsolSorted,
    PresetClassConsolStack,
    PresetClassConsolSorted,
    PresetBothConsolStack,
    PresetBothConsolSorted,
    PresetCoreStackWindow,
    PresetBothStackWindow,
    PresetBothStackWindowTight,
    PresetBothConsolStackWindow
} from "./Presets.sol";
import {ERCXXXX} from "../../contracts/ERCXXXX.sol";
import {IERCXXXX} from "../../contracts/spec/IERCXXXX.sol";

/// @dev All external functions of the test tokens: ERC-20, the core interface (including consolidation), burning,
///      the two extensions (freezing and classification), this implementation's own forced operations that take a
///      position hint and the tidying function, and the admin functions for testing. A token that does not support
///      an extension does not have the corresponding functions, and the tests skip them by supportsInterface; a
///      token without the functions that take a position hint or without the tidying function is skipped for them
///      by whether a call succeeds.
interface ITestToken {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);

    function supportsInterface(bytes4 interfaceId) external view returns (bool);

    function serialsIssued() external view returns (uint256);
    function sliceCount(address account) external view returns (uint256);
    function sliceAt(address account, uint256 index) external view returns (uint256 start, uint256 amount);
    function transferSlices(address to, uint256[] calldata starts, uint256[] calldata amounts) external returns (bool);
    function transferableBalanceOf(address from, address to) external view returns (uint256);

    function burn(uint256 value) external;
    function burnFrom(address account, uint256 value) external;
    function burnSlices(uint256[] calldata starts, uint256[] calldata amounts) external;

    function freezeSlice(uint256 start, uint256 amount, bytes32 reason) external;
    function unfreezeSlice(uint256 start, uint256 amount, bytes32 reason) external;
    function forcedTransferSlice(address from, address to, uint256 start, uint256 amount) external;
    function destroySlice(address from, uint256 start, uint256 amount) external;
    function forcedTransferSliceAt(
        address from,
        address to,
        uint256 start,
        uint256 amount,
        bytes32 pile,
        uint256 index
    ) external;
    function destroySliceAt(address from, uint256 start, uint256 amount, bytes32 pile, uint256 index) external;
    function serialPositionOf(address account, uint256 serial)
        external
        view
        returns (bool held, bytes32 pile, uint256 index, uint256 rangeStart, uint256 rangeAmount);
    function tidySlices(address account, bytes32 pile, uint256 maxMoves) external returns (uint256 moved);
    function frozenRunAt(uint256 serial) external view returns (bool frozen, uint256 length);
    function frozenBalanceOf(address account) external view returns (uint256);
    function freezeReasonsOf(address account) external view returns (bytes32[] memory, uint256[] memory);
    function freezeReasonInfo(bytes32 reason) external view returns (string memory, string memory);

    function classRunAt(uint256 serial) external view returns (bytes32 classId, uint256 length);
    function classAllows(bytes32 classId, address from, address to) external view returns (bool);
    function classesOf(address account) external view returns (bytes32[] memory, uint256[] memory);
    function classInfo(bytes32 classId) external view returns (string memory, string memory);

    function consolidateSlices(uint256[] calldata starts, uint256[] calldata amounts) external returns (uint256 newStart);
    function consolidatedRunAt(uint256 serial)
        external
        view
        returns (bool consolidated, uint256 successor, uint256 length);

    function openMint(address to, uint256 value) external;
    function openMintWithClass(address to, uint256 value, bytes32 classId) external;

    function admin() external view returns (address);
    function transferAdmin(address newAdmin) external;
    function mint(address to, uint256 value) external;
    function mintWithClass(address to, uint256 value, bytes32 classId) external;
    function setReasonInfo(bytes32 reason, string calldata name_, string calldata uri) external;
    function defineClass(bytes32 classId, Rule rule, uint64 unlockTime, string calldata name_, string calldata uri)
        external;
    function setAllowed(bytes32 classId, address account, bool allowed) external;
    function setClass(uint256 start, uint256 amount, bytes32 classId) external;
}

/// @dev What is wrong with the revert data of a consolidateSlices call on a token that keeps consolidation closed,
///      when the arguments are valid and the serials are all held by the caller, not frozen and of the same class:
///      the data has to carry a custom error that is not an error about the arguments, holding, transferability or
///      consolidatability, and not a Panic (otherwise the call might have reverted for another reason, not because
///      consolidation is closed). Returns the empty string when nothing is wrong.
function closedConsolidationErrorProblem(bytes memory err) pure returns (string memory) {
    if (err.length < 4) return "closed consolidation must revert with an error";
    bytes4 sel = bytes4(err);
    if (sel == IERCXXXX.ERCXXXXNotHeld.selector) return "closed consolidation reverted with NotHeld";
    if (sel == IERCXXXX.ERCXXXXNotConsolidatable.selector) {
        return "closed consolidation reverted with NotConsolidatable";
    }
    if (sel == IERCXXXX.ERCXXXXNotTransferable.selector) {
        return "closed consolidation reverted with NotTransferable";
    }
    if (sel == ERCXXXX.ERCXXXXInvalidRanges.selector) {
        return "closed consolidation reverted with InvalidRanges";
    }
    if (sel == ERCXXXX.ERCXXXXInvalidRange.selector) {
        return "closed consolidation reverted with InvalidRange";
    }
    if (sel == bytes4(0x4e487b71)) return "closed consolidation reverted with a panic";
    return "";
}

/// @dev The token under test. Each concrete test contract inherits both a test base contract and one of the targets
///      below.
abstract contract TokenTarget {
    /// @dev Deploys a token named "Serial" with the symbol "SRL", 6 decimals and admin as its admin, and states which
    ///      extensions it is expected to support (freeze, class_) and whether it opens consolidation (consol).
    ///      Consolidation belongs to the core interface and has no separate interface id, so the tests cannot tell
    ///      by supportsInterface, and each target marks it explicitly here: a target with consol true inherits the
    ///      consolidation module ERCXXXXConsolidation; in a target with consol false, consolidation is closed, and
    ///      the tests assert the closed behavior (consolidateSlices always reverts, consolidatedRunAt reports no
    ///      consolidated serial).
    function _deployToken(address admin)
        internal
        virtual
        returns (ITestToken token, bool freeze, bool class_, bool consol);
}

abstract contract TargetCoreStack is TokenTarget {
    function _deployToken(address a) internal override returns (ITestToken, bool, bool, bool) {
        return (ITestToken(address(new PresetCoreStack("Serial", "SRL", 6, a))), false, false, false);
    }
}

abstract contract TargetCoreSorted is TokenTarget {
    function _deployToken(address a) internal override returns (ITestToken, bool, bool, bool) {
        return (ITestToken(address(new PresetCoreSorted("Serial", "SRL", 6, a))), false, false, false);
    }
}

abstract contract TargetFreezeStack is TokenTarget {
    function _deployToken(address a) internal override returns (ITestToken, bool, bool, bool) {
        return (ITestToken(address(new PresetFreezeStack("Serial", "SRL", 6, a))), true, false, false);
    }
}

abstract contract TargetFreezeSorted is TokenTarget {
    function _deployToken(address a) internal override returns (ITestToken, bool, bool, bool) {
        return (ITestToken(address(new PresetFreezeSorted("Serial", "SRL", 6, a))), true, false, false);
    }
}

abstract contract TargetClassStack is TokenTarget {
    function _deployToken(address a) internal override returns (ITestToken, bool, bool, bool) {
        return (ITestToken(address(new PresetClassStack("Serial", "SRL", 6, a))), false, true, false);
    }
}

abstract contract TargetClassSorted is TokenTarget {
    function _deployToken(address a) internal override returns (ITestToken, bool, bool, bool) {
        return (ITestToken(address(new PresetClassSorted("Serial", "SRL", 6, a))), false, true, false);
    }
}

abstract contract TargetBothStack is TokenTarget {
    function _deployToken(address a) internal override returns (ITestToken, bool, bool, bool) {
        return (ITestToken(address(new PresetBothStack("Serial", "SRL", 6, a))), true, true, false);
    }
}

abstract contract TargetBothSorted is TokenTarget {
    function _deployToken(address a) internal override returns (ITestToken, bool, bool, bool) {
        return (ITestToken(address(new PresetBothSorted("Serial", "SRL", 6, a))), true, true, false);
    }
}

abstract contract TargetBothStackTight is TokenTarget {
    function _deployToken(address a) internal override returns (ITestToken, bool, bool, bool) {
        return (ITestToken(address(new PresetBothStackTight("Serial", "SRL", 6, a))), true, true, false);
    }
}

abstract contract TargetBothSortedTight is TokenTarget {
    function _deployToken(address a) internal override returns (ITestToken, bool, bool, bool) {
        return (ITestToken(address(new PresetBothSortedTight("Serial", "SRL", 6, a))), true, true, false);
    }
}

abstract contract TargetAcceptStack is TokenTarget {
    function _deployToken(address a) internal override returns (ITestToken, bool, bool, bool) {
        return (ITestToken(address(new PresetAcceptStack("Serial", "SRL", 6, a))), false, false, false);
    }
}

abstract contract TargetAcceptSorted is TokenTarget {
    function _deployToken(address a) internal override returns (ITestToken, bool, bool, bool) {
        return (ITestToken(address(new PresetAcceptSorted("Serial", "SRL", 6, a))), false, false, false);
    }
}

abstract contract TargetAllStack is TokenTarget {
    function _deployToken(address a) internal override returns (ITestToken, bool, bool, bool) {
        return (ITestToken(address(new PresetAllStack("Serial", "SRL", 6, a))), true, true, false);
    }
}

abstract contract TargetAllSorted is TokenTarget {
    function _deployToken(address a) internal override returns (ITestToken, bool, bool, bool) {
        return (ITestToken(address(new PresetAllSorted("Serial", "SRL", 6, a))), true, true, false);
    }
}

abstract contract TargetCoreConsolStack is TokenTarget {
    function _deployToken(address a) internal override returns (ITestToken, bool, bool, bool) {
        return (ITestToken(address(new PresetCoreConsolStack("Serial", "SRL", 6, a))), false, false, true);
    }
}

abstract contract TargetCoreConsolSorted is TokenTarget {
    function _deployToken(address a) internal override returns (ITestToken, bool, bool, bool) {
        return (ITestToken(address(new PresetCoreConsolSorted("Serial", "SRL", 6, a))), false, false, true);
    }
}

abstract contract TargetFreezeConsolStack is TokenTarget {
    function _deployToken(address a) internal override returns (ITestToken, bool, bool, bool) {
        return (ITestToken(address(new PresetFreezeConsolStack("Serial", "SRL", 6, a))), true, false, true);
    }
}

abstract contract TargetFreezeConsolSorted is TokenTarget {
    function _deployToken(address a) internal override returns (ITestToken, bool, bool, bool) {
        return (ITestToken(address(new PresetFreezeConsolSorted("Serial", "SRL", 6, a))), true, false, true);
    }
}

abstract contract TargetClassConsolStack is TokenTarget {
    function _deployToken(address a) internal override returns (ITestToken, bool, bool, bool) {
        return (ITestToken(address(new PresetClassConsolStack("Serial", "SRL", 6, a))), false, true, true);
    }
}

abstract contract TargetClassConsolSorted is TokenTarget {
    function _deployToken(address a) internal override returns (ITestToken, bool, bool, bool) {
        return (ITestToken(address(new PresetClassConsolSorted("Serial", "SRL", 6, a))), false, true, true);
    }
}

abstract contract TargetBothConsolStack is TokenTarget {
    function _deployToken(address a) internal override returns (ITestToken, bool, bool, bool) {
        return (ITestToken(address(new PresetBothConsolStack("Serial", "SRL", 6, a))), true, true, true);
    }
}

abstract contract TargetBothConsolSorted is TokenTarget {
    function _deployToken(address a) internal override returns (ITestToken, bool, bool, bool) {
        return (ITestToken(address(new PresetBothConsolSorted("Serial", "SRL", 6, a))), true, true, true);
    }
}

// Targets for the second rule ("best fit in a bounded window"). The window is 3: in the invariant tests an account
// often holds more than ten slices, so the window is really smaller than the number of slices.

/// @dev The window size of the second rule, shared by all targets with a window.
uint256 constant TEST_WINDOW = 3;

abstract contract TargetCoreStackWindow is TokenTarget {
    function _deployToken(address a) internal override returns (ITestToken, bool, bool, bool) {
        return (
            ITestToken(address(new PresetCoreStackWindow("Serial", "SRL", 6, a, TEST_WINDOW))), false, false, false
        );
    }
}

abstract contract TargetBothStackWindow is TokenTarget {
    function _deployToken(address a) internal override returns (ITestToken, bool, bool, bool) {
        return (ITestToken(address(new PresetBothStackWindow("Serial", "SRL", 6, a, TEST_WINDOW))), true, true, false);
    }
}

abstract contract TargetBothStackWindowTight is TokenTarget {
    function _deployToken(address a) internal override returns (ITestToken, bool, bool, bool) {
        return (
            ITestToken(address(new PresetBothStackWindowTight("Serial", "SRL", 6, a, TEST_WINDOW))), true, true, false
        );
    }
}

abstract contract TargetBothConsolStackWindow is TokenTarget {
    function _deployToken(address a) internal override returns (ITestToken, bool, bool, bool) {
        return (
            ITestToken(address(new PresetBothConsolStackWindow("Serial", "SRL", 6, a, TEST_WINDOW))), true, true, true
        );
    }
}
