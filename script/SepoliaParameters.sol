// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Static launch handoff shared by deployment rehearsals. No wallet, RPC, or broadcast logic.
/// @dev The launch service deploys the three application bytecodes in order; this library is not deployed.
library SepoliaParameters {
    uint256 internal constant CHAIN_ID = 11155111;
    address internal constant OWNER = 0x397DACB1EE8e9a8ce5196988958f56bDE0A0a312;
    address internal constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address internal constant IMD = 0x44a1Cd38474FB1748400E7DEb5F8D786ccE3F89A;
    address internal constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address internal constant SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    bytes32 internal constant ACTION = 0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000;
    uint256 internal constant PRICE = 500000000000000000;
    uint16 internal constant IMD_CREATOR_BPS = 150;
    uint16 internal constant IMD_BURN_BPS = 50;
    uint16 internal constant IMD_TREASURY_BPS = 50;
    uint256 internal constant IMD_POOL_CAP = 500000000000000000000;
    uint16 internal constant WETH_CREATOR_BPS = 150;
    uint16 internal constant WETH_BURN_BPS = 0;
    uint16 internal constant WETH_TREASURY_BPS = 100;
    uint256 internal constant WETH_POOL_CAP = 1000000000000000000;
    uint256 internal constant MAX_SETTLER_REWARD = 250000000000000000;

    function oracleConstructorArgs() internal pure returns (bytes memory) {
        return abi.encode(INTAKE, IMD, SIGNER, ACTION, PRICE, OWNER, uint256(0));
    }

    function marketsConstructorArgs(address oracle, address burnVault) internal pure returns (bytes memory) {
        require(oracle != address(0) && burnVault != address(0), "deploy dependencies first");
        return abi.encode(
            oracle,
            OWNER,
            burnVault,
            OWNER,
            IMD,
            IMD_CREATOR_BPS,
            IMD_BURN_BPS,
            IMD_TREASURY_BPS,
            IMD_POOL_CAP,
            WETH,
            WETH_CREATOR_BPS,
            WETH_BURN_BPS,
            WETH_TREASURY_BPS,
            WETH_POOL_CAP,
            MAX_SETTLER_REWARD
        );
    }
}
