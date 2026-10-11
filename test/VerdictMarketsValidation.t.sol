// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./TestBase.sol";
import {VerdictMarkets} from "../src/VerdictMarkets.sol";
import {VerdictOracle} from "../src/VerdictOracle.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {Vm} from "forge-std/Vm.sol";

contract VerdictMarketsValidationTest is TestBase {
    bytes32 internal validationRequest;

    function test_pauseBlocksOnlyEntryAndRenounceRequiresUnpaused() public {
        uint256 id = create();
        uint256 unanswered = create();
        betAs(id, alice, 1, 1 ether);
        markets.pause();
        vm.prank(alice);
        vm.expectRevert(VerdictMarkets.EntryPaused.selector);
        markets.bet(id, 1, 1, 0);
        VerdictMarkets.Params memory p = params();
        vm.prank(creator);
        vm.expectRevert(VerdictMarkets.EntryPaused.selector);
        markets.createMarket(p, body, escalationBody, "", 0);
        vm.expectRevert(VerdictMarkets.MustUnpause.selector);
        markets.renounceGuardian();
        primary(id, true);
        bytes32 rid = markets.escalate(id, escalationBody);
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(true), 10);
        deliver(rid, a);
        markets.propose(id, a);
        vm.warp(markets.getMarket(id).disputeEnds);
        markets.finalize(id);
        vm.prank(alice);
        markets.claim(id);
        assertConserved(id, true);
        vm.warp(markets.getMarket(unanswered).params.voidAfter);
        markets.voidMarket(unanswered);
        assertConserved(unanswered, true);
        markets.unpause();
        markets.disableAllowlist();
        markets.renounceGuardian();
        assertEq(markets.guardian(), address(0));
        vm.expectRevert(VerdictMarkets.NotGuardian.selector);
        markets.pause();
    }

    function test_guardianHandoverIsTwoStepAndNoUnauthorizedPowers() public {
        vm.startPrank(alice);
        vm.expectRevert(VerdictMarkets.NotGuardian.selector);
        markets.pause();
        vm.expectRevert(VerdictMarkets.NotGuardian.selector);
        markets.unpause();
        vm.expectRevert(VerdictMarkets.NotGuardian.selector);
        markets.setCreatorAllowed(alice, true);
        vm.expectRevert(VerdictMarkets.NotGuardian.selector);
        markets.disableAllowlist();
        vm.expectRevert(VerdictMarkets.NotGuardian.selector);
        markets.transferGuardian(alice);
        vm.expectRevert(VerdictMarkets.NotGuardian.selector);
        markets.renounceGuardian();
        vm.stopPrank();
        vm.expectRevert(VerdictMarkets.InvalidAddress.selector);
        markets.transferGuardian(address(0));
        markets.transferGuardian(alice);
        assertEq(markets.guardian(), address(this));
        vm.prank(bob);
        vm.expectRevert(VerdictMarkets.NotPendingGuardian.selector);
        markets.acceptGuardian();
        vm.prank(alice);
        markets.acceptGuardian();
        assertEq(markets.guardian(), alice);
        assertEq(markets.pendingGuardian(), address(0));
        vm.expectRevert(VerdictMarkets.NotGuardian.selector);
        markets.pause();
        vm.prank(alice);
        markets.pause();
    }

    function test_allowlistRemovalAndPermanentDisable() public {
        VerdictMarkets.Params memory p = params();
        vm.prank(alice);
        vm.expectRevert(VerdictMarkets.CreatorNotAllowed.selector);
        markets.createMarket(p, body, escalationBody, "", 0);
        markets.setCreatorAllowed(alice, true);
        vm.prank(alice);
        markets.createMarket(p, body, escalationBody, "", 0);
        markets.setCreatorAllowed(alice, false);
        vm.prank(alice);
        vm.expectRevert(VerdictMarkets.CreatorNotAllowed.selector);
        markets.createMarket(p, body, escalationBody, "", 0);
        markets.disableAllowlist();
        vm.prank(alice);
        markets.createMarket(p, body, escalationBody, "", 0);
        assertFalse(markets.allowlistOn());
        vm.expectRevert(VerdictMarkets.AllowlistDisabled.selector);
        markets.setCreatorAllowed(alice, false);
        vm.expectRevert(VerdictMarkets.AllowlistDisabled.selector);
        markets.disableAllowlist();
        markets.renounceGuardian();
        vm.prank(bob);
        markets.createMarket(p, body, escalationBody, "", 0);
    }

    function test_feeCapAndPoolCapConstructor() public {
        vm.expectRevert(VerdictMarkets.InvalidFees.selector);
        newMarkets(address(oracle), 100, 200, 201, 1, 0.25 ether);
        vm.expectRevert(VerdictMarkets.InvalidFees.selector);
        newMarkets(address(oracle), 65535, 65535, 65535, 1, 0.25 ether);
        vm.expectRevert(VerdictMarkets.InvalidCap.selector);
        newMarkets(address(oracle), 100, 50, 50, 0, 0.25 ether);
        VerdictMarkets maxFees = newMarkets(address(oracle), 100, 200, 200, 1, 0.25 ether);
        assertEq(maxFees.treasuryFeeBps(0), 200);
    }

    function test_poolCapUsesReceivedBalanceAndFailedBetIsAtomic() public {
        uint256 id = create();
        betAs(id, alice, 0, 499 ether);
        betAs(id, bob, 1, 1 ether);
        uint256 balance = token.balanceOf(carol);
        vm.prank(carol);
        vm.expectRevert(VerdictMarkets.PoolCapExceeded.selector);
        markets.bet(id, 1, 1, 0);
        assertEq(token.balanceOf(carol), balance);
        assertEq(markets.getMarket(id).pool, 500 ether);
    }

    function test_feeOnTransferCreditsOnlyActualBountyAndStakes() public {
        token.setFee(1000);
        VerdictMarkets.Params memory p = params();
        p.bounty = 2 ether;
        uint256 id = createWith(p);
        assertEq(markets.getMarket(id).params.bounty, 1.8 ether);
        assertEq(markets.getMarket(id).bountyRemaining, 1.8 ether);
        betAs(id, alice, 0, 550 ether); // 495 IMD received: below the 500 IMD cap.
        assertEq(markets.getMarket(id).pool, 495 ether);
        assertEq(markets.stakes(id, alice, 0), 495 ether);
        token.setFee(0);
        vm.warp(markets.getMarket(id).params.voidAfter);
        markets.voidMarket(id);
        vm.prank(alice);
        assertEq(markets.claim(id), 495 ether);
        assertConserved(id, true);
        assertEq(token.balanceOf(address(markets)), 0);
    }

    function test_bountyMustCoverTwoAsksAfterTransferFee() public {
        VerdictMarkets.Params memory p = params();
        p.bounty = 2 * PRICE - 1;
        vm.prank(creator);
        vm.expectRevert(VerdictMarkets.InsufficientBounty.selector);
        markets.createMarket(p, body, escalationBody, "", 0);
        p.bounty = 2 * PRICE;
        token.setFee(1);
        vm.prank(creator);
        vm.expectRevert(VerdictMarkets.InsufficientBounty.selector);
        markets.createMarket(p, body, escalationBody, "", 0);
        assertEq(markets.marketCount(), 0);
        assertEq(token.balanceOf(address(markets)), 0);
    }

    function test_betZeroUnknownOutcomeAndCloseBoundary() public {
        uint256 id = create();
        vm.expectRevert(VerdictMarkets.InvalidAmount.selector);
        markets.bet(id, 0, 0, 0);
        vm.expectRevert(VerdictMarkets.InvalidOutcome.selector);
        markets.bet(id, 2, 1, 0);
        vm.warp(markets.getMarket(id).params.closeAt - 1);
        betAs(id, alice, 0, 1);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(VerdictMarkets.OutsideWindow.selector);
        markets.bet(id, 0, 1, 0);
    }

    function test_creationEmitsBothFullBodies() public {
        vm.recordLogs();
        uint256 id = create();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        bytes32 topic = keccak256("MarketCreated(uint256,address,bytes32,bytes32,bytes,bytes,string,uint256,address)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(markets) || logs[i].topics[0] != topic) continue;
            (
                bytes32 escalationHash,
                bytes memory primaryBody,
                bytes memory secondBody,
                string memory uri,
                uint256 agentId,
                address collateralToken
            ) = abi.decode(logs[i].data, (bytes32, bytes, bytes, string, uint256, address));
            assertEq(collateralToken, address(token));
            assertEq(uint256(logs[i].topics[1]), id);
            assertEq(logs[i].topics[3], keccak256(body));
            assertEq(escalationHash, keccak256(escalationBody));
            assertEq(primaryBody, body);
            assertEq(secondBody, escalationBody);
            assertEq(uri, "ipfs://market");
            assertEq(agentId, 42);
            found = true;
        }
        assertTrue(found);
    }

    function test_invalidTimesPanelsAndTypes() public {
        VerdictMarkets.Params memory p = params();
        p.closeAt = uint64(block.timestamp);
        expectInvalid(p);
        p = params();
        p.answerFrom = p.closeAt - 1;
        expectInvalid(p);
        p = params();
        p.answerUntil = p.answerFrom;
        expectInvalid(p);
        p = params();
        p.voidAfter = p.answerUntil;
        expectInvalid(p);
        p = params();
        p.disputeWindow = 1 hours - 1;
        expectInvalid(p);
        p = params();
        p.disputeWindow = 3 days + 1;
        expectInvalid(p);
        p = params();
        p.minPanelSize = 4;
        expectInvalid(p);
        p = params();
        p.minAgreed = 0;
        expectInvalid(p);
        p = params();
        p.answerType = 1;
        expectInvalid(p);
        p = params();
        p.answerType = 2;
        expectInvalid(p);
        p = params();
        p.answerType = 6;
        expectInvalid(p);
        p = params();
        p.fromBlock = p.toBlock + 1;
        expectInvalid(p);
        p = params();
        p.questionHash = bytes32(0);
        expectInvalid(p);
        p = params();
        p.dataChainId = 0;
        expectInvalid(p);
    }

    function test_bodyHashAndBodySizeValidation() public {
        VerdictMarkets.Params memory p = params();
        vm.startPrank(creator);
        vm.expectRevert(VerdictMarkets.InvalidBody.selector);
        markets.createMarket(p, "", "", "", 0);
        vm.expectRevert(VerdictMarkets.InvalidBody.selector);
        markets.createMarket(p, body, body, "", 0);
        vm.expectRevert(VerdictMarkets.InvalidBody.selector);
        markets.createMarket(p, new bytes(16_385), "", "", 0);
        vm.expectRevert(VerdictMarkets.InvalidBody.selector);
        markets.createMarket(p, body, new bytes(16_385), "", 0);
        uint256 id = markets.createMarket(p, body, "", "", 0);
        assertEq(markets.getMarket(id).escalationBodyHash, bytes32(0));
        vm.stopPrank();
    }

    function test_minAgreedCanRequireMoreThanMinimumPanelSize() public {
        VerdictMarkets.Params memory p = params();
        p.minAgreed = 7;
        uint256 id = createWith(p);
        vm.warp(p.answerFrom);
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(true), 7);
        deliver(markets.resolve(id, body), a);
        markets.propose(id, a);
        assertEq(markets.getMarket(id).panelSize, 7);
    }

    function test_attestationMustMatchEveryMarketFieldAndPanelRequirements() public {
        uint256 id = create();
        vm.warp(markets.getMarket(id).params.answerFrom);
        validationRequest = markets.resolve(id, body);
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(true), 5);
        a.questionHash = keccak256("wrong question");
        rejectAuthenticated(id, a);
        a = attestation(id, abi.encode(true), 5);
        a.answerType = 3;
        rejectAuthenticated(id, a);
        a = attestation(id, abi.encode(true), 5);
        a.chainId = 11155111;
        rejectAuthenticated(id, a);
        a = attestation(id, abi.encode(true), 5);
        a.fromBlock++;
        rejectAuthenticated(id, a);
        a = attestation(id, abi.encode(true), 5);
        a.toBlock--;
        rejectAuthenticated(id, a);
        a = attestation(id, abi.encode(true), 4);
        rejectAuthenticated(id, a);
        a = attestation(id, abi.encode(true), 5);
        a.agreed = 3;
        rejectAuthenticated(id, a);
        a = attestation(id, abi.encode(true), 5);
        a.quorum = 6;
        rejectAuthenticated(id, a);
        a = attestation(id, abi.encode(true), 5);
        a.agreed = 6;
        rejectAuthenticated(id, a);
        a = attestation(id, abi.encode(true), 5);
        a.quorum = 0;
        rejectAuthenticated(id, a);
        a = attestation(id, abi.encode(true), 5);
        a.issuedAt--;
        rejectAuthenticated(id, a);
        vm.warp(markets.getMarket(id).params.answerUntil + 1);
        a = attestation(id, abi.encode(true), 5);
        rejectAuthenticated(id, a);
        assertEq(uint256(markets.getMarket(id).status), uint256(VerdictMarkets.Status.Open));
    }

    function test_escalationRequiresDoubleCurrentPanelAndCorrectBody() public {
        uint256 id = create();
        primary(id, true);
        bytes32 rid = markets.escalate(id, escalationBody);
        uint256 snapshot = vm.snapshotState();
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(false), 9);
        deliver(rid, a);
        vm.expectRevert(VerdictMarkets.InvalidAttestation.selector);
        markets.propose(id, a);
        assertTrue(vm.revertToState(snapshot));
        a = attestation(id, abi.encode(false), 10);
        deliver(oracle.request(body), a);
        vm.expectRevert(VerdictMarkets.UnauthenticatedAnswer.selector);
        markets.propose(id, a);
        a = attestation(id, abi.encode(false), 10);
        deliver(rid, a);
        markets.propose(id, a);
        assertTrue(markets.getMarket(id).escalated);
    }

    function test_firstProposalAtVoidDeadlineCannotResurrectMarket() public {
        uint256 id = create();
        vm.warp(markets.getMarket(id).params.answerFrom);
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(true), 5);
        deliver(markets.resolve(id, body), a);
        vm.warp(markets.getMarket(id).params.voidAfter);
        vm.expectRevert(VerdictMarkets.OutsideWindow.selector);
        markets.propose(id, a);
        markets.voidMarket(id);
        vm.expectRevert(VerdictMarkets.WrongState.selector);
        markets.propose(id, a);
    }

    function rejectAuthenticated(uint256 id, OracleAttestation.Attestation memory a) internal {
        uint256 snapshot = vm.snapshotState();
        deliver(validationRequest, a);
        vm.expectRevert(VerdictMarkets.InvalidAttestation.selector);
        markets.propose(id, a);
        assertTrue(vm.revertToState(snapshot));
    }

    function expectInvalid(VerdictMarkets.Params memory p) internal {
        vm.prank(creator);
        vm.expectRevert(VerdictMarkets.InvalidParams.selector);
        markets.createMarket(p, body, escalationBody, "", 0);
    }
}
