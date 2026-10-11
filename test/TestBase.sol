// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VerdictOracle} from "../src/VerdictOracle.sol";
import {VerdictMarkets} from "../src/VerdictMarkets.sol";
import {VerdictBurnVault} from "../src/VerdictBurnVault.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {MockIMD} from "./mocks/MockIMD.sol";
import {MockIntake} from "./mocks/MockIntake.sol";

abstract contract TestBase is Test {
    uint256 internal constant SIGNER_KEY = 0x123456;
    uint256 internal constant PRICE = 0.5 ether;
    bytes32 internal constant ACTION = bytes32("oracle.request@oracle-1");
    bytes32 internal constant QUESTION = keccak256("precisely defined question");
    /// @dev Slot 1 mirrors the launch's WETH slot: 1.5% creator, no burn, 1% treasury, 1 WETH cap.
    uint16 internal constant WETH_CREATOR_BPS = 150;
    uint16 internal constant WETH_BURN_BPS = 0;
    uint16 internal constant WETH_TREASURY_BPS = 100;
    uint256 internal constant WETH_CAP = 1 ether;
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal treasury = makeAddr("treasury");
    MockIMD internal token;
    MockIMD internal weth;
    MockIntake internal intake;
    VerdictOracle internal oracle;
    VerdictMarkets internal markets;
    VerdictBurnVault internal burn;
    bytes internal body = '{"v":1,"question":"primary"}';
    bytes internal escalationBody = '{"v":1,"question":"primary","panelSize":10}';
    uint256 internal attNonce;

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        vm.chainId(11155111);
        token = new MockIMD();
        weth = new MockIMD();
        intake = new MockIntake();
        oracle =
            new VerdictOracle(address(intake), address(token), vm.addr(SIGNER_KEY), ACTION, PRICE, address(this), 0);
        burn = new VerdictBurnVault();
        markets = newMarkets(address(oracle), 100, 50, 50, 500 ether, 0.25 ether);
        markets.setCreatorAllowed(creator, true);
        address[5] memory users = [address(this), creator, alice, bob, carol];
        for (uint256 i; i < users.length; i++) {
            token.mint(users[i], 1_000_000 ether);
            weth.mint(users[i], 1_000_000 ether);
            vm.startPrank(users[i]);
            token.approve(address(markets), type(uint256).max);
            token.approve(address(oracle), type(uint256).max);
            weth.approve(address(markets), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// @dev Slot 0 is IMD with the given terms; slot 1 is always the WETH double with the launch's WETH terms.
    function newMarkets(
        address oracle_,
        uint16 creatorBps,
        uint16 burnBps,
        uint16 treasuryBps,
        uint256 cap,
        uint256 maxReward
    ) internal returns (VerdictMarkets) {
        return new VerdictMarkets(
            oracle_,
            treasury,
            address(burn),
            address(this),
            address(token),
            creatorBps,
            burnBps,
            treasuryBps,
            cap,
            address(weth),
            WETH_CREATOR_BPS,
            WETH_BURN_BPS,
            WETH_TREASURY_BPS,
            WETH_CAP,
            maxReward
        );
    }

    function params() internal view returns (VerdictMarkets.Params memory p) {
        p.questionHash = QUESTION;
        p.answerType = 0;
        p.dataChainId = 1;
        p.fromBlock = 100;
        p.toBlock = 200;
        p.minPanelSize = 5;
        p.minAgreed = 4;
        p.closeAt = uint64(block.timestamp + 1 hours);
        p.answerFrom = p.closeAt;
        p.answerUntil = p.answerFrom + 4 days;
        p.disputeWindow = 1 days;
        p.voidAfter = p.answerUntil + 1 hours;
        p.bounty = 2 * PRICE;
        p.settlerReward = 0;
        p.collateralId = 0;
    }

    function create() internal returns (uint256 id) {
        return createWith(params());
    }

    function createWith(VerdictMarkets.Params memory p) internal returns (uint256 id) {
        vm.prank(creator);
        return markets.createMarket(p, body, escalationBody, "ipfs://market", 42);
    }

    function betAs(uint256 id, address user, uint8 outcome, uint256 amount) internal {
        vm.prank(user);
        markets.bet(id, outcome, amount, 7);
    }

    function attestation(uint256 id, bytes memory answer, uint16 panel)
        internal
        returns (OracleAttestation.Attestation memory a)
    {
        VerdictMarkets.Params memory p = markets.getMarket(id).params;
        a.requestId = keccak256(abi.encode("oracle request", ++attNonce));
        a.chainId = p.dataChainId;
        a.questionHash = p.questionHash;
        a.answerType = p.answerType;
        a.answer = answer;
        a.figure = 12345;
        a.fromBlock = p.fromBlock;
        a.toBlock = p.toBlock;
        a.blockHash = keccak256("closing block");
        a.panelJobId = keccak256(abi.encode("panel", attNonce));
        a.panelSize = panel;
        a.quorum = 4;
        a.agreed = panel;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 7 days);
    }

    function sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        return signDigest(SIGNER_KEY, oracle.attestationDigest(a));
    }

    function signDigest(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function deliver(bytes32 requestId, OracleAttestation.Attestation memory a) internal {
        (bool ok, uint256 gasUsed) = intake.deliver(requestId, a, sign(a), 150_000);
        assertTrue(ok, "callback failed");
        assertLt(gasUsed, 150_000, "callback too expensive");
    }

    function primary(uint256 id, bool value) internal returns (OracleAttestation.Attestation memory a) {
        vm.warp(markets.getMarket(id).params.answerFrom);
        bytes32 requestId = markets.resolve(id, body);
        a = attestation(id, abi.encode(value), 5);
        deliver(requestId, a);
        markets.propose(id, a);
    }

    /// @dev Two ledgers per market: the collateral ledger and the bounty-token ledger never mix.
    function assertConserved(uint256 id, bool drained) internal view {
        VerdictMarkets.Market memory m = markets.getMarket(id);
        uint256 collateralExits = m.paidOut + m.refunded + m.fees;
        uint256 bountyExits = m.oracleSpend + m.rewardsPaid + m.returnedBounty;
        if (drained) {
            assertEq(collateralExits, m.pool, "per-market collateral conservation");
            assertEq(bountyExits, m.params.bounty, "per-market bounty conservation");
        } else {
            assertLe(collateralExits, m.pool, "overdrawn collateral");
            assertLe(bountyExits, m.params.bounty, "overdrawn bounty");
        }
    }
}
