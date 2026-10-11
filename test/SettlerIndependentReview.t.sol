// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TestBase} from "./TestBase.sol";
import {VerdictMarkets} from "../src/VerdictMarkets.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev An independent oracle double changes its quoted price during the paid ask.
/// The real oracle prevents config reentrancy; this probes the market's post-ask reserve directly.
contract ReviewChangingPriceOracle {
    address public immutable asset;
    uint256 public price = 0.5 ether;
    uint256 public nextPrice;

    constructor(address token, uint256 nextPrice_) {
        asset = token;
        nextPrice = nextPrice_;
    }

    function request(bytes calldata) external returns (bytes32) {
        require(IERC20(asset).transferFrom(msg.sender, address(this), price));
        price = nextPrice;
        return keccak256("review ask");
    }
}

/// @dev Observe token callbacks after its balance update, and attempt an otherwise valid reentry.
contract ReviewRewardObserver {
    VerdictMarkets internal immutable markets;
    IERC20 internal immutable token;
    uint256 internal immutable id;
    address internal immutable creator;
    address internal immutable settler;
    bytes internal reentry;
    uint256 public observations;
    bytes32 public firstMarketHash;
    uint256 public firstCreatorBalance;
    uint256 public firstSettlerBalance;
    bool public reentered;
    bytes public lastReason;

    constructor(
        VerdictMarkets markets_,
        IERC20 token_,
        uint256 id_,
        address creator_,
        address settler_,
        bytes memory data
    ) {
        markets = markets_;
        token = token_;
        id = id_;
        creator = creator_;
        settler = settler_;
        reentry = data;
    }

    function observe() external {
        if (observations++ == 0) {
            firstMarketHash = keccak256(abi.encode(markets.getMarket(id)));
            firstCreatorBalance = token.balanceOf(creator);
            firstSettlerBalance = token.balanceOf(settler);
        }
        (bool ok, bytes memory reason) = address(markets).call(reentry);
        reentered = reentered || ok;
        lastReason = reason;
    }
}

