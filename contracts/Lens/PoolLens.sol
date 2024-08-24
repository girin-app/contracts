// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ResilientOracleInterface } from "../Oracle/OracleInterface.sol";

import { ExponentialNoError } from "../ExponentialNoError.sol";
import {LtToken} from "../LtToken.sol";
import { Action, ComptrollerInterface, ComptrollerViewInterface } from "../ComptrollerInterface.sol";
import { PoolRegistryInterface } from "../Pool/PoolRegistryInterface.sol";
import { PoolRegistry } from "../Pool/PoolRegistry.sol";
import { RewardsDistributor } from "../Rewards/RewardsDistributor.sol";
import { TimeManagerV8 } from "../lib/TimeManagerV8.sol";

/**
 * @title PoolLens
 * @author Venus
 * @notice The `PoolLens` contract is designed to retrieve important information for each registered pool. A list of essential information
 * for all pools within the lending protocol can be acquired through the function `getAllPools()`. Additionally, the following records can be
 * looked up for specific pools and markets:
- the ltToken balance of a given user;
- the pool data (oracle address, associated ltToken, liquidation incentive, etc) of a pool via its associated comptroller address;
- the ltToken address in a pool for a given asset;
- a list of all pools that support an asset;
- the underlying asset price of a ltToken;
- the metadata (exchange/borrow/supply rate, total supply, collateral factor, etc) of any ltToken.
 */
