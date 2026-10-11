// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {TestBase} from "./TestBase.sol";
import {VerdictMarkets} from "src/VerdictMarkets.sol";
import {VerdictOracle} from "src/VerdictOracle.sol";
import {OracleAttestation} from "src/OracleAttestation.sol";

/// @dev Complements the existing conservation campaign: an underpayment can conserve
/// funds, so this handler also checks reward maximality and the actual event/recipient.
contract SettlerRewardSequenceHandler is TestBase {
    bytes32 private constant REWARD_EVENT = keccak256("SettlerRewarded(uint256,address,uint8,uint256)");
    bytes32 private constant TRANSFER_EVENT = keccak256("Transfer(address,address,uint256)");
    uint256 public count;
    uint256 public donations;
    uint256 public rejectedCalls;
    uint256 public clippedRewards;
    uint256 public zeroRewards;
    uint256 public replacements;
    uint256 public retries;
    uint256[5] public successes;
    mapping(uint256 => uint256) public deposited;
    mapping(uint256 => uint256) public bountyDeposited;
    mapping(uint256 => uint256) public exited;
    mapping(uint256 => uint256) public rewarded;
    mapping(uint256 => uint256) public spent;
    mapping(uint256 => uint8) private terminalStatus;
    mapping(uint256 => uint8) private terminalOutcome;
    mapping(uint256 => OracleAttestation.Attestation) private primaryAnswers;
    mapping(uint256 => OracleAttestation.Attestation) private replacementAnswers;

    constructor() {
        setUp();
        for (uint256 i; i < 4; ++i) {
            markets.setCreatorAllowed(wallet(i), true);
        }
        openMarket(0, 0, 0);
        openMarket(1, 0, 1);
        openMarket(0.25 ether, 0, 2);
        openMarket(0.1 ether, PRICE, 3);
        for (uint256 seed; seed < 3; ++seed) {
            wager(seed, 0, 31 ether + 1, true);
            wager(seed, 1, 37 ether + 3, true);
            wager(seed, 2, 41 ether + 7, false);
        }
        wager(3, 0, 43 ether + 11, false); // An unbacked true outcome can be voided.
    }

    function wallet(uint256 index) public view returns (address) {
        address[7] memory accounts = [creator, alice, bob, carol, treasury, address(burn), address(intake)];
        return accounts[index % accounts.length];
    }

    function market(uint256 seed) public view returns (VerdictMarkets.Market memory) {
        return markets.getMarket(seed % count + 1);
    }

    function openMarket(uint256 rewardSeed, uint256 extraSeed, uint256 creatorSeed) public {
        if (count == 8 || markets.paused()) return;
        VerdictMarkets.Params memory p = params();
        p.settlerReward = bound(rewardSeed, 0, markets.maxSettlerReward());
        p.bounty = 2 * oracle.price() + 5 * p.settlerReward + bound(extraSeed, 0, 1 ether);
        uint256 beforeBalance = token.balanceOf(address(markets));
        vm.prank(wallet(creatorSeed % 4));
        uint256 id = markets.createMarket(p, body, escalationBody, "", 0);
        assertEq(id, ++count);
        bountyDeposited[id] = token.balanceOf(address(markets)) - beforeBalance;
        deposited[id] = bountyDeposited[id];
        assertEq(markets.getMarket(id).settlerReward, p.settlerReward);
        assertEq(markets.getMarket(id).params.settlerReward, p.settlerReward);
    }

    function wager(uint256 seed, uint256 actor, uint256 amountSeed, bool side) public {
        uint256 id = seed % count + 1;
        VerdictMarkets.Market memory m = markets.getMarket(id);
        if (markets.paused() || m.status != VerdictMarkets.Status.Open || block.timestamp >= m.params.closeAt) return;
        uint256 room = markets.maxPoolPerMarket(0) - m.pool;
        if (room == 0) return;
        uint256 amount = bound(amountSeed, 1, room);
        uint256 beforeBalance = token.balanceOf(address(markets));
        betAs(id, wallet(actor % 4), side ? 1 : 0, amount);
        deposited[id] += token.balanceOf(address(markets)) - beforeBalance;
    }

    function advance(uint256 secondsSeed) public {
        vm.warp(block.timestamp + bound(secondsSeed, 0, 12 hours));
    }

    function changePrice(uint256 priceSeed) public {
        uint256 price = bound(priceSeed, 1, 4 ether);
        oracle.proposeConfig(VerdictOracle.Config(address(intake), address(token), vm.addr(SIGNER_KEY), ACTION, price));
        oracle.acceptConfig();
    }

    function pauseEntry() public {
        if (markets.paused()) markets.unpause();
        else markets.pause();
    }

    function donate(uint256 amountSeed) public {
        uint256 amount = bound(amountSeed, 1, 1 ether);
        uint256 beforeBalance = token.balanceOf(address(markets));
        token.transfer(address(markets), amount);
        donations += token.balanceOf(address(markets)) - beforeBalance;
    }

    function resolve(uint256 seed, uint256 actor) public {
        uint256 id = seed % count + 1;
        VerdictMarkets.Market memory m = markets.getMarket(id);
        if (
            m.status != VerdictMarkets.Status.Open || block.timestamp < m.params.answerFrom
                || block.timestamp >= m.params.answerUntil || m.asks == 2 || oracle.price() > m.bountyRemaining
        ) return;
        if (
            m.asks == 1
                && (block.timestamp < m.lastPrimaryAsk + 24 hours || !oracle.hasPendingRequest(m.primaryRequests[0]))
        ) return;
        _action(id, actor, 0, abi.encodeCall(markets.resolve, (id, body)), oracle.price());
        if (m.asks == 1) ++retries;
    }

    function deliverAnswer(uint256 seed, bool escalation, bool useRetry, bool side) public {
        uint256 id = seed % count + 1;
        VerdictMarkets.Market memory m = markets.getMarket(id);
        bytes32 rid = escalation ? m.escalationRequest : m.primaryRequests[useRetry ? 1 : 0];
        if (rid == bytes32(0) || intake.attempted(rid)) return;
        if (escalation && (m.status != VerdictMarkets.Status.Provisional || block.timestamp >= m.disputeEnds)) return;
        if (!escalation && block.timestamp > m.params.answerUntil) return;
        OracleAttestation.Attestation memory a = attestation(id, abi.encode(side), escalation ? 10 : 5);
        bytes32 beforeState = keccak256(abi.encode(m));
        uint256 held = token.balanceOf(address(markets));
        deliver(rid, a);
        assertEq(keccak256(abi.encode(markets.getMarket(id))), beforeState, "callback changed a market");
        assertEq(token.balanceOf(address(markets)), held, "delivery paid a reward");
        if (escalation) replacementAnswers[id] = a;
        else primaryAnswers[id] = a;
    }

    function propose(uint256 seed, uint256 actor, bool replacement) public {
        uint256 id = seed % count + 1;
        VerdictMarkets.Market memory m = markets.getMarket(id);
        OracleAttestation.Attestation memory a = replacement ? replacementAnswers[id] : primaryAnswers[id];
        if (a.requestId == bytes32(0)) return;
        if (replacement) {
            if (m.status != VerdictMarkets.Status.Provisional || m.escalated || block.timestamp >= m.disputeEnds) {
                return;
            }
        } else if (m.status != VerdictMarkets.Status.Open || block.timestamp >= m.params.voidAfter) {
            return;
        } else if (oracle.intakeRequestOf(a.requestId) != m.primaryRequests[m.asks - 1]) {
            return; // Only the most recent paid primary ask can establish the outcome.
        }
        _action(id, actor, 1, abi.encodeCall(markets.propose, (id, a)), 0);
        if (replacement) ++replacements;
    }

    function escalate(uint256 seed, uint256 actor) public {
        uint256 id = seed % count + 1;
        VerdictMarkets.Market memory m = markets.getMarket(id);
        if (
            m.status != VerdictMarkets.Status.Provisional || m.escalated || m.escalationAsked || m.asks == 2
                || block.timestamp >= m.params.answerUntil || block.timestamp >= m.disputeEnds
                || oracle.price() > m.bountyRemaining
        ) return;
        _action(id, actor, 4, abi.encodeCall(markets.escalate, (id, escalationBody)), oracle.price());
    }

    function settle(uint256 seed, uint256 actor) public {
        uint256 id = seed % count + 1;
        VerdictMarkets.Market memory m = markets.getMarket(id);
        if (m.status == VerdictMarkets.Status.Open && block.timestamp >= m.params.voidAfter) {
            _action(id, actor, 3, abi.encodeCall(markets.voidMarket, (id)), 0);
        } else if (m.status == VerdictMarkets.Status.Provisional && block.timestamp >= m.disputeEnds) {
            if (markets.outcomePool(id, m.outcome) == 0) {
                _action(id, actor, 3, abi.encodeCall(markets.voidMarket, (id)), 0);
            } else {
                _action(id, actor, 2, abi.encodeCall(markets.finalize, (id)), 0);
            }
        }
    }

    function collect(uint256 seed, uint256 actor) public {
        uint256 id = seed % count + 1;
        address recipient = wallet(actor % 4);
        VerdictMarkets.Market memory m = markets.getMarket(id);
        if (markets.claimed(id, recipient)) return;
        if (m.status == VerdictMarkets.Status.Finalized) {
            if (markets.stakes(id, recipient, m.outcome) == 0) return;
        } else if (m.status == VerdictMarkets.Status.Voided) {
            if (markets.totalStake(id, recipient) == 0) return;
        } else {
            return;
        }
        uint256 beforeBalance = token.balanceOf(recipient);
        uint256 held = token.balanceOf(address(markets));
        vm.recordLogs();
        vm.prank(recipient);
        uint256 payout = markets.claim(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _rewardLog(logs, id, recipient, 5, false);
        assertEq(token.balanceOf(recipient) - beforeBalance, payout);
        assertEq(held - token.balanceOf(address(markets)), payout);
        assertEq(markets.getMarket(id).rewardsPaid, m.rewardsPaid, "claim earned an extra reward");
        if (m.status == VerdictMarkets.Status.Voided) assertEq(payout, markets.totalStake(id, recipient));
        exited[id] += payout;
    }

    /// @dev Invalid calls run in arbitrary states, checking atomicity instead of
    /// filtering all failure paths out of the invariant campaign.
    function probeRejected(uint256 seed, uint256 actor, uint8 choice) public {
        uint256 id = seed % count + 1;
        VerdictMarkets.Market memory m = markets.getMarket(id);
        bytes memory payload;
        uint256 mode = choice % 6;
        if (mode == 0) {
            payload = abi.encodeCall(markets.resolve, (id, bytes("wrong committed body")));
        } else if (mode == 1) {
            payload = abi.encodeCall(markets.escalate, (id, bytes("wrong escalation body")));
        } else if (mode == 2) {
            OracleAttestation.Attestation memory a = attestation(id, abi.encode(true), 10);
            payload = abi.encodeCall(markets.propose, (id, a)); // Never delivered.
        } else if (mode == 3) {
            payload = abi.encodeCall(markets.bet, (id, m.outcomes, 1, 0));
        } else if (mode == 4) {
            if (
                m.status == VerdictMarkets.Status.Provisional && block.timestamp >= m.disputeEnds
                    && markets.outcomePool(id, m.outcome) != 0
            ) return;
            payload = abi.encodeCall(markets.finalize, (id));
        } else {
            if (m.status == VerdictMarkets.Status.Open && block.timestamp >= m.params.voidAfter) return;
            if (
                m.status == VerdictMarkets.Status.Provisional && block.timestamp >= m.disputeEnds
                    && markets.outcomePool(id, m.outcome) == 0
            ) return;
            payload = abi.encodeCall(markets.voidMarket, (id));
        }
        bytes32 stateBefore = keccak256(abi.encode(m));
        uint256[7] memory balancesBefore = _balances();
        uint256 held = token.balanceOf(address(markets));
        uint256 nonce = intake.nonce();
        vm.prank(wallet(actor % 5));
        (bool ok,) = address(markets).call(payload);
        assertFalse(ok, "invalid operation succeeded");
        assertEq(keccak256(abi.encode(markets.getMarket(id))), stateBefore, "revert changed market accounting");
        assertEq(keccak256(abi.encode(_balances())), keccak256(abi.encode(balancesBefore)), "revert moved funds");
        assertEq(token.balanceOf(address(markets)), held);
        assertEq(intake.nonce(), nonce);
        ++rejectedCalls;
    }

    function _action(uint256 id, uint256 actor, uint8 action, bytes memory payload, uint256 cost) private {
        address caller = wallet(actor % 5); // Creators, bettors and the treasury can all settle.
        VerdictMarkets.Market memory beforeMarket = markets.getMarket(id);
        uint256[7] memory balancesBefore = _balances();
        uint256 held = token.balanceOf(address(markets));
        bytes32[] memory otherMarkets = new bytes32[](count + 1);
        for (uint256 i = 1; i <= count; ++i) {
            if (i != id) otherMarkets[i] = keccak256(abi.encode(markets.getMarket(i)));
        }
        vm.recordLogs();
        vm.prank(caller);
        (bool ok, bytes memory reason) = address(markets).call(payload);
        if (!ok) {
            assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        VerdictMarkets.Market memory m = markets.getMarket(id);
        bool terminal = action == 2 || action == 3;
        uint256 paid = _rewardLog(logs, id, caller, action, action < 4 && beforeMarket.settlerReward != 0);
        uint256 available = beforeMarket.bountyRemaining - cost;
        assertLe(paid, beforeMarket.settlerReward, "reward exceeds agreement");
        assertLe(paid, available, "reward spends bettor deposits");
        assertEq(m.rewardsPaid, beforeMarket.rewardsPaid + paid);
        assertEq(m.oracleSpend, beforeMarket.oracleSpend + cost);
        assertEq(m.asks, beforeMarket.asks + ((action == 0 || action == 4) ? 1 : 0));
        assertEq(m.pool, beforeMarket.pool, "settlement changed bettor principal");
        if (terminal) {
            assertTrue(paid == beforeMarket.settlerReward || paid == available, "terminal reward was not maximal");
            assertEq(m.bountyRemaining, 0);
            assertEq(m.returnedBounty, available - paid, "reward must precede bounty release");
            terminalStatus[id] = uint8(m.status);
            terminalOutcome[id] = m.outcome;
            if (paid != 0) _assertFirstTransfer(logs, caller, paid);
        } else {
            assertEq(m.bountyRemaining, available - paid);
            if (action < 2) {
                uint256 reserve = uint256(2 - m.asks) * oracle.price();
                if (available <= reserve) {
                    assertEq(paid, 0, "reward consumed oracle reserve");
                } else {
                    assertGe(m.bountyRemaining, reserve, "remaining ask is no longer funded");
                    assertTrue(paid == beforeMarket.settlerReward || m.bountyRemaining == reserve, "reward underpaid");
                }
            } else {
                assertEq(paid, 0, "escalation was rewarded");
            }
        }
        if (action < 4 && beforeMarket.settlerReward != 0) {
            if (paid == 0) ++zeroRewards;
            else if (paid < beforeMarket.settlerReward) ++clippedRewards;
        }
        uint256 creatorFee = action == 2 ? beforeMarket.pool * 100 / 10_000 : 0;
        uint256 burnFee = action == 2 ? beforeMarket.pool * 50 / 10_000 : 0;
        uint256 treasuryFee = action == 2 ? beforeMarket.pool * 50 / 10_000 : 0;
        for (uint256 i; i < 7; ++i) {
            address recipient = wallet(i);
            uint256 credit = recipient == caller ? paid : 0;
            if (terminal && recipient == beforeMarket.creator) credit += available - paid + creatorFee;
            if (i == 4) credit += treasuryFee;
            if (i == 5) credit += burnFee;
            if (i == 6) credit += cost;
            assertEq(token.balanceOf(recipient), balancesBefore[i] + credit, "wrong reward/fee/bounty recipient");
        }
        assertEq(m.fees, beforeMarket.fees + creatorFee + burnFee + treasuryFee);
        if (action == 2) assertEq(m.remainingPayout, beforeMarket.pool - creatorFee - burnFee - treasuryFee);
        rewarded[id] += paid;
        spent[id] += token.balanceOf(address(intake)) - balancesBefore[6];
        exited[id] += held - token.balanceOf(address(markets));
        ++successes[action];
        for (uint256 i = 1; i <= count; ++i) {
            if (i != id) assertEq(keccak256(abi.encode(markets.getMarket(i))), otherMarkets[i], "cross-market write");
        }
    }

    function _balances() private view returns (uint256[7] memory balances) {
        for (uint256 i; i < 7; ++i) {
            balances[i] = token.balanceOf(wallet(i));
        }
    }

    function _rewardLog(Vm.Log[] memory logs, uint256 id, address caller, uint8 action, bool expected)
        private
        view
        returns (uint256 paid)
    {
        uint256 matches;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(markets) || logs[i].topics.length == 0 || logs[i].topics[0] != REWARD_EVENT) continue;
            ++matches;
            assertEq(logs[i].topics.length, 3, "indexed reward fields");
            assertEq(logs[i].topics[1], bytes32(id));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(caller))));
            (uint8 emittedAction, uint256 amount) = abi.decode(logs[i].data, (uint8, uint256));
            assertEq(emittedAction, action);
            paid = amount;
        }
        assertEq(matches, expected ? 1 : 0, "each accepted reward must emit exactly once");
    }

    function _assertFirstTransfer(Vm.Log[] memory logs, address caller, uint256 paid) private view {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(token) || logs[i].topics.length != 3 || logs[i].topics[0] != TRANSFER_EVENT) continue;
            if (logs[i].topics[1] != bytes32(uint256(uint160(address(markets))))) continue;
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(caller))), "settler must be paid first");
            assertEq(abi.decode(logs[i].data, (uint256)), paid, "reward event differs from transfer");
            return;
        }
        assertTrue(false, "reward event has no token transfer");
    }

    function assertAccounting() public view {
        uint256 liability;
        uint256 intakeReceipts;
        for (uint256 id = 1; id <= count; ++id) {
            VerdictMarkets.Market memory m = markets.getMarket(id);
            assertEq(m.params.bounty, bountyDeposited[id]);
            assertEq(m.pool + m.params.bounty, deposited[id]);
            assertEq(m.rewardsPaid, rewarded[id]);
            assertEq(m.oracleSpend, spent[id]);
            assertEq(m.paidOut + m.refunded + m.fees + m.oracleSpend + m.rewardsPaid + m.returnedBounty, exited[id]);
            assertEq(m.bountyRemaining + m.oracleSpend + m.rewardsPaid + m.returnedBounty, bountyDeposited[id]);
            assertLe(m.asks, 2);
            assertLe(m.pool, markets.maxPoolPerMarket(0));
            assertLe(m.rewardsPaid, 5 * m.settlerReward);
            if (terminalStatus[id] != 0) {
                assertEq(uint8(m.status), terminalStatus[id], "terminal market reopened");
                assertEq(m.outcome, terminalOutcome[id], "terminal outcome changed");
            }
            liability += deposited[id] - exited[id];
            intakeReceipts += spent[id];
        }
        assertEq(token.balanceOf(address(markets)), liability + donations, "escrow differs from independent transfers");
        assertEq(token.balanceOf(address(intake)), intakeReceipts);
        assertEq(token.balanceOf(address(oracle)), 0);
        assertEq(token.allowance(address(markets), address(oracle)), 0);
        assertEq(token.allowance(address(oracle), address(intake)), 0);
    }

    function drain() public {
        vm.warp(block.timestamp + 30 days);
        for (uint256 seed; seed < count; ++seed) {
            settle(seed, seed);
            for (uint256 actor; actor < 4; ++actor) {
                collect(seed, (seed + actor) % 4);
            }
            assertEq(deposited[seed + 1], exited[seed + 1], "market did not drain");
        }
        assertAccounting();
        assertEq(token.balanceOf(address(markets)), donations, "payout or bounty dust");
    }
}

