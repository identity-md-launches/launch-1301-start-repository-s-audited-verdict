// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TestBase} from "./TestBase.sol";
import {VerdictOracle} from "../src/VerdictOracle.sol";
import {VerdictMarkets} from "../src/VerdictMarkets.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {MockIMD} from "./mocks/MockIMD.sol";

/// @dev Full lifecycle campaign over markets in both collateral slots with settler rewards and changing
/// oracle prices. Every market keeps two ledgers that are checked against measured token movements:
/// collateral (pool == payouts + refunds + fees) and bounty token (bounty == spend + rewards + returned).
contract CollateralLifecycleHandler is TestBase {
    uint256 internal constant COUNT = 4;
    mapping(uint256 => bytes32) internal primaryRequests;
    mapping(uint256 => bytes32) internal escalationRequests;
    mapping(uint256 => OracleAttestation.Attestation) internal deliveredPrimaries;
    mapping(uint256 => uint256) public collateralDeposits;
    mapping(uint256 => uint256) public collateralExits;
    mapping(uint256 => uint256) public bountyExits;
    mapping(uint256 => uint256) public actualRewards;

    constructor() {
        setUp();
        for (uint256 i; i < COUNT; i++) {
            VerdictMarkets.Params memory p = params();
            p.collateralId = uint8(i % 2);
            p.settlerReward = (i / 2 + 1) * 0.05 ether;
            p.bounty += 5 * p.settlerReward + 0.3 ether;
            p.closeAt += uint64(i * 1 hours);
            p.answerFrom = p.closeAt;
            p.disputeWindow = uint32(1 hours + i * 6 hours);
            createWith(p);
        }
    }

    function slotToken(uint256 id) internal view returns (MockIMD) {
        return markets.getMarket(id).params.collateralId == 0 ? token : weth;
    }

    function enter(uint256 seed, uint256 actor, uint256 amount, bool side) external {
        uint256 id = seed % COUNT + 1;
        VerdictMarkets.Market memory m = markets.getMarket(id);
        if (markets.paused() || m.status != VerdictMarkets.Status.Open || block.timestamp >= m.params.closeAt) return;
        uint256 room = markets.maxPoolPerMarket(m.params.collateralId) - m.pool;
        if (room == 0) return;
        amount = bound(amount, 1, room < 50 ether ? room : 50 ether);
        uint256 imdBefore = token.balanceOf(address(markets));
        uint256 wethBefore = weth.balanceOf(address(markets));
        betAs(id, user(actor), side ? 1 : 0, amount);
        if (m.params.collateralId == 0) {
            assertEq(weth.balanceOf(address(markets)), wethBefore, "IMD bet moved WETH");
            collateralDeposits[id] += token.balanceOf(address(markets)) - imdBefore;
        } else {
            assertEq(token.balanceOf(address(markets)), imdBefore, "WETH bet moved IMD");
            collateralDeposits[id] += weth.balanceOf(address(markets)) - wethBefore;
        }
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
        if (oracle.price() > m.bountyRemaining) return;
        uint256 rewardBefore = token.balanceOf(address(this));
        uint256 before = token.balanceOf(address(intake));
        uint256 wethBefore = weth.balanceOf(address(markets));
        primaryRequests[id] = markets.resolve(id, body);
        assertEq(weth.balanceOf(address(markets)), wethBefore, "ask spent WETH");
        bountyExits[id] += token.balanceOf(address(intake)) - before;
        recordReward(id, rewardBefore);
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
        OracleAttestation.Attestation memory a = deliveredPrimaries[id];
        if (
            m.status != VerdictMarkets.Status.Open || block.timestamp < m.params.answerFrom
                || block.timestamp >= m.params.voidAfter || a.requestId == bytes32(0)
                || oracle.intakeRequestOf(a.requestId) != m.primaryRequests[m.asks - 1]
        ) return;
        uint256 rewardBefore = token.balanceOf(address(this));
        markets.propose(id, a);
        recordReward(id, rewardBefore);
    }

    function askEscalation(uint256 seed) external {
        uint256 id = seed % COUNT + 1;
        VerdictMarkets.Market memory m = markets.getMarket(id);
        if (
            m.status != VerdictMarkets.Status.Provisional || m.escalated || m.escalationAsked || m.asks == 2
                || block.timestamp >= m.params.answerUntil || block.timestamp >= m.disputeEnds
        ) return;
        if (oracle.price() > m.bountyRemaining) return;
        uint256 rewardBefore = token.balanceOf(address(this));
        uint256 before = token.balanceOf(address(intake));
        escalationRequests[id] = markets.escalate(id, escalationBody);
        bountyExits[id] += token.balanceOf(address(intake)) - before;
        assertEq(token.balanceOf(address(this)), rewardBefore, "escalate paid a reward");
    }

    function replaceOutcome(uint256 seed, bool side) external {
        uint256 id = seed % COUNT + 1;
        bytes32 rid = escalationRequests[id];
        VerdictMarkets.Market memory m = markets.getMarket(id);
        if (rid == bytes32(0) || intake.attempted(rid)) return;
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(side), 10);
        deliver(rid, a);
        if (m.status == VerdictMarkets.Status.Provisional && !m.escalated && block.timestamp < m.disputeEnds) {
            uint256 rewardBefore = token.balanceOf(address(this));
            markets.propose(id, a);
            recordReward(id, rewardBefore);
        }
    }

    function settle(uint256 seed) public {
        uint256 id = seed % COUNT + 1;
        VerdictMarkets.Market memory m = markets.getMarket(id);
        MockIMD c = slotToken(id);
        uint256 rewardBefore = token.balanceOf(address(this));
        uint256 creatorBountyBefore = token.balanceOf(creator);
        uint256 feesBefore = recipientsBalance(c);
        uint256 burnBefore = c.balanceOf(address(burn));
        bool acted;
        if (m.status == VerdictMarkets.Status.Open && block.timestamp >= m.params.voidAfter) {
            markets.voidMarket(id);
            acted = true;
        } else if (m.status == VerdictMarkets.Status.Provisional && block.timestamp >= m.disputeEnds) {
            if (markets.outcomePool(id, m.outcome) == 0) markets.voidMarket(id);
            else markets.finalize(id);
            acted = true;
        }
        if (!acted) return;
        VerdictMarkets.Market memory after_ = markets.getMarket(id);
        uint256 creatorBounty = after_.returnedBounty;
        if (address(c) == address(token)) {
            // Same token: the creator receives fee and bounty together; split by the recorded fee.
            uint256 creatorGot = token.balanceOf(creator) - creatorBountyBefore;
            uint256 creatorFee = creatorGot - creatorBounty;
            bool finalized = after_.status == VerdictMarkets.Status.Finalized;
            assertEq(creatorFee, finalized ? (after_.pool * markets.creatorFeeBps(0)) / 10_000 : 0, "creator fee");
            collateralExits[id] += recipientsBalance(c) - feesBefore - creatorBounty;
        } else {
            assertEq(token.balanceOf(creator) - creatorBountyBefore, creatorBounty, "bounty returned in IMD");
            collateralExits[id] += recipientsBalance(c) - feesBefore;
            assertEq(c.balanceOf(address(burn)), burnBefore, "zero burn share paid WETH to the sink");
        }
        bountyExits[id] += creatorBounty;
        recordReward(id, rewardBefore);
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
        MockIMD c = slotToken(id);
        MockIMD o = address(c) == address(token) ? weth : token;
        uint256 before = c.balanceOf(bettor);
        uint256 otherBefore = o.balanceOf(bettor);
        vm.prank(bettor);
        uint256 payout = markets.claim(id);
        assertEq(c.balanceOf(bettor) - before, payout, "claim paid in the wrong token");
        assertEq(o.balanceOf(bettor), otherBefore);
        collateralExits[id] += payout;
    }

    function changePrice(uint256 priceSeed) external {
        uint256 price = bound(priceSeed, 1, 2 ether);
        oracle.proposeConfig(VerdictOracle.Config(address(intake), address(token), vm.addr(SIGNER_KEY), ACTION, price));
        oracle.acceptConfig();
    }

    function assertAccounting() external view {
        uint256 imdHeld;
        uint256 wethHeld;
        uint256 totalSpent;
        for (uint256 id = 1; id <= COUNT; id++) {
            VerdictMarkets.Market memory m = markets.getMarket(id);
            uint256 collateralAccounted = m.paidOut + m.refunded + m.fees;
            uint256 bountyAccounted = m.oracleSpend + m.rewardsPaid + m.returnedBounty;
            assertEq(collateralDeposits[id], m.pool, "pool vs measured deposits");
            assertEq(collateralExits[id], collateralAccounted, "collateral exits vs measured");
            assertEq(bountyExits[id], bountyAccounted, "bounty exits vs measured");
            assertEq(actualRewards[id], m.rewardsPaid);
            assertLe(collateralAccounted, m.pool, "collateral overdrawn");
            assertLe(bountyAccounted, m.params.bounty, "bounty overdrawn");
            assertEq(m.bountyRemaining + bountyAccounted, m.params.bounty, "bounty ledger");
            assertLe(m.pool, markets.maxPoolPerMarket(m.params.collateralId));
            assertEq(address(m.bountyToken), address(token));
            assertEq(address(m.collateral), address(slotToken(id)));
            uint256 poolHeld = m.pool - collateralAccounted;
            if (m.params.collateralId == 0) imdHeld += poolHeld;
            else wethHeld += poolHeld;
            imdHeld += m.bountyRemaining;
            totalSpent += m.oracleSpend;
        }
        assertEq(token.balanceOf(address(markets)), imdHeld, "IMD custody = IMD pools + bounties");
        assertEq(weth.balanceOf(address(markets)), wethHeld, "WETH custody = WETH pools");
        assertEq(token.balanceOf(address(oracle)), 0);
        assertEq(weth.balanceOf(address(oracle)), 0);
        assertEq(weth.balanceOf(address(intake)), 0);
        assertEq(token.balanceOf(address(intake)), totalSpent);
    }

    function drainAndAssert() external {
        vm.warp(block.timestamp + 14 days);
        for (uint256 seed; seed < COUNT; seed++) {
            settle(seed);
            for (uint256 actor; actor < 4; actor++) {
                collect(seed, actor);
            }
            VerdictMarkets.Market memory m = markets.getMarket(seed + 1);
            assertEq(m.pool, m.paidOut + m.refunded + m.fees, "collateral ledger drained");
            assertEq(m.params.bounty, m.oracleSpend + m.rewardsPaid + m.returnedBounty, "bounty ledger drained");
            assertEq(collateralDeposits[seed + 1], collateralExits[seed + 1]);
        }
        assertEq(token.balanceOf(address(markets)), 0, "IMD dust");
        assertEq(weth.balanceOf(address(markets)), 0, "WETH dust");
    }

    function recordReward(uint256 id, uint256 beforeBalance) internal {
        uint256 paid = token.balanceOf(address(this)) - beforeBalance;
        actualRewards[id] += paid;
        bountyExits[id] += paid;
        assertLe(paid, markets.getMarket(id).settlerReward);
    }

    function user(uint256 actor) internal view returns (address) {
        address[4] memory users = [alice, bob, carol, creator];
        return users[actor % 4];
    }

    function recipientsBalance(MockIMD c) internal view returns (uint256) {
        return c.balanceOf(creator) + c.balanceOf(treasury) + c.balanceOf(address(burn));
    }
}

contract VerdictCollateralInvariantTest is Test {
    CollateralLifecycleHandler internal handler;

    function setUp() public {
        handler = new CollateralLifecycleHandler();
        bytes4[] memory selectors = new bytes4[](11);
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
        selectors[10] = handler.changePrice.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_bothSlotsKeepSeparateLedgersMatchingTokenBalances() public view {
        handler.assertAccounting();
    }

    function afterInvariant() public {
        handler.drainAndAssert();
    }

    function test_handlerSettlesBothSlotsWithRewards() public {
        for (uint256 i; i < 4; i++) {
            handler.enter(i, i, 0.3 ether, true);
            handler.enter(i, i + 1, 0.2 ether, false);
        }
        handler.advance(6 hours);
        for (uint256 i; i < 4; i++) {
            handler.ask(i);
            handler.deliverPrimary(i, i % 2 == 0);
            handler.proposePrimary(i);
        }
        handler.changePrice(0.7 ether);
        handler.askEscalation(1);
        handler.replaceOutcome(1, false);
        handler.assertAccounting();
        handler.drainAndAssert();
        for (uint256 i = 1; i <= 4; i++) {
            assertGt(handler.actualRewards(i), 0, "no reward paid in this slot");
        }
    }
}
