// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VerdictBurnVault} from "../src/VerdictBurnVault.sol";
import {VerdictOracle} from "../src/VerdictOracle.sol";
import {VerdictMarkets} from "../src/VerdictMarkets.sol";
import {SepoliaParameters} from "../script/SepoliaParameters.sol";
import {RehearsalFactory} from "./Deployment.t.sol";

contract SettlerDeploymentTest is Test {
    function test_launchHandoffPinsV2AndFifteenConstructorArguments() public {
        vm.chainId(11155111);
        RehearsalFactory factory = new RehearsalFactory();
        address vault = factory.deploy(type(VerdictBurnVault).creationCode, keccak256("rewards vault"));
        bytes memory oracleArgs = SepoliaParameters.oracleConstructorArgs();
        assertEq(
            oracleArgs,
            abi.encode(
                0xa43e6F75ee006411F79Ac1C84120606C2330DE82,
                0x44a1Cd38474FB1748400E7DEb5F8D786ccE3F89A,
                0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982,
                bytes32("oracle.request@oracle-1"),
                uint256(500000000000000000),
                0x397DACB1EE8e9a8ce5196988958f56bDE0A0a312,
                uint256(0)
            )
        );
        VerdictOracle oracle = VerdictOracle(
            factory.deploy(bytes.concat(type(VerdictOracle).creationCode, oracleArgs), keccak256("rewards oracle"))
        );
        bytes memory marketArgs = SepoliaParameters.marketsConstructorArgs(address(oracle), vault);
        assertEq(marketArgs.length, 15 * 32);
        assertEq(
            marketArgs,
            abi.encode(
                address(oracle),
                0x397DACB1EE8e9a8ce5196988958f56bDE0A0a312,
                vault,
                0x397DACB1EE8e9a8ce5196988958f56bDE0A0a312,
                0x44a1Cd38474FB1748400E7DEb5F8D786ccE3F89A,
                uint16(150),
                uint16(50),
                uint16(50),
                uint256(500000000000000000000),
                0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14,
                uint16(150),
                uint16(0),
                uint16(100),
                uint256(1000000000000000000),
                uint256(250000000000000000)
            )
        );
        VerdictMarkets markets = VerdictMarkets(
            factory.deploy(bytes.concat(type(VerdictMarkets).creationCode, marketArgs), keccak256("rewards markets"))
        );
        assertEq(oracle.intake(), 0xa43e6F75ee006411F79Ac1C84120606C2330DE82);
        assertEq(markets.maxSettlerReward(), 250000000000000000);
        assertEq(markets.guardian(), oracle.owner());
        assertEq(address(markets.oracle()), address(oracle));
        assertEq(markets.burnSink(), vault);
        assertEq(address(markets.collateral(0)), 0x44a1Cd38474FB1748400E7DEb5F8D786ccE3F89A);
        assertEq(address(markets.collateral(1)), 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14);
        vm.expectRevert(VerdictMarkets.InvalidCollateral.selector);
        markets.collateralConfig(2);
    }
}
