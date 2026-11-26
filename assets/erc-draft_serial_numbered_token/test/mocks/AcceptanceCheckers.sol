// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IERCXXXXAcceptance} from "../../contracts/spec/IERCXXXXAcceptance.sol";

/// @dev The value a recipient returns to accept, 0x4689efd4.
bytes4 constant ACCEPT = IERCXXXXAcceptance.acceptsERCXXXXTransfer.selector;
bytes4 constant ERC165_ID = 0x01ffc9a7;
bytes4 constant INVALID_ID = 0xffffffff;

interface IPull {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/// @dev Uses about `amount` gas. When less than that remains, it loops until the gas runs out; it does not revert
///      early and return the unused gas.
function _burn(uint256 amount) view {
    uint256 left = gasleft();
    uint256 stop = left > amount ? left - amount : 0;
    while (gasleft() > stop) {}
}

// ───────────────────────── Conforming receiving contracts ─────────────────────────

/// @dev A receiving contract that declares IERCXXXXAcceptance through ERC-165.
abstract contract Receiver is IERCXXXXAcceptance {
    function supportsInterface(bytes4 id) public view virtual returns (bool) {
        return id == ERC165_ID || id == type(IERCXXXXAcceptance).interfaceId;
    }
}

/// @dev R of the acceptance check sequence in the draft's test cases: accepts when the number of slices is not
///      greater than the limit, and returns 0x00000000 otherwise.
contract RangeLimitReceiver is Receiver {
    uint256 public immutable maxRanges;

    constructor(uint256 maxRanges_) {
        maxRanges = maxRanges_;
    }

    function acceptsERCXXXXTransfer(address, address, uint256, uint256 slices) external view returns (bytes4) {
        return slices <= maxRanges ? ACCEPT : bytes4(0);
    }
}

/// @dev S of the acceptance check sequence in the draft's test cases: always reverts; anyone can make it pull units
///      by calling transferFrom(from, S, value) on the token.
contract PullingReceiver is Receiver {
    error Refused();

    address public immutable token;

    constructor(address token_) {
        token = token_;
    }

    function acceptsERCXXXXTransfer(address, address, uint256, uint256) external pure returns (bytes4) {
        revert Refused();
    }

    function pull(address from, uint256 value) external {
        IPull(token).transferFrom(from, address(this), value);
    }
}

/// @dev Accepts everything.
contract AcceptAllReceiver is Receiver {
    function acceptsERCXXXXTransfer(address, address, uint256, uint256) external pure returns (bytes4) {
        return ACCEPT;
    }
}

/// @dev Returns 0x00000000.
contract ZeroReturnReceiver is Receiver {
    function acceptsERCXXXXTransfer(address, address, uint256, uint256) external pure returns (bytes4) {
        return bytes4(0);
    }
}

/// @dev Accepts only a call whose arguments are exactly the ones set beforehand, and whose caller is the given
///      token. Used to check the arguments the token passes.
contract ExactReceiver is Receiver {
    address public token;
    bytes32 public expected;

    function expect(address token_, address operator, address from, uint256 value, uint256 ranges) external {
        token = token_;
        expected = keccak256(abi.encode(operator, from, value, ranges));
    }

    function acceptsERCXXXXTransfer(address operator, address from, uint256 value, uint256 slices)
        external
        view
        returns (bytes4)
    {
        if (msg.sender != token) return bytes4(0);
        return keccak256(abi.encode(operator, from, value, slices)) == expected ? ACCEPT : bytes4(0);
    }
}

/// @dev Accepts when its own balance in the token is not less than the threshold. Used to observe whether the call
///      takes place before or after the change of holder.
contract BalanceThresholdReceiver is Receiver {
    uint256 public immutable threshold;

    constructor(uint256 threshold_) {
        threshold = threshold_;
    }

    function acceptsERCXXXXTransfer(address, address, uint256, uint256) external view returns (bytes4) {
        (bool ok, bytes memory ret) =
            msg.sender.staticcall(abi.encodeWithSignature("balanceOf(address)", address(this)));
        return ok && abi.decode(ret, (uint256)) >= threshold ? ACCEPT : bytes4(0);
    }
}

/// @dev acceptsERCXXXXTransfer first uses about `used` gas and then accepts. Used to show that this implementation
///      does not limit the gas forwarded to it.
contract ExpensiveAcceptReceiver is Receiver {
    uint256 public immutable used;

    constructor(uint256 used_) {
        used = used_;
    }

    function acceptsERCXXXXTransfer(address, address, uint256, uint256) external view returns (bytes4) {
        _burn(used);
        return ACCEPT;
    }
}

/// @dev supportsInterface conforms but uses about 20,000 gas (within the 30,000 of ERC-165);
///      when `accepting` is false, it refuses everything. Used to test that a payer cannot bypass the acceptance
///      check by lowering the gas.
contract HeavyReceiver is IERCXXXXAcceptance {
    bool public immutable accepting;

    constructor(bool accepting_) {
        accepting = accepting_;
    }

    function supportsInterface(bytes4 id) external view returns (bool) {
        _burn(20_000);
        return id == ERC165_ID || id == type(IERCXXXXAcceptance).interfaceId;
    }

    function acceptsERCXXXXTransfer(address, address, uint256, uint256) external view returns (bytes4) {
        return accepting ? ACCEPT : bytes4(0);
    }
}

/// @dev supportsInterface conforms, but reverts at once when it receives less than 25,000 gas, returning the unused
///      gas to the token. Refuses everything. When such a receiving contract fails for lack of gas, the failure does
///      not also exhaust the token's gas, so an implementation that only looks at whether the call succeeded treats
///      it as not being a receiving contract and lets the transfer through.
contract GasCheckingReceiver is IERCXXXXAcceptance {
    function supportsInterface(bytes4 id) external view returns (bool) {
        require(gasleft() >= 25_000);
        return id == ERC165_ID || id == type(IERCXXXXAcceptance).interfaceId;
    }

    function acceptsERCXXXXTransfer(address, address, uint256, uint256) external pure returns (bytes4) {
        return bytes4(0);
    }
}

/// @dev supportsInterface succeeds and returns false when it receives less than 25,000 gas, and otherwise answers
///      normally as ERC-165 specifies; refuses everything. Given the full 30,000 gas, it answers true, so it is a
///      receiving contract as the draft defines it. When gas is short it does not fail but successfully answers
///      false, so an implementation that checks the gas only when a query fails treats it as not being a receiving
///      contract.
contract FalseOnLowGasReceiver is IERCXXXXAcceptance {
    function supportsInterface(bytes4 id) external view returns (bool) {
        if (gasleft() < 25_000) return false;
        return id == ERC165_ID || id == type(IERCXXXXAcceptance).interfaceId;
    }

    function acceptsERCXXXXTransfer(address, address, uint256, uint256) external pure returns (bytes4) {
        return bytes4(0);
    }
}

/// @dev A registry whose query first uses about 12,000 gas, used by TryCatchReceiver. When the gas is not enough, it
///      loops until the gas runs out.
contract SlowInterfaceRegistry {
    function lookup(bytes4 id) external view returns (bool) {
        _burn(12_000);
        return id == ERC165_ID || id == ACCEPT;
    }
}

/// @dev supportsInterface queries the registry with try/catch and returns false when the subcall fails; refuses
///      everything. When `reserve` is zero, the subcall receives all the gas that can be forwarded under EIP-150 and
///      uses it up when it fails; when `reserve` is not zero, only gasleft() - reserve is forwarded and `reserve` is
///      left for the catch branch (a common pattern that keeps the catch branch itself from failing for lack of
///      gas), and after the subcall fails most of this gas goes back to the token.
///      Given the full 30,000 gas, the subcall succeeds and the contract answers true for 0x01ffc9a7 and
///      0x4689efd4, so it is a receiving contract.
contract TryCatchReceiver is IERCXXXXAcceptance {
    SlowInterfaceRegistry public immutable registry;
    uint256 public immutable reserve;

    constructor(uint256 reserve_) {
        registry = new SlowInterfaceRegistry();
        reserve = reserve_;
    }

    function supportsInterface(bytes4 id) external view returns (bool) {
        uint256 g = gasleft() - reserve;
        try registry.lookup{gas: g}(id) returns (bool answer) {
            return answer;
        } catch {
            return false;
        }
    }

    function acceptsERCXXXXTransfer(address, address, uint256, uint256) external pure returns (bytes4) {
        return bytes4(0);
    }
}

// ───────────────────────── Return values that do not mean acceptance ─────────────────────────
// They all declare the acceptance check interface through ERC-165; only what acceptsERCXXXXTransfer returns does
// not mean acceptance.

/// @dev Tries to write state in acceptsERCXXXXTransfer. The token calls it with STATICCALL, so the call fails.
contract WritingReceiver {
    uint256 public calls;

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == ERC165_ID || id == ACCEPT;
    }

