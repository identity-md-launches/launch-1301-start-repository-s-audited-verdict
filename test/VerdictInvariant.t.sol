// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TestBase} from "./TestBase.sol";
import {VerdictMarkets} from "../src/VerdictMarkets.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";

/// @dev Exercises real payment, signature verification, callback and settlement across three markets.
contract VerdictHandler is TestBase {
    uint256 internal constant COUNT = 3;
    mapping(uint256 => bytes32) internal primaryRequests;
    mapping(uint256 => bytes32) internal escalationRequests;
    mapping(uint256 => OracleAttestation.Attestation) internal deliveredPrimaries;
    mapping(uint256 => uint256) public actualDeposits;
    mapping(uint256 => uint256) public actualExits;

    constructor() {
        setUp();
        for (uint256 i; i < COUNT; i++) {
            VerdictMarkets.Params memory p = params();
            p.closeAt += uint64(i * 1 hours);
            p.answerFrom = p.closeAt;
            p.disputeWindow = uint32(1 hours + i * 12 hours);
            uint256 id = createWith(p);
            actualDeposits[id] = p.bounty;
        }
    }

    function enter(uint256 seed, uint256 actor, uint256 amount, bool side) external {
        uint256 id = seed % COUNT + 1;
        VerdictMarkets.Market memory m = markets.getMarket(id);
        if (markets.paused() || m.status != VerdictMarkets.Status.Open || block.timestamp >= m.params.closeAt) return;
        uint256 room = markets.maxPoolPerMarket(0) - m.pool;
        if (room == 0) return;
        amount = bound(amount, 1, room < 50 ether ? room : 50 ether);
        betAs(id, user(actor), side ? 1 : 0, amount);
        actualDeposits[id] += amount;
    }

    function advance(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 6 hours));
    }

    function togglePause() external {
        if (markets.paused()) markets.unpause();
        else markets.pause();
    }

    function ask(uint256 seed) external {
        uint256 id = seed % COUNT + 1;
        VerdictMarkets.Market memory m = markets.getMarket(id);
        if (
            m.status != VerdictMarkets.Status.Open || block.timestamp < m.params.answerFrom
                || block.timestamp >= m.params.answerUntil || m.asks == 2
        ) return;
        if (
            m.asks == 1
                && (block.timestamp < m.lastPrimaryAsk + 24 hours || !oracle.hasPendingRequest(m.primaryRequests[0]))
        ) return;
        uint256 before = token.balanceOf(address(intake));
        primaryRequests[id] = markets.resolve(id, body);
        actualExits[id] += token.balanceOf(address(intake)) - before;
    }

    function deliverPrimary(uint256 seed, bool side) external {
        uint256 id = seed % COUNT + 1;
        bytes32 rid = primaryRequests[id];
        VerdictMarkets.Market memory m = markets.getMarket(id);
        if (rid == bytes32(0) || intake.attempted(rid) || block.timestamp > m.params.answerUntil) return;
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(side), 5);
        deliver(rid, a);
        deliveredPrimaries[id] = a;
    }

    function proposePrimary(uint256 seed) external {
        uint256 id = seed % COUNT + 1;
        VerdictMarkets.Market memory m = markets.getMarket(id);
        if (
            m.status != VerdictMarkets.Status.Open || block.timestamp < m.params.answerFrom
                || block.timestamp >= m.params.voidAfter || deliveredPrimaries[id].requestId == bytes32(0)
        ) return;
        markets.propose(id, deliveredPrimaries[id]);
    }

    function askEscalation(uint256 seed) external {
        uint256 id = seed % COUNT + 1;
        VerdictMarkets.Market memory m = markets.getMarket(id);
        if (
            m.status != VerdictMarkets.Status.Provisional || m.escalated || m.escalationAsked || m.asks == 2
                || block.timestamp >= m.params.answerUntil || block.timestamp >= m.disputeEnds
        ) return;
        uint256 before = token.balanceOf(address(intake));
        escalationRequests[id] = markets.escalate(id, escalationBody);
        actualExits[id] += token.balanceOf(address(intake)) - before;
    }

    function replaceOutcome(uint256 seed, bool side) external {
        uint256 id = seed % COUNT + 1;
        bytes32 rid = escalationRequests[id];
        VerdictMarkets.Market memory m = markets.getMarket(id);
        if (rid == bytes32(0) || intake.attempted(rid)) return;
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(side), 10);
        deliver(rid, a);
        if (m.status == VerdictMarkets.Status.Provisional && !m.escalated && block.timestamp < m.disputeEnds) {
            markets.propose(id, a);
        }
    }

    function settle(uint256 seed) public {
        uint256 id = seed % COUNT + 1;
        VerdictMarkets.Market memory m = markets.getMarket(id);
        uint256 before = recipientsBalance();
        if (m.status == VerdictMarkets.Status.Open && block.timestamp >= m.params.voidAfter) {
            markets.voidMarket(id);
        } else if (m.status == VerdictMarkets.Status.Provisional && block.timestamp >= m.disputeEnds) {
            if (markets.outcomePool(id, m.outcome) == 0) markets.voidMarket(id);
            else markets.finalize(id);
        }
        actualExits[id] += recipientsBalance() - before;
    }

    function collect(uint256 seed, uint256 actor) public {
        uint256 id = seed % COUNT + 1;
        address bettor = user(actor);
        VerdictMarkets.Market memory m = markets.getMarket(id);
        if (markets.claimed(id, bettor)) return;
        if (m.status == VerdictMarkets.Status.Finalized) {
            if (markets.stakes(id, bettor, m.outcome) == 0) return;
        } else if (m.status == VerdictMarkets.Status.Voided) {
            if (markets.totalStake(id, bettor) == 0) return;
        } else {
            return;
        }
        uint256 before = token.balanceOf(bettor);
        vm.prank(bettor);
        uint256 payout = markets.claim(id);
        uint256 transferred = token.balanceOf(bettor) - before;
        assertEq(transferred, payout);
        actualExits[id] += transferred;
    }

    function assertAccounting() external view {
        uint256 held;
        uint256 totalSpent;
        for (uint256 id = 1; id <= COUNT; id++) {
            VerdictMarkets.Market memory m = markets.getMarket(id);
            uint256 accountedExits = m.paidOut + m.refunded + m.fees + m.returnedBounty + m.oracleSpend;
            assertEq(actualDeposits[id], m.pool + m.params.bounty);
            assertEq(actualExits[id], accountedExits);
            assertLe(accountedExits, actualDeposits[id]);
            assertLe(m.asks, 2);
            assertLe(m.pool, 500 ether);
            assertEq(m.bountyRemaining + m.oracleSpend + m.returnedBounty, m.params.bounty);
            held += actualDeposits[id] - actualExits[id];
            totalSpent += m.oracleSpend;
        }
        assertEq(token.balanceOf(address(markets)), held);
        assertEq(token.balanceOf(address(oracle)), 0);
        assertEq(token.balanceOf(address(intake)), totalSpent);
    }

    function drainAndAssert() external {
        vm.warp(block.timestamp + 14 days);
        for (uint256 seed; seed < COUNT; seed++) {
            settle(seed);
            for (uint256 actor; actor < 4; actor++) {
                collect(seed, actor);
            }
            assertConserved(seed + 1, true);
            assertEq(actualDeposits[seed + 1], actualExits[seed + 1]);
        }
        assertEq(token.balanceOf(address(markets)), 0, "terminal dust");
    }

    function user(uint256 actor) internal view returns (address) {
        address[4] memory users = [alice, bob, carol, creator];
        return users[actor % 4];
    }

    function recipientsBalance() internal view returns (uint256) {
        return token.balanceOf(creator) + token.balanceOf(treasury) + token.balanceOf(address(burn));
    }
}

contract VerdictInvariantTest is Test {
    VerdictHandler internal handler;

    function setUp() public {
        handler = new VerdictHandler();
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.enter.selector;
        selectors[1] = handler.advance.selector;
        selectors[2] = handler.togglePause.selector;
        selectors[3] = handler.ask.selector;
        selectors[4] = handler.deliverPrimary.selector;
        selectors[5] = handler.proposePrimary.selector;
        selectors[6] = handler.askEscalation.selector;
        selectors[7] = handler.replaceOutcome.selector;
        selectors[8] = handler.settle.selector;
        selectors[9] = handler.collect.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_actualTokensMatchEveryMarketsAccounting() public view {
        handler.assertAccounting();
    }

    function afterInvariant() public {
        handler.drainAndAssert();
    }
}
