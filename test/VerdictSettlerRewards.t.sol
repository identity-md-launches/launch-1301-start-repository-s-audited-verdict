// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./TestBase.sol";
import {VerdictMarkets} from "../src/VerdictMarkets.sol";
import {VerdictOracle} from "../src/VerdictOracle.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {Vm} from "forge-std/Vm.sol";

abstract contract SettlerRewardsBase is TestBase {
    uint256 internal constant REWARD = 0.1 ether;
    bytes32 internal constant REWARDED = keccak256("SettlerRewarded(uint256,address,uint8,uint256)");
    address internal resolver = makeAddr("resolver");
    address internal proposer = makeAddr("proposer");
    address internal finisher = makeAddr("finisher");

    function rewardedParams(uint256 reward) internal view returns (VerdictMarkets.Params memory p) {
        p = params();
        p.settlerReward = reward;
        p.bounty += 5 * reward;
    }

    function setPrice(uint256 price) internal {
        oracle.proposeConfig(VerdictOracle.Config(address(intake), address(token), vm.addr(SIGNER_KEY), ACTION, price));
        oracle.acceptConfig();
    }

    function rewardCall(uint256 id, address caller, uint8 action, bytes memory payload, uint256 expected)
        internal
        returns (bytes memory result)
    {
        uint256 balance = token.balanceOf(caller);
        uint256 paid = markets.getMarket(id).rewardsPaid;
        vm.recordLogs();
        vm.prank(caller);
        bool ok;
        (ok, result) = address(markets).call(payload);
        assertTrue(ok, "rewarded action reverted");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(markets) || logs[i].topics[0] != REWARDED) continue;
            ++count;
            assertEq(logs[i].topics.length, 3);
            assertEq(logs[i].topics[1], bytes32(id));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(caller))));
            (uint8 emittedAction, uint256 amount) = abi.decode(logs[i].data, (uint8, uint256));
            assertEq(emittedAction, action);
            assertEq(amount, expected);
        }
        assertEq(count, markets.getMarket(id).settlerReward == 0 ? 0 : 1, "reward emitted more than once");
        assertEq(token.balanceOf(caller) - balance, expected, "reward not paid to caller");
        assertEq(markets.getMarket(id).rewardsPaid - paid, expected);
    }

    function rewardedPrimary(uint256 id) internal returns (OracleAttestation.Attestation memory a) {
        vm.warp(markets.getMarket(id).params.answerFrom);
        bytes32 rid =
            abi.decode(rewardCall(id, resolver, 0, abi.encodeCall(markets.resolve, (id, body)), REWARD), (bytes32));
        a = attestation(id, abi.encode(true), 5);
        deliver(rid, a);
        rewardCall(id, proposer, 1, abi.encodeCall(markets.propose, (id, a)), REWARD);
    }

    function assertRewardConserved(uint256 id) internal view {
        VerdictMarkets.Market memory m = markets.getMarket(id);
        assertEq(
            m.pool + m.params.bounty, m.paidOut + m.refunded + m.fees + m.oracleSpend + m.rewardsPaid + m.returnedBounty
        );
        assertEq(m.bountyRemaining, 0);
    }
}