    function acceptsERCXXXXTransfer(address, address, uint256, uint256) external returns (bytes4) {
        ++calls;
        return ACCEPT;
    }
}

/// @dev Returns true instead of the agreed value.
contract BoolReturnReceiver {
    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == ERC165_ID || id == ACCEPT;
    }

    function acceptsERCXXXXTransfer(address, address, uint256, uint256) external pure returns (bool) {
        return true;
    }
}

/// @dev The common part of the receiving contracts that answer acceptsERCXXXXTransfer through their fallback.
abstract contract RawReceiver {
    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == ERC165_ID || id == ACCEPT;
    }
}

/// @dev Returns only 4 bytes (not padded to 32 bytes as the ABI requires).
contract ShortReturnReceiver is RawReceiver {
    fallback() external {
        bytes4 v = ACCEPT;
        assembly {
            mstore(0x00, v)
            return(0x00, 0x04)
        }
    }
}

/// @dev The padding bits after the selector are not zero, so this is not a valid encoding of a bytes4.
contract DirtyReturnReceiver is RawReceiver {
    fallback() external {
        bytes4 v = ACCEPT;
        assembly {
            mstore(0x00, or(v, 1))
            return(0x00, 0x20)
        }
    }
}

/// @dev The agreed value followed by 64 KiB of data. The token reads only the first 32 bytes, so this still means
///      acceptance.
contract LongReturnReceiver is RawReceiver {
    fallback() external {
        bytes4 v = ACCEPT;
        assembly {
            mstore(0x00, v)
            return(0x00, 0x10000)
        }
    }
}

