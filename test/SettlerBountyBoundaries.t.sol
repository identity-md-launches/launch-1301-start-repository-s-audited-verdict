// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./TestBase.sol";
import {VerdictMarkets} from "src/VerdictMarkets.sol";
import {VerdictOracle} from "src/VerdictOracle.sol";
import {VerdictBurnVault} from "src/VerdictBurnVault.sol";
import {MockIMD} from "./mocks/MockIMD.sol";
import {MockIntake} from "./mocks/MockIntake.sol";

/// @dev Fresh zero-supply fixture permits valid bounty amounts up to uint256.max.
/// Real transfers exercise creation and return, including arithmetic at the cap.
contract SettlerBountyBoundariesTest is TestBase {
    function setUp() public override {
        vm.warp(1_800_000_000);
        vm.chainId(11155111);
        token = new MockIMD();
        weth = new MockIMD();
        intake = new MockIntake();
        burn = new VerdictBurnVault();
        oracle =
            new VerdictOracle(address(intake), address(token), vm.addr(SIGNER_KEY), ACTION, PRICE, address(this), 0);
        markets = newMarkets(address(oracle), 100, 50, 50, 500 ether, type(uint256).max);
        markets.setCreatorAllowed(creator, true);
        vm.prank(creator);
        token.approve(address(markets), type(uint256).max);
    }

    function _price(uint256 cost) private {
        oracle.proposeConfig(VerdictOracle.Config(address(intake), address(token), vm.addr(SIGNER_KEY), ACTION, cost));
        oracle.acceptConfig();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_exactMinimumAndOneWeiShortAcrossUint256(uint256 costSeed, uint256 rewardSeed) public {
        uint256 cost = bound(costSeed, 1, type(uint256).max / 2);
        uint256 reward = bound(rewardSeed, 0, (type(uint256).max - 2 * cost) / 5);
        _minimumBoundary(cost, reward);
    }

    function test_maximumPriceWithRepresentableBountyAndZeroReward() public {
        _minimumBoundary(type(uint256).max / 2, 0);
    }

    function test_maximumRepresentableRewardBudget() public {
        _minimumBoundary(1, (type(uint256).max - 2) / 5);
    }

    function test_oneWeiPriceAndOneWeiReward() public {
        _minimumBoundary(1, 1);
    }

    function test_entireUint256SupplyCanBeReturnedWithoutDust() public {
        _price(1);
        VerdictMarkets.Params memory p = params();
        p.settlerReward = (type(uint256).max - 2) / 5;
        p.bounty = type(uint256).max;
        token.mint(creator, p.bounty);
        uint256 id = createWith(p);
        _voidAndCheck(id, p.bounty, p.settlerReward);
    }

    function _minimumBoundary(uint256 cost, uint256 reward) private {
        _price(cost);
        uint256 minimum = 2 * cost + 5 * reward;
        token.mint(creator, minimum);
        VerdictMarkets.Params memory p = params();
        p.settlerReward = reward;
        p.bounty = minimum - 1;
        vm.expectRevert(VerdictMarkets.InsufficientBounty.selector);
        createWith(p);
        assertEq(markets.marketCount(), 0);
        assertEq(token.balanceOf(creator), minimum);
        assertEq(token.balanceOf(address(markets)), 0);
        p.bounty = minimum;
        uint256 id = createWith(p);
        assertEq(markets.getMarket(id).params.bounty, minimum);
        assertEq(markets.getMarket(id).bountyRemaining, minimum);
        assertEq(token.balanceOf(address(markets)), minimum);
        _voidAndCheck(id, minimum, reward);
    }

    function _voidAndCheck(uint256 id, uint256 bounty, uint256 reward) private {
        vm.warp(markets.getMarket(id).params.voidAfter);
        vm.prank(carol);
        markets.voidMarket(id);
        VerdictMarkets.Market memory m = markets.getMarket(id);
        assertEq(m.rewardsPaid, reward);
        assertEq(token.balanceOf(carol), reward);
        assertEq(token.balanceOf(creator), bounty - reward);
        assertEq(m.returnedBounty + m.rewardsPaid, bounty);
        assertEq(m.bountyRemaining, 0);
        assertEq(token.balanceOf(address(markets)), 0);
        vm.expectRevert(VerdictMarkets.WrongState.selector);
        markets.voidMarket(id);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferTaxAcceptsExactReceivedMinimumAndRejectsOneWeiLess(uint96 rewardSeed, uint16 taxSeed)
        public
    {
        uint256 reward = bound(rewardSeed, 0, 0.25 ether);
        uint16 rate = uint16(bound(taxSeed, 1, 1000));
        uint256 minimum = 2 * PRICE + 5 * reward;
        // received(gross) = ceil(gross * (10000-rate) / 10000).
        // This is the smallest gross amount whose received amount reaches minimum.
        uint256 gross = (minimum - 1) * 10_000 / (10_000 - rate) + 1;
        token.mint(creator, gross);
        token.setFee(rate);
        VerdictMarkets.Params memory p = params();
        p.settlerReward = reward;
        p.bounty = gross - 1;
        assertGe(p.bounty, minimum, "must reach the received-bounty check");
        vm.expectRevert(VerdictMarkets.InsufficientBounty.selector);
        createWith(p);
        assertEq(token.totalSupply(), gross, "reverted creation burned transfer tax");
        assertEq(token.balanceOf(creator), gross);
        assertEq(markets.marketCount(), 0);
        p.bounty = gross;
        uint256 id = createWith(p);
        assertEq(token.balanceOf(address(markets)), minimum);
        assertEq(markets.getMarket(id).params.bounty, minimum);
        assertEq(markets.getMarket(id).bountyRemaining, minimum);
        token.setFee(0); // Outgoing payment asset is conventional, as on the launch.
        _voidAndCheck(id, minimum, reward);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_unrepresentableMinimumRevertsBeforeTokenTransfer(uint256 costSeed, uint256 rewardSeed) public {
        uint256 cost = bound(costSeed, 1, type(uint256).max / 2);
        uint256 largestReward = (type(uint256).max - 2 * cost) / 5;
        uint256 reward = bound(rewardSeed, largestReward + 1, type(uint256).max);
        _price(cost);
        VerdictMarkets.Params memory p = params();
        p.bounty = type(uint256).max;
        p.settlerReward = reward;
        // No balance is minted: a missing pre-transfer check would revert with a
        // token balance error (or an arithmetic panic), not InsufficientBounty.
        vm.expectRevert(VerdictMarkets.InsufficientBounty.selector);
        createWith(p);
        assertEq(markets.marketCount(), 0);
        assertEq(token.totalSupply(), 0);
    }
}
