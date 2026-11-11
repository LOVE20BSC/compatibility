// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Vm} from "./Vm.sol";
import {ReferenceCode} from "./fixtures/ReferenceCode.sol";
import {IUniswapV2Pair} from "@core/interfaces/UniswapV2/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "@core/interfaces/UniswapV2/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "@core/interfaces/UniswapV2/IUniswapV2Router02.sol";

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IWBNB is IERC20Like {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @dev Own clear switches that are not part of `Stake`'s requirements but decide whether observed
///      numbers may move without the callers noticing. They are read through separate interfaces so
///      the production interfaces stay exactly what `Stake` declares.
interface IFactoryDiagnostics {
    function feeTo() external view returns (address);
    function feeToSetter() external view returns (address);
    function allPairsLength() external view returns (uint256);
    function INIT_CODE_PAIR_HASH() external view returns (bytes32);
}

interface IRouterDiagnostics {
    function factory() external view returns (address);
    function WETH() external view returns (address);
}

interface IPairDiagnostics {
    function factory() external view returns (address);
    function symbol() external view returns (string memory);
    function kLast() external view returns (uint256);
}

/// @title Compatibility harness base
/// @notice One harness for every profile. A profile is either a fork pinned to a fixed block with
///         concrete addresses, or a local deployment of the Uniswap V2 reference. Both branches hand
///         the tests the same three addresses, so every assertion is written once and asked twice.
// forge-lint: disable-next-item(locked-ether)
abstract contract CompatBase {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // Uniswap V2 numbers that are part of the semantic contract, not of any particular deployment.
    uint256 internal constant FEE_DENOMINATOR = 1000;
    uint256 internal constant FEE_NUMERATOR = 997;
    uint256 internal constant MINIMUM_LIQUIDITY = 1000;

    string internal profileName;
    bool internal localReference;
    uint256 internal forkBlock;
    address internal wbnbAddress;
    address internal factoryAddress;
    address internal routerAddress;

    function loadProfile() internal {
        profileName = vm.envOr("COMPAT_PROFILE", string("anvil"));
        localReference = vm.envOr("COMPAT_LOCAL", false);

        if (localReference) {
            deployReference();
        } else {
            string memory rpc = vm.envString("COMPAT_RPC_URL");
            forkBlock = vm.envUint("COMPAT_FORK_BLOCK");
            vm.createSelectFork(rpc, forkBlock);
            wbnbAddress = vm.envAddress("COMPAT_WBNB");
            factoryAddress = vm.envAddress("COMPAT_FACTORY");
            routerAddress = vm.envAddress("COMPAT_ROUTER");
        }

        vm.label(wbnbAddress, "wbnb");
        vm.label(factoryAddress, "factory");
        vm.label(routerAddress, "router");

        require(IWBNB(wbnbAddress).decimals() == 18, "parent token is not 18 decimals");
        if (!localReference) {
            // The three configured addresses must describe one single deployment set, otherwise every
            // later assertion would be comparing notes from different contracts.
            require(IRouterDiagnostics(routerAddress).factory() == factoryAddress, "router points elsewhere");
            require(IRouterDiagnostics(routerAddress).WETH() == wbnbAddress, "router wraps another token");
        }
    }

    /// @dev The local baseline: the published Uniswap V2 build, deployed from `ReferenceCode`. The
    ///      published pair template is required rather than a recompilation of the sources, because
    ///      `UniswapV2Library.pairFor` hard-codes that template's init code hash.
    function deployReference() internal {
        wbnbAddress = deployCode("WETH9", "");
        factoryAddress = deployInit(ReferenceCode.FACTORY_INIT, abi.encode(address(this)));
        routerAddress = deployInit(ReferenceCode.ROUTER_INIT, abi.encode(factoryAddress, wbnbAddress));
    }

    function deployCode(string memory artifactName, bytes memory args) internal returns (address deployed) {
        bytes memory creation = vm.getCode(artifactName);
        require(creation.length != 0, string.concat("missing artefact: ", artifactName));
        return deployInit(creation, args);
    }

    function deployInit(bytes memory creation, bytes memory args) internal returns (address deployed) {
        // forge-lint: disable-next-item(encode-packed-collision)
        bytes memory init = abi.encodePacked(creation, args);
        assembly {
            deployed := create(0, add(init, 0x20), mload(init))
        }
        require(deployed != address(0), "deploying the reference failed");
    }

    // --------------------------------------------------------------- evidence

    /// @dev Appends one measured line to the profile's evidence file, so a run can be re-read later
    ///      without re-running it.
    function record(string memory key, uint256 value) internal {
        vm.writeLine(evidencePath(), string.concat(key, "=", vm.toString(value)));
    }

    function recordText(string memory line) internal {
        vm.writeLine(evidencePath(), line);
    }

    /// @dev Selects this test contract's evidence file. The driver clears the results directory before
    ///      a run, so lines accumulate across tests without one test erasing another's measurements.
    function openEvidence(string memory fileId) internal returns (string memory) {
        evidence = string.concat(vm.envOr("COMPAT_RESULTS_DIR", string("results/default")), "/", fileId, ".evidence.txt");
        vm.writeLine(evidence, string.concat("# profile=", profileName, " block=", vm.toString(block.number)));
        return evidence;
    }

    string internal evidence;

    function evidencePath() private view returns (string memory) {
        return evidence;
    }

    // -------------------------------------------------------------- assertions

    function assertTrue(bool condition, string memory why) internal pure {
        require(condition, why);
    }

    function assertEq(uint256 actual, uint256 expected, string memory why) internal pure {
        require(actual == expected, string.concat(why, ": got ", vm.toString(actual), " want ", vm.toString(expected)));
    }

    function assertEqAddress(address actual, address expected, string memory why) internal pure {
        require(actual == expected, why);
    }

    /// @dev Asserts that an ERC20 call really returned a bool. `Stake` hands the return value straight
    ///      to `require`, so a token that returns nothing would decode-fail rather than report false.
    function callReturnsBool(address token, bytes memory data, string memory why)
        internal
        returns (bool returned)
    {
        (bool ok, bytes memory out) = token.call(data);
        require(ok, string.concat(why, ": call reverted"));
        require(out.length == 32, string.concat(why, ": return data is not one word"));
        assembly {
            returned := mload(add(out, 0x20))
        }
        require(returned, string.concat(why, ": returned false"));
    }

    function expectFailure(address target, bytes memory data, string memory why) internal {
        (bool ok, bytes memory out) = target.call(data);
        require(!ok, string.concat(why, ": expected a revert, got success"));
        require(out.length > 0, string.concat(why, ": reverted without a reason"));
    }

    // ------------------------------------------------------------------- maths

    /// @dev The constant-product quote, recomputed here from the reserves so a router's answer is never
    ///      taken on trust. `feeNumerator` is passed rather than fixed because the swap fee is exactly
    ///      one of the things a fork may change: Uniswap V2 charges 997/1000, PancakeSwap charges
    ///      998/1000, and quoting with the wrong one moves every fee settlement.
    function quoteOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint256 feeNumerator)
        internal
        pure
        returns (uint256 amountOut)
    {
        return quoteOutScaled(amountIn, reserveIn, reserveOut, feeNumerator, FEE_DENOMINATOR);
    }

    function quoteOutScaled(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint256 numerator, uint256 denominator)
        internal
        pure
        returns (uint256 amountOut)
    {
        uint256 amountInWithFee = amountIn * numerator;
        amountOut = (amountInWithFee * reserveOut) / (reserveIn * denominator + amountInWithFee);
    }

    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y == 0) return 0;
        z = y;
        uint256 x = y / 2 + 1;
        while (x < z) {
            z = x;
            x = (y / x + x) / 2;
        }
    }

    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function sortedReserves(address pair, address token)
        internal
        view
        returns (uint256 reserveToken, uint256 reserveParent, uint256 pairTotalSupply)
    {
        IUniswapV2Pair pairContract = IUniswapV2Pair(pair);
        // forge-lint: disable-next-line(unused-return)
        (uint112 reserve0, uint112 reserve1, ) = pairContract.getReserves();
        pairTotalSupply = pairContract.totalSupply();
        if (token == pairContract.token0()) {
            (reserveToken, reserveParent) = (uint256(reserve0), uint256(reserve1));
        } else {
            (reserveToken, reserveParent) = (uint256(reserve1), uint256(reserve0));
        }
    }

    function wrapBnb(uint256 amount) internal returns (address) {
        // forge-lint: disable-next-item(arbitrary-send-eth)
        IWBNB(wbnbAddress).deposit{value: amount}();
        return wbnbAddress;
    }

    receive() external payable virtual {}
}
