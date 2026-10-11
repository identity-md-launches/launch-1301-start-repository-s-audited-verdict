// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {TestBase} from "./TestBase.sol";
import {VerdictMarkets} from "../src/VerdictMarkets.sol";
import {VerdictOracle} from "../src/VerdictOracle.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {MockIMD} from "./mocks/MockIMD.sol";

/// @dev Adversarial probes of the two-collateral VerdictMarkets written against the implementation's edges
/// rather than its happy path: fuzzed constructor bounds per slot, one-wei and cap-filling WETH stakes, the
/// full 500 bps fee ceiling in WETH, a bounty token that differs from both IMD and the collateral after an
/// oracle asset rotation, a WETH double that re-enters during every finalize payout, stakes that arrive
/// taxed to zero, and callers who hold the wrong token.
contract CollateralAdversarialTest is TestBase {
    bytes32 internal constant TRANSFER = keccak256("Transfer(address,address,uint256)");
    address internal settler = makeAddr("settler");

    function wethParams(uint256 reward) internal view returns (VerdictMarkets.Params memory p) {
        p = params();
        p.collateralId = 1;
        p.settlerReward = reward;
        p.bounty = 2 * PRICE + 5 * reward;
    }

    function rotateAsset(address asset) internal {
        oracle.proposeConfig(VerdictOracle.Config(address(intake), asset, vm.addr(SIGNER_KEY), ACTION, PRICE));
        oracle.acceptConfig();
    }

    function deployWith(uint16 c0, uint16 b0, uint16 t0, uint256 cap0, uint16 c1, uint16 b1, uint16 t1, uint256 cap1)
        internal
        returns (VerdictMarkets)
    {
        return new VerdictMarkets(
            address(oracle),
            treasury,
            address(burn),
            address(this),
            address(token),
            c0,
            b0,
            t0,
            cap0,
            address(weth),
            c1,
            b1,
            t1,
            cap1,
            0.25 ether
        );
    }

    function transfersTo(Vm.Log[] memory logs, address emitter, address to)
        internal
        pure
        returns (uint256 count, uint256 total)
    {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != emitter || logs[i].topics[0] != TRANSFER) continue;
            if (address(uint160(uint256(logs[i].topics[2]))) != to) continue;
            count++;
            total += abi.decode(logs[i].data, (uint256));
        }
    }

    // ------------------------------------------------------------------ constructor

    /// forge-config: default.fuzz.runs = 512
    /// @dev Each slot's fee sum is checked on its own against 500 bps; a slot at exactly 500 is accepted and
    /// one bp over is rejected, whatever the other slot holds. Caps of one wei are accepted; zero is not.
    function testFuzz_constructorChecksEachSlotIndependently(
        uint16 c0,
        uint16 b0,
        uint16 t0,
        uint16 c1,
        uint16 b1,
        uint16 t1,
        uint256 cap0,
        uint256 cap1
    ) public {
        c0 = uint16(bound(c0, 0, 600));
        b0 = uint16(bound(b0, 0, 600));
        t0 = uint16(bound(t0, 0, 600));
        c1 = uint16(bound(c1, 0, 600));
        b1 = uint16(bound(b1, 0, 600));
        t1 = uint16(bound(t1, 0, 600));
        cap0 = bound(cap0, 0, type(uint256).max);
        cap1 = bound(cap1, 0, type(uint256).max);
        bool fees0Ok = uint256(c0) + b0 + t0 <= 500;
        bool fees1Ok = uint256(c1) + b1 + t1 <= 500;
        if (!fees0Ok || !fees1Ok) {
            vm.expectRevert(VerdictMarkets.InvalidFees.selector);
            deployWith(c0, b0, t0, cap0, c1, b1, t1, cap1);
            return;
        }
        if (cap0 == 0 || cap1 == 0) {
            vm.expectRevert(VerdictMarkets.InvalidCap.selector);
            deployWith(c0, b0, t0, cap0, c1, b1, t1, cap1);
            return;
        }
        VerdictMarkets m = deployWith(c0, b0, t0, cap0, c1, b1, t1, cap1);
        VerdictMarkets.Collateral memory s0 = m.collateralConfig(0);
        VerdictMarkets.Collateral memory s1 = m.collateralConfig(1);
        assertEq(address(s0.token), address(token));
        assertEq(address(s1.token), address(weth));
        assertEq(s0.creatorFeeBps, c0);
        assertEq(s0.burnFeeBps, b0);
        assertEq(s0.treasuryFeeBps, t0);
        assertEq(s0.maxPoolPerMarket, cap0);
        assertEq(s1.creatorFeeBps, c1);
        assertEq(s1.burnFeeBps, b1);
        assertEq(s1.treasuryFeeBps, t1);
        assertEq(s1.maxPoolPerMarket, cap1);
        assertEq(m.creatorFeeBps(0), c0);
        assertEq(m.burnFeeBps(1), b1);
        assertEq(m.treasuryFeeBps(1), t1);
        assertEq(m.maxPoolPerMarket(0), cap0);
    }

    /// @dev Both slots may hold a one-wei cap and the maximal cap; the equal-token check runs before the fee
    /// and cap checks so a degenerate configuration cannot slip past by failing a later check first.
    function test_constructorBoundaryCapsAndCheckOrder() public {
        VerdictMarkets m = deployWith(0, 0, 0, 1, 500, 0, 0, type(uint256).max);
        assertEq(m.maxPoolPerMarket(0), 1);
        assertEq(m.maxPoolPerMarket(1), type(uint256).max);
        // Equal tokens with otherwise invalid fees and caps: InvalidCollateral wins.
        vm.expectRevert(VerdictMarkets.InvalidCollateral.selector);
        new VerdictMarkets(
            address(oracle),
            treasury,
            address(burn),
            alice,
            address(weth),
            600,
            600,
            600,
            0,
            address(weth),
            0,
            0,
            0,
            0,
            0
        );
        // Zero token with invalid fees: InvalidAddress wins.
        vm.expectRevert(VerdictMarkets.InvalidAddress.selector);
        new VerdictMarkets(
            address(oracle), treasury, address(burn), alice, address(0), 600, 0, 0, 0, address(0), 0, 0, 0, 0, 0
        );
        // The slot order is preserved: the same tokens swapped produce swapped getters, not a rejection.
        VerdictMarkets swapped = new VerdictMarkets(
            address(oracle), treasury, address(burn), alice, address(weth), 1, 2, 3, 4, address(token), 5, 6, 7, 8, 0
        );
        assertEq(address(swapped.collateral(0)), address(weth));
        assertEq(address(swapped.collateral(1)), address(token));
        assertEq(swapped.burnFeeBps(0), 2);
        assertEq(swapped.maxPoolPerMarket(1), 8);
    }

    // ------------------------------------------------------------------ bets in WETH

    /// @dev One wei fills a one-wei slot; the next wei is refused; the cap is exact, not approximate.
    function test_wethCapIsExactAtOneWei() public {
        markets = deployWith(100, 50, 50, 500 ether, 150, 0, 100, 1);
        markets.setCreatorAllowed(creator, true);
        address[3] memory users = [creator, alice, bob];
        for (uint256 i; i < users.length; i++) {
            vm.startPrank(users[i]);
            token.approve(address(markets), type(uint256).max);
            weth.approve(address(markets), type(uint256).max);
            vm.stopPrank();
        }
        uint256 id = createWith(wethParams(0));
        betAs(id, alice, 1, 1);
        assertEq(markets.getMarket(id).pool, 1);
        vm.prank(bob);
        vm.expectRevert(VerdictMarkets.PoolCapExceeded.selector);
        markets.bet(id, 0, 1, 0);
        // Zero is never a bet, in either slot, before the cap is even consulted.
        vm.prank(bob);
        vm.expectRevert(VerdictMarkets.InvalidAmount.selector);
        markets.bet(id, 0, 0, 0);
    }

    /// @dev The last wei of the cap is accepted and one more wei is refused, in WETH.
    function test_wethCapBoundaryAtLaunchCap() public {
        uint256 id = createWith(wethParams(0));
        betAs(id, alice, 1, WETH_CAP - 1);
        vm.prank(bob);
        vm.expectRevert(VerdictMarkets.PoolCapExceeded.selector);
        markets.bet(id, 0, 2, 0);
        betAs(id, bob, 0, 1);
        assertEq(markets.getMarket(id).pool, WETH_CAP);
        assertEq(weth.balanceOf(address(markets)), WETH_CAP);
        vm.prank(carol);
        vm.expectRevert(VerdictMarkets.PoolCapExceeded.selector);
        markets.bet(id, 0, 1, 0);
        // The IMD slot's room is untouched by the full WETH market.
        uint256 imd = create();
        betAs(imd, carol, 1, 500 ether);
    }

    /// @dev A transfer taxed to nothing credits nothing and reverts rather than minting a free stake.
    function test_wethStakeTaxedToZeroReverts() public {
        uint256 id = createWith(wethParams(0));
        weth.setFee(10_000);
        vm.prank(alice);
        vm.expectRevert(VerdictMarkets.InvalidAmount.selector);
        markets.bet(id, 1, 1 ether, 0);
        weth.setFee(0);
        assertEq(markets.getMarket(id).pool, 0);
        assertEq(markets.stakes(id, alice, 1), 0);
    }

    /// @dev A WETH market refuses bets once closed, when paused, on an unknown outcome and on an unknown id;
    /// none of these touch WETH custody.
    function test_wethBetFailurePathsLeaveCustodyUntouched() public {
        uint256 id = createWith(wethParams(0));
        betAs(id, alice, 1, 0.1 ether);
        uint256 held = weth.balanceOf(address(markets));
        vm.prank(alice);
        vm.expectRevert(VerdictMarkets.InvalidOutcome.selector);
        markets.bet(id, 2, 0.1 ether, 0);
        vm.prank(alice);
        vm.expectRevert(VerdictMarkets.UnknownMarket.selector);
        markets.bet(id + 1, 0, 0.1 ether, 0);
        markets.pause();
        vm.prank(alice);
        vm.expectRevert(VerdictMarkets.EntryPaused.selector);
        markets.bet(id, 0, 0.1 ether, 0);
        markets.unpause();
        vm.warp(markets.getMarket(id).params.closeAt);
        vm.prank(alice);
        vm.expectRevert(VerdictMarkets.OutsideWindow.selector);
        markets.bet(id, 0, 0.1 ether, 0);
        assertEq(weth.balanceOf(address(markets)), held);
        assertEq(markets.getMarket(id).pool, 0.1 ether);
    }

    /// @dev A creator rich in WETH but without IMD cannot open a WETH market: the bounty is IMD only.
    function test_wethMarketCreationNeedsIMDBounty() public {
        address rich = makeAddr("rich-in-weth");
        weth.mint(rich, 100 ether);
        markets.setCreatorAllowed(rich, true);
        vm.startPrank(rich);
        weth.approve(address(markets), type(uint256).max);
        token.approve(address(markets), type(uint256).max);
        vm.expectRevert();
        markets.createMarket(wethParams(0), body, escalationBody, "", 0);
        vm.stopPrank();
        assertEq(markets.marketCount(), 0);
        assertEq(weth.balanceOf(rich), 100 ether, "no WETH may be taken as a bounty");
        assertEq(weth.balanceOf(address(markets)), 0);
    }

    // ------------------------------------------------------------------ settlement in WETH

    /// forge-config: default.fuzz.runs = 512
    /// @dev Any fee schedule up to the 500 bps ceiling, any split of stakes down to one wei: WETH payouts plus
    /// WETH fees equal the WETH pool exactly, the bounty ledger closes in IMD, and nothing stays behind.
    function testFuzz_wethFeeSplitConservesPoolExactly(
        uint16 c1,
        uint16 b1,
        uint16 t1,
        uint256 winA,
        uint256 winB,
        uint256 lose,
        uint256 reward
    ) public {
        c1 = uint16(bound(c1, 0, 500));
        b1 = uint16(bound(b1, 0, 500 - c1));
        t1 = uint16(bound(t1, 0, 500 - c1 - b1));
        winA = bound(winA, 1, 0.4 ether);
        winB = bound(winB, 1, 0.4 ether);
        lose = bound(lose, 0, 0.2 ether);
        reward = bound(reward, 0, 0.25 ether);
        markets = deployWith(100, 50, 50, 500 ether, c1, b1, t1, WETH_CAP);
        markets.setCreatorAllowed(creator, true);
        address[4] memory users = [creator, alice, bob, carol];
        for (uint256 i; i < users.length; i++) {
            vm.startPrank(users[i]);
            token.approve(address(markets), type(uint256).max);
            weth.approve(address(markets), type(uint256).max);
            vm.stopPrank();
        }
        uint256 id = createWith(wethParams(reward));
        betAs(id, alice, 1, winA);
        betAs(id, bob, 1, winB);
        if (lose != 0) betAs(id, carol, 0, lose);
        uint256 pool = winA + winB + lose;
        uint256 treasuryImd = token.balanceOf(treasury);
        uint256 creatorWeth = weth.balanceOf(creator);
        uint256 creatorImd = token.balanceOf(creator);

        vm.warp(markets.getMarket(id).params.answerFrom);
        vm.prank(settler);
        bytes32 rid = markets.resolve(id, body);
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(true), 5);
        deliver(rid, a);
        vm.prank(settler);
        markets.propose(id, a);
        vm.warp(markets.getMarket(id).disputeEnds);
        vm.prank(settler);
        markets.finalize(id);

        VerdictMarkets.Market memory m = markets.getMarket(id);
        uint256 expectedFees = pool * c1 / 10_000 + pool * b1 / 10_000 + pool * t1 / 10_000;
        assertEq(m.fees, expectedFees, "fees from the slot's own schedule");
        assertEq(weth.balanceOf(creator) - creatorWeth, pool * c1 / 10_000, "creator fee in WETH");
        assertEq(weth.balanceOf(address(burn)), pool * b1 / 10_000, "burn fee in WETH");
        assertEq(weth.balanceOf(treasury), pool * t1 / 10_000, "treasury fee in WETH");
        assertEq(token.balanceOf(treasury), treasuryImd, "treasury took no IMD from a WETH market");
        assertEq(token.balanceOf(address(burn)), 0, "burn sink took no IMD from a WETH market");
        assertEq(token.balanceOf(creator) - creatorImd, m.returnedBounty, "creator's IMD is only the bounty");
        assertEq(token.balanceOf(settler), m.rewardsPaid, "rewards in IMD");
        assertEq(weth.balanceOf(settler), 0, "settler never receives collateral");
        assertEq(m.rewardsPaid, 3 * reward, "three rewarded actions at the full reward");

        vm.prank(alice);
        uint256 paidA = markets.claim(id);
        vm.prank(bob);
        uint256 paidB = markets.claim(id);
        if (lose != 0) {
            vm.prank(carol);
            vm.expectRevert(VerdictMarkets.NothingToClaim.selector);
            markets.claim(id);
        }
        assertEq(paidA + paidB + m.fees, pool, "WETH ledger closes without dust");
        assertGe(paidA, winA * (pool - m.fees) / (winA + winB), "floor bound A");
        assertGe(paidB, winB * (pool - m.fees) / (winA + winB), "floor bound B");
        assertEq(m.params.bounty, m.oracleSpend + m.rewardsPaid + m.returnedBounty, "IMD ledger closes");
        assertEq(weth.balanceOf(address(markets)), 0);
        assertEq(token.balanceOf(address(markets)), 0);
        assertConserved(id, true);
    }

    /// @dev A WETH double that re-enters Markets on every outgoing transfer during finalize cannot bet, claim,
    /// void, or finalize again; the payouts stay exact and the market still drains.
    function test_wethCallbackDuringFinalizeCannotReenter() public {
        uint256 id = createWith(wethParams(0.05 ether));
        betAs(id, alice, 1, 0.5 ether);
        betAs(id, bob, 0, 0.5 ether);
        primary(id, true);
        vm.warp(markets.getMarket(id).disputeEnds);
        bytes[4] memory attempts = [
            abi.encodeCall(markets.claim, (id)),
            abi.encodeCall(markets.finalize, (id)),
            abi.encodeCall(markets.voidMarket, (id)),
            abi.encodeCall(markets.bet, (id, 1, 1, 0))
        ];
        // Snapshot the pre-finalize state and try each re-entrant call from the creator's WETH transfer.
        uint256 snapshot = vm.snapshotState();
        for (uint256 i; i < attempts.length; i++) {
            weth.setHook(address(markets), attempts[i]);
            vm.prank(settler);
            markets.finalize(id);
            assertFalse(weth.hookSuccess(), "re-entrant call during finalize succeeded");
            VerdictMarkets.Market memory m = markets.getMarket(id);
            assertEq(uint8(m.status), uint8(VerdictMarkets.Status.Finalized));
            assertEq(m.fees, 0.025 ether);
            assertEq(m.paidOut, 0, "a claim slipped through during finalize");
            assertEq(weth.balanceOf(address(markets)), 0.975 ether);
            weth.setHook(address(0), "");
            vm.prank(alice);
            assertEq(markets.claim(id), 0.975 ether);
            assertConserved(id, true);
            assertEq(weth.balanceOf(address(markets)), 0);
            vm.revertToState(snapshot);
        }
    }

    /// @dev Claims on a WETH market: a loser has nothing, a second claim reverts, a stranger reverts, and a
    /// claim before finalization reverts; each leaves WETH custody and the collateral ledger as it was.
    function test_wethClaimFailurePaths() public {
        uint256 id = createWith(wethParams(0));
        betAs(id, alice, 1, 0.3 ether);
        betAs(id, bob, 0, 0.3 ether);
        vm.prank(alice);
        vm.expectRevert(VerdictMarkets.WrongState.selector);
        markets.claim(id);
        primary(id, true);
        vm.prank(alice);
        vm.expectRevert(VerdictMarkets.WrongState.selector);
        markets.claim(id);
        vm.warp(markets.getMarket(id).disputeEnds);
        markets.finalize(id);
        vm.prank(bob);
        vm.expectRevert(VerdictMarkets.NothingToClaim.selector);
        markets.claim(id);
        vm.prank(carol);
        vm.expectRevert(VerdictMarkets.NothingToClaim.selector);
        markets.claim(id);
        vm.prank(alice);
        assertEq(markets.claim(id), 0.585 ether);
        vm.prank(alice);
        vm.expectRevert(VerdictMarkets.NothingToClaim.selector);
        markets.claim(id);
        assertEq(weth.balanceOf(address(markets)), 0);
        assertConserved(id, true);
    }

    /// @dev Refund claims work in WETH while entry is paused; a bettor on both sides gets every wei back.
    function test_wethRefundsWhilePausedReturnBothSides() public {
        uint256 id = createWith(wethParams(0));
        betAs(id, alice, 1, 0.25 ether);
        betAs(id, alice, 0, 0.5 ether);
        betAs(id, bob, 0, 0.25 ether);
        markets.pause();
        vm.warp(markets.getMarket(id).params.voidAfter);
        markets.voidMarket(id);
        vm.prank(alice);
        assertEq(markets.claim(id), 0.75 ether);
        vm.prank(bob);
        assertEq(markets.claim(id), 0.25 ether);
        assertEq(weth.balanceOf(alice), 1_000_000 ether);
        assertEq(weth.balanceOf(address(markets)), 0);
        assertConserved(id, true);
    }

    /// @dev A WETH market whose bounty can no longer pay a reward still pays nothing out of the WETH pool.
    function test_wethPoolNeverSubsidisesSettlerRewards() public {
        uint256 id = createWith(wethParams(0.25 ether));
        betAs(id, alice, 1, 0.9 ether);
        // The oracle's price rises so the whole remaining bounty is needed as the retry reserve.
        oracle.proposeConfig(
            VerdictOracle.Config(address(intake), address(token), vm.addr(SIGNER_KEY), ACTION, 1.125 ether)
        );
        oracle.acceptConfig();
        vm.warp(markets.getMarket(id).params.answerFrom);
        vm.prank(settler);
        bytes32 rid = markets.resolve(id, body);
        VerdictMarkets.Market memory m = markets.getMarket(id);
        assertEq(m.bountyRemaining, 2.25 ether - 1.125 ether);
        assertEq(token.balanceOf(settler), 0, "reward clipped to zero: reserve equals the remainder");
        assertEq(weth.balanceOf(settler), 0);
        assertEq(weth.balanceOf(address(markets)), 0.9 ether, "WETH pool is not a reward source");
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(true), 5);
        deliver(rid, a);
        vm.prank(settler);
        markets.propose(id, a);
        assertEq(token.balanceOf(settler), 0);
        vm.warp(markets.getMarket(id).disputeEnds);
        vm.prank(settler);
        markets.finalize(id);
        m = markets.getMarket(id);
        assertEq(token.balanceOf(settler), 0.25 ether, "terminal action pays from what remains");
        assertEq(m.rewardsPaid, 0.25 ether);
        assertEq(m.returnedBounty, 2.25 ether - 1.125 ether - 0.25 ether);
        assertEq(weth.balanceOf(settler), 0);
        vm.prank(alice);
        assertEq(markets.claim(id), 0.9 ether - 0.0225 ether);
        assertConserved(id, true);
    }

    // ------------------------------------------------------------------ bounty token is a snapshot

    /// @dev If the oracle's asset is WETH when an IMD-collateral market opens, that market's bounty, oracle spend,
    /// rewards and bounty return are in WETH while its stakes, fees and payouts are in IMD. The two ledgers are
    /// then in swapped tokens and still never mix.
    function test_imdCollateralWithWethBountyKeepsLedgersInSwappedTokens() public {
        rotateAsset(address(weth));
        VerdictMarkets.Params memory p = params();
        p.settlerReward = 0.1 ether;
        p.bounty = 2 * PRICE + 5 * p.settlerReward;
        uint256 creatorWeth = weth.balanceOf(creator);
        uint256 id = createWith(p);
        VerdictMarkets.Market memory m = markets.getMarket(id);
        assertEq(address(m.collateral), address(token));
        assertEq(address(m.bountyToken), address(weth));
        assertEq(creatorWeth - weth.balanceOf(creator), 1.5 ether, "bounty pulled in the oracle's asset");
        assertEq(token.balanceOf(address(markets)), 0);
        betAs(id, alice, 1, 100 ether);
        betAs(id, bob, 0, 60 ether);
        assertEq(token.balanceOf(address(markets)), 160 ether);
        assertEq(weth.balanceOf(address(markets)), 1.5 ether);

        vm.warp(m.params.answerFrom);
        vm.prank(settler);
        bytes32 rid = markets.resolve(id, body);
        assertEq(weth.balanceOf(settler), 0.1 ether, "reward in the bounty token");
        assertEq(token.balanceOf(settler), 0);
        assertEq(weth.balanceOf(address(intake)), PRICE, "oracle paid in its asset");
        assertEq(token.balanceOf(address(intake)), 0);
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(false), 5);
        deliver(rid, a);
        vm.prank(settler);
        markets.propose(id, a);
        vm.warp(markets.getMarket(id).disputeEnds);
        uint256 creatorImd = token.balanceOf(creator);
        creatorWeth = weth.balanceOf(creator);
        vm.recordLogs();
        vm.prank(settler);
        markets.finalize(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 count, uint256 total) = transfersTo(logs, address(token), creator);
        assertEq(count, 1);
        assertEq(total, 1.6 ether, "creator fee alone in IMD");
        (count, total) = transfersTo(logs, address(weth), creator);
        assertEq(count, 1);
        m = markets.getMarket(id);
        assertEq(total, m.returnedBounty, "bounty returned in WETH");
        assertEq(m.returnedBounty, 1.5 ether - PRICE - 0.3 ether);
        assertEq(token.balanceOf(creator) - creatorImd, 1.6 ether);
        assertEq(weth.balanceOf(creator) - creatorWeth, m.returnedBounty);
        assertEq(token.balanceOf(address(burn)), 0.8 ether);
        assertEq(token.balanceOf(treasury), 0.8 ether);
        assertEq(weth.balanceOf(treasury), 0);
        vm.prank(bob);
        assertEq(markets.claim(id), 160 ether - 3.2 ether);
        assertConserved(id, true);
        assertEq(token.balanceOf(address(markets)), 0);
        assertEq(weth.balanceOf(address(markets)), 0);
    }

    /// @dev With the asset rotated to WETH, a WETH-collateral market has collateral == bounty token; the creator
    /// receives fee plus bounty in a single WETH transfer and no IMD moves anywhere.
    function test_wethCollateralWithWethBountyPaysCreatorOnce() public {
        rotateAsset(address(weth));
        uint256 id = createWith(wethParams(0));
        VerdictMarkets.Market memory m = markets.getMarket(id);
        assertEq(address(m.collateral), address(weth));
        assertEq(address(m.bountyToken), address(weth));
        betAs(id, alice, 1, 0.5 ether);
        primary(id, true);
        vm.warp(markets.getMarket(id).disputeEnds);
        vm.recordLogs();
        markets.finalize(id);
        (uint256 count, uint256 total) = transfersTo(vm.getRecordedLogs(), address(weth), creator);
        assertEq(count, 1, "same-token path pays once");
        assertEq(total, 0.0075 ether + PRICE);
        assertEq(token.balanceOf(address(markets)), 0);
        assertEq(token.balanceOf(address(intake)), 0);
        vm.prank(alice);
        markets.claim(id);
        assertConserved(id, true);
        assertEq(weth.balanceOf(address(markets)), 0);
    }

    /// @dev Rotating the asset away mid-dispute blocks escalation but not finalization, the settler's reward or
    /// the bounty return, all of which stay in the token recorded at creation.
    function test_assetRotationAfterProposalStillFinalizesInRecordedToken() public {
        uint256 id = createWith(wethParams(0.1 ether));
        betAs(id, alice, 1, 0.4 ether);
        betAs(id, bob, 0, 0.4 ether);
        vm.warp(markets.getMarket(id).params.answerFrom);
        vm.prank(settler);
        bytes32 rid = markets.resolve(id, body);
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(true), 5);
        deliver(rid, a);
        vm.prank(settler);
        markets.propose(id, a);
        rotateAsset(address(weth));
        vm.expectRevert(VerdictMarkets.OracleAssetMismatch.selector);
        markets.escalate(id, escalationBody);
        vm.warp(markets.getMarket(id).disputeEnds);
        uint256 creatorImd = token.balanceOf(creator);
        vm.prank(settler);
        markets.finalize(id);
        assertEq(token.balanceOf(settler), 0.3 ether, "reward still in IMD");
        assertEq(weth.balanceOf(settler), 0);
        VerdictMarkets.Market memory m = markets.getMarket(id);
        assertEq(token.balanceOf(creator) - creatorImd, m.returnedBounty, "bounty still returned in IMD");
        vm.prank(alice);
        assertEq(markets.claim(id), 0.78 ether);
        assertConserved(id, true);
    }

    /// @dev An oracle asset rotated to a token nobody holds strands new markets but not existing ones' refunds.
    function test_assetRotationToUnheldTokenCannotOpenMarketsOrTouchExistingCustody() public {
        uint256 id = createWith(wethParams(0));
        betAs(id, alice, 1, 0.2 ether);
        MockIMD stranger = new MockIMD();
        rotateAsset(address(stranger));
        vm.prank(creator);
        vm.expectRevert();
        markets.createMarket(wethParams(0), body, escalationBody, "", 0);
        assertEq(markets.marketCount(), 1);
        vm.warp(markets.getMarket(id).params.answerFrom);
        vm.expectRevert(VerdictMarkets.OracleAssetMismatch.selector);
        markets.resolve(id, body);
        vm.warp(markets.getMarket(id).params.voidAfter);
        uint256 creatorImd = token.balanceOf(creator);
        markets.voidMarket(id);
        assertEq(token.balanceOf(creator) - creatorImd, 2 * PRICE);
        vm.prank(alice);
        assertEq(markets.claim(id), 0.2 ether);
        assertEq(weth.balanceOf(address(markets)), 0);
        assertEq(token.balanceOf(address(markets)), 0);
        assertEq(stranger.balanceOf(address(markets)), 0);
    }

    // ------------------------------------------------------------------ labels and guardian powers

    /// @dev agentId is a free label: two callers may use the same one, and nothing about it changes settlement.
    function test_agentIdIsAnUnverifiedLabel() public {
        uint256 id = createWith(wethParams(0));
        vm.expectEmit(true, true, true, true, address(markets));
        emit VerdictMarkets.BetPlaced(id, alice, 1, 0.1 ether, type(uint256).max);
        vm.prank(alice);
        markets.bet(id, 1, 0.1 ether, type(uint256).max);
        vm.expectEmit(true, true, true, true, address(markets));
        emit VerdictMarkets.BetPlaced(id, bob, 1, 0.1 ether, type(uint256).max);
        vm.prank(bob);
        markets.bet(id, 1, 0.1 ether, type(uint256).max);
        assertEq(markets.stakes(id, alice, 1), 0.1 ether);
        assertEq(markets.stakes(id, bob, 1), 0.1 ether);
    }

    /// @dev The guardian's powers do not reach the slots: pausing, allowlisting, handing over and renouncing
    /// leave every slot field as constructed, and no selector exists to change them.
    function test_guardianCannotAlterSlots() public {
        VerdictMarkets.Collateral memory before0 = markets.collateralConfig(0);
        VerdictMarkets.Collateral memory before1 = markets.collateralConfig(1);
        markets.pause();
        markets.unpause();
        markets.disableAllowlist();
        markets.transferGuardian(alice);
        vm.prank(alice);
        markets.acceptGuardian();
        vm.prank(alice);
        markets.renounceGuardian();
        assertEq(markets.guardian(), address(0));
        assertEq(keccak256(abi.encode(before0)), keccak256(abi.encode(markets.collateralConfig(0))));
        assertEq(keccak256(abi.encode(before1)), keccak256(abi.encode(markets.collateralConfig(1))));
        // Plausible mutators do not exist on the contract: every such call falls through to no function.
        string[4] memory names = ["setCollateral", "setCollateralConfig", "setFees", "setMaxPoolPerMarket"];
        for (uint256 i; i < names.length; i++) {
            (bool ok,) = address(markets)
                .call(
                    abi.encodeWithSignature(
                        string.concat(names[i], "(uint8,address,uint16,uint16,uint16,uint256)"),
                        uint8(1),
                        address(token),
                        uint16(0),
                        uint16(0),
                        uint16(0),
                        uint256(1)
                    )
                );
            assertFalse(ok, names[i]);
        }
        // No receive or fallback: native ETH is refused and an unknown selector reverts.
        vm.deal(address(this), 1 ether);
        (bool sent,) = address(markets).call{value: 1 ether}("");
        assertFalse(sent, "native ETH accepted");
        (bool fallbackOk,) = address(markets).call(hex"deadbeef");
        assertFalse(fallbackOk, "fallback accepted");
        assertEq(address(markets).balance, 0);
    }
}