contract SettlerRewardSequenceTest is Test {
    SettlerRewardSequenceHandler private handler;

    function setUp() public {
        handler = new SettlerRewardSequenceHandler();
        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = handler.openMarket.selector;
        selectors[1] = handler.wager.selector;
        selectors[2] = handler.advance.selector;
        selectors[3] = handler.changePrice.selector;
        selectors[4] = handler.pauseEntry.selector;
        selectors[5] = handler.donate.selector;
        selectors[6] = handler.resolve.selector;
        selectors[7] = handler.deliverAnswer.selector;
        selectors[8] = handler.propose.selector;
        selectors[9] = handler.escalate.selector;
        selectors[10] = handler.settle.selector;
        selectors[11] = handler.collect.selector;
        selectors[12] = handler.probeRejected.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 80
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_rewardsAreMaximalAndEscrowIsConserved() public view {
        handler.assertAccounting();
    }

    function afterInvariant() public {
        handler.drain();
    }

    function test_handlerReachesRetryReplacementClippingAndBothTerminalPaths() public {
        handler.advance(1 hours);
        handler.resolve(0, 0); // Zero reward, caller is also creator and bettor.
        handler.resolve(1, 1); // One wei reward.
        handler.resolve(2, 2); // Maximum configured reward.
        handler.resolve(3, 3);
        handler.deliverAnswer(0, false, false, true);
        handler.propose(0, 4, false);
        handler.deliverAnswer(2, false, false, true);
        // Market 3 has 1.5 IMD left. Reserving 1.4 clips a 0.25 reward to 0.1.
        handler.changePrice(1.4 ether);
        handler.propose(2, 0, false);
        handler.escalate(2, 4);
        handler.deliverAnswer(2, true, false, false);
        handler.propose(2, 2, true); // Empty bounty: successful replacement earns zero.
        handler.changePrice(0.5 ether);
        handler.deliverAnswer(3, false, false, true);
        handler.propose(3, 3, false); // True has no stake, so terminal action is void.
        handler.pauseEntry();
        handler.advance(12 hours);
        handler.advance(12 hours);
        handler.resolve(1, 4); // Retry pays a different caller.
        handler.deliverAnswer(1, false, true, true);
        handler.propose(1, 1, false);
        handler.settle(0, 0);
        handler.settle(2, 2);
        handler.settle(3, 3);
        for (uint8 mode; mode < 6; ++mode) {
            handler.probeRejected(2, mode, mode);
        }
        handler.donate(17);
        handler.drain();
        assertEq(handler.retries(), 1);
        assertEq(handler.replacements(), 1);
        assertEq(handler.clippedRewards(), 1);
        assertGe(handler.zeroRewards(), 2);
        assertEq(handler.successes(0), 5);
        assertEq(handler.successes(1), 5);
        assertEq(handler.successes(2), 3);
        assertEq(handler.successes(3), 1);
        assertEq(handler.successes(4), 1);
        assertEq(handler.rejectedCalls(), 6);
    }
}
