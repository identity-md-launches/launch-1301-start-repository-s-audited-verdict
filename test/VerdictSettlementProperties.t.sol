// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./TestBase.sol";
import {VerdictMarkets} from "src/VerdictMarkets.sol";
import {OracleAttestation} from "src/OracleAttestation.sol";

contract VerdictSettlementPropertiesTest is TestBase {
    function replaceMarkets(uint16 creatorBps, uint16 burnBps, uint16 treasuryBps, uint256 cap) internal {
        markets = newMarkets(address(oracle), creatorBps, burnBps, treasuryBps, cap, 0.25 ether);
        markets.setCreatorAllowed(creator, true);
        address[4] memory users = [creator, alice, bob, carol];
        for (uint256 i; i < users.length; ++i) {
            vm.prank(users[i]);
            token.approve(address(markets), type(uint256).max);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_feeSplitsAndRationalPayoutBoundsInEveryClaimOrder(
        uint256 seed,
        uint16 creatorSeed,
        uint16 burnSeed,
        uint16 treasurySeed,
        uint8 order
    ) public {
        uint16 creatorBps = uint16(bound(creatorSeed, 0, 500));
        uint16 burnBps = uint16(bound(burnSeed, 0, 500 - creatorBps));
        uint16 treasuryBps = uint16(bound(treasurySeed, 0, 500 - creatorBps - burnBps));
        replaceMarkets(creatorBps, burnBps, treasuryBps, 500 ether);
        uint256 id = create();
        address[3] memory winners = [alice, bob, carol];
        uint256[3] memory stakes;
        uint256 winningPool;
        for (uint256 i; i < 3; ++i) {
            stakes[i] = bound(uint256(keccak256(abi.encode(seed, i))), 1, 100 ether);
            betAs(id, winners[i], 1, stakes[i]);
            winningPool += stakes[i];
        }
        uint256 losingStake = bound(seed, 1, 100 ether);
        betAs(id, creator, 0, losingStake);
        uint256 pool = winningPool + losingStake;
        uint256 creatorBefore = token.balanceOf(creator);
        primary(id, true);
        vm.warp(markets.getMarket(id).disputeEnds);
        markets.finalize(id);
        uint256 creatorFee = pool * creatorBps / 10_000;
        uint256 burnFee = pool * burnBps / 10_000;
        uint256 treasuryFee = pool * treasuryBps / 10_000;
        assertEq(token.balanceOf(creator) - creatorBefore, creatorFee + PRICE);
        assertEq(token.balanceOf(address(burn)), burnFee);
        assertEq(token.balanceOf(treasury), treasuryFee);
        uint256 netPool = pool - creatorFee - burnFee - treasuryFee;
        uint256 paid;
        uint256[3] memory indices = [uint256(0), 1, 2];
        uint256 permutation = order;
        for (uint256 remaining = 3; remaining > 0; --remaining) {
            uint256 index = permutation % remaining;
            permutation /= remaining;
            uint256 actor = indices[index];
            indices[index] = indices[remaining - 1];
            uint256 beforeBalance = token.balanceOf(winners[actor]);
            vm.prank(winners[actor]);
            uint256 amount = markets.claim(id);
            assertEq(token.balanceOf(winners[actor]) - beforeBalance, amount);
            if (remaining == 1) {
                assertEq(amount, netPool - paid, "last claimant did not take exact remainder");
            } else {
                // Characterize floor division by its inequalities, independently
                // of the production mulDiv implementation.
                assertLe(amount * winningPool, stakes[actor] * netPool);
                assertGt((amount + 1) * winningPool, stakes[actor] * netPool);
            }
            paid += amount;
            vm.prank(winners[actor]);
            vm.expectRevert(VerdictMarkets.NothingToClaim.selector);
            markets.claim(id);
        }
        assertEq(paid, netPool);
        assertEq(token.balanceOf(address(markets)), 0);
        assertConserved(id, true);
    }

    function test_oneWeiWinnerMayRoundToZeroButLastClaimStillDrainsExactly() public {
        replaceMarkets(500, 0, 0, 500 ether);
        uint256 id = create();
        betAs(id, alice, 1, 1);
        betAs(id, bob, 1, 100);
        primary(id, true);
        vm.warp(markets.getMarket(id).disputeEnds);
        markets.finalize(id);
        assertEq(markets.getMarket(id).fees, 5);
        vm.expectEmit(true, true, false, true, address(markets));
        emit VerdictMarkets.Claimed(id, alice, 0, false);
        vm.prank(alice);
        assertEq(markets.claim(id), 0);
        assertTrue(markets.claimed(id, alice));
        assertEq(markets.getMarket(id).remainingWinningStake, 100);
        vm.prank(bob);
        assertEq(markets.claim(id), 96);
        assertEq(markets.getMarket(id).remainingPayout, 0);
        assertEq(markets.getMarket(id).remainingWinningStake, 0);
        assertConserved(id, true);
    }

    function test_oneWeiLastWinnerReceivesTheRoundingRemainder() public {
        replaceMarkets(500, 0, 0, 500 ether);
        uint256 id = create();
        betAs(id, alice, 1, 1);
        betAs(id, bob, 1, 100);
        primary(id, true);
        vm.warp(markets.getMarket(id).disputeEnds);
        markets.finalize(id);
        vm.prank(bob);
        assertEq(markets.claim(id), 95);
        vm.prank(alice);
        assertEq(markets.claim(id), 1);
        assertConserved(id, true);
        assertEq(token.balanceOf(address(markets)), 0);
    }

    function test_payoutUsesFullPrecisionWhenIntermediateStakeTimesPoolOverflows256Bits() public {
        replaceMarkets(0, 0, 0, type(uint256).max);
        uint256 unit = uint256(1) << 200;
        token.mint(alice, unit);
        token.mint(bob, 2 * unit);
        token.mint(carol, 4 * unit);
        uint256 id = create();
        betAs(id, alice, 1, unit);
        betAs(id, bob, 1, 2 * unit);
        betAs(id, carol, 0, 4 * unit);
        primary(id, true);
        vm.warp(markets.getMarket(id).disputeEnds);
        markets.finalize(id);
        // Cancel the common unit first. Multiplying stake * pool directly would overflow.
        uint256 alicePayout = 7 * unit / 3;
        uint256 beforeBalance = token.balanceOf(alice);
        vm.prank(alice);
        assertEq(markets.claim(id), alicePayout);
        assertEq(token.balanceOf(alice) - beforeBalance, alicePayout);
        vm.prank(bob);
        assertEq(markets.claim(id), 7 * unit - alicePayout);
        assertConserved(id, true);
        assertEq(token.balanceOf(address(markets)), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_numericOutcomeSatisfiesItsHalfOpenInterval(
        uint128 first,
        uint96 spacing,
        uint256 valueSeed,
        uint8 lengthSeed
    ) public {
        VerdictMarkets.Params memory p = params();
        p.answerType = 3;
        uint256 length = bound(lengthSeed, 1, 7);
        uint256 width = uint256(spacing) + 1;
        // The revision forbids an unreachable first bucket; zero-bound rejection
        // is covered separately in RevisionRegressionTest.
        uint256 firstBound = bound(first, 1, type(uint128).max);
        p.bounds = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            p.bounds[i] = firstBound + i * width;
        }
        uint256 value = bound(valueSeed, 0, p.bounds[length - 1] + width);
        uint256 id = createWith(p);
        vm.warp(p.answerFrom);
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(value), 5);
        deliver(markets.resolve(id, body), a);
        markets.propose(id, a);
        uint256 outcome = markets.getMarket(id).outcome;
        assertLe(outcome, length);
        if (outcome > 0) assertGe(value, p.bounds[outcome - 1], "value fell below bucket's inclusive lower bound");
        if (outcome < length) assertLt(value, p.bounds[outcome], "value reached bucket's exclusive upper bound");
    }

    function test_malformedListsCannotChangeAnAuthenticatedMarketsOutcome() public {
        for (uint8 answerType = 4; answerType <= 5; ++answerType) {
            VerdictMarkets.Params memory p = params();
            p.answerType = answerType;
            p.keys = new bytes32[](1);
            p.keys[0] = bytes32(uint256(1));
            uint256 id = createWith(p);
            vm.warp(p.answerFrom);
            bytes memory malformed = answerType == 4
                ? abi.encode(uint256(32), uint256(1), uint256(1) << 160)  // Noncanonical address word.
                : abi.encode(uint256(32), uint256(2), bytes32(uint256(1))); // Missing second list element.
            OracleAttestation.Attestation memory a = attestation(id, malformed, 5);
            deliver(markets.resolve(id, body), a);
            bytes32 beforeState = keccak256(abi.encode(markets.getMarket(id)));
            vm.expectRevert();
            markets.propose(id, a);
            assertEq(keccak256(abi.encode(markets.getMarket(id))), beforeState);
            vm.warp(p.voidAfter);
            markets.voidMarket(id);
            assertConserved(id, true);
        }
    }

    function test_settlementEventsDescribeWholePoolFeesAndUnspentBounty() public {
        uint256 id = create();
        betAs(id, alice, 1, 101);
        betAs(id, bob, 0, 902);
        primary(id, true);
        vm.warp(markets.getMarket(id).disputeEnds);
        vm.expectEmit(true, true, false, true, address(markets));
        emit VerdictMarkets.BountyReturned(id, creator, PRICE);
        vm.expectEmit(true, false, false, true, address(markets));
        emit VerdictMarkets.Finalized(id, 1, 10, 5, 5);
        markets.finalize(id);
        vm.expectEmit(true, true, false, true, address(markets));
        emit VerdictMarkets.Claimed(id, alice, 983, false);
        vm.prank(alice);
        assertEq(markets.claim(id), 983);
        assertConserved(id, true);
    }
}
