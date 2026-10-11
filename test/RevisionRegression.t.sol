// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {TestBase} from "./TestBase.sol";
import {VerdictMarkets} from "../src/VerdictMarkets.sol";
import {VerdictOracle} from "../src/VerdictOracle.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";

contract RevisionRegressionTest is TestBase {
    function test_unusableDeliveryBlocksRetry() public {
        uint256 id = create();
        vm.warp(markets.getMarket(id).params.answerFrom);
        bytes32 rid = markets.resolve(id, body);
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(true), 5);
        a.agreed = 3;
        deliver(rid, a);
        vm.expectRevert(VerdictMarkets.InvalidAttestation.selector);
        markets.propose(id, a);
        vm.warp(block.timestamp + 24 hours);
        vm.expectRevert(VerdictMarkets.AnswerAlreadyDelivered.selector);
        markets.resolve(id, body);
    }

    function test_renounceRequiresAllowlistDisabledEvenWhenEmpty() public {
        markets.setCreatorAllowed(creator, false);
        vm.expectRevert(VerdictMarkets.MustDisableAllowlist.selector);
        markets.renounceGuardian();
        assertEq(markets.guardian(), address(this));
        markets.disableAllowlist();
        markets.renounceGuardian();
        assertEq(markets.guardian(), address(0));
        VerdictMarkets.Params memory p = params();
        vm.prank(creator);
        markets.createMarket(p, body, escalationBody, "", 0);
    }

    function test_zeroBoundRejectedWithoutTakingBounty() public {
        VerdictMarkets.Params memory p = params();
        p.answerType = 3;
        p.bounds = new uint256[](2);
        p.bounds[1] = 10;
        uint256 beforeBalance = token.balanceOf(creator);
        vm.prank(creator);
        vm.expectRevert(VerdictMarkets.InvalidParams.selector);
        markets.createMarket(p, body, escalationBody, "", 0);
        assertEq(token.balanceOf(creator), beforeBalance);
        assertEq(markets.marketCount(), 0);
        p.bounds[0] = 1;
        uint256 id = createWith(p);
        betAs(id, alice, 0, 1 ether);
        vm.warp(p.answerFrom);
        bytes32 rid = markets.resolve(id, body);
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(uint256(0)), 5);
        deliver(rid, a);
        markets.propose(id, a);
        assertEq(markets.getMarket(id).outcome, 0);
    }

    function test_zeroDelayAcceptsConfigInSameBlock() public {
        address newSigner = vm.addr(9876);
        oracle.proposeConfig(VerdictOracle.Config(address(intake), address(token), newSigner, ACTION, PRICE));
        oracle.acceptConfig();
        assertEq(oracle.signer(), newSigner);
    }

    function test_oversizeAnswerRefused() public {
        uint256 id = create();
        bytes32 rid = oracle.request(body);
        OracleAttestation.Attestation memory a = attestation(id, new bytes(16_416), 5);
        a.answerType = 5;
        (bool ok,) = intake.deliver(rid, a, sign(a), 200_000);
        assertFalse(ok);
        assertEq(oracle.answerOf(a), bytes32(0));
        (, address pendingIntake,) = oracle.pending(rid);
        assertEq(pendingIntake, address(intake));
    }

    function test_otherMarketAnswerCannotSetOutcomeOrBlockRetry() public {
        uint256 first = create();
        uint256 second = create();
        vm.warp(markets.getMarket(first).params.answerFrom);
        bytes32 firstRid = markets.resolve(first, body);
        bytes32 secondRid = markets.resolve(second, body);
        OracleAttestation.Attestation memory a = attestation(second, abi.encode(true), 5);
        deliver(secondRid, a);
        assertEq(oracle.intakeRequestOf(a.requestId), secondRid);
        vm.expectRevert(VerdictMarkets.UnauthenticatedAnswer.selector);
        markets.propose(first, a);
        vm.warp(block.timestamp + 24 hours);
        markets.resolve(first, body);
        assertEq(markets.getMarket(first).asks, 2);
        bytes32 retryRid = markets.getMarket(first).primaryRequests[1];
        a = attestation(first, abi.encode(false), 5);
        deliver(firstRid, a); // A late first response is authentic but superseded by the paid retry.
        vm.expectRevert(VerdictMarkets.UnauthenticatedAnswer.selector);
        markets.propose(first, a);
        a = attestation(first, abi.encode(false), 5);
        deliver(retryRid, a);
        markets.propose(first, a);
        assertEq(markets.getMarket(first).outcome, 0);
    }

    function test_lateEscalationIssuedAfterAnswerUntilSettlesCorrectedOutcome() public {
        uint256 id = create();
        betAs(id, alice, 1, 100 ether);
        betAs(id, bob, 0, 100 ether);
        vm.warp(markets.getMarket(id).params.answerFrom);
        bytes32 rid = markets.resolve(id, body);
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(true), 5);
        deliver(rid, a);
        uint256 until = markets.getMarket(id).params.answerUntil;
        vm.warp(until - 10 minutes);
        markets.propose(id, a);
        rid = markets.escalate(id, escalationBody);
        vm.warp(until + 5 minutes);
        a = attestation(id, abi.encode(false), 10);
        deliver(rid, a);
        markets.propose(id, a);
        assertEq(markets.getMarket(id).outcome, 0);
        vm.warp(markets.getMarket(id).disputeEnds);
        markets.finalize(id);
        vm.prank(bob);
        assertEq(markets.claim(id), 196 ether);
        assertConserved(id, true);
        assertEq(token.balanceOf(address(markets)), 0);
    }

    function test_escalationCannotUseAnswerIssuedBeforeItsAsk() public {
        uint256 id = create();
        primary(id, true);
        vm.warp(block.timestamp + 1 minutes);
        bytes32 rid = markets.escalate(id, escalationBody);
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(false), 10);
        a.issuedAt = uint64(markets.getMarket(id).escalationAskedAt - 1);
        deliver(rid, a);
        vm.expectRevert(VerdictMarkets.InvalidAttestation.selector);
        markets.propose(id, a);
    }

    /// forge-config: default.fuzz.runs = 256
    /// @dev Audit 94b4f1d1: the two primary asks of one market can be answered differently. Only the most
    /// recent paid ask may establish the outcome, whatever the delivery order, so no proposer chooses.
    function testFuzz_onlyLatestPaidPrimaryRequestCanProposeRegardlessOfDeliveryOrder(bool retryFirst, bool value)
        public
    {
        uint256 id = create();
        betAs(id, alice, 0, 101);
        betAs(id, bob, 1, 202);
        vm.warp(markets.getMarket(id).params.answerFrom);
        bytes32 first = markets.resolve(id, body);
        vm.warp(block.timestamp + 24 hours);
        bytes32 retry = markets.resolve(id, body);
        OracleAttestation.Attestation memory accepted = attestation(id, abi.encode(value), 5);
        OracleAttestation.Attestation memory other = attestation(id, abi.encode(!value), 10);
        deliver(retryFirst ? retry : first, retryFirst ? accepted : other);
        deliver(retryFirst ? first : retry, retryFirst ? other : accepted);
        assertEq(oracle.intakeRequestOf(accepted.requestId), retry);
        assertEq(oracle.intakeRequestOf(other.requestId), first);
        bytes32 beforeState = keccak256(abi.encode(markets.getMarket(id)));
        vm.expectRevert(VerdictMarkets.UnauthenticatedAnswer.selector);
        markets.propose(id, other); // The first ask's answer can no longer compete with the retry.
        assertEq(keccak256(abi.encode(markets.getMarket(id))), beforeState);
        markets.propose(id, accepted);
        assertEq(markets.getMarket(id).outcome, value ? 1 : 0);
        vm.expectRevert(VerdictMarkets.UnauthenticatedAnswer.selector);
        markets.propose(id, other);
        assertEq(markets.getMarket(id).asks, 2);
        vm.warp(markets.getMarket(id).disputeEnds);
        markets.finalize(id);
        vm.prank(value ? bob : alice);
        markets.claim(id);
        assertConserved(id, true);
        assertEq(token.balanceOf(address(markets)), 0);
    }

    function test_identicalEscalationBodiesStillRequireEachMarketsOwnPaidAsk() public {
        uint256 first = create();
        uint256 second = create();
        betAs(first, alice, 0, 101);
        betAs(first, bob, 1, 202);
        betAs(second, alice, 0, 307);
        betAs(second, bob, 1, 409);
        primary(first, true);
        primary(second, true);
        bytes32 firstAsk = markets.escalate(first, escalationBody);
        bytes32 secondAsk = markets.escalate(second, escalationBody);
        OracleAttestation.Attestation memory correction = attestation(first, abi.encode(false), 10);
        deliver(firstAsk, correction);
        assertEq(oracle.answerOf(correction), markets.getMarket(second).escalationBodyHash);
        bytes32 beforeState = keccak256(abi.encode(markets.getMarket(second)));
        vm.expectRevert(VerdictMarkets.UnauthenticatedAnswer.selector);
        markets.propose(second, correction);
        assertEq(keccak256(abi.encode(markets.getMarket(second))), beforeState);
        markets.propose(first, correction);
        correction = attestation(second, abi.encode(true), 10);
        deliver(secondAsk, correction);
        markets.propose(second, correction);
        vm.warp(markets.getMarket(second).disputeEnds);
        markets.finalize(first);
        markets.finalize(second);
        vm.prank(alice);
        markets.claim(first);
        vm.prank(bob);
        markets.claim(second);
        assertConserved(first, true);
        assertConserved(second, true);
        assertEq(token.balanceOf(address(markets)), 0);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_lateEscalationHasFiniteSettlementDeadline(
        uint32 windowSeed,
        uint32 leadSeed,
        uint32 latencySeed,
        bool replacementArrives
    ) public {
        VerdictMarkets.Params memory p = params();
        p.disputeWindow = uint32(bound(windowSeed, 1 hours, 3 days));
        p.voidAfter = p.answerUntil + 1;
        uint256 id = createWith(p);
        betAs(id, alice, 0, 101);
        betAs(id, bob, 1, 202);
        vm.warp(p.answerFrom);
        bytes32 rid = markets.resolve(id, body);
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(true), 5);
        deliver(rid, a);
        vm.warp(p.answerUntil - bound(leadSeed, 1, 1 hours - 1));
        markets.propose(id, a);
        vm.warp(p.answerUntil - 1);
        rid = markets.escalate(id, escalationBody);
        uint256 extendedEnd = markets.getMarket(id).disputeEnds;
        assertGe(extendedEnd, block.timestamp + 24 hours);
        vm.warp(p.answerUntil + bound(latencySeed, 1, extendedEnd - p.answerUntil - 1));
        assertGe(block.timestamp, p.voidAfter);
        if (replacementArrives) {
            a = attestation(id, abi.encode(false), 10);
            deliver(rid, a);
            markets.propose(id, a);
            assertEq(markets.getMarket(id).disputeEnds, block.timestamp + p.disputeWindow);
            vm.expectRevert(VerdictMarkets.EscalationUnavailable.selector);
            markets.propose(id, a); // The window cannot restart repeatedly.
        }
        vm.expectRevert(VerdictMarkets.OutsideWindow.selector);
        markets.voidMarket(id);
        uint256 deadline = markets.getMarket(id).disputeEnds;
        assertLe(deadline, extendedEnd + p.disputeWindow);
        vm.warp(deadline - 1);
        vm.expectRevert(VerdictMarkets.OutsideWindow.selector);
        markets.finalize(id);
        vm.warp(deadline);
        markets.finalize(id);
        assertEq(markets.getMarket(id).outcome, replacementArrives ? 0 : 1);
        vm.prank(replacementArrives ? alice : bob);
        markets.claim(id);
        assertConserved(id, true);
        assertEq(token.balanceOf(address(markets)), 0);
    }
}
