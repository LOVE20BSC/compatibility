// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {CompatBase, IERC20Like, IWBNB, IFactoryDiagnostics, IPairDiagnostics} from "../src/CompatBase.sol";
import {Stake} from "@core/Stake.sol";
import {IStake} from "@core/interfaces/IStake.sol";
import {IUniswapV2Pair} from "@core/interfaces/UniswapV2/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "@core/interfaces/UniswapV2/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "@core/interfaces/UniswapV2/IUniswapV2Router02.sol";
import {LOVE20Token} from "@core/LOVE20Token.sol";
import {MockPhase, MockMemberNFT} from "../src/fixtures/StageFixtures.sol";

contract MockLaunchRegistry {
    address private immutable token;

    constructor(address token_) { token = token_; }

    function isLOVE20Token(address candidate) external view returns (bool) { return candidate == token; }
}

contract MockSubmitRights {
    function proposalIdBySubmitterId(address, uint256, uint256) external pure returns (uint256) { return 0; }
}

contract MockVoteForStake {
    address public SUBMIT_ADDRESS;

    constructor(address submitAddress_) { SUBMIT_ADDRESS = submitAddress_; }

    function voteAmountByMemberId(address, uint256, uint256) external pure returns (uint256) { return 0; }
}

/// @title Uniswap V2 compatibility probe
/// @notice One parameterised probe for every profile. It is given a network and three addresses, drives
///         the deployed contracts through the operations `Stake` performs, and writes a verdict line per
///         check. Nothing about a particular network is hard-coded here, so pointing it at a new chain
///         is a config file, not a code change.
/// @dev A failed check fails its probe, so the run's exit status can never disagree with the evidence
///      file. Differences that need a decision instead of a red light are written as `note=` lines.
contract CompatibilityProbe is CompatBase {
    // 1e18 = 100% of the pair's LP supply; 1e14 is the old 1/10000 fee denominator.
    uint256 internal constant FEE_RATIO = 1e14;
    uint256 internal constant PROMISED_PHASES = 1;
    // Probe 11 deliberately offers more token than the pool ratio can take, so the token side is the one
    // the conversion trims and the surplus has to stay in the caller's wallet.
    uint256 internal constant OFF_RATIO_TOKEN = 1e21;
    uint256 internal constant OFF_RATIO_PARENT = 5e17;
    // The quote may be missed by at most one part in a million.
    uint256 internal constant QUOTE_TOLERANCE = 1_000_000;

    LOVE20Token internal token;
    address internal pair;
    Stake internal stake;
    MockPhase internal phase;
    address internal staker = address(0xBEEF);

    function setUp() public {
        loadProfile();
        openEvidence("probe");
        token = new LOVE20Token("Compat Probe Token", "CPTK", 1e27, 1e30, address(this), address(this), wbnbAddress);
        pair = IUniswapV2Factory(factoryAddress).createPair(address(token), wbnbAddress);
        vm.label(pair, "probe-pair");

        phase = new MockPhase();
        phase.setPhase(1);
        MockMemberNFT members = new MockMemberNFT();
        members.setOwner(1, staker);
        members.setOwner(2, staker);

        stake = new Stake(
            address(phase),
            address(members),
            address(new MockVoteForStake(address(new MockSubmitRights()))),
            address(new MockLaunchRegistry(address(token))),
            routerAddress,
            factoryAddress,
            PROMISED_PHASES,
            10,
            FEE_RATIO,
            2,
            5
        );
        vm.label(address(stake), "stake");

        require(token.transfer(staker, 1e25), "fund the staker");
        vm.deal(staker, 5e18);
        vm.prank(staker);
        IWBNB(wbnbAddress).deposit{value: 5e18}();
        vm.startPrank(staker);
        require(IERC20Like(address(token)).approve(address(stake), type(uint256).max), "approve token");
        require(IERC20Like(wbnbAddress).approve(address(stake), type(uint256).max), "approve parent");
        require(IERC20Like(address(token)).approve(routerAddress, type(uint256).max), "approve router");
        vm.stopPrank();

        vm.deal(address(this), 6e18);
        IWBNB(wbnbAddress).deposit{value: 6e18}();
        require(IERC20Like(wbnbAddress).approve(routerAddress, type(uint256).max), "approve router parent");
        require(IERC20Like(address(token)).approve(routerAddress, type(uint256).max), "approve router token");
    }

    // --------------------------------------------------------------- reporting

    /// @dev Failing a check fails the probe. A soft failure that nothing turns into a verdict later
    ///      would let a run report success while its own evidence says otherwise.
    function check(bool ok, string memory name, string memory detail) internal {
        vm.writeLine(evidence, string.concat("probe=", name, " status=", ok ? "PASS" : "FAIL", " ", detail));
        require(ok, string.concat("failed: ", name, " ", detail));
    }

    /// @dev Records an observation without judging it, for differences that need a decision rather
    ///      than a red light.
    function note(string memory name, string memory detail) internal {
        vm.writeLine(evidence, string.concat("note=", name, " ", detail));
    }

    function checkEq(uint256 actual, uint256 expected, string memory name) internal {
        check(actual == expected, name, string.concat("got=", vm.toString(actual), " want=", vm.toString(expected)));
    }

    function measure(string memory name, uint256 value) internal {
        record(name, value);
    }

    // ------------------------------------------------------------------ probes

    function test_01_wrapper() public {
        uint256 amount = 1e18;
        uint256 supplyBefore = IERC20Like(wbnbAddress).totalSupply();
        uint256 heldBefore = IERC20Like(wbnbAddress).balanceOf(address(this));
        vm.deal(address(this), amount);
        IWBNB(wbnbAddress).deposit{value: amount}();
        checkEq(IERC20Like(wbnbAddress).balanceOf(address(this)) - heldBefore, amount, "wrapper.deposit");
        checkEq(IERC20Like(wbnbAddress).totalSupply(), supplyBefore + amount, "wrapper.supply");
        check(IERC20Like(wbnbAddress).decimals() == 18, "wrapper.decimals", "must be 18");

        bool word = returnsSingleWord(wbnbAddress, abi.encodeWithSelector(IERC20Like.approve.selector, address(this), 1));
        check(word, "wrapper.approveReturnsBool", "Stake requires the boolean");

        IWBNB(wbnbAddress).withdraw(amount);
        checkEq(IERC20Like(wbnbAddress).balanceOf(address(this)), heldBefore, "wrapper.withdraw");
        measure("wrapper_deposit", amount);
    }

    function test_02_factory() public {
        LOVE20Token second =
            new LOVE20Token("Compat Second", "CSND", 1e24, 1e27, address(this), address(this), wbnbAddress);

        address forward = IUniswapV2Factory(factoryAddress).getPair(address(token), address(second));
        address backward = IUniswapV2Factory(factoryAddress).getPair(address(second), address(token));
        check(forward == backward && forward == address(0), "factory.getPair", "symmetric and zero when unknown");

        uint256 lengthBefore = IFactoryDiagnostics(factoryAddress).allPairsLength();
        address created = IUniswapV2Factory(factoryAddress).createPair(address(token), address(second));
        check(created != address(0), "factory.createPair", "must return the pair");
        check(
            IUniswapV2Factory(factoryAddress).getPair(address(second), address(token)) == created,
            "factory.registry",
            "reverse lookup must find it"
        );
        checkEq(IFactoryDiagnostics(factoryAddress).allPairsLength(), lengthBefore + 1, "factory.allPairsLength");

        (address token0,) = sortTokens(address(token), address(second));
        check(IUniswapV2Pair(created).token0() == token0, "factory.tokenOrder", "token0 is the lower address");
        check(reverts(factoryAddress, abi.encodeWithSelector(IUniswapV2Factory.createPair.selector, address(token), address(second))), "factory.duplicateReverts", "a second create must fail");
        measure("factory_allPairsLength", lengthBefore + 1);
    }

    function test_03_pairMint() public {
        check(IUniswapV2Pair(pair).token0() == sortTokens0(), "pair.tokenOrder", "token0 is the lower address");

        uint256 tokenAmount = 1e21;
        uint256 parentAmount = 1e18;
        uint256 liquidity = seed(tokenAmount, parentAmount);
        uint256 expected = sqrt(tokenAmount * parentAmount) - MINIMUM_LIQUIDITY;

        checkEq(liquidity, expected, "pair.firstMintLocksMinimum");
        checkEq(IUniswapV2Pair(pair).totalSupply(), liquidity + MINIMUM_LIQUIDITY, "pair.supplyCarriesLock");
        checkEq(IERC20Like(pair).balanceOf(address(0)), MINIMUM_LIQUIDITY, "pair.lockIsUnownable");

        if (liquidity == expected) {
            (uint256 rToken, uint256 rParent, uint256 supply) = sortedReserves(pair, address(token));
            uint256 second = 2e20;
            uint256 parentSecond = 2e17;
            uint256 byToken = (second * supply) / rToken;
            uint256 byParent = (parentSecond * supply) / rParent;
            uint256 expectedSecond = byToken < byParent ? byToken : byParent;
            uint256 minted = seed(second, parentSecond);
            checkEq(minted, expectedSecond, "pair.secondMintIsProportional");
        }
        measure("pair_firstMint", liquidity);
    }

    function test_04_pairBurnBoundary() public {
        seed(1e21, 1e18);
        (, uint256 rParent, uint256 supply) = sortedReserves(pair, address(token));
        uint256 smallest = rParent == 0 ? 0 : (supply - 1) / rParent + 1;

        require(IERC20Like(pair).transfer(pair, smallest - 1), "stage dust");
        bool rejected = reverts(pair, abi.encodeWithSelector(IUniswapV2Pair.burn.selector, address(this)));
        check(rejected, "pair.burnBelowGuardReverts", string.concat("lp=", vm.toString(smallest - 1)));
        checkEq(IERC20Like(pair).balanceOf(pair), smallest - 1, "pair.failedBurnKeepsLp");

        require(IERC20Like(pair).transfer(pair, 1), "stage boundary");
        (uint256 amount0, uint256 amount1) = IUniswapV2Pair(pair).burn(address(this));
        check(amount0 > 0 && amount1 > 0, "pair.burnAtGuardPaysOut", string.concat("lp=", vm.toString(smallest)));
        measure("pair_smallestBurnableLp", smallest);
    }

    function test_05_pairProtocolFee() public {
        address feeTo = IFactoryDiagnostics(factoryAddress).feeTo();
        measure("pair_feeToConfigured", feeTo == address(0) ? 0 : 1);

        seed(1e21, 1e18);
        trade(3e20);

        uint256 supplyBefore = IUniswapV2Pair(pair).totalSupply();
        uint256 kLast = IPairDiagnostics(pair).kLast();
        uint256 tokenBalance = IERC20Like(address(token)).balanceOf(pair);
        uint256 parentBalance = IERC20Like(wbnbAddress).balanceOf(pair);

        uint256 depositToken = 1e17;
        require(IERC20Like(address(token)).transfer(pair, depositToken), "stage token");
        require(IERC20Like(wbnbAddress).transfer(pair, 1e14), "stage parent");
        uint256 rootK = sqrt((tokenBalance + depositToken) * (parentBalance + 1e14));

        uint256 treasuryBefore = IERC20Like(pair).balanceOf(feeTo);
        IUniswapV2Pair(pair).mint(address(this));
        uint256 mintedToTreasury = IERC20Like(pair).balanceOf(feeTo) - treasuryBefore;

        uint256 three = protocolFee(supplyBefore, rootK, kLast, 3);
        uint256 five = protocolFee(supplyBefore, rootK, kLast, 5);
        measure("pair_treasuryMint", mintedToTreasury);
        measure("pair_treasuryMint_denominator3", three);
        measure("pair_treasuryMint_denominator5", five);

        if (feeTo == address(0) || kLast == 0) {
            check(mintedToTreasury == 0, "pair.noTreasuryMint", "nothing may be minted to a zero treasury");
        } else {
            measure("pair_treasuryMint_ofSupply", supplyBefore);
            note("pair.protocolFeeMinted", vm.toString(mintedToTreasury));
            note("pair.protocolFeeModelRootK3", vm.toString(three));
            note("pair.protocolFeeModelRootK5", vm.toString(five));
        }
    }

    function test_06_pairErc20() public {
        seed(1e21, 1e18);
        check(
            returnsSingleWord(pair, abi.encodeWithSelector(IERC20Like.approve.selector, address(this), 1)),
            "pair.lpApproveReturnsBool",
            "Stake requires the boolean"
        );
        check(
            returnsSingleWord(pair, abi.encodeWithSelector(IERC20Like.transfer.selector, pair, 1)),
            "pair.lpSelfTransferReturnsBool",
            "Stake transfers its LP into the pair"
        );
        measure("pair_lpDecimals", IERC20Like(pair).decimals());
    }

    function test_07_routerQuote() public {
        seed(1e21, 1e18);
        (uint256 rToken, uint256 rParent, ) = sortedReserves(pair, address(token));

        uint256 amountIn = 1e17;
        uint256 quoted = quote(amountIn, address(token), wbnbAddress);
        uint256 at998 = quoteOutScaled(amountIn, rToken, rParent, 998, 1000);
        uint256 at997 = quoteOutScaled(amountIn, rToken, rParent, 997, 1000);
        uint256 at9975 = quoteOutScaled(amountIn, rToken, rParent, 9975, 10_000);

        check(
            quoted == at998 || quoted == at997 || quoted == at9975,
            "router.quoteMatchesKnownFeeModel",
            string.concat("quote=", vm.toString(quoted))
        );
        measure("router_quote", quoted);
        measure("router_quote_model998", at998);
        measure("router_quote_model997", at997);
        measure("router_quote_model9975_per10000", at9975);
        note(
            "router.feeModel",
            string.concat(
                "matched=",
                quoted == at9975 ? "25bps" : (quoted == at998 ? "20bps" : "30bps"),
                " uniswapV2WouldGive=",
                vm.toString(at997)
            )
        );
    }

    function test_08_routerSwap() public {
        seed(1e21, 1e18);
        uint256 amountIn = 1e17;
        uint256 quoted = quote(amountIn, address(token), wbnbAddress);

        uint256 parentBefore = IERC20Like(wbnbAddress).balanceOf(address(this));
        uint256[] memory amounts = IUniswapV2Router02(routerAddress).swapExactTokensForTokens(
            amountIn, quoted, route(address(token), wbnbAddress), address(this), block.timestamp
        );
        checkEq(amounts[amounts.length - 1], quoted, "router.swapDeliversTheQuote");
        checkEq(IERC20Like(wbnbAddress).balanceOf(address(this)) - parentBefore, quoted, "router.swapMovesTheBalance");
        check(true, "router.deadlineEqualToNowAccepted", "Stake passes block.timestamp");
        measure("router_swap_delivered", quoted);

        uint256 amountIn2 = 1e15;
        uint256 quoted2 = quote(amountIn2, wbnbAddress, address(token));
        uint256 tokenBefore = IERC20Like(address(token)).balanceOf(address(this));
        IUniswapV2Router02(routerAddress).swapExactTokensForTokens(
            amountIn2, quoted2, route(wbnbAddress, address(token)), address(this), block.timestamp
        );
        checkEq(IERC20Like(address(token)).balanceOf(address(this)) - tokenBefore, quoted2, "router.parentSideDeliversQuote");
    }

    function test_09_routerFailures() public {
        seed(1e21, 1e18);
        (uint256 r0, uint256 r1, ) = reserves();
        uint256 amountIn = 1e15;
        uint256 quoted = quote(amountIn, address(token), wbnbAddress);

        check(
            reverts(
                routerAddress,
                abi.encodeWithSelector(
                    IUniswapV2Router02.swapExactTokensForTokens.selector,
                    amountIn,
                    quoted + 1,
                    route(address(token), wbnbAddress),
                    address(this),
                    block.timestamp
                )
            ),
            "router.amountOutMinTooHighReverts",
            "an unattainable minimum must fail"
        );

        uint256 expired = block.timestamp;
        vm.warp(expired + 1);
        check(
            reverts(
                routerAddress,
                abi.encodeWithSelector(
                    IUniswapV2Router02.swapExactTokensForTokens.selector,
                    amountIn,
                    quote(amountIn, address(token), wbnbAddress),
                    route(address(token), wbnbAddress),
                    address(this),
                    expired
                )
            ),
            "router.expiredDeadlineReverts",
            "a stale deadline must fail"
        );

        (uint256 r0After, uint256 r1After, ) = reserves();
        check(r0After == r0 && r1After == r1, "router.failedSwapKeepsReserves", "a failed swap changes nothing");

        LOVE20Token orphan = new LOVE20Token("Orphan", "ORPH", 1e24, 1e27, address(this), address(this), wbnbAddress);
        check(
            reverts(routerAddress, abi.encodeWithSelector(IUniswapV2Router02.getAmountsOut.selector, 1e15, route(address(orphan), wbnbAddress))),
            "router.unregisteredPairReverts",
            "an unknown pool must fail"
        );
    }

    function test_10_stakeReplay() public {
        stakeAs(1, 1e21, 1e18);
        (uint256 shares, uint256 lp, uint256 withdrawable, uint256 fee) = globalData();
        checkEq(lp, IUniswapV2Pair(pair).totalSupply() - MINIMUM_LIQUIDITY, "stake.firstStakeExcludesTheLock");
        checkEq(shares, lp, "stake.firstStakeTakesTheWholeBasis");
        check(fee == 0, "stake.noFeeBeforeAnyTrade", string.concat("fee=", vm.toString(fee)));
        check(withdrawable == lp, "stake.withdrawableStartsAtTheBasis", "");

        (uint256 sharesBefore,, uint256 withdrawableBefore, ) = globalData();
        uint256 expectedSecond = (sharesBefore * IUniswapV2Pair(pair).totalSupply()) / withdrawableBefore;
        stakeAs(2, 1e21, 1e18);
        (uint256 sharesAfter,,, ) = globalData();
        (uint256 memberTwo,,,,,,) = stake.memberStake(address(token), 2);
        checkEq(memberTwo, sharesAfter - sharesBefore, "stake.secondStakeLandsOnTheMember");
        checkEq(memberTwo, expectedSecond, "stake.secondStakePricesOffWithdrawable");

        // The resting basis is the one to compare against: it is what the withdrawable side was worth
        // before the trade, with both stakes already in.
        (,, uint256 withdrawableAtRest, ) = globalData();
        trade(3e20);
        phase.setPhase(2);
        uint256 supplyBefore = IERC20Like(address(token)).totalSupply();
        (,,, uint256 feeBefore) = globalData();
        stake.settleFees(address(token));
        (,, uint256 withdrawableAfter, uint256 feeAfter) = globalData();

        uint256 burned = stake.totalBurnedToken(address(token));
        uint256 parentBurned = stake.totalParentTokenBurned(address(token));
        check(burned > 0, "stake.settlementBurnsTheToken", string.concat("burned=", vm.toString(burned)));
        check(parentBurned > 0, "stake.settlementSwapsParentSide", string.concat("parent=", vm.toString(parentBurned)));
        checkEq(supplyBefore - IERC20Like(address(token)).totalSupply(), burned, "stake.burnLeavesTheSupply");
        // `totalStake` reclassifies on read, so the growth already left the withdrawable basis on
        // the first read after the trade; the settlement only realises it. Compare against the resting
        // basis captured before the trade.
        measure("stake_withdrawableAtRest", withdrawableAtRest);
        check(withdrawableAfter < withdrawableAtRest, "stake.growthLeavesWithdrawable", "");
        measure("stake_feeReclassified", feeBefore);
        measure("stake_feeRemainingAfterSettlement", feeAfter);

        uint256 burnedAfterFirst = stake.totalBurnedToken(address(token));
        stake.settleFees(address(token));
        checkEq(stake.totalBurnedToken(address(token)), burnedAfterFirst, "stake.oneSettlementPerRound");

        exitFirstMember();
    }

    /// @dev The exit half of the replay, kept apart so the probe stays below the stack limit.
    function exitFirstMember() internal {
        vm.prank(staker);
        stake.unstake(address(token), 1);
        phase.setPhase(2 + PROMISED_PHASES + 1);
        stake.settleFees(address(token));

        (uint256 totalShares,, uint256 withdrawableNow, ) = globalData();
        (uint256 memberOne, , , , uint256 quotedToken, uint256 quotedParent,) = stake.memberStake(address(token), 1);
        (uint256 rToken, uint256 rParent, uint256 pairSupply) = sortedReserves(pair, address(token));
        uint256 lpAmount = (memberOne * withdrawableNow) / totalShares;
        measure("stake_withdraw_formulaToken", (lpAmount * rToken) / pairSupply);
        measure("stake_withdraw_formulaParent", (lpAmount * rParent) / pairSupply);

        uint256 tokenBefore = IERC20Like(address(token)).balanceOf(staker);
        uint256 parentBefore = IERC20Like(wbnbAddress).balanceOf(staker);
        vm.prank(staker);
        stake.withdraw(address(token), 1);
        uint256 tokenOut = IERC20Like(address(token)).balanceOf(staker) - tokenBefore;
        uint256 parentOut = IERC20Like(wbnbAddress).balanceOf(staker) - parentBefore;

        check(tokenOut > 0 && parentOut > 0, "stake.withdrawReturnsBothSides", "");
        measure("stake_withdraw_tokenGap", quotedToken - tokenOut);
        measure("stake_withdraw_parentGap", quotedParent - parentOut);
        check(quotedToken - tokenOut <= quotedToken / QUOTE_TOLERANCE, "stake.withdrawMatchesStakeQuote_token", "");
        check(quotedParent - parentOut <= quotedParent / QUOTE_TOLERANCE, "stake.withdrawMatchesStakeQuote_parent", "");
        (uint256 left,,,,,,) = stake.memberStake(address(token), 1);
        checkEq(left, 0, "stake.positionIsCleared");
        measure("stake_withdraw_tokenOut", tokenOut);
        measure("stake_withdraw_parentOut", parentOut);
    }

    /// @dev This probe used to drive the `slippage` parameter: an off-ratio deposit reverted with
    ///      `SlippageExceeded` and rolled back. Neither the parameter nor the error exists any more, so
    ///      the same deposit must now be trimmed to the reserves and accepted, with the surplus left in
    ///      the caller's wallet. Same number of verdicts, pointed at the only behaviour left to check.
    function test_11_offRatioDeposit() public {
        stakeAs(1, 1e21, 1e18);
        (uint256 rToken, uint256 rParent, uint256 supply) = sortedReserves(pair, address(token));

        (bool ok, uint256 govVotesAdded, uint256 liquiditySharesAdded, uint256 spentToken, uint256 spentParent) =
            stakeOffRatio();

        check(
            ok,
            "stake.offRatioDepositAccepted",
            "no slippage parameter is left, so an off-ratio deposit must be trimmed rather than rejected"
        );
        checkEq(spentToken, (OFF_RATIO_PARENT * rToken) / rParent, "stake.offRatioRemainderStaysWithCaller");
        checkEq(spentParent, OFF_RATIO_PARENT, "stake.offRatioKeepsParentSide");
        check(
            liquiditySharesAdded != 0 && govVotesAdded == liquiditySharesAdded * PROMISED_PHASES,
            "stake.offRatioCreditsVotesOnWhatLanded",
            string.concat("shares=", vm.toString(liquiditySharesAdded), " votes=", vm.toString(govVotesAdded))
        );
        (uint256 rTokenAfter, uint256 rParentAfter, uint256 supplyAfter) = sortedReserves(pair, address(token));
        check(
            rTokenAfter == rToken + spentToken && rParentAfter == rParent + spentParent && supplyAfter > supply,
            "stake.offRatioGrowsThePool",
            string.concat("supply=", vm.toString(supplyAfter - supply))
        );
    }

    /// @dev The off-ratio deposit of probe 11, split out so the probe itself stays inside the stack limit.
    ///      `OFF_RATIO_TOKEN` is far more than the pool ratio allows, so the surplus must stay behind.
    function stakeOffRatio()
        internal
        returns (bool ok, uint256 govVotesAdded, uint256 liquiditySharesAdded, uint256 spentToken, uint256 spentParent)
    {
        uint256 tokenBefore = IERC20Like(address(token)).balanceOf(staker);
        uint256 parentBefore = IERC20Like(wbnbAddress).balanceOf(staker);

        bytes memory out;
        vm.prank(staker);
        (ok, out) = address(stake).call(
            abi.encodeWithSelector(
                IStake.stakeLiquidity.selector,
                address(token),
                OFF_RATIO_TOKEN,
                OFF_RATIO_PARENT,
                PROMISED_PHASES,
                uint256(2)
            )
        );
        if (ok) (govVotesAdded, liquiditySharesAdded) = abi.decode(out, (uint256, uint256));

        spentToken = tokenBefore - IERC20Like(address(token)).balanceOf(staker);
        spentParent = parentBefore - IERC20Like(wbnbAddress).balanceOf(staker);
    }


    // ------------------------------------------------------------------ helpers

    function sortTokens0() internal view returns (address token0) {
        (token0,) = sortTokens(address(token), wbnbAddress);
    }

    function seed(uint256 tokenAmount, uint256 parentAmount) internal returns (uint256 liquidity) {
        require(IERC20Like(address(token)).transfer(pair, tokenAmount), "transfer token failed");
        require(IERC20Like(wbnbAddress).transfer(pair, parentAmount), "transfer parent failed");
        liquidity = IUniswapV2Pair(pair).mint(address(this));
    }

    function reserves() internal view returns (uint256 r0, uint256 r1, uint256 supply) {
        // forge-lint: disable-next-line(unused-return)
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pair).getReserves();
        (r0, r1, supply) = (uint256(reserve0), uint256(reserve1), IUniswapV2Pair(pair).totalSupply());
    }

    function route(address from, address to) internal pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = from;
        path[1] = to;
    }

    function quote(uint256 amountIn, address from, address to) internal view returns (uint256) {
        return IUniswapV2Router02(routerAddress).getAmountsOut(amountIn, route(from, to))[1];
    }

    function stakeAs(uint256 memberId, uint256 tokenAmount, uint256 parentAmount) internal {
        vm.prank(staker);
        stake.stakeLiquidity(address(token), tokenAmount, parentAmount, PROMISED_PHASES, memberId);
    }

    function globalData() internal view returns (uint256 shares, uint256 lp, uint256 withdrawable, uint256 fee) {
        (shares, lp, withdrawable, fee,,,,) = stake.totalStake(address(token));
    }

    function trade(uint256 amount) internal {
        token.mint(address(this), amount);
        require(IERC20Like(address(token)).approve(routerAddress, amount), "approve router failed");
        IUniswapV2Router02(routerAddress).swapExactTokensForTokens(
            amount, 0, route(address(token), wbnbAddress), address(this), block.timestamp
        );
    }

    function protocolFee(uint256 supply, uint256 rootK, uint256 kLast, uint256 coefficient)
        internal
        pure
        returns (uint256)
    {
        if (rootK <= kLast) return 0;
        return (supply * (rootK - kLast)) / (rootK * coefficient + kLast);
    }

    function reverts(address target, bytes memory data) internal returns (bool) {
        (bool ok,) = target.call(data);
        return !ok;
    }

    function returnsSingleWord(address target, bytes memory data) internal returns (bool) {
        (bool ok, bytes memory out) = target.call(data);
        if (!ok || out.length != 32) return false;
        bool value;
        assembly {
            value := mload(add(out, 0x20))
        }
        return value;
    }

    receive() external payable override {}
}
