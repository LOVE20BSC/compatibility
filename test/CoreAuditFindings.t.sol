// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {CompatBase, IWBNB} from "../src/CompatBase.sol";
import {ReferenceCode} from "../src/fixtures/ReferenceCode.sol";
import {IUniswapV2Factory} from "@core/interfaces/UniswapV2/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "../lib/uni-v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Router02} from "@core/interfaces/UniswapV2/IUniswapV2Router02.sol";
import {ERC20} from "../lib/core/lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Phase} from "@core/Phase.sol";
import {MemberNFT} from "@core/MemberNFT.sol";
import {LOVE20Token} from "@core/LOVE20Token.sol";
import {Launch} from "@core/Launch.sol";
import {Stake} from "@core/Stake.sol";
import {DexConfig} from "@core/interfaces/IStake.sol";
import {Submit} from "@core/Submit.sol";
import {Vote} from "@core/Vote.sol";
import {Mint} from "@core/Mint.sol";
import {LaunchInitParams, DistributorMode} from "@core/interfaces/ILaunch.sol";
import {ProposalBody, TargetMode} from "@core/interfaces/ISubmit.sol";
import {IStakeErrors} from "@core/interfaces/IStake.sol";

contract AuditToken is ERC20 {
    address public parentTokenAddress;

    constructor(string memory symbol_, address parent_) ERC20(symbol_, symbol_) {
        parentTokenAddress = parent_;
        _mint(msg.sender, 1_000_000 ether);
    }

    function setParent(address parent_) external {
        parentTokenAddress = parent_;
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

contract AuditPhase {
    function currentPhase() external pure returns (uint256) { return 1; }
    function sync() external pure returns (bool, uint256) { return (false, 1); }
}

contract AuditMembers {
    address public immutable owner;

    constructor(address owner_) { owner = owner_; }

    function ownerOf(uint256) external view returns (address) { return owner; }
}

contract AuditStakeVotes {
    mapping(uint256 => uint256) internal _votes;
    uint256 public total;

    function set(uint256 memberId, uint256 votes, uint256 total_) external {
        _votes[memberId] = votes;
        total = total_;
    }

    function validGovVotes(address, uint256, uint256 memberId) external view returns (uint256) { return _votes[memberId]; }
    function totalValidGovVotes(address, uint256) external view returns (uint256) { return total; }
}

contract CoreAuditFindingsTest is CompatBase {
    Stake private _callbackStake;
    address private _callbackToken;
    uint256 private _callbackSource;
    uint256 private _callbackTarget;
    bool private _callbackMergeBlocked;

    struct AuditState {
        IWBNB weth;
        IUniswapV2Factory factory;
        IUniswapV2Router02 router;
        Phase phase;
        MemberNFT member;
        Launch launch;
        Stake stake;
        Submit submit;
        Vote vote;
        Mint mint;
        LOVE20Token victim;
        AuditToken fakeParent;
        AuditToken fakeChild;
        IUniswapV2Pair fakeParentPair;
        IUniswapV2Pair victimPair;
        uint256 memberId;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }

    function onProposalCreated(address, uint256, bytes[] calldata) external {
        (bool merged,) = address(_callbackStake)
            .call(abi.encodeWithSelector(Stake.mergeStake.selector, _callbackToken, _callbackSource, _callbackTarget));
        _callbackMergeBlocked = !merged;
    }

    function onProposalSubmitted(address, uint256, uint256, bytes[] calldata) external {}

    function onProposalVoted(address, uint256, uint256, uint256, uint256, bytes[] calldata) external {}

    function _deployCore() private returns (AuditState memory s) {
        // Constructor injection leaves two cycles (Launch/MemberNFT and Stake/Vote). Predict the
        // CREATE addresses from this harness's deployment order, exactly as DeployCore does. The
        // offsets are pinned by the three require() checks below, so a reordering fails loudly.
        uint256 nonce = vm.getNonce(address(this));
        address predictedMemberNFT = vm.computeCreateAddress(address(this), nonce + 6);
        address predictedVote = vm.computeCreateAddress(address(this), nonce + 9);
        address predictedMint = vm.computeCreateAddress(address(this), nonce + 10);

        s.weth = IWBNB(deployCode("WETH9", ""));
        s.factory = IUniswapV2Factory(deployInit(ReferenceCode.FACTORY_INIT, abi.encode(address(0))));
        s.router =
            IUniswapV2Router02(deployInit(ReferenceCode.ROUTER_INIT, abi.encode(address(s.factory), address(s.weth))));
        vm.deal(address(this), 100 ether);
        s.weth.deposit{value: 100 ether}();

        s.phase = new Phase(1, 10, 3600, 1e18, 10);
        s.launch = new Launch(
            LaunchInitParams({
                mintAddress: predictedMint,
                memberNFTAddress: predictedMemberNFT,
                rootParentTokenAddress: address(s.weth),
                pairFactoryAddress: address(s.factory),
                distributor: address(this),
                launchCountThresholdRatio: 1e16,
                maxLaunchCount: 100,
                tokenSymbolLength: 3,
                launchAmount: 1_000_000_000 ether,
                maxSupply: 2_000_000_000 ether,
                name: "Victim",
                symbol: "VIC"
            })
        );
        (address[] memory tokens,) = s.launch.tokens(0, 1, false);
        s.victim = LOVE20Token(tokens[0]);
        s.member = new MemberNFT(1e30, 7, 10, 32, address(s.victim));
        require(address(s.member) == predictedMemberNFT, "MemberNFT address differs from prediction");
        s.stake = new Stake(
            address(s.phase),
            address(s.member),
            predictedVote,
            address(s.launch),
            DexConfig({router: address(s.router), pairFactory: address(s.factory), swapFeeForLpRatio: 3000000000000000, swapFeeForProtocolRatio: 0}),
            1,
            100,
            1e15,
            2,
            5
        );
        s.submit = new Submit(address(s.phase), address(s.stake), address(s.member), 1e16);
        s.vote = new Vote(address(s.phase), address(s.stake), address(s.submit), address(s.member));
        require(address(s.vote) == predictedVote, "Vote address differs from prediction");
        s.mint = new Mint(
            address(s.phase),
            address(s.vote),
            address(s.submit),
            address(s.launch),
            address(s.member),
            5e16,
            1e15,
            1e15
        );
        require(address(s.mint) == predictedMint, "Mint address differs from prediction");
        (s.memberId,) = s.member.mint("attacker");
    }

    function testFakeTokenCannotSpendAnotherCommunityBoost() public {
        AuditState memory s = _deployCore();
        address victimOwner = address(0xBEEF);
        s.victim.transfer(victimOwner, 1100 ether);
        s.weth.transfer(victimOwner, 10 ether);
        vm.prank(victimOwner);
        (uint256 victimMemberId,) = s.member.mint("victim");
        vm.startPrank(victimOwner);
        s.victim.approve(address(s.stake), type(uint256).max);
        s.weth.approve(address(s.stake), type(uint256).max);
        s.stake.stakeLiquidity(address(s.victim), 1000 ether, 10 ether, 1, victimMemberId);
        s.stake.stakeBoost(address(s.victim), 100 ether, 1, victimMemberId);
        vm.stopPrank();

        s.fakeParent = new AuditToken("FA", address(s.weth));
        s.fakeChild = new AuditToken("FC", address(s.fakeParent));
        require(s.launch.isLOVE20Token(address(s.victim)), "Victim token is not registered");
        require(!s.launch.isLOVE20Token(address(s.fakeChild)), "Attack token is registered");
        s.fakeParentPair = IUniswapV2Pair(s.factory.createPair(address(s.fakeChild), address(s.fakeParent)));
        s.victimPair = IUniswapV2Pair(s.factory.createPair(address(s.fakeChild), address(s.victim)));
        s.fakeChild.approve(address(s.stake), type(uint256).max);
        s.fakeParent.approve(address(s.stake), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IStakeErrors.TokenNotRegistered.selector, address(s.fakeChild))
        );
        s.stake.stakeLiquidity(address(s.fakeChild), 10_000 ether, 10_000 ether, 1, s.memberId);
        s.fakeChild.setParent(address(s.victim));

        uint256 storedBoost = s.victim.balanceOf(address(s.stake));
        vm.expectRevert(
            abi.encodeWithSelector(IStakeErrors.TokenNotRegistered.selector, address(s.fakeChild))
        );
        s.stake.settleFees(address(s.fakeChild));
        require(s.victim.balanceOf(address(s.stake)) == storedBoost, "Other community boost was spent");
        (,,,, uint256 boostLiability,,,) = s.stake.totalStake(address(s.victim));
        require(boostLiability == storedBoost, "Victim boost liability changed");

        vm.prank(victimOwner);
        s.stake.unstake(address(s.victim), victimMemberId);
        vm.roll(21);
        vm.prank(victimOwner);
        s.stake.withdraw(address(s.victim), victimMemberId);
        require(s.victim.balanceOf(victimOwner) >= storedBoost, "Victim could not recover boost");
    }

    function testPrecreatedPairDoesNotBlockChildLaunch() public {
        AuditState memory s = _deployCore();
        vm.prank(address(s.mint));
        s.launch.addLaunchCount(address(s.victim), s.memberId, 1);

        address nextToken =
            address(uint160(uint256(keccak256(abi.encodePacked(hex"d6", hex"94", address(s.launch), hex"02")))));
        require(nextToken.code.length == 0, "Next token already exists");
        vm.prank(address(0xA77A));
        address precreatedPair = s.factory.createPair(nextToken, address(s.victim));

        address child = s.launch
            .launchToken(
                "ABC", address(s.victim), s.memberId, address(this), DistributorMode.NoCallback, new bytes[](0)
            );
        require(child == nextToken, "Launch did not deploy the predicted token");
        require(s.factory.getPair(child, address(s.victim)) == precreatedPair, "Launch did not reuse the pair");
        require(s.launch.remainingLaunchCount(address(s.victim), s.memberId) == 0, "Launch count was not consumed");
    }

    function testCurrentRoundSubmissionBlocksMerge() public {
        AuditState memory s = _deployCore();
        s.victim.approve(address(s.stake), type(uint256).max);
        s.weth.approve(address(s.stake), type(uint256).max);
        s.stake.stakeLiquidity(address(s.victim), 1000 ether, 10 ether, 1, s.memberId);
        ProposalBody memory body = ProposalBody({
            title: "proposal",
            details: "",
            target: address(this),
            targetMode: TargetMode.NoCallback,
            targetData: new bytes[](0)
        });
        uint256 proposalId = s.submit.submitNewProposal(address(s.victim), s.memberId, body);
        require(s.submit.proposalIdBySubmitterId(address(s.victim), 1, s.memberId) == proposalId, "Submission was not recorded");
        (uint256 nextMemberId,) = s.member.mint("next");
        vm.expectRevert(
            abi.encodeWithSelector(IStakeErrors.StakeRightsUsed.selector, address(s.victim), 1, s.memberId)
        );
        s.stake.mergeStake(address(s.victim), s.memberId, nextMemberId);

        vm.roll(11);
        require(s.submit.proposalIdBySubmitterId(address(s.victim), 2, s.memberId) == 0, "Previous round leaked into current round");
        s.stake.mergeStake(address(s.victim), s.memberId, nextMemberId);
        s.submit.submit(address(s.victim), nextMemberId, proposalId);
        (uint256 thirdMemberId,) = s.member.mint("third");
        vm.expectRevert(
            abi.encodeWithSelector(IStakeErrors.StakeRightsUsed.selector, address(s.victim), 2, nextMemberId)
        );
        s.stake.mergeStake(address(s.victim), nextMemberId, thirdMemberId);
    }

    function testProposalCreationCallbackCannotMergeSource() public {
        AuditState memory s = _deployCore();
        s.victim.approve(address(s.stake), type(uint256).max);
        s.weth.approve(address(s.stake), type(uint256).max);
        s.stake.stakeLiquidity(address(s.victim), 1000 ether, 10 ether, 1, s.memberId);
        (uint256 nextMemberId,) = s.member.mint("next");
        _callbackStake = s.stake;
        _callbackToken = address(s.victim);
        _callbackSource = s.memberId;
        _callbackTarget = nextMemberId;

        s.submit
            .submitNewProposal(
                address(s.victim),
                s.memberId,
                ProposalBody({
                    title: "callback",
                    details: "",
                    target: address(this),
                    targetMode: TargetMode.Callback,
                    targetData: new bytes[](0)
                })
            );
        require(_callbackMergeBlocked, "Proposal creation callback merged used stake");
    }

    function testCurrentRoundVoteBlocksMerge() public {
        AuditState memory s = _deployCore();
        s.victim.approve(address(s.stake), type(uint256).max);
        s.weth.approve(address(s.stake), type(uint256).max);
        s.stake.stakeLiquidity(address(s.victim), 1000 ether, 10 ether, 1, s.memberId);
        (uint256 voterId,) = s.member.mint("voter");
        s.stake.stakeLiquidity(address(s.victim), 1000 ether, 10 ether, 1, voterId);
        uint256 proposalId = s.submit
            .submitNewProposal(
                address(s.victim),
                s.memberId,
                ProposalBody({
                    title: "vote",
                    details: "",
                    target: address(this),
                    targetMode: TargetMode.NoCallback,
                    targetData: new bytes[](0)
                })
            );
        uint256[] memory ids = new uint256[](1);
        ids[0] = proposalId;
        uint256[] memory votes = new uint256[](1);
        votes[0] = 1;
        s.vote.vote(address(s.victim), voterId, ids, votes, new bytes[][](0));
        (uint256 nextMemberId,) = s.member.mint("next");
        vm.expectRevert(
            abi.encodeWithSelector(IStakeErrors.StakeRightsUsed.selector, address(s.victim), 1, voterId)
        );
        s.stake.mergeStake(address(s.victim), voterId, nextMemberId);
        vm.roll(11);
        s.stake.mergeStake(address(s.victim), voterId, nextMemberId);
    }

    function testFreshCapitalCanStillGrowProposalCountPastThresholdBound() public {
        AuditPhase phase = new AuditPhase();
        AuditMembers members = new AuditMembers(address(this));
        AuditStakeVotes votes = new AuditStakeVotes();
        Submit submit = new Submit(address(phase), address(votes), address(members), 1e16);
        ProposalBody memory body = ProposalBody({
            title: "proposal", details: "", target: address(this), targetMode: TargetMode.NoCallback,
            targetData: new bytes[](0)
        });

        for (uint256 memberId = 1; memberId <= 101; memberId++) {
            uint256 total = memberId == 1 ? 1000 : memberId * 100;
            uint256 memberVotes = memberId == 101 ? 102 : 100;
            votes.set(memberId, memberVotes, total);
            submit.submitNewProposal(address(0xBEEF), memberId, body);
        }

        (, uint256 totalProposals) = submit.submitInfos(address(0xBEEF), 1, 0, 0, false);
        require(totalProposals == 101, "Fresh capital did not exceed the old bound");
    }
}
