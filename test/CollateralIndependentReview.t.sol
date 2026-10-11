// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {TestBase} from "./TestBase.sol";
import {VerdictMarkets} from "../src/VerdictMarkets.sol";
import {VerdictOracle} from "../src/VerdictOracle.sol";

/// @dev Reviewer-authored probes of the two-collateral adaptation, written after the implementation and
/// its own tests, against the attack surface a second token adds: reentrancy through the collateral token,
/// lying tokens, cross-ledger leakage, and the payment paths that differ between same and distinct tokens.
contract CollateralIndependentReviewTest is TestBase {
    bytes32 internal constant TRANSFER = keccak256("Transfer(address,address,uint256)");

    function wethMarket(uint256 reward) internal returns (uint256 id) {
        VerdictMarkets.Params memory p = params();
        p.collateralId = 1;
        p.settlerReward = reward;
        p.bounty = 2 * PRICE + 5 * reward;
        id = createWith(p);
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

    /// @dev A WETH double that calls back into Markets during the claim payout cannot bet, claim or settle again.
    function test_wethCallbackDuringClaimCannotReenter() public {
        uint256 id = wethMarket(0);
        betAs(id, alice, 1, 0.4 ether);
        betAs(id, bob, 0, 0.4 ether);
        primary(id, true);
        vm.warp(markets.getMarket(id).disputeEnds);
        markets.finalize(id);
        weth.setHook(address(markets), abi.encodeCall(markets.claim, (id)));
        vm.prank(alice);
        uint256 paid = markets.claim(id);
        assertFalse(weth.hookSuccess(), "reentrant claim succeeded");
        assertEq(paid, 0.78 ether);
        assertEq(markets.getMarket(id).paidOut, 0.78 ether);
        assertEq(markets.getMarket(id).remainingPayout, 0);
        weth.setHook(address(0), "");
        vm.prank(alice);
        vm.expectRevert(VerdictMarkets.NothingToClaim.selector);
        markets.claim(id);
        assertConserved(id, true);
        assertEq(weth.balanceOf(address(markets)), 0);
    }

    /// @dev A fee-on-transfer collateral credits only what arrived; the cap and the refund use that amount.
    function test_feeOnTransferWethCreditsOnlyReceivedAmount() public {
        uint256 id = wethMarket(0);
        weth.setFee(1000);
        betAs(id, alice, 1, 1 ether); // 0.9 WETH arrives: below the 1 WETH cap.
        assertEq(markets.getMarket(id).pool, 0.9 ether);
        assertEq(markets.stakes(id, alice, 1), 0.9 ether);
        betAs(id, bob, 0, 0.1 ether); // 0.09 arrives, pool 0.99.
        vm.prank(carol);
        vm.expectRevert(VerdictMarkets.PoolCapExceeded.selector);
        markets.bet(id, 0, 0.02 ether, 0); // 0.018 would exceed the remaining 0.01.
        weth.setFee(0);
        vm.warp(markets.getMarket(id).params.voidAfter);
        markets.voidMarket(id);
        vm.prank(alice);
        assertEq(markets.claim(id), 0.9 ether);
        vm.prank(bob);
        assertEq(markets.claim(id), 0.09 ether);
        assertConserved(id, true);
        assertEq(weth.balanceOf(address(markets)), 0);
        assertEq(token.balanceOf(address(markets)), 0);
    }

    /// @dev IMD held for other markets (pools or bounties) and IMD donations are unreachable from a WETH market.
    function test_wethMarketCannotReachIMDHeldForOthers() public {
        uint256 imd = create();
        betAs(imd, alice, 1, 100 ether);
        uint256 id = wethMarket(0.25 ether);
        token.transfer(address(markets), 3 ether); // Donation outside every ledger.
        uint256 imdHeld = token.balanceOf(address(markets));
        betAs(id, bob, 1, 0.5 ether);
        betAs(id, carol, 0, 0.5 ether);
        primary(id, false);
        vm.warp(markets.getMarket(id).disputeEnds);
        markets.finalize(id);
        vm.prank(carol);
        markets.claim(id);
        VerdictMarkets.Market memory m = markets.getMarket(id);
        uint256 imdOut = m.oracleSpend + m.rewardsPaid + m.returnedBounty;
        assertEq(imdOut, m.params.bounty, "WETH market drew more or less IMD than its bounty");
        assertEq(token.balanceOf(address(markets)), imdHeld - imdOut + 0, "IMD for the IMD market or donation moved");
        assertEq(token.balanceOf(address(markets)), 100 ether + 1 ether + 3 ether);
        assertConserved(id, true);
        assertConserved(imd, false);
    }

    /// @dev A price rise after creation blocks a WETH market's ask but never its refunds or bounty return.
    function test_priceRiseBlocksWethAskButRefundsAndBountyReturnStillWork() public {
        uint256 id = wethMarket(0);
        betAs(id, alice, 1, 0.2 ether);
        oracle.proposeConfig(
            VerdictOracle.Config(address(intake), address(token), vm.addr(SIGNER_KEY), ACTION, 2 ether)
        );
        oracle.acceptConfig();
        vm.warp(markets.getMarket(id).params.answerFrom);
        vm.expectRevert(VerdictMarkets.InsufficientBounty.selector);
        markets.resolve(id, body);
        vm.warp(markets.getMarket(id).params.voidAfter);
        uint256 creatorImd = token.balanceOf(creator);
        markets.voidMarket(id);
        assertEq(token.balanceOf(creator) - creatorImd, 1 ether);
        vm.prank(alice);
        assertEq(markets.claim(id), 0.2 ether);
        assertConserved(id, true);
    }

    /// @dev Same-token markets pay the creator fee and bounty in one transfer, as before; distinct tokens pay two.
    function test_creatorPaymentIsOneTransferForIMDAndTwoForWeth() public {
        uint256 imd = create();
        betAs(imd, alice, 1, 100 ether);
        uint256 id = wethMarket(0);
        betAs(id, alice, 1, 0.5 ether);
        primary(imd, true);
        primary(id, true);
        vm.warp(markets.getMarket(id).disputeEnds);
        vm.recordLogs();
        markets.finalize(imd);
        (uint256 count, uint256 total) = transfersTo(vm.getRecordedLogs(), address(token), creator);
        assertEq(count, 1, "IMD market should pay the creator once");
        assertEq(total, 1 ether + PRICE);
        vm.recordLogs();
        markets.finalize(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (count, total) = transfersTo(logs, address(weth), creator);
        assertEq(count, 1);
        assertEq(total, 0.0075 ether);
        (count, total) = transfersTo(logs, address(token), creator);
        assertEq(count, 1);
        assertEq(total, PRICE);
        (count,) = transfersTo(logs, address(weth), address(burn));
        assertEq(count, 0, "zero burn share must not emit a transfer");
    }

    /// @dev The bounty token is fixed at creation: a later oracle asset change cannot redirect the return.
    function test_bountyReturnsInTheTokenItWasPulledInAfterAssetRotation() public {
        uint256 id = wethMarket(0);
        betAs(id, alice, 1, 0.1 ether);
        oracle.proposeConfig(VerdictOracle.Config(address(intake), address(weth), vm.addr(SIGNER_KEY), ACTION, PRICE));
        oracle.acceptConfig();
        vm.warp(markets.getMarket(id).params.voidAfter);
        uint256 creatorImd = token.balanceOf(creator);
        uint256 creatorWeth = weth.balanceOf(creator);
        markets.voidMarket(id);
        assertEq(token.balanceOf(creator) - creatorImd, 1 ether, "bounty must return in IMD");
        assertEq(weth.balanceOf(creator), creatorWeth);
        vm.prank(alice);
        markets.claim(id);
        assertEq(weth.balanceOf(address(markets)), 0);
        assertEq(token.balanceOf(address(markets)), 0);
    }
}
