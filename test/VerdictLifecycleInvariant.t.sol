// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TestBase} from "./TestBase.sol";
import {VerdictMarkets} from "src/VerdictMarkets.sol";
import {OracleAttestation} from "src/OracleAttestation.sol";

/// @dev A second campaign complements the existing three-market handler. Markets
/// are created throughout a run, all four answer types are reachable, and ghosts
/// come from token balance deltas and submitted stakes, not the market's counters.
contract VerdictLifecycleHandler is TestBase {
    uint256 public constant MAX_MARKETS = 12;
    uint256 public count;
    uint256 public marketDonations;
    uint256 public burnDonations;
    uint256 public successfulBets;
    uint256 public successfulPrimaryAsks;
    uint256 public successfulPrimaryAnswers;
    uint256 public successfulReplacements;
    uint256 public failedDeliveries;
    uint256 public finalizedMarkets;
    uint256 public voidedMarkets;
    uint256 public successfulClaims;
    uint256 public independentOracleSpend;
    uint256 public rejectedIndependentProposals;
    uint256 public lateEscalationAnswers;

    struct Ledger {
        uint256 bounty;
        uint256 pool;
        uint256 spend;
        uint256 returned;
        uint256 creatorFees;
        uint256 burnFees;
        uint256 treasuryFees;
        uint256 payouts;
        uint256 refunds;
        uint8 asks;
        uint8 terminalStatus;
        uint8 fixedOutcome;
    }

    mapping(uint256 => Ledger) internal ledger;
    mapping(uint256 => mapping(uint256 => mapping(uint8 => uint256))) internal credited;
    mapping(uint256 => mapping(uint256 => bool)) internal collected;
    mapping(uint256 => bytes32) internal primaryRequests;
    mapping(uint256 => bytes32) internal escalationRequests;

    constructor() {
        setUp();
        for (uint256 actor; actor < 4; ++actor) {
            markets.setCreatorAllowed(user(actor), true);
        }
        for (uint256 kind; kind < 4; ++kind) {
            openMarket(kind, kind, 0, 0);
            // Ensure every run begins with economically meaningful states, including
            // mixed stakes by one user. Later random actions can also create empty markets.
            wager(kind, 0, 101, 0, 0, 0);
            wager(kind, 1, 202, 1, 0, 0);
            wager(kind, 0, 307, 1, 0, 0);
        }
    }

    function user(uint256 actor) internal view returns (address) {
        address[4] memory users = [alice, bob, carol, creator];
        return users[actor % 4];
    }

    function primaryBody(uint256 id) internal pure returns (bytes memory) {
        return abi.encode("lifecycle primary", id);
    }

    function secondBody(uint256 id) internal pure returns (bytes memory) {
        return abi.encode("lifecycle escalation", id);
    }

    function openMarket(uint256 kindSeed, uint256 creatorSeed, uint256 extraSeed, uint16 transferFeeSeed) public {
        if (count == MAX_MARKETS || markets.paused()) return;
        uint256 id = count + 1;
        VerdictMarkets.Params memory p = params();
        uint256 kind = kindSeed % 4;
        p.questionHash = keccak256(primaryBody(id));
        p.closeAt = uint64(block.timestamp + 2 hours);
        p.answerFrom = p.closeAt + 1 hours;
        p.answerUntil = p.answerFrom + 3 days;
        p.voidAfter = p.answerUntil + 1;
        p.disputeWindow = uint32(1 hours + kind * 12 hours);
        p.bounty = 3 * PRICE + bound(extraSeed, 0, PRICE);
        if (kind == 1) {
            p.answerType = 3;
            p.bounds = new uint256[](7);
            for (uint256 i; i < 7; ++i) {
                p.bounds[i] = (i + 1) * 10;
            }
        } else if (kind >= 2) {
            p.answerType = kind == 2 ? 4 : 5;
            p.keys = new bytes32[](7);
            for (uint256 i; i < 7; ++i) {
                p.keys[i] = bytes32(i + 1);
            }
        }
        // The model credits what arrived, including creation with a transfer fee.
        token.setFee(transferFeeSeed % 1001);
        uint256 beforeBalance = token.balanceOf(address(markets));
        vm.prank(user(creatorSeed));
        uint256 actualId = markets.createMarket(p, primaryBody(id), secondBody(id), "", id);
        assertEq(actualId, id);
        ledger[id].bounty = token.balanceOf(address(markets)) - beforeBalance;
        token.setFee(0);
        count = id;
    }

    function wager(
        uint256 marketSeed,
        uint256 actorSeed,
        uint256 amountSeed,
        uint8 outcomeSeed,
        uint16 feeSeed,
        uint8 amountMode
    ) public {
        uint256 id = marketSeed % count + 1;
        VerdictMarkets.Market memory m = markets.getMarket(id);
        if (markets.paused() || m.status != VerdictMarkets.Status.Open || block.timestamp >= m.params.closeAt) return;
        uint256 room = markets.maxPoolPerMarket(0) - ledger[id].pool;
        if (room == 0) return;
        uint256 amount = amountMode % 3 == 1 ? room : bound(amountSeed, 1, room);
        if (amountMode % 3 == 2) amount = bound(amountSeed, 1, room < 200 ? room : 200);
        uint256 actor = actorSeed % 4;
        uint8 side = outcomeSeed % m.outcomes;
        token.setFee(feeSeed % 1001);
        uint256 beforeBalance = token.balanceOf(address(markets));
        betAs(id, user(actor), side, amount);
        uint256 received = token.balanceOf(address(markets)) - beforeBalance;
        token.setFee(0);
        ledger[id].pool += received;
        credited[id][actor][side] += received;
        ++successfulBets;
    }

    function askPrimary(uint256 seed) public {
        uint256 id = seed % count + 1;
        VerdictMarkets.Market memory m = markets.getMarket(id);
        if (
            m.status != VerdictMarkets.Status.Open || block.timestamp < m.params.answerFrom
                || block.timestamp >= m.params.answerUntil || ledger[id].asks == 2
        ) return;
        if (
            ledger[id].asks != 0
                && (block.timestamp < m.lastPrimaryAsk + 24 hours || !oracle.hasPendingRequest(m.primaryRequests[0]))
        ) return;
        uint256 beforeBalance = token.balanceOf(address(intake));
        primaryRequests[id] = markets.resolve(id, primaryBody(id));
        ledger[id].spend += token.balanceOf(address(intake)) - beforeBalance;
        ++ledger[id].asks;
        ++successfulPrimaryAsks;
    }

    function askEscalation(uint256 seed) public {
        uint256 id = seed % count + 1;
        VerdictMarkets.Market memory m = markets.getMarket(id);
        if (
            m.status != VerdictMarkets.Status.Provisional || m.escalated || m.escalationAsked
                || block.timestamp >= m.params.answerUntil || block.timestamp >= m.disputeEnds || ledger[id].asks == 2
        ) return;
        uint256 oldEnd = m.disputeEnds;
        uint256 beforeBalance = token.balanceOf(address(intake));
        escalationRequests[id] = markets.escalate(id, secondBody(id));
        ledger[id].spend += token.balanceOf(address(intake)) - beforeBalance;
        ++ledger[id].asks;
        uint256 newEnd = markets.getMarket(id).disputeEnds;
        assertGe(newEnd, oldEnd);
        assertGe(newEnd, block.timestamp + 24 hours);
    }

    function encodedAnswer(VerdictMarkets.Market memory m, uint8 side) internal pure returns (bytes memory) {
        if (m.params.answerType == 0) return abi.encode(side == 1);
        if (m.params.answerType == 3) return abi.encode(side == 0 ? 0 : m.params.bounds[side - 1]);
        if (m.params.answerType == 4) {
            address[] memory values = new address[](side == m.outcomes - 1 ? 0 : 2);
            if (values.length != 0) {
                values[0] = address(uint160(uint256(m.params.keys[side])));
                values[1] = address(uint160(uint256(m.params.keys[(side + 1) % m.params.keys.length])));
            }
            return abi.encode(values);
        }
        bytes32[] memory keys = new bytes32[](side == m.outcomes - 1 ? 0 : 2);
        if (keys.length != 0) {
            keys[0] = m.params.keys[side];
            keys[1] = m.params.keys[(side + 1) % m.params.keys.length];
        }
        return abi.encode(keys);
    }

    function deliverAnswer(uint256 seed, uint8 outcomeSeed, bool escalation, bool corrupt) public {
        uint256 id = seed % count + 1;
        VerdictMarkets.Market memory m = markets.getMarket(id);
        bytes32 requestId = escalation ? escalationRequests[id] : primaryRequests[id];
        if (requestId == bytes32(0) || intake.attempted(requestId)) return;
        if (escalation) {
            if (m.status != VerdictMarkets.Status.Provisional || m.escalated || block.timestamp >= m.disputeEnds) {
                return;
            }
        } else if (m.status != VerdictMarkets.Status.Open || block.timestamp >= m.params.voidAfter) {
            return;
        }
        uint8 side = outcomeSeed % m.outcomes;
        OracleAttestation.Attestation memory a = attestation(id, encodedAnswer(m, side), escalation ? 10 : 5);
        // Primary issuance has a fixed cutoff; a paid escalation uses the extended window.
        if (!escalation && a.issuedAt > m.params.answerUntil) a.issuedAt = m.params.answerUntil;
        bytes memory signature = corrupt ? signDigest(SIGNER_KEY + 1, oracle.attestationDigest(a)) : sign(a);
        bytes32 beforeState = keccak256(abi.encode(m));
        (bool ok, uint256 gasUsed) = intake.deliver(requestId, a, signature, 150_000);
        if (corrupt) {
            assertFalse(ok);
            assertEq(oracle.answerOf(a), bytes32(0));
            assertEq(keccak256(abi.encode(markets.getMarket(id))), beforeState);
            ++failedDeliveries;
            return;
        }
        assertTrue(ok);
        assertLt(gasUsed, 150_000);
        markets.propose(id, a);
        assertEq(markets.getMarket(id).outcome, side, "answer mapped to wrong outcome");
        assertEq(markets.getMarket(id).disputeEnds, block.timestamp + m.params.disputeWindow);
        if (escalation) {
            ++successfulReplacements;
            if (a.issuedAt > m.params.answerUntil) ++lateEscalationAnswers;
        } else {
            ++successfulPrimaryAnswers;
        }
    }

    /// @dev A buyer can obtain a genuine signature for the exact same body and domain.
    /// It must not establish or replace this market's outcome, or consume its bounty.
    function probeIndependentAnswer(uint256 seed, uint8 outcomeSeed, bool escalationBodyChoice) public {
        uint256 id = seed % count + 1;
        VerdictMarkets.Market memory m = markets.getMarket(id);
        if (block.timestamp < m.params.answerFrom) return;
        if (m.status == VerdictMarkets.Status.Open) {
            if (block.timestamp >= m.params.voidAfter) return;
        } else if (m.status == VerdictMarkets.Status.Provisional) {
            if (m.escalated || block.timestamp >= m.disputeEnds) return;
        } else {
            return;
        }
        bytes memory requestedBody = escalationBodyChoice ? secondBody(id) : primaryBody(id);
        uint256 intakeBefore = token.balanceOf(address(intake));
        bytes32 rid = oracle.request(requestedBody);
        independentOracleSpend += token.balanceOf(address(intake)) - intakeBefore;
        uint8 side = outcomeSeed % m.outcomes;
        OracleAttestation.Attestation memory a = attestation(id, encodedAnswer(m, side), 10);
        if (m.status == VerdictMarkets.Status.Open && a.issuedAt > m.params.answerUntil) {
            a.issuedAt = m.params.answerUntil;
        }
        deliver(rid, a);
        assertEq(oracle.answerOf(a), keccak256(requestedBody), "probe needs a genuine stored answer");
        assertEq(oracle.intakeRequestOf(a.requestId), rid);
        uint256 heldBefore = token.balanceOf(address(markets));
        vm.expectRevert(VerdictMarkets.UnauthenticatedAnswer.selector);
        markets.propose(id, a);
        assertEq(keccak256(abi.encode(markets.getMarket(id))), keccak256(abi.encode(m)));
        assertEq(token.balanceOf(address(markets)), heldBefore);
        ++rejectedIndependentProposals;
    }

    function advance(uint256 seed, uint8 boundary, uint32 delta) public {
        VerdictMarkets.Market memory m = markets.getMarket(seed % count + 1);
        uint256[6] memory edges = [
            uint256(m.params.closeAt),
            m.params.answerFrom,
            uint256(m.params.answerUntil - 1),
            m.disputeEnds == 0 ? 0 : m.disputeEnds - 1,
            m.disputeEnds,
            uint256(m.params.voidAfter)
        ];
        uint256 target = edges[boundary % 6];
        vm.warp(target > block.timestamp ? target : block.timestamp + bound(delta, 1, 6 hours));
    }

    function togglePause() public {
        if (markets.paused()) markets.unpause();
        else markets.pause();
    }

    function settle(uint256 seed) public {
        uint256 id = seed % count + 1;
        VerdictMarkets.Market memory m = markets.getMarket(id);
        bool finalize;
        if (m.status == VerdictMarkets.Status.Open) {
            if (block.timestamp < m.params.voidAfter) return;
        } else if (m.status == VerdictMarkets.Status.Provisional) {
            if (block.timestamp < m.disputeEnds) return;
            for (uint256 actor; actor < 4; ++actor) {
                if (credited[id][actor][m.outcome] != 0) finalize = true;
            }
        } else {
            return;
        }

        Ledger storage g = ledger[id];
        uint256 creatorBefore = token.balanceOf(m.creator);
        uint256 burnBefore = token.balanceOf(address(burn));
        uint256 treasuryBefore = token.balanceOf(treasury);
        if (finalize) {
            markets.finalize(id);
            ++finalizedMarkets;
        } else {
            markets.voidMarket(id);
            ++voidedMarkets;
        }
        g.returned = g.bounty - g.spend;
        uint256 creatorReceived = token.balanceOf(m.creator) - creatorBefore;
        assertGe(creatorReceived, g.returned, "unspent bounty withheld");
        g.creatorFees = creatorReceived - g.returned;
        g.burnFees = token.balanceOf(address(burn)) - burnBefore;
        g.treasuryFees = token.balanceOf(treasury) - treasuryBefore;
        g.terminalStatus = uint8(finalize ? VerdictMarkets.Status.Finalized : VerdictMarkets.Status.Voided);
        g.fixedOutcome = m.outcome;
        if (!finalize) assertEq(g.creatorFees + g.burnFees + g.treasuryFees, 0);
    }

    function collect(uint256 seed, uint256 actorSeed) public {
        uint256 id = seed % count + 1;
        uint256 actor = actorSeed % 4;
        Ledger storage g = ledger[id];
        if (g.terminalStatus == 0 || collected[id][actor]) return;
        bool refund = g.terminalStatus == uint8(VerdictMarkets.Status.Voided);
        uint256 stake;
        uint256 expected;
        if (refund) {
            for (uint8 side; side < markets.getMarket(id).outcomes; ++side) {
                stake += credited[id][actor][side];
            }
            expected = stake;
        } else {
            stake = credited[id][actor][g.fixedOutcome];
            uint256 winningPool;
            uint256 outstandingStake;
            for (uint256 who; who < 4; ++who) {
                winningPool += credited[id][who][g.fixedOutcome];
                if (!collected[id][who]) outstandingStake += credited[id][who][g.fixedOutcome];
            }
            uint256 netPool = g.pool - g.creatorFees - g.burnFees - g.treasuryFees;
            // Amounts are bounded by the 500 IMD cap, so this independent plain
            // integer calculation cannot overflow even though production uses mulDiv.
            expected = stake == outstandingStake ? netPool - g.payouts : stake * netPool / winningPool;
        }
        if (stake == 0) return;
        uint256 beforeBalance = token.balanceOf(user(actor));
        vm.prank(user(actor));
        uint256 reported = markets.claim(id);
        uint256 transferred = token.balanceOf(user(actor)) - beforeBalance;
        assertEq(transferred, expected, "wrong recipient payout");
        assertEq(reported, transferred);
        collected[id][actor] = true;
        if (refund) g.refunds += transferred;
        else g.payouts += transferred;
        ++successfulClaims;
    }

    function donate(uint256 amountSeed, bool toBurn) public {
        uint256 amount = bound(amountSeed, 0, 1 ether);
        token.transfer(toBurn ? address(burn) : address(markets), amount);
        if (toBurn) burnDonations += amount;
        else marketDonations += amount;
    }

    function probeBurn(bytes32 selectorSeed, bytes32 argument) public {
        uint256 held = token.balanceOf(address(burn));
        (bool ok,) = address(burn).call(abi.encodePacked(selectorSeed, argument));
        assertFalse(ok, "burn vault exposed a callable path");
        assertEq(token.balanceOf(address(burn)), held);
    }

    function probeTerminal(uint256 seed, uint8 action) public {
        uint256 id = seed % count + 1;
        if (ledger[id].terminalStatus == 0) return;
        bytes32 beforeState = keccak256(abi.encode(markets.getMarket(id)));
        bytes memory payload;
        if (action % 4 == 0) payload = abi.encodeCall(markets.resolve, (id, primaryBody(id)));
        else if (action % 4 == 1) payload = abi.encodeCall(markets.escalate, (id, secondBody(id)));
        else if (action % 4 == 2) payload = abi.encodeCall(markets.finalize, (id));
        else payload = abi.encodeCall(markets.voidMarket, (id));
        (bool ok,) = address(markets).call(payload);
        assertFalse(ok, "terminal market reopened or settled twice");
        assertEq(keccak256(abi.encode(markets.getMarket(id))), beforeState);
    }

    function checkAccounting() public view {
        uint256 held = marketDonations;
        uint256 allSpend;
        uint256 allBurn = burnDonations;
        uint256 allTreasury;
        assertEq(markets.marketCount(), count);
        for (uint256 id = 1; id <= count; ++id) {
            VerdictMarkets.Market memory m = markets.getMarket(id);
            Ledger storage g = ledger[id];
            uint256 fees = g.creatorFees + g.burnFees + g.treasuryFees;
            uint256 exits = g.spend + g.returned + fees + g.payouts + g.refunds;
            assertLe(exits, g.pool + g.bounty, "one market spent another's deposits");
            held += g.pool + g.bounty - exits;
            allSpend += g.spend;
            allBurn += g.burnFees;
            allTreasury += g.treasuryFees;
            assertEq(m.params.bounty, g.bounty);
            assertEq(m.pool, g.pool);
            assertEq(m.oracleSpend, g.spend);
            assertEq(m.returnedBounty, g.returned);
            assertEq(m.fees, fees);
            assertEq(m.paidOut, g.payouts);
            assertEq(m.refunded, g.refunds);
            assertEq(m.bountyRemaining, g.bounty - g.spend - g.returned);
            assertEq(m.asks, g.asks);
            assertLe(m.asks, 2);
            assertLe(m.pool, markets.maxPoolPerMarket(0));
            uint256 stakeSum;
            for (uint8 side; side < m.outcomes; ++side) {
                uint256 sideSum;
                for (uint256 actor; actor < 4; ++actor) {
                    assertEq(markets.stakes(id, user(actor), side), credited[id][actor][side]);
                    sideSum += credited[id][actor][side];
                }
                assertEq(markets.outcomePool(id, side), sideSum);
                stakeSum += sideSum;
            }
            assertEq(stakeSum, g.pool);
            uint256 outstandingWinningStake;
            for (uint256 actor; actor < 4; ++actor) {
                uint256 actorStake;
                for (uint8 side; side < m.outcomes; ++side) {
                    actorStake += credited[id][actor][side];
                }
                assertEq(markets.totalStake(id, user(actor)), actorStake);
                assertEq(markets.claimed(id, user(actor)), collected[id][actor]);
                if (!collected[id][actor]) outstandingWinningStake += credited[id][actor][m.outcome];
            }
            if (g.terminalStatus != 0) {
                assertEq(uint8(m.status), g.terminalStatus);
                assertEq(m.outcome, g.fixedOutcome);
            }
            if (m.status == VerdictMarkets.Status.Finalized) {
                assertEq(m.remainingPayout, g.pool - fees - g.payouts);
                assertEq(m.remainingWinningStake, outstandingWinningStake);
                if (outstandingWinningStake == 0) assertEq(m.remainingPayout, 0, "final claim left dust");
            }
        }
        assertEq(token.balanceOf(address(markets)), held, "aggregate custody mismatch");
        assertEq(token.balanceOf(address(oracle)), 0);
        assertEq(token.balanceOf(address(intake)), allSpend + independentOracleSpend);
        assertEq(token.balanceOf(address(burn)), allBurn, "burn balance decreased or fee misdirected");
        assertEq(token.balanceOf(treasury), allTreasury);
        assertEq(token.allowance(address(markets), address(oracle)), 0);
        assertEq(token.allowance(address(oracle), address(intake)), 0);
    }

    function drainAndCheck() external {
        vm.warp(block.timestamp + 14 days);
        for (uint256 seed; seed < count; ++seed) {
            settle(seed);
            for (uint256 actor; actor < 4; ++actor) {
                collect(seed, actor);
            }
            Ledger storage g = ledger[seed + 1];
            assertEq(
                g.pool + g.bounty,
                g.payouts + g.refunds + g.creatorFees + g.burnFees + g.treasuryFees + g.spend + g.returned,
                "terminal per-market conservation"
            );
        }
        checkAccounting();
        assertEq(token.balanceOf(address(markets)), marketDonations, "unclaimed market dust");
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract VerdictLifecycleInvariantTest is Test {
    VerdictLifecycleHandler internal handler;

    function setUp() public {
        handler = new VerdictLifecycleHandler();
        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = handler.openMarket.selector;
        selectors[1] = handler.wager.selector;
        selectors[2] = handler.askPrimary.selector;
        selectors[3] = handler.askEscalation.selector;
        selectors[4] = handler.deliverAnswer.selector;
        selectors[5] = handler.advance.selector;
        selectors[6] = handler.togglePause.selector;
        selectors[7] = handler.settle.selector;
        selectors[8] = handler.collect.selector;
        selectors[9] = handler.donate.selector;
        selectors[10] = handler.probeBurn.selector;
        selectors[11] = handler.probeTerminal.selector;
        selectors[12] = handler.probeIndependentAnswer.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_tokensStakesAndFinalityMatchIndependentLedger() public view {
        handler.checkAccounting();
    }

    function afterInvariant() public {
        handler.drainAndCheck();
    }

    function test_handlerReachesPrimaryEscalationFailureFinalizeAndRefundPaths() public {
        handler.advance(0, 1, 0);
        handler.askPrimary(0);
        handler.deliverAnswer(0, 0, false, false);
        handler.askEscalation(0);
        handler.deliverAnswer(0, 1, true, false);
        handler.askPrimary(1);
        handler.deliverAnswer(1, 1, false, true);
        handler.askPrimary(2);
        handler.deliverAnswer(2, 0, false, false);
        handler.askPrimary(3);
        handler.deliverAnswer(3, 7, false, false); // Empty winning bucket, so refund.
        handler.togglePause();
        handler.donate(31, false);
        handler.donate(17, true);
        handler.probeBurn(bytes32("withdraw"), bytes32(uint256(1)));
        handler.drainAndCheck(); // Settlement and claims must work while paused.
        handler.probeTerminal(0, 0);
        handler.probeTerminal(0, 1);
        handler.probeTerminal(0, 2);
        handler.probeTerminal(0, 3);
        assertEq(handler.successfulPrimaryAnswers(), 3);
        assertEq(handler.successfulReplacements(), 1);
        assertEq(handler.failedDeliveries(), 1);
        assertEq(handler.finalizedMarkets(), 2);
        assertEq(handler.voidedMarkets(), 2);
        assertGt(handler.successfulClaims(), 0);
        handler.togglePause();
        handler.openMarket(1, 2, 11, 1000);
        assertEq(handler.count(), 5, "campaign cannot create after its initial markets expire");
        handler.wager(4, 3, 1, 7, 1000, 1);
        handler.checkAccounting();
        handler.drainAndCheck();
    }

    function test_handlerIndependentAnswersCannotBlockRetryOrShopOutcomes() public {
        handler.advance(0, 1, 0);
        handler.askPrimary(0);
        handler.probeIndependentAnswer(0, 1, false);
        handler.probeIndependentAnswer(0, 0, true); // Escalation cannot be the first proposal.
        for (uint256 i; i < 4; ++i) {
            handler.advance(0, 0, 6 hours);
        }
        handler.askPrimary(0); // Genuine pending first request permits retry despite global delivery.
        assertEq(handler.successfulPrimaryAsks(), 2, "independent answer blocked the market's retry");
        handler.deliverAnswer(0, 1, false, false);
        handler.probeIndependentAnswer(0, 0, true); // Cannot replace after two primary asks.
        handler.checkAccounting();
        assertEq(handler.rejectedIndependentProposals(), 3);
        assertEq(handler.independentOracleSpend(), 1.5 ether);
        handler.drainAndCheck();
        assertEq(handler.finalizedMarkets(), 1);
    }

    function test_handlerUsesActualLateEscalationIssuanceAndStillDrains() public {
        handler.advance(0, 2, 0); // answerUntil - 1
        handler.askPrimary(0);
        handler.deliverAnswer(0, 0, false, false);
        handler.probeIndependentAnswer(0, 1, true); // No paid escalation yet.
        handler.askEscalation(0);
        handler.probeIndependentAnswer(0, 1, true); // Paid ask exists, but this answer belongs to a buyer.
        handler.advance(0, 5, 0); // voidAfter, beyond the primary issuance cutoff
        handler.deliverAnswer(0, 1, true, false);
        assertEq(handler.lateEscalationAnswers(), 1);
        assertEq(handler.successfulReplacements(), 1);
        assertEq(handler.rejectedIndependentProposals(), 2);
        handler.checkAccounting();
        handler.drainAndCheck();
        assertEq(handler.finalizedMarkets(), 1);
    }
}