/// @dev Uses up all the gas it receives.
contract GasBurningReceiver is RawReceiver {
    fallback() external {
        while (true) {}
    }
}

// ───────────────────────── Proving that the call is a STATICCALL ─────────────────────────

/// @dev Accepts only in a read-only context: it tries to call one of its own functions that writes state; if the
///      write succeeds, the call is not a STATICCALL, and it refuses.
contract StaticOnlyReceiver {
    uint256 public pokes = 1; // not zero, so a write is cheap (see StaticOnlyErc165Receiver)

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == ERC165_ID || id == ACCEPT;
    }

    function poke() external {
        ++pokes;
    }

    function acceptsERCXXXXTransfer(address, address, uint256, uint256) external returns (bytes4) {
        (bool wrote,) = address(this).call{gas: 30_000}(abi.encodeCall(this.poke, ()));
        return wrote ? bytes4(0) : ACCEPT;
    }
}

/// @dev Declares the acceptance check interface only in a read-only context, and refuses everything. When the token
///      queries it with STATICCALL, it is a receiving contract and the transfer is refused; when queried with a
///      call that can change state, it answers false for 0x4689efd4 and the transfer would succeed.
contract StaticOnlyErc165Receiver {
    /// @dev The initial value is not zero: changing a non-zero value to another non-zero value costs about 5,000
    ///      gas, within the 10,000 forwarded to poke, so when the call is not a STATICCALL, poke always manages to
    ///      write.
    uint256 public pokes = 1;

    function poke() external {
        ++pokes;
    }

    function supportsInterface(bytes4 id) external returns (bool) {
        if (id == ERC165_ID) return true;
        if (id != ACCEPT) return false;
        (bool wrote,) = address(this).call{gas: 10_000}(abi.encodeCall(this.poke, ()));
        return !wrote;
    }

    function acceptsERCXXXXTransfer(address, address, uint256, uint256) external pure returns (bytes4) {
        return bytes4(0);
    }
}

