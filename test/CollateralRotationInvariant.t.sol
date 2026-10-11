// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TestBase} from "./TestBase.sol";
import {VerdictOracle} from "../src/VerdictOracle.sol";
import {VerdictMarkets} from "../src/VerdictMarkets.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {MockIMD} from "./mocks/MockIMD.sol";

/// @dev Second lifecycle campaign over the two collateral slots. Unlike the fixed four-market campaign, markets
/// are opened during the sequence while the oracle's asset rotates between IMD and WETH and its price moves, so
/// a market's bounty token and collateral token vary independently: IMD/IMD, WETH/IMD, IMD/WETH and WETH/WETH
/// markets coexist in one contract. Every token movement is measured against the ledger it belongs to, and the
/// contract's balance in each token must equal the sum of what every market still owes in that token.
contract CollateralRotationHandler is TestBase {
    uint256 internal constant MAX_MARKETS = 6;
    mapping(uint256 => bytes32) internal primaryRequests;
    mapping(uint256 => bytes32) internal escalationRequests;
    mapping(uint256 => OracleAttestation.Attestation) internal deliveredPrimaries;
    mapping(uint256 => uint256) public collateralDeposits;
    mapping(uint256 => uint256) public collateralExits;
    mapping(uint256 => uint256) public bountyExits;
    mapping(uint256 => uint256) public actualRewards;
    uint256 public rotations;
    uint256 public imdCollateralWethBounty; // the pairing the launch never produces unless the asset rotates
    uint256 public wethCollateralWethBounty; // collateral and bounty in the same token, and it is not IMD

    /// @dev A timing seed whose window fields land on a 3-day answer window and a one-day dispute window.
    uint256 internal constant LONG_WINDOWS = (uint256(3 days) << 8) | (uint256(1 days) << 16);

    constructor() {
        setUp();
        markets.disableAllowlist();
        open(0, LONG_WINDOWS, 0.05 ether, 0);
        open(1, LONG_WINDOWS, 0.05 ether, 0);
    }

    function wethToken() external view returns (MockIMD) {
        return weth;
    }

    function tokenOf(address t) internal view returns (MockIMD) {
        return t == address(token) ? token : weth;
    }

    function collateralOf(uint256 id) internal view returns (MockIMD) {
        return tokenOf(address(markets.getMarket(id).collateral));
    }

    function bountyTokenOf(uint256 id) internal view returns (MockIMD) {
        return tokenOf(address(markets.getMarket(id).bountyToken));
    }

    function pick(uint256 seed) internal view returns (uint256) {
        return seed % markets.marketCount() + 1;
    }

    // ------------------------------------------------------------------ actions

    function open(uint256 slotSeed, uint256 timing, uint256 reward, uint256 extra) public {
        if (markets.marketCount() >= MAX_MARKETS || markets.paused()) return;
        VerdictMarkets.Params memory p = params();
        p.collateralId = uint8(slotSeed % 2);
        p.settlerReward = bound(reward, 0, 0.25 ether);
        uint256 price = oracle.price();
        p.bounty = 2 * price + 5 * p.settlerReward + bound(extra, 0, 1 ether);
        p.closeAt = uint64(block.timestamp + 1 hours + bound(timing, 0, 12 hours));
        p.answerFrom = p.closeAt;
        p.answerUntil = p.answerFrom + uint64(1 hours + bound(timing >> 8, 0, 3 days));
        p.voidAfter = p.answerUntil + 1 hours;
        p.disputeWindow = uint32(1 hours + bound(timing >> 16, 0, 2 days));
        address asset = oracle.asset();
        MockIMD bountyTok = tokenOf(asset);
        uint256 creatorBefore = bountyTok.balanceOf(creator);
        uint256 otherBefore = (asset == address(token) ? weth : token).balanceOf(creator);
        uint256 id = createWith(p);
        VerdictMarkets.Market memory m = markets.getMarket(id);
        assertEq(address(m.bountyToken), asset, "bounty token must be the oracle's asset at creation");
        assertEq(creatorBefore - bountyTok.balanceOf(creator), m.params.bounty, "bounty pulled in the asset");
        assertEq((asset == address(token) ? weth : token).balanceOf(creator), otherBefore, "other token moved");
        if (asset == address(weth)) {
            if (p.collateralId == 0) imdCollateralWethBounty++;
            else wethCollateralWethBounty++;
        }
    }

    function rotate(bool toWeth, uint256 priceSeed) external {
        address asset = toWeth ? address(weth) : address(token);
        uint256 price = bound(priceSeed, 0.1 ether, 1.5 ether);
        oracle.proposeConfig(VerdictOracle.Config(address(intake), asset, vm.addr(SIGNER_KEY), ACTION, price));
        oracle.acceptConfig();
        rotations++;
    }

    function enter(uint256 seed, uint256 actor, uint256 amount, bool side) external {
        uint256 id = pick(seed);
        VerdictMarkets.Market memory m = markets.getMarket(id);
        if (markets.paused() || m.status != VerdictMarkets.Status.Open || block.timestamp >= m.params.closeAt) return;
        uint256 room = markets.maxPoolPerMarket(m.params.collateralId) - m.pool;
        if (room == 0) return;
        amount = bound(amount, 1, room < 50 ether ? room : 50 ether);
        MockIMD c = collateralOf(id);
        MockIMD o = address(c) == address(token) ? weth : token;
        uint256 before = c.balanceOf(address(markets));
        uint256 otherBefore = o.balanceOf(address(markets));
        betAs(id, user(actor), side ? 1 : 0, amount);
        assertEq(o.balanceOf(address(markets)), otherBefore, "bet moved the other token");
        collateralDeposits[id] += c.balanceOf(address(markets)) - before;
    }

    function advance(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 8 hours));
    }

    function togglePause() external {
        if (markets.paused()) markets.unpause();
        else markets.pause();
    }

    function ask(uint256 seed) external {
        uint256 id = pick(seed);
        VerdictMarkets.Market memory m = markets.getMarket(id);
        if (
            m.status != VerdictMarkets.Status.Open || block.timestamp < m.params.answerFrom
                || block.timestamp >= m.params.answerUntil || m.asks == 2
        ) return;
        if (
            m.asks == 1
                && (block.timestamp < m.lastPrimaryAsk + 24 hours || !oracle.hasPendingRequest(m.primaryRequests[0]))
        ) return;
        if (oracle.asset() != address(m.bountyToken)) {
            vm.expectRevert(VerdictMarkets.OracleAssetMismatch.selector);
            markets.resolve(id, body);
            return;
        }
        if (oracle.price() > m.bountyRemaining) return;
        MockIMD b = bountyTokenOf(id);
        MockIMD o = address(b) == address(token) ? weth : token;
        uint256 rewardBefore = b.balanceOf(address(this));
        uint256 before = b.balanceOf(address(intake));
        uint256 otherHeld = o.balanceOf(address(markets));
        primaryRequests[id] = markets.resolve(id, body);
        assertEq(o.balanceOf(address(markets)), otherHeld, "ask spent the other token");
        bountyExits[id] += b.balanceOf(address(intake)) - before;
        recordReward(id, b, rewardBefore);
    }

    function deliverPrimary(uint256 seed, bool side) external {
        uint256 id = pick(seed);
        bytes32 rid = primaryRequests[id];
        VerdictMarkets.Market memory m = markets.getMarket(id);
        if (rid == bytes32(0) || intake.attempted(rid) || block.timestamp > m.params.answerUntil) return;
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(side), 5);
        deliver(rid, a);
        deliveredPrimaries[id] = a;
    }

    function proposePrimary(uint256 seed) external {
        uint256 id = pick(seed);
        VerdictMarkets.Market memory m = markets.getMarket(id);
        OracleAttestation.Attestation memory a = deliveredPrimaries[id];
        if (
            m.status != VerdictMarkets.Status.Open || block.timestamp < m.params.answerFrom
                || block.timestamp >= m.params.voidAfter || a.requestId == bytes32(0)
                || oracle.intakeRequestOf(a.requestId) != m.primaryRequests[m.asks - 1]
        ) return;
        MockIMD b = bountyTokenOf(id);
        uint256 rewardBefore = b.balanceOf(address(this));
        markets.propose(id, a);
        recordReward(id, b, rewardBefore);
    }

    function askEscalation(uint256 seed) external {
        uint256 id = pick(seed);
        VerdictMarkets.Market memory m = markets.getMarket(id);
        if (
            m.status != VerdictMarkets.Status.Provisional || m.escalated || m.escalationAsked || m.asks == 2
                || block.timestamp < m.params.answerFrom || block.timestamp >= m.params.answerUntil
                || block.timestamp >= m.disputeEnds
        ) return;
        if (oracle.asset() != address(m.bountyToken)) {
            vm.expectRevert(VerdictMarkets.OracleAssetMismatch.selector);
            markets.escalate(id, escalationBody);
            return;
        }
        if (oracle.price() > m.bountyRemaining) return;
        MockIMD b = bountyTokenOf(id);
        uint256 rewardBefore = b.balanceOf(address(this));
        uint256 before = b.balanceOf(address(intake));
        escalationRequests[id] = markets.escalate(id, escalationBody);
        bountyExits[id] += b.balanceOf(address(intake)) - before;
        assertEq(b.balanceOf(address(this)), rewardBefore, "escalate paid a reward");
    }

    function replaceOutcome(uint256 seed, bool side) external {
        uint256 id = pick(seed);
        bytes32 rid = escalationRequests[id];
        VerdictMarkets.Market memory m = markets.getMarket(id);
        if (rid == bytes32(0) || intake.attempted(rid)) return;
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(side), 10);
        deliver(rid, a);
        if (m.status == VerdictMarkets.Status.Provisional && !m.escalated && block.timestamp < m.disputeEnds) {
            MockIMD b = bountyTokenOf(id);
            uint256 rewardBefore = b.balanceOf(address(this));
            markets.propose(id, a);
            recordReward(id, b, rewardBefore);
        }
    }

    function settle(uint256 seed) public {
        uint256 id = pick(seed);
        VerdictMarkets.Market memory m = markets.getMarket(id);
        MockIMD c = collateralOf(id);
        MockIMD b = bountyTokenOf(id);
        bool sameToken = address(c) == address(b);
        uint256 rewardBefore = b.balanceOf(address(this));
        uint256 creatorBountyBefore = b.balanceOf(creator);
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
        bool finalized = after_.status == VerdictMarkets.Status.Finalized;
        VerdictMarkets.Collateral memory cfg = markets.collateralConfig(after_.params.collateralId);
        uint256 creatorFee = finalized ? (after_.pool * cfg.creatorFeeBps) / 10_000 : 0;
        uint256 burnFee = finalized ? (after_.pool * cfg.burnFeeBps) / 10_000 : 0;
        if (sameToken) {
            assertEq(b.balanceOf(creator) - creatorBountyBefore, creatorBounty + creatorFee, "creator, one token");
            collateralExits[id] += recipientsBalance(c) - feesBefore - creatorBounty;
        } else {
            assertEq(b.balanceOf(creator) - creatorBountyBefore, creatorBounty, "bounty returned in its token");
            collateralExits[id] += recipientsBalance(c) - feesBefore;
        }
        assertEq(c.balanceOf(address(burn)) - burnBefore, burnFee, "burn share");
        if (cfg.burnFeeBps == 0) assertEq(c.balanceOf(address(burn)), burnBefore, "zero burn share paid the sink");
        bountyExits[id] += creatorBounty;
        recordReward(id, b, rewardBefore);
    }

    function collect(uint256 seed, uint256 actor) public {
        uint256 id = pick(seed);
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
        MockIMD c = collateralOf(id);
        MockIMD o = address(c) == address(token) ? weth : token;
        uint256 before = c.balanceOf(bettor);
        uint256 otherBefore = o.balanceOf(bettor);
        vm.prank(bettor);
        uint256 payout = markets.claim(id);
        assertEq(c.balanceOf(bettor) - before, payout, "claim paid in the wrong token");
        assertEq(o.balanceOf(bettor), otherBefore, "claim moved the other token");
        collateralExits[id] += payout;
    }

    // ------------------------------------------------------------------ properties

    function assertAccounting() external view {
        uint256 imdHeld;
        uint256 wethHeld;
        uint256 imdSpent;
        uint256 wethSpent;
        uint256 count = markets.marketCount();
        for (uint256 id = 1; id <= count; id++) {
            VerdictMarkets.Market memory m = markets.getMarket(id);
            uint256 collateralAccounted = m.paidOut + m.refunded + m.fees;
            uint256 bountyAccounted = m.oracleSpend + m.rewardsPaid + m.returnedBounty;
            assertEq(collateralDeposits[id], m.pool, "pool vs measured deposits");
            assertEq(collateralExits[id], collateralAccounted, "collateral exits vs measured");
            assertEq(bountyExits[id], bountyAccounted, "bounty exits vs measured");
            assertEq(actualRewards[id], m.rewardsPaid, "rewards vs measured");
            assertLe(collateralAccounted, m.pool, "collateral overdrawn");
            assertEq(m.bountyRemaining + bountyAccounted, m.params.bounty, "bounty ledger");
            assertLe(m.pool, markets.maxPoolPerMarket(m.params.collateralId), "cap");
            assertEq(address(m.collateral), address(markets.collateral(m.params.collateralId)), "slot token");
            assertTrue(
                address(m.bountyToken) == address(token) || address(m.bountyToken) == address(weth),
                "bounty token is one of the two rotated assets"
            );
            uint256 poolHeld = m.pool - collateralAccounted;
            if (address(m.collateral) == address(token)) imdHeld += poolHeld;
            else wethHeld += poolHeld;
            if (address(m.bountyToken) == address(token)) {
                imdHeld += m.bountyRemaining;
                imdSpent += m.oracleSpend;
            } else {
                wethHeld += m.bountyRemaining;
                wethSpent += m.oracleSpend;
            }
        }
        assertEq(token.balanceOf(address(markets)), imdHeld, "IMD custody = IMD pools + IMD bounties");
        assertEq(weth.balanceOf(address(markets)), wethHeld, "WETH custody = WETH pools + WETH bounties");
        assertEq(token.balanceOf(address(intake)), imdSpent, "intake IMD = IMD oracle spend");
        assertEq(weth.balanceOf(address(intake)), wethSpent, "intake WETH = WETH oracle spend");
        assertEq(token.balanceOf(address(oracle)), 0);
        assertEq(weth.balanceOf(address(oracle)), 0);
        assertEq(address(markets).balance, 0, "native ETH held");
    }

    function drainAndAssert() external {
        vm.warp(block.timestamp + 14 days);
        uint256 count = markets.marketCount();
        for (uint256 seed; seed < count; seed++) {
            settle(seed);
            for (uint256 actor; actor < 4; actor++) {
                collect(seed, actor);
            }
            VerdictMarkets.Market memory m = markets.getMarket(seed + 1);
            assertTrue(
                m.status == VerdictMarkets.Status.Finalized || m.status == VerdictMarkets.Status.Voided, "terminal"
            );
            assertEq(m.pool, m.paidOut + m.refunded + m.fees, "collateral ledger drained");
            assertEq(m.params.bounty, m.oracleSpend + m.rewardsPaid + m.returnedBounty, "bounty ledger drained");
            assertEq(collateralDeposits[seed + 1], collateralExits[seed + 1], "deposits == exits");
        }
        assertEq(token.balanceOf(address(markets)), 0, "IMD dust");
        assertEq(weth.balanceOf(address(markets)), 0, "WETH dust");
    }

    function recordReward(uint256 id, MockIMD b, uint256 beforeBalance) internal {
        uint256 paid = b.balanceOf(address(this)) - beforeBalance;
        MockIMD o = address(b) == address(token) ? weth : token;
        actualRewards[id] += paid;
        bountyExits[id] += paid;
        assertLe(paid, markets.getMarket(id).settlerReward, "reward above the market's reward");
        // The settler never receives collateral: address(this) was minted 1_000_000 of each token in setUp
        // and only ever receives rewards, so its balance in the other token is exactly its rewards there.
        assertEq(o.balanceOf(address(this)), 1_000_000 ether + rewardsIn(o), "settler received the wrong token");
    }

    function rewardsIn(MockIMD t) internal view returns (uint256 total) {
        uint256 count = markets.marketCount();
        for (uint256 id = 1; id <= count; id++) {
            if (address(markets.getMarket(id).bountyToken) == address(t)) total += actualRewards[id];
        }
    }

    function user(uint256 actor) internal view returns (address) {
        address[4] memory users = [alice, bob, carol, creator];
        return users[actor % 4];
    }

    function recipientsBalance(MockIMD c) internal view returns (uint256) {
        return c.balanceOf(creator) + c.balanceOf(treasury) + c.balanceOf(address(burn));
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract CollateralRotationInvariantTest is Test {
    CollateralRotationHandler internal handler;
    MockIMD internal weth;

    function setUp() public {
        handler = new CollateralRotationHandler();
        weth = handler.wethToken();
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.open.selector;
        selectors[1] = handler.rotate.selector;
        selectors[2] = handler.enter.selector;
        selectors[3] = handler.advance.selector;
        selectors[4] = handler.togglePause.selector;
        selectors[5] = handler.ask.selector;
        selectors[6] = handler.deliverPrimary.selector;
        selectors[7] = handler.proposePrimary.selector;
        selectors[8] = handler.askEscalation.selector;
        selectors[9] = handler.replaceOutcome.selector;
        selectors[10] = handler.settle.selector;
        selectors[11] = handler.collect.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_everyTokenCustodyEqualsItsLedgersAcrossRotations() public view {
        handler.assertAccounting();
    }

    function afterInvariant() public {
        handler.drainAndAssert();
    }

    /// @dev Deterministic walk through the four token pairings so the campaign is known to reach them.
    function test_handlerReachesAllFourTokenPairings() public {
        uint256 timing = (uint256(3 days) << 8) | (uint256(1 days) << 16);
        handler.rotate(true, 0.5 ether); // asset: WETH
        handler.open(0, timing, 0.1 ether, 0); // 3: IMD collateral, WETH bounty
        handler.open(1, timing, 0.1 ether, 0); // 4: WETH collateral, WETH bounty
        handler.rotate(false, 0.7 ether); // asset: IMD, price moved
        handler.open(1, timing, 0.1 ether, 0); // 5: WETH collateral, IMD bounty
        assertEq(handler.imdCollateralWethBounty(), 1);
        assertEq(handler.wethCollateralWethBounty(), 1);
        for (uint256 i; i < 5; i++) {
            handler.enter(i, i, 0.3 ether, true);
            handler.enter(i, i + 1, 0.2 ether, false);
        }
        handler.advance(8 hours);
        handler.advance(8 hours);
        // Asset is IMD: markets 1, 2 and 5 ask and are proposed; 3 and 4 hit OracleAssetMismatch and wait.
        for (uint256 i; i < 5; i++) {
            handler.ask(i);
            handler.deliverPrimary(i, i % 2 == 0);
            handler.proposePrimary(i);
        }
        handler.assertAccounting();
        handler.rotate(true, 0.4 ether);
        for (uint256 i = 2; i < 4; i++) {
            handler.ask(i);
            handler.deliverPrimary(i, true);
            handler.proposePrimary(i);
        }
        handler.askEscalation(2);
        handler.replaceOutcome(2, false);
        handler.assertAccounting();
        // Markets 1 and 2 opened at price 0.5 and were asked at 0.7: the retry reserve swallows their resolve
        // and propose rewards, so only the terminal action pays them. Markets 3 to 5 paid on every action.
        assertEq(handler.actualRewards(1), 0, "reserve must clip the reward when the price rose");
        assertEq(handler.actualRewards(2), 0);
        assertEq(handler.actualRewards(3), 0.3 ether, "resolve, propose and replacement in WETH");
        assertEq(handler.actualRewards(4), 0.2 ether, "resolve and propose in WETH");
        assertEq(handler.actualRewards(5), 0.2 ether, "resolve and propose in IMD");
        assertEq(weth.balanceOf(address(handler)), 1_000_000 ether + 0.5 ether, "WETH rewards reached the settler");
        handler.drainAndAssert();
        for (uint256 id = 1; id <= 5; id++) {
            assertGt(handler.actualRewards(id), 0, "terminal action pays once the reserve is released");
        }
        assertEq(handler.rotations(), 3);
    }
}