contract PoolLens is ExponentialNoError, TimeManagerV8 {
    /**
     * @dev Struct for PoolDetails.
     */
    struct PoolData {
        string name;
        address creator;
        address comptroller;
        uint256 blockPosted;
        uint256 timestampPosted;
        string category;
        string logoURL;
        string description;
        address priceOracle;
        uint256 closeFactor;
        uint256 liquidationIncentive;
        uint256 minLiquidatableCollateral;
        LtTokenMetadata[] ltTokens;
    }

    /**
     * @dev Struct for LtToken.sol.
     */
    struct LtTokenMetadata {
        address ltToken;
        uint256 exchangeRateCurrent;
        uint256 supplyRatePerBlockOrTimestamp;
        uint256 borrowRatePerBlockOrTimestamp;
        uint256 reserveFactorMantissa;
        uint256 supplyCaps;
        uint256 borrowCaps;
        uint256 totalBorrows;
        uint256 totalReserves;
        uint256 totalSupply;
        uint256 totalCash;
        bool isListed;
        uint256 collateralFactorMantissa;
        address underlyingAssetAddress;
        uint256 ltTokenDecimals;
        uint256 underlyingDecimals;
        uint256 pausedActions;
    }

    /**
     * @dev Struct for LtTokenBalance.
     */
    struct LtTokenBalances {
        address ltToken;
        uint256 balanceOf;
        uint256 borrowBalanceCurrent;
        uint256 balanceOfUnderlying;
        uint256 tokenBalance;
        uint256 tokenAllowance;
    }

    /**
     * @dev Struct for underlyingPrice of LtToken.sol.
     */
    struct LtTokenUnderlyingPrice {
        address ltToken;
        uint256 underlyingPrice;
    }

    /**
     * @dev Struct with pending reward info for a market.
     */
    struct PendingReward {
        address ltTokenAddress;
        uint256 amount;
    }

    /**
     * @dev Struct with reward distribution totals for a single reward token and distributor.
     */
    struct RewardSummary {
        address distributorAddress;
        address rewardTokenAddress;
        uint256 totalRewards;
        PendingReward[] pendingRewards;
    }

    /**
     * @dev Struct used in RewardDistributor to save last updated market state.
     */
    struct RewardTokenState {
        // The market's last updated rewardTokenBorrowIndex or rewardTokenSupplyIndex
        uint224 index;
        // The block number or timestamp the index was last updated at
        uint256 blockOrTimestamp;
        // The block number or timestamp at which to stop rewards
        uint256 lastRewardingBlockOrTimestamp;
    }

    /**
     * @dev Struct with bad debt of a market denominated
     */
    struct BadDebt {
        address ltTokenAddress;
        uint256 badDebtUsd;
    }

    /**
     * @dev Struct with bad debt total denominated in usd for a pool and an array of BadDebt structs for each market
     */
    struct BadDebtSummary {
        address comptroller;
        uint256 totalBadDebtUsd;
        BadDebt[] badDebts;
    }

    /**
     * @param timeBased_ A boolean indicating whether the contract is based on time or block.
     * @param blocksPerYear_ The number of blocks per year
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(bool timeBased_, uint256 blocksPerYear_) TimeManagerV8(timeBased_, blocksPerYear_) {}

    /**
     * @notice Queries the user's supply/borrow balances in ltTokens
     * @param ltTokens The list of ltToken addresses
     * @param account The user Account
     * @return A list of structs containing balances data
     */
    function ltTokenBalancesAll(LtToken[] calldata ltTokens, address account) external returns (LtTokenBalances[] memory) {
        uint256 ltTokenCount = ltTokens.length;
        LtTokenBalances[] memory res = new LtTokenBalances[](ltTokenCount);
        for (uint256 i; i < ltTokenCount; ++i) {
            res[i] = ltTokenBalances(ltTokens[i], account);
        }
        return res;
    }

    /**
     * @notice Queries all pools with addtional details for each of them
     * @dev This function is not designed to be called in a transaction: it is too gas-intensive
     * @param poolRegistryAddress The address of the PoolRegistry contract
     * @return Arrays of all Venus pools' data
     */
    function getAllPools(address poolRegistryAddress) external view returns (PoolData[] memory) {
        PoolRegistryInterface poolRegistryInterface = PoolRegistryInterface(poolRegistryAddress);
        PoolRegistry.VenusPool[] memory venusPools = poolRegistryInterface.getAllPools();
        uint256 poolLength = venusPools.length;

        PoolData[] memory poolDataItems = new PoolData[](poolLength);

        for (uint256 i; i < poolLength; ++i) {
            PoolRegistry.VenusPool memory venusPool = venusPools[i];
            PoolData memory poolData = getPoolDataFromVenusPool(poolRegistryAddress, venusPool);
            poolDataItems[i] = poolData;
        }

        return poolDataItems;
    }

    /**
     * @notice Queries the details of a pool identified by Comptroller address
     * @param poolRegistryAddress The address of the PoolRegistry contract
     * @param comptroller The Comptroller implementation address
     * @return PoolData structure containing the details of the pool
     */
    function getPoolByComptroller(
        address poolRegistryAddress,
        address comptroller
    ) external view returns (PoolData memory) {
        PoolRegistryInterface poolRegistryInterface = PoolRegistryInterface(poolRegistryAddress);
        return getPoolDataFromVenusPool(poolRegistryAddress, poolRegistryInterface.getPoolByComptroller(comptroller));
    }

    /**
     * @notice Returns ltToken holding the specified underlying asset in the specified pool
     * @param poolRegistryAddress The address of the PoolRegistry contract
     * @param comptroller The pool comptroller
     * @param asset The underlyingAsset of LtToken.sol
     * @return Address of the ltToken
     */
    function getLtTokenForAsset(
        address poolRegistryAddress,
        address comptroller,
        address asset
    ) external view returns (address) {
        PoolRegistryInterface poolRegistryInterface = PoolRegistryInterface(poolRegistryAddress);
        return poolRegistryInterface.getLtTokenForAsset(comptroller, asset);
    }

    /**
     * @notice Returns all pools that support the specified underlying asset
     * @param poolRegistryAddress The address of the PoolRegistry contract
     * @param asset The underlying asset of ltToken
     * @return A list of Comptroller contracts
     */
    function getPoolsSupportedByAsset(
        address poolRegistryAddress,
        address asset
    ) external view returns (address[] memory) {
        PoolRegistryInterface poolRegistryInterface = PoolRegistryInterface(poolRegistryAddress);
        return poolRegistryInterface.getPoolsSupportedByAsset(asset);
    }

    /**
     * @notice Returns the price data for the underlying assets of the specified ltTokens
     * @param ltTokens The list of ltToken addresses
     * @return An array containing the price data for each asset
     */
    function ltTokenUnderlyingPriceAll(
        LtToken[] calldata ltTokens
    ) external view returns (LtTokenUnderlyingPrice[] memory) {
        uint256 ltTokenCount = ltTokens.length;
        LtTokenUnderlyingPrice[] memory res = new LtTokenUnderlyingPrice[](ltTokenCount);
        for (uint256 i; i < ltTokenCount; ++i) {
            res[i] = ltTokenUnderlyingPrice(ltTokens[i]);
        }
        return res;
    }

    /**
     * @notice Returns the pending rewards for a user for a given pool.
     * @param account The user account.
     * @param comptrollerAddress address
     * @return Pending rewards array
     */
    function getPendingRewards(
        address account,
        address comptrollerAddress
    ) external view returns (RewardSummary[] memory) {
        LtToken[] memory markets = ComptrollerInterface(comptrollerAddress).getAllMarkets();
        RewardsDistributor[] memory rewardsDistributors = ComptrollerViewInterface(comptrollerAddress)
            .getRewardDistributors();
        RewardSummary[] memory rewardSummary = new RewardSummary[](rewardsDistributors.length);
        for (uint256 i; i < rewardsDistributors.length; ++i) {
            RewardSummary memory reward;
            reward.distributorAddress = address(rewardsDistributors[i]);
            reward.rewardTokenAddress = address(rewardsDistributors[i].rewardToken());
            reward.totalRewards = rewardsDistributors[i].rewardTokenAccrued(account);
            reward.pendingRewards = _calculateNotDistributedAwards(account, markets, rewardsDistributors[i]);
            rewardSummary[i] = reward;
        }
        return rewardSummary;
    }

    /**
     * @notice Returns a summary of a pool's bad debt broken down by market
     *
     * @param comptrollerAddress Address of the comptroller
     *
     * @return badDebtSummary A struct with comptroller address, total bad debut denominated in usd, and
     *   a break down of bad debt by market
     */
    function getPoolBadDebt(address comptrollerAddress) external view returns (BadDebtSummary memory) {
        uint256 totalBadDebtUsd;

        // Get every market in the pool
        ComptrollerViewInterface comptroller = ComptrollerViewInterface(comptrollerAddress);
        LtToken[] memory markets = comptroller.getAllMarkets();
        ResilientOracleInterface priceOracle = comptroller.oracle();

        BadDebt[] memory badDebts = new BadDebt[](markets.length);

        BadDebtSummary memory badDebtSummary;
        badDebtSummary.comptroller = comptrollerAddress;
        badDebtSummary.badDebts = badDebts;

        // // Calculate the bad debt is USD per market
        for (uint256 i; i < markets.length; ++i) {
            BadDebt memory badDebt;
            badDebt.ltTokenAddress = address(markets[i]);
            badDebt.badDebtUsd =
                (LtToken(address(markets[i])).badDebt() * priceOracle.getUnderlyingPrice(address(markets[i]))) /
                EXP_SCALE;
            badDebtSummary.badDebts[i] = badDebt;
            totalBadDebtUsd = totalBadDebtUsd + badDebt.badDebtUsd;
        }

        badDebtSummary.totalBadDebtUsd = totalBadDebtUsd;

        return badDebtSummary;
    }

    /**
     * @notice Queries the user's supply/borrow balances in the specified ltToken
     * @param ltToken ltToken address
     * @param account The user Account
     * @return A struct containing the balances data
     */
    function ltTokenBalances(LtToken ltToken, address account) public returns (LtTokenBalances memory) {
        uint256 balanceOf = ltToken.balanceOf(account);
        uint256 borrowBalanceCurrent = ltToken.borrowBalanceCurrent(account);
        uint256 balanceOfUnderlying = ltToken.balanceOfUnderlying(account);
        uint256 tokenBalance;
        uint256 tokenAllowance;

        IERC20 underlying = IERC20(ltToken.underlying());
        tokenBalance = underlying.balanceOf(account);
        tokenAllowance = underlying.allowance(account, address(ltToken));

        return
            LtTokenBalances({
                ltToken: address(ltToken),
                balanceOf: balanceOf,
                borrowBalanceCurrent: borrowBalanceCurrent,
                balanceOfUnderlying: balanceOfUnderlying,
                tokenBalance: tokenBalance,
                tokenAllowance: tokenAllowance
            });
    }

    /**
     * @notice Queries additional information for the pool
     * @param poolRegistryAddress Address of the PoolRegistry
     * @param venusPool The VenusPool Object from PoolRegistry
     * @return Enriched PoolData
     */
    function getPoolDataFromVenusPool(
        address poolRegistryAddress,
        PoolRegistry.VenusPool memory venusPool
    ) public view returns (PoolData memory) {
        // Get tokens in the Pool
        ComptrollerInterface comptrollerInstance = ComptrollerInterface(venusPool.comptroller);

        LtToken[] memory ltTokens = comptrollerInstance.getAllMarkets();

        LtTokenMetadata[] memory ltTokenMetadataItems = ltTokenMetadataAll(ltTokens);

        PoolRegistryInterface poolRegistryInterface = PoolRegistryInterface(poolRegistryAddress);

        PoolRegistry.VenusPoolMetaData memory venusPoolMetaData = poolRegistryInterface.getVenusPoolMetadata(
            venusPool.comptroller
        );

        ComptrollerViewInterface comptrollerViewInstance = ComptrollerViewInterface(venusPool.comptroller);

        PoolData memory poolData = PoolData({
            name: venusPool.name,
            creator: venusPool.creator,
            comptroller: venusPool.comptroller,
            blockPosted: venusPool.blockPosted,
            timestampPosted: venusPool.timestampPosted,
            category: venusPoolMetaData.category,
            logoURL: venusPoolMetaData.logoURL,
            description: venusPoolMetaData.description,
            ltTokens: ltTokenMetadataItems,
            priceOracle: address(comptrollerViewInstance.oracle()),
            closeFactor: comptrollerViewInstance.closeFactorMantissa(),
            liquidationIncentive: comptrollerViewInstance.liquidationIncentiveMantissa(),
            minLiquidatableCollateral: comptrollerViewInstance.minLiquidatableCollateral()
        });

        return poolData;
    }

    /**
     * @notice Returns the metadata of LtToken.sol
     * @param ltToken The address of ltToken
     * @return LtTokenMetadata struct
     */
    function ltTokenMetadata(LtToken ltToken) public view returns (LtTokenMetadata memory) {
        uint256 exchangeRateCurrent = ltToken.exchangeRateStored();
        address comptrollerAddress = address(ltToken.comptroller());
        ComptrollerViewInterface comptroller = ComptrollerViewInterface(comptrollerAddress);
        (bool isListed, uint256 collateralFactorMantissa) = comptroller.markets(address(ltToken));

        address underlyingAssetAddress = ltToken.underlying();
        uint256 underlyingDecimals = IERC20Metadata(underlyingAssetAddress).decimals();

        uint256 pausedActions;
        for (uint8 i; i <= uint8(type(Action).max); ++i) {
            uint256 paused = ComptrollerInterface(comptrollerAddress).actionPaused(address(ltToken), Action(i)) ? 1 : 0;
            pausedActions |= paused << i;
        }

        return
            LtTokenMetadata({
                ltToken: address(ltToken),
                exchangeRateCurrent: exchangeRateCurrent,
                supplyRatePerBlockOrTimestamp: ltToken.supplyRatePerBlock(),
                borrowRatePerBlockOrTimestamp: ltToken.borrowRatePerBlock(),
                reserveFactorMantissa: ltToken.reserveFactorMantissa(),
                supplyCaps: comptroller.supplyCaps(address(ltToken)),
                borrowCaps: comptroller.borrowCaps(address(ltToken)),
                totalBorrows: ltToken.totalBorrows(),
                totalReserves: ltToken.totalReserves(),
                totalSupply: ltToken.totalSupply(),
                totalCash: ltToken.getCash(),
                isListed: isListed,
                collateralFactorMantissa: collateralFactorMantissa,
                underlyingAssetAddress: underlyingAssetAddress,
                ltTokenDecimals: ltToken.decimals(),
                underlyingDecimals: underlyingDecimals,
                pausedActions: pausedActions
            });
    }

    /**
     * @notice Returns the metadata of all LtTokens
     * @param ltTokens The list of ltToken addresses
     * @return An array of LtTokenMetadata structs
     */
    function ltTokenMetadataAll(LtToken[] memory ltTokens) public view returns (LtTokenMetadata[] memory) {
        uint256 ltTokenCount = ltTokens.length;
        LtTokenMetadata[] memory res = new LtTokenMetadata[](ltTokenCount);
        for (uint256 i; i < ltTokenCount; ++i) {
            res[i] = ltTokenMetadata(ltTokens[i]);
        }
        return res;
    }

    /**
     * @notice Returns the price data for the underlying asset of the specified ltToken
     * @param ltToken ltToken address
     * @return The price data for each asset
     */
    function ltTokenUnderlyingPrice(LtToken ltToken) public view returns (LtTokenUnderlyingPrice memory) {
        ComptrollerViewInterface comptroller = ComptrollerViewInterface(address(ltToken.comptroller()));
        ResilientOracleInterface priceOracle = comptroller.oracle();

        return
            LtTokenUnderlyingPrice({
                ltToken: address(ltToken),
                underlyingPrice: priceOracle.getUnderlyingPrice(address(ltToken))
            });
    }

    function _calculateNotDistributedAwards(
        address account,
        LtToken[] memory markets,
        RewardsDistributor rewardsDistributor
    ) internal view returns (PendingReward[] memory) {
        PendingReward[] memory pendingRewards = new PendingReward[](markets.length);

        for (uint256 i; i < markets.length; ++i) {
            // Market borrow and supply state we will modify update in-memory, in order to not modify storage
            RewardTokenState memory borrowState;
            RewardTokenState memory supplyState;

            if (isTimeBased) {
                (
                    borrowState.index,
                    borrowState.blockOrTimestamp,
                    borrowState.lastRewardingBlockOrTimestamp
                ) = rewardsDistributor.rewardTokenBorrowStateTimeBased(address(markets[i]));
                (
                    supplyState.index,
                    supplyState.blockOrTimestamp,
                    supplyState.lastRewardingBlockOrTimestamp
                ) = rewardsDistributor.rewardTokenSupplyStateTimeBased(address(markets[i]));
            } else {
                (
                    borrowState.index,
                    borrowState.blockOrTimestamp,
                    borrowState.lastRewardingBlockOrTimestamp
                ) = rewardsDistributor.rewardTokenBorrowState(address(markets[i]));
                (
                    supplyState.index,
                    supplyState.blockOrTimestamp,
                    supplyState.lastRewardingBlockOrTimestamp
                ) = rewardsDistributor.rewardTokenSupplyState(address(markets[i]));
            }

            Exp memory marketBorrowIndex = Exp({ mantissa: markets[i].borrowIndex() });

            // Update market supply and borrow index in-memory
            updateMarketBorrowIndex(address(markets[i]), rewardsDistributor, borrowState, marketBorrowIndex);
            updateMarketSupplyIndex(address(markets[i]), rewardsDistributor, supplyState);

            // Calculate pending rewards
            uint256 borrowReward = calculateBorrowerReward(
                address(markets[i]),
                rewardsDistributor,
                account,
                borrowState,
                marketBorrowIndex
            );
            uint256 supplyReward = calculateSupplierReward(
                address(markets[i]),
                rewardsDistributor,
                account,
                supplyState
            );

            PendingReward memory pendingReward;
            pendingReward.ltTokenAddress = address(markets[i]);
            pendingReward.amount = borrowReward + supplyReward;
            pendingRewards[i] = pendingReward;
        }
        return pendingRewards;
    }

    function updateMarketBorrowIndex(
        address ltToken,
        RewardsDistributor rewardsDistributor,
        RewardTokenState memory borrowState,
        Exp memory marketBorrowIndex
    ) internal view {
        uint256 borrowSpeed = rewardsDistributor.rewardTokenBorrowSpeeds(ltToken);
        uint256 blockNumberOrTimestamp = getBlockNumberOrTimestamp();

        if (
            borrowState.lastRewardingBlockOrTimestamp > 0 &&
            blockNumberOrTimestamp > borrowState.lastRewardingBlockOrTimestamp
        ) {
            blockNumberOrTimestamp = borrowState.lastRewardingBlockOrTimestamp;
        }

        uint256 deltaBlocksOrTimestamp = sub_(blockNumberOrTimestamp, borrowState.blockOrTimestamp);
        if (deltaBlocksOrTimestamp > 0 && borrowSpeed > 0) {
            // Remove the total earned interest rate since the opening of the market from total borrows
            uint256 borrowAmount = div_(LtToken(ltToken).totalBorrows(), marketBorrowIndex);
            uint256 tokensAccrued = mul_(deltaBlocksOrTimestamp, borrowSpeed);
            Double memory ratio = borrowAmount > 0 ? fraction(tokensAccrued, borrowAmount) : Double({ mantissa: 0 });
            Double memory index = add_(Double({ mantissa: borrowState.index }), ratio);
            borrowState.index = safe224(index.mantissa, "new index overflows");
            borrowState.blockOrTimestamp = blockNumberOrTimestamp;
        } else if (deltaBlocksOrTimestamp > 0) {
            borrowState.blockOrTimestamp = blockNumberOrTimestamp;
        }
    }

    function updateMarketSupplyIndex(
        address ltToken,
        RewardsDistributor rewardsDistributor,
        RewardTokenState memory supplyState
    ) internal view {
        uint256 supplySpeed = rewardsDistributor.rewardTokenSupplySpeeds(ltToken);
        uint256 blockNumberOrTimestamp = getBlockNumberOrTimestamp();

        if (
            supplyState.lastRewardingBlockOrTimestamp > 0 &&
            blockNumberOrTimestamp > supplyState.lastRewardingBlockOrTimestamp
        ) {
            blockNumberOrTimestamp = supplyState.lastRewardingBlockOrTimestamp;
        }

        uint256 deltaBlocksOrTimestamp = sub_(blockNumberOrTimestamp, supplyState.blockOrTimestamp);
        if (deltaBlocksOrTimestamp > 0 && supplySpeed > 0) {
            uint256 supplyTokens = LtToken(ltToken).totalSupply();
            uint256 tokensAccrued = mul_(deltaBlocksOrTimestamp, supplySpeed);
            Double memory ratio = supplyTokens > 0 ? fraction(tokensAccrued, supplyTokens) : Double({ mantissa: 0 });
            Double memory index = add_(Double({ mantissa: supplyState.index }), ratio);
            supplyState.index = safe224(index.mantissa, "new index overflows");
            supplyState.blockOrTimestamp = blockNumberOrTimestamp;
        } else if (deltaBlocksOrTimestamp > 0) {
            supplyState.blockOrTimestamp = blockNumberOrTimestamp;
        }
    }

    function calculateBorrowerReward(
        address ltToken,
        RewardsDistributor rewardsDistributor,
        address borrower,
        RewardTokenState memory borrowState,
        Exp memory marketBorrowIndex
    ) internal view returns (uint256) {
        Double memory borrowIndex = Double({ mantissa: borrowState.index });
        Double memory borrowerIndex = Double({
            mantissa: rewardsDistributor.rewardTokenBorrowerIndex(ltToken, borrower)
        });
        if (borrowerIndex.mantissa == 0 && borrowIndex.mantissa >= rewardsDistributor.INITIAL_INDEX()) {
            // Covers the case where users borrowed tokens before the market's borrow state index was set
            borrowerIndex.mantissa = rewardsDistributor.INITIAL_INDEX();
        }
        Double memory deltaIndex = sub_(borrowIndex, borrowerIndex);
        uint256 borrowerAmount = div_(LtToken(ltToken).borrowBalanceStored(borrower), marketBorrowIndex);
        uint256 borrowerDelta = mul_(borrowerAmount, deltaIndex);
        return borrowerDelta;
    }

    function calculateSupplierReward(
        address ltToken,
        RewardsDistributor rewardsDistributor,
        address supplier,
        RewardTokenState memory supplyState
    ) internal view returns (uint256) {
        Double memory supplyIndex = Double({ mantissa: supplyState.index });
        Double memory supplierIndex = Double({
            mantissa: rewardsDistributor.rewardTokenSupplierIndex(ltToken, supplier)
        });
        if (supplierIndex.mantissa == 0 && supplyIndex.mantissa >= rewardsDistributor.INITIAL_INDEX()) {
            // Covers the case where users supplied tokens before the market's supply state index was set
            supplierIndex.mantissa = rewardsDistributor.INITIAL_INDEX();
        }
        Double memory deltaIndex = sub_(supplyIndex, supplierIndex);
        uint256 supplierTokens = LtToken(ltToken).balanceOf(supplier);
        uint256 supplierDelta = mul_(supplierTokens, deltaIndex);
        return supplierDelta;
    }
}