// ───────────────────────── Contracts that are not receiving contracts ─────────────────────────
// Their acceptsERCXXXXTransfer always refuses (reverts or returns another value); if the token called it, the
// transfer would fail.

/// @dev P of the acceptance check sequence in the draft's test cases: has code and does not implement ERC-165 (it has
///      no functions, so every call reverts).
contract NoInterfaceContract {}

/// @dev Returns true (a 32-byte 1) for every call, so supportsInterface(0xffffffff) returns true too: not ERC-165.
contract AllTrueContract {
    fallback() external {
        assembly {
            mstore(0x00, 1)
            return(0x00, 0x20)
        }
    }
}

/// @dev Implements ERC-165 but does not declare the acceptance check interface; it has an acceptsERCXXXXTransfer
///      that always reverts.
contract Erc165OnlyContract {
    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == ERC165_ID;
    }

    function acceptsERCXXXXTransfer(address, address, uint256, uint256) external pure returns (bytes4) {
        revert("must not be called");
    }
}

/// @dev supportsInterface(0x01ffc9a7) returns false: by ERC-165 the contract does not implement ERC-165, even though
///      it returns true for 0x4689efd4.
contract Erc165FalseContract {
    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == ACCEPT;
    }

    function acceptsERCXXXXTransfer(address, address, uint256, uint256) external pure returns (bytes4) {
        revert("must not be called");
    }
}

/// @dev supportsInterface(0xffffffff) reverts: by ERC-165 the second call fails, so the contract does not implement
///      ERC-165.
contract InvalidIdRevertsContract {
    function supportsInterface(bytes4 id) external pure returns (bool) {
        require(id != INVALID_ID);
        return id == ERC165_ID || id == ACCEPT;
    }

    function acceptsERCXXXXTransfer(address, address, uint256, uint256) external pure returns (bytes4) {
        revert("must not be called");
    }
}

/// @dev supportsInterface(0xffffffff) returns a 32-byte 2: not false (0), so by the test ERC-165 applies to the
///      second call (result != 0 in ERC165Query) the contract does not implement ERC-165.
contract InvalidIdMalformedContract {
    fallback() external {
        bytes4 id;
        assembly {
            id := shl(224, shr(224, calldataload(4)))
        }
        uint256 answer;
        if (msg.sig == 0x01ffc9a7) {
            if (id == INVALID_ID) answer = 2;
            else if (id == ERC165_ID || id == ACCEPT) answer = 1;
        } else {
            revert("must not be called");
        }
        assembly {
            mstore(0x00, answer)
            return(0x00, 0x20)
        }
    }
}

/// @dev supportsInterface(0x01ffc9a7) returns a 32-byte 2: not false (0), so by the test ERC-165 applies to the
///      first call (only result == 0 in ERC165Query counts as no) the queries continue; the next two answer 0 and 1,
///      so it is a receiving contract. It refuses everything.
contract FirstQueryNonBoolReceiver {
    fallback() external {
        bytes4 id;
        assembly {
            id := shl(224, shr(224, calldataload(4)))
        }
        uint256 answer;
        if (msg.sig == 0x01ffc9a7) {
            if (id == ERC165_ID) answer = 2;
            else if (id == ACCEPT) answer = 1;
        }
        // acceptsERCXXXXTransfer also ends up here and returns 0, which means refusal.
        assembly {
            mstore(0x00, answer)
            return(0x00, 0x20)
        }
    }
}

/// @dev supportsInterface uses up all the 30,000 gas it receives, so the query fails. When the token had ample gas,
///      it is not a receiving contract.
contract Erc165GasBurnerContract {
    function supportsInterface(bytes4) external pure returns (bool) {
        while (true) {}
        return true;
    }

    function acceptsERCXXXXTransfer(address, address, uint256, uint256) external pure returns (bytes4) {
        revert("must not be called");
    }
}