contract SettlerIndependentReviewTest is TestBase {
    uint256 internal constant REVIEW_REWARD = 0.1 ether;
    address internal settler = makeAddr("independent settler");

    function reviewCreate() internal returns (uint256 id) {
        VerdictMarkets.Params memory p = params();
        p.settlerReward = REVIEW_REWARD;
        p.bounty = 1.5 ether;
        return createWith(p);
    }

    function stateHash(uint256 id) internal view returns (bytes32) {
        return keccak256(abi.encode(markets.getMarket(id)));
    }

    function preparePrimary(uint256 id) internal returns (OracleAttestation.Attestation memory a) {
        vm.warp(markets.getMarket(id).params.answerFrom);
        vm.prank(settler);
        bytes32 requestId = markets.resolve(id, body);
        a = attestation(id, abi.encode(true), 5);
        deliver(requestId, a);
    }

    function readyToFinalize() internal returns (uint256 id) {
        id = reviewCreate();
        betAs(id, alice, 1, 100 ether);
        betAs(id, bob, 0, 100 ether);
        OracleAttestation.Attestation memory a = preparePrimary(id);
        vm.prank(settler);
        markets.propose(id, a);
        vm.warp(markets.getMarket(id).disputeEnds);
    }

    function refuseTransfer(address recipient, uint256 amount) internal {
        vm.mockCall(address(token), abi.encodeCall(token.transfer, (recipient, amount)), abi.encode(false));
    }

    function test_rewardFailureRollsBackTheWholePaidAskAndAllowsRetry() public {
        uint256 id = reviewCreate();
        betAs(id, alice, 1, 29 ether);
        vm.warp(markets.getMarket(id).params.answerFrom);
        bytes32 beforeState = stateHash(id);
        uint256 held = token.balanceOf(address(markets));
        bytes32 expectedRequest = keccak256(abi.encode(address(intake), uint256(1)));
        refuseTransfer(settler, REVIEW_REWARD);
        vm.expectRevert();
        vm.prank(settler);
        markets.resolve(id, body);

        assertEq(stateHash(id), beforeState);
        assertEq(token.balanceOf(address(markets)), held);
        assertEq(token.balanceOf(address(oracle)), 0);
        assertEq(token.balanceOf(address(intake)), 0);
        assertEq(token.balanceOf(settler), 0);
        assertEq(token.allowance(address(markets), address(oracle)), 0);
        assertEq(token.allowance(address(oracle), address(intake)), 0);
        assertEq(intake.nonce(), 0);
        assertEq(intake.totalSpent(), 0);
        assertFalse(oracle.requested(expectedRequest));
        assertFalse(oracle.hasPendingRequest(expectedRequest));
        (address callbackTarget,) = intake.callbacks(expectedRequest);
        assertEq(callbackTarget, address(0));

        vm.clearMockedCalls();
        vm.prank(settler);
        assertEq(markets.resolve(id, body), expectedRequest);
        assertTrue(oracle.requested(expectedRequest));
        assertTrue(oracle.hasPendingRequest(expectedRequest));
        assertEq(token.balanceOf(settler), REVIEW_REWARD);
        assertEq(token.balanceOf(address(intake)), PRICE);
        assertEq(markets.getMarket(id).rewardsPaid, REVIEW_REWARD);
    }

    function test_failedProposalRewardLeavesStoredAnswerUsableAndPaysOnceOnRetry() public {
        uint256 id = reviewCreate();
        OracleAttestation.Attestation memory a = preparePrimary(id);
        bytes32 beforeState = stateHash(id);
        refuseTransfer(settler, REVIEW_REWARD);
        vm.expectRevert();
        vm.prank(settler);
        markets.propose(id, a);
        assertEq(stateHash(id), beforeState);
        assertEq(oracle.answerOf(a), keccak256(body));
        assertEq(token.balanceOf(settler), REVIEW_REWARD);

        vm.clearMockedCalls();
        vm.prank(settler);
        markets.propose(id, a);
        assertEq(token.balanceOf(settler), 2 * REVIEW_REWARD);
        assertEq(markets.getMarket(id).rewardsPaid, 2 * REVIEW_REWARD);
        vm.expectRevert(VerdictMarkets.InvalidAttestation.selector);
        vm.prank(settler);
        markets.propose(id, a);
        assertEq(token.balanceOf(settler), 2 * REVIEW_REWARD);
    }

    function test_creatorReturnFailureRevertsFinalizeIncludingEarlierReward() public {
        uint256 id = readyToFinalize();
        bytes32 beforeState = stateHash(id);
        uint256 creatorBefore = token.balanceOf(creator);
        uint256 held = token.balanceOf(address(markets));
        // With one ask and three rewards, the creator receives 2 IMD fee + 0.7 IMD bounty.
        refuseTransfer(creator, 2.7 ether);
        vm.expectRevert();
        vm.prank(settler);
        markets.finalize(id);
        assertEq(stateHash(id), beforeState);
        assertEq(token.balanceOf(settler), 2 * REVIEW_REWARD);
        assertEq(token.balanceOf(creator), creatorBefore);
        assertEq(token.balanceOf(address(markets)), held);
        assertEq(token.balanceOf(treasury), 0);
        assertEq(token.balanceOf(address(burn)), 0);

        vm.clearMockedCalls();
        vm.prank(settler);
        markets.finalize(id);
        assertEq(token.balanceOf(settler), 3 * REVIEW_REWARD);
        assertEq(token.balanceOf(creator) - creatorBefore, 2.7 ether);
        vm.prank(alice);
        assertEq(markets.claim(id), 196 ether);
        assertEq(token.balanceOf(address(markets)), 0);
    }

    function test_creatorReturnFailureRevertsVoidIncludingEarlierReward() public {
        uint256 id = reviewCreate();
        betAs(id, alice, 1, 31 ether);
        vm.warp(markets.getMarket(id).params.voidAfter);
        bytes32 beforeState = stateHash(id);
        uint256 creatorBefore = token.balanceOf(creator);
        refuseTransfer(creator, 1.4 ether);
        vm.expectRevert();
        vm.prank(settler);
        markets.voidMarket(id);
        assertEq(stateHash(id), beforeState);
        assertEq(token.balanceOf(settler), 0);
        assertEq(token.balanceOf(creator), creatorBefore);
        assertEq(token.balanceOf(address(markets)), 32.5 ether);

        vm.clearMockedCalls();
        vm.prank(settler);
        markets.voidMarket(id);
        assertEq(token.balanceOf(settler), REVIEW_REWARD);
        assertEq(token.balanceOf(creator) - creatorBefore, 1.4 ether);
        vm.prank(alice);
        assertEq(markets.claim(id), 31 ether);
        assertEq(token.balanceOf(address(markets)), 0);
    }

    function test_positiveTerminalRewardsDoNotDependOnAWorkingOraclePrice() public {
        uint256 finalized = readyToFinalize();
        uint256 voided = reviewCreate();
        vm.warp(markets.getMarket(voided).params.voidAfter);
        vm.mockCallRevert(address(oracle), abi.encodeWithSelector(oracle.price.selector), "price unavailable");
        vm.prank(settler);
        markets.finalize(finalized);
        vm.prank(settler);
        markets.voidMarket(voided);
        assertEq(token.balanceOf(settler), 4 * REVIEW_REWARD);
        assertEq(markets.getMarket(finalized).returnedBounty, 0.7 ether);
        assertEq(markets.getMarket(voided).returnedBounty, 1.4 ether);
        vm.prank(alice);
        assertEq(markets.claim(finalized), 196 ether);
        assertEq(token.balanceOf(address(markets)), 0);
    }

    function test_finalizeRewardCallbackSeesCompleteAccountingAndCannotReenter() public {
        observeTerminalReward(true);
    }

    function test_voidRewardCallbackSeesCompleteAccountingAndCannotReenter() public {
        observeTerminalReward(false);
    }

    function observeTerminalReward(bool finalize) internal {
        uint256 id = finalize ? readyToFinalize() : reviewCreate();
        if (!finalize) vm.warp(markets.getMarket(id).params.voidAfter);
        uint256 settlerBefore = token.balanceOf(settler);
        uint256 creatorBefore = token.balanceOf(creator);
        bytes memory payload =
            finalize ? abi.encodeCall(markets.finalize, (id)) : abi.encodeCall(markets.voidMarket, (id));
        ReviewRewardObserver observer =
            new ReviewRewardObserver(markets, IERC20(address(token)), id, creator, settler, payload);
        token.setHook(address(observer), abi.encodeCall(observer.observe, ()));
        vm.prank(settler);
        (bool ok,) = address(markets).call(payload);
        assertTrue(ok);
        assertEq(observer.observations(), finalize ? 4 : 2);
        assertEq(observer.firstMarketHash(), stateHash(id), "terminal accounting was incomplete during reward transfer");
        assertEq(observer.firstSettlerBalance(), settlerBefore + REVIEW_REWARD, "reward was not first payment");
        assertEq(observer.firstCreatorBalance(), creatorBefore, "creator was paid before the settler");
        assertFalse(observer.reentered());
        assertEq(observer.lastReason(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        token.setHook(address(0), "");
    }

    function testFuzz_rewardRecipientsMayAlsoBeCreatorWinnerOrTreasury(uint8 actors) public {
        address[7] memory recipients = [creator, alice, bob, treasury, settler, address(burn), address(intake)];
        uint256[7] memory expected;
        for (uint256 i; i < recipients.length; ++i) {
            expected[i] = token.balanceOf(recipients[i]);
        }
        uint8[4] memory selectable = [uint8(0), 1, 3, 4];
        uint8 resolveActor = selectable[actors % 4];
        uint8 proposeActor = selectable[(actors / 4) % 4];
        uint8 finalizeActor = selectable[(actors / 16) % 4];
        uint256 id = reviewCreate();
        betAs(id, alice, 1, 101 ether + 3);
        betAs(id, bob, 0, 103 ether + 7);
        vm.warp(markets.getMarket(id).params.answerFrom);
        vm.prank(recipients[resolveActor]);
        bytes32 rid = markets.resolve(id, body);
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(true), 5);
        deliver(rid, a);
        vm.prank(recipients[proposeActor]);
        markets.propose(id, a);
        vm.warp(markets.getMarket(id).disputeEnds);
        vm.prank(recipients[finalizeActor]);
        markets.finalize(id);
        vm.prank(alice);
        markets.claim(id);

        expected[0] = expected[0] - 1.5 ether + 2.04 ether + 0.7 ether;
        expected[1] = expected[1] - (101 ether + 3) + (199.92 ether + 10);
        expected[2] -= 103 ether + 7;
        expected[3] += 1.02 ether;
        expected[5] += 1.02 ether;
        expected[6] += PRICE;
        expected[resolveActor] += REVIEW_REWARD;
        expected[proposeActor] += REVIEW_REWARD;
        expected[finalizeActor] += REVIEW_REWARD;
        for (uint256 i; i < recipients.length; ++i) {
            assertEq(token.balanceOf(recipients[i]), expected[i], "actual balances disagreed with independent ledger");
        }
        assertEq(token.balanceOf(address(markets)), 0);
        assertEq(token.balanceOf(address(oracle)), 0);
        VerdictMarkets.Market memory m = markets.getMarket(id);
        assertEq(m.oracleSpend, PRICE);
        assertEq(m.rewardsPaid, 3 * REVIEW_REWARD);
        assertEq(m.returnedBounty, 0.7 ether);
        assertEq(m.pool + m.params.bounty, m.paidOut + m.fees + m.oracleSpend + m.rewardsPaid + m.returnedBounty);
    }

    function testFuzz_rewardReserveUsesPriceAfterPaidAsk(uint256 nextPrice) public {
        nextPrice = bound(nextPrice, 1, 1.1 ether);
        changingPriceReserve(nextPrice);
    }

    function test_maximumPriceAfterPaidAskSuppressesRewardWithoutReverting() public {
        changingPriceReserve(type(uint256).max);
    }

    function changingPriceReserve(uint256 nextPrice) internal {
        ReviewChangingPriceOracle changingOracle = new ReviewChangingPriceOracle(address(token), nextPrice);
        markets = newMarkets(address(changingOracle), 100, 50, 50, 500 ether, REVIEW_REWARD);
        markets.setCreatorAllowed(creator, true);
        vm.prank(creator);
        token.approve(address(markets), type(uint256).max);
        uint256 id = reviewCreate();
        vm.warp(markets.getMarket(id).params.answerFrom);
        vm.prank(settler);
        markets.resolve(id, body);
        uint256 expectedReward =
            nextPrice >= 1 ether ? 0 : (nextPrice >= 0.9 ether ? 1 ether - nextPrice : REVIEW_REWARD);
        assertEq(token.balanceOf(settler), expectedReward);
        assertEq(token.balanceOf(address(changingOracle)), PRICE);
        assertEq(token.balanceOf(address(markets)), 1 ether - expectedReward);
        assertEq(markets.getMarket(id).bountyRemaining, 1 ether - expectedReward);
        assertEq(markets.getMarket(id).rewardsPaid, expectedReward);
        assertEq(markets.getMarket(id).asks, 1);
    }
}