contract VerdictSettlerRewardsTest is SettlerRewardsBase {
    function test_eachProposalResolveAndFinalizePaysItsCallerOnceEscalatePaysNothing() public {
        uint256 id = createWith(rewardedParams(REWARD));
        assertEq(markets.getMarket(id).settlerReward, REWARD);
        assertEq(markets.getMarket(id).params.settlerReward, REWARD);
        betAs(id, alice, 1, 100 ether);
        betAs(id, bob, 0, 100 ether);
        OracleAttestation.Attestation memory a = rewardedPrimary(id);
        vm.expectRevert(VerdictMarkets.WrongState.selector);
        markets.resolve(id, body);
        vm.expectRevert(VerdictMarkets.InvalidAttestation.selector);
        markets.propose(id, a);
        uint256 beforeBalance = token.balanceOf(carol);
        uint256 paid = markets.getMarket(id).rewardsPaid;
        vm.recordLogs();
        vm.prank(carol);
        bytes32 escalation = markets.escalate(id, escalationBody);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertFalse(logs[i].emitter == address(markets) && logs[i].topics[0] == REWARDED);
        }
        assertEq(token.balanceOf(carol), beforeBalance);
        assertEq(markets.getMarket(id).rewardsPaid, paid);
        a = attestation(id, abi.encode(false), 10);
        deliver(escalation, a);
        rewardCall(id, resolver, 1, abi.encodeCall(markets.propose, (id, a)), REWARD);
        vm.expectRevert(VerdictMarkets.EscalationUnavailable.selector);
        markets.propose(id, a);
        vm.warp(markets.getMarket(id).disputeEnds);
        beforeBalance = token.balanceOf(creator);
        rewardCall(id, finisher, 2, abi.encodeCall(markets.finalize, (id)), REWARD);
        VerdictMarkets.Market memory m = markets.getMarket(id);
        assertEq(m.rewardsPaid, 4 * REWARD);
        assertEq(m.returnedBounty, REWARD);
        assertEq(m.fees, 4 ether);
        assertEq(token.balanceOf(creator) - beforeBalance, 2 ether + REWARD);
        assertEq(token.balanceOf(treasury), 1 ether);
        assertEq(token.balanceOf(address(burn)), 1 ether);
        vm.expectRevert(VerdictMarkets.WrongState.selector);
        markets.finalize(id);
        vm.expectRevert(VerdictMarkets.WrongState.selector);
        markets.voidMarket(id);
        vm.prank(bob);
        assertEq(markets.claim(id), 196 ether);
        assertRewardConserved(id);
        assertEq(token.balanceOf(address(markets)), 0);
    }

    function test_retryResolveIsAlsoRewardedOnce() public {
        uint256 id = createWith(rewardedParams(REWARD));
        vm.warp(markets.getMarket(id).params.answerFrom);
        rewardCall(id, resolver, 0, abi.encodeCall(markets.resolve, (id, body)), REWARD);
        vm.expectRevert(VerdictMarkets.RetryNotReady.selector);
        markets.resolve(id, body);
        vm.warp(block.timestamp + 24 hours);
        bytes32 rid =
            abi.decode(rewardCall(id, proposer, 0, abi.encodeCall(markets.resolve, (id, body)), REWARD), (bytes32));
        vm.expectRevert(VerdictMarkets.AskLimit.selector);
        markets.resolve(id, body);
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(true), 5);
        deliver(rid, a);
        // No asks remain: even an enormous new price must not prevent a proposal reward.
        setPrice(type(uint256).max);
        rewardCall(id, proposer, 1, abi.encodeCall(markets.propose, (id, a)), REWARD);
        vm.warp(markets.getMarket(id).disputeEnds);
        rewardCall(id, finisher, 3, abi.encodeCall(markets.voidMarket, (id)), REWARD);
        assertEq(markets.getMarket(id).rewardsPaid, 4 * REWARD);
        assertRewardConserved(id);
    }

    function test_voidWithoutAsksPaysBeforeReturningBountyAndNeverTwice() public {
        uint256 id = createWith(rewardedParams(REWARD));
        betAs(id, alice, 0, 17 ether);
        vm.warp(markets.getMarket(id).params.voidAfter);
        setPrice(type(uint256).max);
        uint256 beforeBalance = token.balanceOf(creator);
        rewardCall(id, finisher, 3, abi.encodeCall(markets.voidMarket, (id)), REWARD);
        assertEq(token.balanceOf(creator) - beforeBalance, 2 * PRICE + 4 * REWARD);
        vm.expectRevert(VerdictMarkets.WrongState.selector);
        markets.voidMarket(id);
        vm.prank(alice);
        assertEq(markets.claim(id), 17 ether);
        assertEq(markets.getMarket(id).fees, 0);
        assertRewardConserved(id);
        assertEq(token.balanceOf(address(markets)), 0);
    }

    function test_priceRiseBeforeResolveClipsRewardToExactReserve() public {
        uint256 id = createWith(rewardedParams(REWARD));
        setPrice(0.73 ether);
        vm.warp(markets.getMarket(id).params.answerFrom);
        bytes32 rid =
            abi.decode(rewardCall(id, resolver, 0, abi.encodeCall(markets.resolve, (id, body)), 0.04 ether), (bytes32));
        assertEq(markets.getMarket(id).bountyRemaining, 0.73 ether);
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(true), 5);
        deliver(rid, a);
        setPrice(0.8 ether);
        rewardCall(id, proposer, 1, abi.encodeCall(markets.propose, (id, a)), 0);
        assertEq(markets.getMarket(id).bountyRemaining, 0.73 ether);
        vm.warp(markets.getMarket(id).disputeEnds);
        rewardCall(id, finisher, 3, abi.encodeCall(markets.voidMarket, (id)), REWARD);
        assertEq(markets.getMarket(id).returnedBounty, 0.63 ether);
        assertRewardConserved(id);
    }

    function test_proposalUsesCurrentPriceAndPreservesTheLastAsk() public {
        uint256 id = createWith(rewardedParams(REWARD));
        betAs(id, alice, 1, 100 ether);
        vm.warp(markets.getMarket(id).params.answerFrom);
        bytes32 rid =
            abi.decode(rewardCall(id, resolver, 0, abi.encodeCall(markets.resolve, (id, body)), REWARD), (bytes32));
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(true), 5);
        deliver(rid, a);
        setPrice(0.85 ether);
        rewardCall(id, proposer, 1, abi.encodeCall(markets.propose, (id, a)), 0.05 ether);
        assertEq(markets.getMarket(id).bountyRemaining, 0.85 ether);
        rid = markets.escalate(id, escalationBody);
        assertEq(markets.getMarket(id).bountyRemaining, 0);
        a = attestation(id, abi.encode(true), 10);
        deliver(rid, a);
        rewardCall(id, proposer, 1, abi.encodeCall(markets.propose, (id, a)), 0);
        vm.warp(markets.getMarket(id).disputeEnds);
        rewardCall(id, finisher, 2, abi.encodeCall(markets.finalize, (id)), 0);
        assertEq(markets.getMarket(id).fees, 2 ether);
        vm.prank(alice);
        assertEq(markets.claim(id), 98 ether);
        assertRewardConserved(id);
        assertEq(token.balanceOf(address(markets)), 0);
    }

    function test_terminalRewardIsClippedToBountyNeverBettorDepositsOrAnotherMarket() public {
        uint256 other = createWith(rewardedParams(REWARD));
        betAs(other, bob, 0, 99 ether);
        bytes32 otherState = keccak256(abi.encode(markets.getMarket(other)));
        uint256 id = createWith(rewardedParams(REWARD));
        betAs(id, alice, 1, 100 ether);
        setPrice(1.45 ether);
        vm.warp(markets.getMarket(id).params.answerFrom);
        rewardCall(id, resolver, 0, abi.encodeCall(markets.resolve, (id, body)), 0);
        vm.warp(markets.getMarket(id).params.voidAfter);
        rewardCall(id, finisher, 3, abi.encodeCall(markets.voidMarket, (id)), 0.05 ether);
        vm.prank(alice);
        assertEq(markets.claim(id), 100 ether);
        assertRewardConserved(id);
        assertEq(keccak256(abi.encode(markets.getMarket(other))), otherState);
        assertEq(token.balanceOf(address(markets)), 99 ether + 2 * PRICE + 5 * REWARD);
        markets.voidMarket(other);
        vm.prank(bob);
        assertEq(markets.claim(other), 99 ether);
        assertRewardConserved(other);
        assertEq(token.balanceOf(address(markets)), 0);
    }

    function test_bountyMinimumChecksBothRequestedAndReceivedAmounts() public {
        VerdictMarkets.Params memory p = rewardedParams(REWARD);
        uint256 minimum = p.bounty;
        p.bounty -= 1;
        uint256 beforeBalance = token.balanceOf(creator);
        vm.expectRevert(VerdictMarkets.InsufficientBounty.selector);
        createWith(p);
        assertEq(token.balanceOf(creator), beforeBalance);
        p.bounty = minimum;
        token.setFee(1);
        vm.expectRevert(VerdictMarkets.InsufficientBounty.selector);
        createWith(p);
        assertEq(token.balanceOf(creator), beforeBalance);
        assertEq(markets.marketCount(), 0);
        token.setFee(1000);
        p.bounty = 2 ether;
        uint256 id = createWith(p);
        assertEq(markets.getMarket(id).params.bounty, 1.8 ether);
        token.setFee(0);
        p.bounty = minimum;
        createWith(p); // Exact minimum accepted.
    }

    function test_rewardBoundIsInclusiveAndZeroCapDisablesRewards() public {
        assertEq(markets.maxSettlerReward(), 0.25 ether);
        createWith(rewardedParams(0.25 ether));
        vm.expectRevert(VerdictMarkets.InvalidParams.selector);
        createWith(rewardedParams(0.25 ether + 1));
        markets = newMarkets(address(oracle), 100, 50, 50, 500 ether, 0);
        markets.setCreatorAllowed(creator, true);
        vm.prank(creator);
        token.approve(address(markets), type(uint256).max);
        createWith(rewardedParams(0));
        vm.expectRevert(VerdictMarkets.InvalidParams.selector);
        createWith(rewardedParams(1));
    }

    function test_bountyArithmeticRejectsImpossiblePriceOrRewardWithoutOverflow() public {
        VerdictMarkets.Params memory p = rewardedParams(REWARD);
        p.bounty = type(uint256).max;
        setPrice(type(uint256).max);
        vm.expectRevert(VerdictMarkets.InsufficientBounty.selector);
        createWith(p);
        setPrice(PRICE);
        markets = newMarkets(address(oracle), 100, 50, 50, 500 ether, type(uint256).max);
        markets.setCreatorAllowed(creator, true);
        p.settlerReward = type(uint256).max;
        vm.expectRevert(VerdictMarkets.InsufficientBounty.selector);
        createWith(p);
    }

    function test_zeroRewardKeepsLegacyBalancesEventsAndNoNewPriceDependency() public {
        uint256 id = create();
        betAs(id, alice, 1, 100 ether);
        vm.warp(markets.getMarket(id).params.answerFrom);
        bytes32 rid = abi.decode(rewardCall(id, resolver, 0, abi.encodeCall(markets.resolve, (id, body)), 0), (bytes32));
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(true), 5);
        deliver(rid, a);
        vm.mockCallRevert(address(oracle), abi.encodeWithSelector(oracle.price.selector), "price unavailable");
        rewardCall(id, proposer, 1, abi.encodeCall(markets.propose, (id, a)), 0);
        vm.warp(markets.getMarket(id).disputeEnds);
        rewardCall(id, finisher, 2, abi.encodeCall(markets.finalize, (id)), 0);
        vm.clearMockedCalls();
        assertEq(markets.getMarket(id).returnedBounty, PRICE);
        assertEq(markets.getMarket(id).fees, 2 ether);
        vm.prank(alice);
        assertEq(markets.claim(id), 98 ether);
        assertRewardConserved(id);
        assertEq(token.balanceOf(address(markets)), 0);
    }
}
