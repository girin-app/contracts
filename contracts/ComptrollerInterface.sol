// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.25;

import { ResilientOracleInterface } from "./Oracle/OracleInterface.sol";

import {LtToken} from "./LtToken.sol";
import { RewardsDistributor } from "./Rewards/RewardsDistributor.sol";

enum Action {
    MINT,
    REDEEM,
    BORROW,
    REPAY,
    SEIZE,
    LIQUIDATE,
    TRANSFER,
    ENTER_MARKET,
    EXIT_MARKET
}

/**
 * @title ComptrollerInterface
 * @author Venus
 * @notice Interface implemented by the `Comptroller` contract.
 */
interface ComptrollerInterface {
    /*** Assets You Are In ***/

    function enterMarkets(address[] calldata ltTokens) external returns (uint256[] memory);

    function exitMarket(address ltToken) external returns (uint256);

    /*** Policy Hooks ***/

    function preMintHook(address ltToken, address minter, uint256 mintAmount) external;

    function preRedeemHook(address ltToken, address redeemer, uint256 redeemTokens) external;

    function preBorrowHook(address ltToken, address borrower, uint256 borrowAmount) external;

    function preRepayHook(address ltToken, address borrower) external;

    function preLiquidateHook(
        address ltTokenBorrowed,
        address ltTokenCollateral,
        address borrower,
        uint256 repayAmount,
        bool skipLiquidityCheck
    ) external;

    function preSeizeHook(
        address ltTokenCollateral,
        address ltTokenBorrowed,
        address liquidator,
        address borrower
    ) external;

    function preTransferHook(address ltToken, address src, address dst, uint256 transferTokens) external;

    function isComptroller() external view returns (bool);

    /*** Liquidity/Liquidation Calculations ***/

    function liquidateCalculateSeizeTokens(
        address ltTokenBorrowed,
        address ltTokenCollateral,
        uint256 repayAmount
    ) external view returns (uint256, uint256);

    function getAllMarkets() external view returns (LtToken[] memory);

    function actionPaused(address market, Action action) external view returns (bool);
}

/**
 * @title ComptrollerViewInterface
 * @author Venus
 * @notice Interface implemented by the `Comptroller` contract, including only some util view functions.
 */
interface ComptrollerViewInterface {
    function markets(address) external view returns (bool, uint256);

    function oracle() external view returns (ResilientOracleInterface);

    function getAssetsIn(address) external view returns (LtToken[] memory);

    function closeFactorMantissa() external view returns (uint256);

    function liquidationIncentiveMantissa() external view returns (uint256);

    function minLiquidatableCollateral() external view returns (uint256);

    function getRewardDistributors() external view returns (RewardsDistributor[] memory);

    function getAllMarkets() external view returns (LtToken[] memory);

    function borrowCaps(address) external view returns (uint256);

    function supplyCaps(address) external view returns (uint256);

    function approvedDelegates(address user, address delegate) external view returns (bool);

    function getAccountLiquidity(
        address account
    ) external view returns (uint256 error, uint256 liquidity, uint256 shortfall);
}
