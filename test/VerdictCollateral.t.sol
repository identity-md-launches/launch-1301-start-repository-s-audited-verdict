// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {TestBase} from "./TestBase.sol";
import {VerdictMarkets} from "../src/VerdictMarkets.sol";
import {VerdictOracle} from "../src/VerdictOracle.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {MockIMD} from "./mocks/MockIMD.sol";

/// @dev Two collateral slots: bets, fees, payouts and refunds in the market's collateral token; bounty,
/// oracle spend and settler rewards always in the oracle's asset (IMD).
contract VerdictCollateralTest is TestBase {
    bytes32 internal constant TRANSFER = keccak256("Transfer(address,address,uint256)");
    address internal settler = makeAddr("settler");

    function wethParams(uint256 reward) internal view returns (VerdictMarkets.Params memory p) {
        p = params();
        p.collateralId = 1;
        p.settlerReward = reward;
        p.bounty = 2 * PRICE + 5 * reward;
    }

    function balances(address who) internal view returns (uint256 imd, uint256 eth) {
        return (token.balanceOf(who), weth.balanceOf(who));
    }

    function test_constructorExposesBothSlotsAndRejectsOtherSlots() public view {
        VerdictMarkets.Collateral memory c0 = markets.collateralConfig(0);
        VerdictMarkets.Collateral memory c1 = markets.collateralConfig(1);
        assertEq(address(c0.token), address(token));
        assertEq(c0.creatorFeeBps, 100);
        assertEq(c0.burnFeeBps, 50);
        assertEq(c0.treasuryFeeBps, 50);
        assertEq(c0.maxPoolPerMarket, 500 ether);
        assertEq(address(c1.token), address(weth));
        assertEq(c1.creatorFeeBps, WETH_CREATOR_BPS);
        assertEq(c1.burnFeeBps, WETH_BURN_BPS);
        assertEq(c1.treasuryFeeBps, WETH_TREASURY_BPS);
        assertEq(c1.maxPoolPerMarket, WETH_CAP);
        assertEq(address(markets.collateral(1)), address(weth));
        assertEq(markets.creatorFeeBps(1), WETH_CREATOR_BPS);
        assertEq(markets.burnFeeBps(1), WETH_BURN_BPS);
        assertEq(markets.treasuryFeeBps(1), WETH_TREASURY_BPS);
        assertEq(markets.maxPoolPerMarket(1), WETH_CAP);
    }

    function test_collateralConfigRevertsOutOfRange() public {
        vm.expectRevert(VerdictMarkets.InvalidCollateral.selector);
        markets.collateralConfig(2);
        vm.expectRevert(VerdictMarkets.InvalidCollateral.selector);
        markets.collateral(255);
        vm.expectRevert(VerdictMarkets.InvalidCollateral.selector);
        markets.maxPoolPerMarket(3);
    }

    function test_constructorRejectsEqualOrZeroTokensZeroCapsAndFeesOver500() public {
        address o = address(oracle);
        address b = address(burn);
        address t0 = address(token);
        address t1 = address(weth);
        vm.expectRevert(VerdictMarkets.InvalidCollateral.selector);
        new VerdictMarkets(o, treasury, b, alice, t0, 100, 50, 50, 1, t0, 150, 0, 100, 1, 0);
        vm.expectRevert(VerdictMarkets.InvalidAddress.selector);
        new VerdictMarkets(o, treasury, b, alice, address(0), 100, 50, 50, 1, t1, 150, 0, 100, 1, 0);
        vm.expectRevert(VerdictMarkets.InvalidAddress.selector);
        new VerdictMarkets(o, treasury, b, alice, t0, 100, 50, 50, 1, address(0), 150, 0, 100, 1, 0);
        vm.expectRevert(VerdictMarkets.InvalidCap.selector);
        new VerdictMarkets(o, treasury, b, alice, t0, 100, 50, 50, 0, t1, 150, 0, 100, 1, 0);
        vm.expectRevert(VerdictMarkets.InvalidCap.selector);
        new VerdictMarkets(o, treasury, b, alice, t0, 100, 50, 50, 1, t1, 150, 0, 100, 0, 0);
        vm.expectRevert(VerdictMarkets.InvalidFees.selector);
        new VerdictMarkets(o, treasury, b, alice, t0, 200, 200, 101, 1, t1, 150, 0, 100, 1, 0);
        vm.expectRevert(VerdictMarkets.InvalidFees.selector);
        new VerdictMarkets(o, treasury, b, alice, t0, 100, 50, 50, 1, t1, 400, 0, 101, 1, 0);
        vm.expectRevert(VerdictMarkets.InvalidFees.selector);
        new VerdictMarkets(o, treasury, b, alice, t0, 100, 50, 50, 1, t1, 65535, 65535, 65535, 1, 0);
        VerdictMarkets ok = new VerdictMarkets(o, treasury, b, alice, t0, 0, 0, 500, 1, t1, 500, 0, 0, 1, 0);
        assertEq(ok.treasuryFeeBps(0), 500);
        assertEq(ok.creatorFeeBps(1), 500);
        // Existing address checks still apply to the shared arguments.
        vm.expectRevert(VerdictMarkets.InvalidAddress.selector);
        new VerdictMarkets(address(0), treasury, b, alice, t0, 100, 50, 50, 1, t1, 150, 0, 100, 1, 0);
        vm.expectRevert(VerdictMarkets.InvalidAddress.selector);
        new VerdictMarkets(o, treasury, b, address(0), t0, 100, 50, 50, 1, t1, 150, 0, 100, 1, 0);
    }

    function test_collateralIdOutOfRangeRevertsWithoutTakingBounty() public {
        VerdictMarkets.Params memory p = params();
        uint256 before = token.balanceOf(creator);
        p.collateralId = 2;
        vm.prank(creator);
        vm.expectRevert(VerdictMarkets.InvalidCollateral.selector);
        markets.createMarket(p, body, escalationBody, "", 0);
        p.collateralId = 255;
        vm.prank(creator);
        vm.expectRevert(VerdictMarkets.InvalidCollateral.selector);
        markets.createMarket(p, body, escalationBody, "", 0);
        assertEq(markets.marketCount(), 0);
        assertEq(token.balanceOf(creator), before);
    }

    function test_marketsInEachSlotUseTheirOwnFeesAndCaps() public {
        uint256 imdMarket = create();
        uint256 wethMarket = createWith(wethParams(0));
        assertEq(address(markets.getMarket(imdMarket).collateral), address(token));
        assertEq(address(markets.getMarket(wethMarket).collateral), address(weth));
        assertEq(address(markets.getMarket(imdMarket).bountyToken), address(token));
        assertEq(address(markets.getMarket(wethMarket).bountyToken), address(token));
        assertEq(markets.getMarket(wethMarket).params.collateralId, 1);

        // Each slot's cap applies to its own markets and counts only that market's pool.
        betAs(imdMarket, alice, 1, 500 ether);
        vm.prank(bob);
        vm.expectRevert(VerdictMarkets.PoolCapExceeded.selector);
        markets.bet(imdMarket, 0, 1, 0);
        betAs(wethMarket, alice, 1, 0.75 ether);
        betAs(wethMarket, bob, 0, 0.25 ether);
        vm.prank(carol);
        vm.expectRevert(VerdictMarkets.PoolCapExceeded.selector);
        markets.bet(wethMarket, 0, 1, 0);
        assertEq(markets.getMarket(wethMarket).pool, 1 ether);
        assertEq(weth.balanceOf(address(markets)), 1 ether);
        assertEq(token.balanceOf(address(markets)), 500 ether + 2 * (2 * PRICE));

        // Each slot's fee schedule applies at finalization, in that slot's token.
        primary(imdMarket, true);
        primary(wethMarket, true);
        vm.warp(markets.getMarket(wethMarket).disputeEnds);
        (uint256 creatorImd, uint256 creatorWeth) = balances(creator);
        (uint256 treasuryImd, uint256 treasuryWeth) = balances(treasury);
        vm.expectEmit(true, false, false, true, address(markets));
        emit VerdictMarkets.Finalized(imdMarket, 1, 5 ether, 2.5 ether, 2.5 ether);
        markets.finalize(imdMarket);
        vm.expectEmit(true, false, false, true, address(markets));
        emit VerdictMarkets.Finalized(wethMarket, 1, 0.015 ether, 0, 0.01 ether);
        markets.finalize(wethMarket);
        assertEq(token.balanceOf(creator) - creatorImd, 5 ether + PRICE + PRICE, "IMD fee plus both bounties");
        assertEq(weth.balanceOf(creator) - creatorWeth, 0.015 ether);
        assertEq(token.balanceOf(treasury) - treasuryImd, 2.5 ether);
        assertEq(weth.balanceOf(treasury) - treasuryWeth, 0.01 ether);
        assertEq(token.balanceOf(address(burn)), 2.5 ether);
        assertEq(weth.balanceOf(address(burn)), 0);
        vm.prank(alice);
        assertEq(markets.claim(imdMarket), 490 ether);
        vm.prank(alice);
        assertEq(markets.claim(wethMarket), 0.975 ether);
        assertConserved(imdMarket, true);
        assertConserved(wethMarket, true);
        assertEq(token.balanceOf(address(markets)), 0);
        assertEq(weth.balanceOf(address(markets)), 0);
    }

    function test_wethMarketPaysFeesAndPayoutsInWethAndBountyOracleAndRewardsInIMD() public {
        uint256 id = createWith(wethParams(0.1 ether));
        VerdictMarkets.Market memory m = markets.getMarket(id);
        assertEq(m.params.bounty, 1.5 ether, "bounty pulled in IMD");
        assertEq(token.balanceOf(address(markets)), 1.5 ether);
        assertEq(weth.balanceOf(address(markets)), 0);
        betAs(id, alice, 1, 0.6 ether);
        betAs(id, bob, 0, 0.4 ether);
        assertEq(weth.balanceOf(address(markets)), 1 ether);
        assertEq(token.balanceOf(address(markets)), 1.5 ether, "bets never touch the bounty token");

        vm.warp(m.params.answerFrom);
        vm.prank(settler);
        bytes32 rid = markets.resolve(id, body);
        assertEq(token.balanceOf(settler), 0.1 ether, "resolve reward in IMD");
        assertEq(weth.balanceOf(settler), 0);
        assertEq(token.balanceOf(address(intake)), PRICE, "oracle paid in IMD");
        assertEq(weth.balanceOf(address(intake)), 0);
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(true), 5);
        deliver(rid, a);
        vm.prank(settler);
        markets.propose(id, a);
        assertEq(token.balanceOf(settler), 0.2 ether, "propose reward in IMD");
        vm.warp(markets.getMarket(id).disputeEnds);
        (uint256 creatorImd, uint256 creatorWeth) = balances(creator);
        vm.prank(settler);
        markets.finalize(id);
        assertEq(token.balanceOf(settler), 0.3 ether, "finalize reward in IMD");
        assertEq(weth.balanceOf(settler), 0);
        m = markets.getMarket(id);
        assertEq(m.oracleSpend, PRICE);
        assertEq(m.rewardsPaid, 0.3 ether);
        assertEq(m.returnedBounty, 1.5 ether - PRICE - 0.3 ether);
        assertEq(token.balanceOf(creator) - creatorImd, m.returnedBounty, "unspent bounty returned in IMD");
        assertEq(weth.balanceOf(creator) - creatorWeth, 0.015 ether, "creator fee in WETH");
        assertEq(weth.balanceOf(treasury), 0.01 ether, "treasury fee in WETH");
        assertEq(token.balanceOf(treasury), 0);
        assertEq(m.fees, 0.025 ether);
        vm.prank(alice);
        assertEq(markets.claim(id), 0.975 ether);
        assertEq(weth.balanceOf(alice), 1_000_000 ether - 0.6 ether + 0.975 ether, "payout in WETH");
        assertEq(token.balanceOf(alice), 1_000_000 ether, "no IMD moved for a WETH bettor");
        assertConserved(id, true);
        m = markets.getMarket(id);
        assertEq(m.pool, m.paidOut + m.fees + m.refunded);
        assertEq(m.params.bounty, m.oracleSpend + m.rewardsPaid + m.returnedBounty);
        assertEq(token.balanceOf(address(markets)), 0);
        assertEq(weth.balanceOf(address(markets)), 0);
    }

    function test_wethMarketRefundsInWethAndReturnsBountyInIMDOnVoid() public {
        uint256 id = createWith(wethParams(0.05 ether));
        betAs(id, alice, 1, 0.3 ether);
        betAs(id, bob, 0, 0.2 ether);
        vm.warp(markets.getMarket(id).params.voidAfter);
        (uint256 creatorImd, uint256 creatorWeth) = balances(creator);
        vm.prank(settler);
        markets.voidMarket(id);
        assertEq(token.balanceOf(settler), 0.05 ether, "void reward in IMD");
        assertEq(weth.balanceOf(settler), 0);
        assertEq(token.balanceOf(creator) - creatorImd, 1.25 ether - 0.05 ether, "bounty back in IMD");
        assertEq(weth.balanceOf(creator), creatorWeth);
        vm.prank(alice);
        assertEq(markets.claim(id), 0.3 ether);
        vm.prank(bob);
        assertEq(markets.claim(id), 0.2 ether);
        assertEq(weth.balanceOf(alice), 1_000_000 ether);
        assertEq(weth.balanceOf(bob), 1_000_000 ether);
        assertConserved(id, true);
        assertEq(token.balanceOf(address(markets)), 0);
        assertEq(weth.balanceOf(address(markets)), 0);
    }

    function test_zeroBurnShareSendsNothingToBurnSink() public {
        uint256 id = createWith(wethParams(0));
        betAs(id, alice, 1, 0.5 ether);
        primary(id, true);
        vm.warp(markets.getMarket(id).disputeEnds);
        vm.recordLogs();
        markets.finalize(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != TRANSFER) continue;
            assertTrue(address(uint160(uint256(logs[i].topics[2]))) != address(burn), "transfer to burn sink");
        }
        assertEq(weth.balanceOf(address(burn)), 0);
        assertEq(token.balanceOf(address(burn)), 0);
        assertEq(markets.getMarket(id).fees, 0.0125 ether);
    }

    function test_imdMarketKeepsCollateralAndBountyLedgersSeparate() public {
        VerdictMarkets.Params memory p = params();
        p.settlerReward = 0.1 ether;
        p.bounty = 2 * PRICE + 5 * p.settlerReward;
        uint256 id = createWith(p);
        uint256 other = createWith(wethParams(0));
        betAs(id, alice, 1, 100 ether);
        betAs(id, bob, 0, 50 ether);
        betAs(other, carol, 1, 0.2 ether);
        assertEq(token.balanceOf(address(markets)), 150 ether + 1.5 ether + 1 ether, "IMD = pools + bounties");
        vm.warp(markets.getMarket(id).params.answerFrom);
        vm.prank(settler);
        bytes32 rid = markets.resolve(id, body);
        VerdictMarkets.Market memory m = markets.getMarket(id);
        assertEq(m.pool, 150 ether, "pool untouched by the ask");
        assertEq(m.bountyRemaining, 1.5 ether - PRICE - 0.1 ether);
        assertEq(token.balanceOf(address(markets)), m.pool + m.bountyRemaining + 1 ether);
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(false), 5);
        deliver(rid, a);
        vm.prank(settler);
        markets.propose(id, a);
        vm.warp(markets.getMarket(id).disputeEnds);
        uint256 creatorBefore = token.balanceOf(creator);
        vm.prank(settler);
        markets.finalize(id);
        m = markets.getMarket(id);
        assertEq(m.fees, 3 ether);
        assertEq(m.rewardsPaid, 0.3 ether);
        assertEq(m.returnedBounty, 1.5 ether - PRICE - 0.3 ether);
        assertEq(token.balanceOf(creator) - creatorBefore, 1.5 ether + m.returnedBounty, "fee plus bounty, one token");
        assertEq(token.balanceOf(address(markets)), m.pool - m.fees + 1 ether, "payout owed plus other's bounty");
        vm.prank(bob);
        assertEq(markets.claim(id), 147 ether);
        assertEq(m.pool, m.fees + 147 ether, "collateral ledger closes");
        assertEq(m.params.bounty, m.oracleSpend + m.rewardsPaid + m.returnedBounty, "bounty ledger closes");
        assertConserved(id, true);
        assertEq(token.balanceOf(address(markets)), 1 ether, "only the WETH market's IMD bounty remains");
        assertEq(weth.balanceOf(address(markets)), 0.2 ether);
    }

    function test_oracleAssetMismatchWhenOracleAssetChanges() public {
        uint256 wethMarket = createWith(wethParams(0));
        uint256 imdMarket = create();
        betAs(wethMarket, alice, 1, 0.1 ether);
        uint256 provisional = createWith(wethParams(0));
        betAs(provisional, alice, 1, 0.1 ether);
        primary(provisional, true);
        MockIMD other = new MockIMD();
        oracle.proposeConfig(VerdictOracle.Config(address(intake), address(other), vm.addr(SIGNER_KEY), ACTION, PRICE));
        oracle.acceptConfig();
        vm.expectRevert(VerdictMarkets.OracleAssetMismatch.selector);
        markets.resolve(wethMarket, body);
        vm.expectRevert(VerdictMarkets.OracleAssetMismatch.selector);
        markets.resolve(imdMarket, body);
        vm.expectRevert(VerdictMarkets.OracleAssetMismatch.selector);
        markets.escalate(provisional, escalationBody);
        assertEq(markets.getMarket(wethMarket).asks, 0);
        // A market created after the rotation pulls its bounty in the oracle's new asset.
        other.mint(creator, 10 ether);
        vm.prank(creator);
        other.approve(address(markets), type(uint256).max);
        uint256 later = createWith(wethParams(0));
        assertEq(address(markets.getMarket(later).bountyToken), address(other));
        assertEq(other.balanceOf(address(markets)), 2 * PRICE);
        // Rotating back restores asks for the earlier markets and blocks the later one.
        oracle.proposeConfig(VerdictOracle.Config(address(intake), address(token), vm.addr(SIGNER_KEY), ACTION, PRICE));
        oracle.acceptConfig();
        markets.resolve(wethMarket, body);
        vm.warp(markets.getMarket(later).params.answerFrom);
        vm.expectRevert(VerdictMarkets.OracleAssetMismatch.selector);
        markets.resolve(later, body);
        // Refunds stay available in the collateral token regardless of the oracle's asset.
        vm.warp(markets.getMarket(wethMarket).params.voidAfter);
        markets.voidMarket(wethMarket);
        vm.prank(alice);
        assertEq(markets.claim(wethMarket), 0.1 ether);
        assertConserved(wethMarket, true);
    }

    function test_marketCreatedEmitsSlotOneCollateral() public {
        vm.recordLogs();
        uint256 id = createWith(wethParams(0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("MarketCreated(uint256,address,bytes32,bytes32,bytes,bytes,string,uint256,address)");
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(markets) || logs[i].topics[0] != topic) continue;
            (,,,, uint256 agentId, address collateralToken) =
                abi.decode(logs[i].data, (bytes32, bytes, bytes, string, uint256, address));
            assertEq(uint256(logs[i].topics[1]), id);
            assertEq(agentId, 42);
            assertEq(collateralToken, address(weth));
            found = true;
        }
        assertTrue(found);
    }

    function test_wethMarketRejectsIMDApprovalOnlyAndBetsNeedWeth() public {
        uint256 id = createWith(wethParams(0));
        address poor = makeAddr("poor");
        token.mint(poor, 10 ether);
        vm.startPrank(poor);
        token.approve(address(markets), type(uint256).max);
        weth.approve(address(markets), type(uint256).max);
        vm.expectRevert();
        markets.bet(id, 1, 1 ether, 0);
        vm.stopPrank();
        assertEq(markets.getMarket(id).pool, 0);
        assertEq(token.balanceOf(poor), 10 ether);
    }
}
