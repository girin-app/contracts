// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { Ownable2StepUpgradeable } from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { SafeERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import { AccessControlledV8 } from "../ACM/AccessControlledV8.sol";
import { TimeManagerV8 } from "../lib/TimeManagerV8.sol";

import { ExponentialNoError } from "../ExponentialNoError.sol";
import {LtToken} from "../LtToken.sol";
import { Comptroller } from "../Comptroller.sol";
import { MaxLoopsLimitHelper } from "../lib/MaxLoopsLimitHelper.sol";
import { RewardsDistributorStorage } from "./RewardsDistributorStorage.sol";

/**
 * @title `RewardsDistributor`
 * @author Venus
 * @notice Contract used to configure, track and distribute rewards to users based on their actions (borrows and supplies) in the protocol.
 * Users can receive additional rewards through a `RewardsDistributor`. Each `RewardsDistributor` proxy is initialized with a specific reward
 * token and `Comptroller`, which can then distribute the reward token to users that supply or borrow in the associated pool.
 * Authorized users can set the reward token borrow and supply speeds for each market in the pool. This sets a fixed amount of reward
 * token to be released each slot (block or second) for borrowers and suppliers, which is distributed based on a user’s percentage of the borrows or supplies
 * respectively. The owner can also set up reward distributions to contributor addresses (distinct from suppliers and borrowers) by setting
 * their contributor reward token speed, which similarly allocates a fixed amount of reward token per slot (block or second).
 *
 * The owner has the ability to transfer any amount of reward tokens held by the contract to any other address. Rewards are not distributed
 * automatically and must be claimed by a user calling `claimRewardToken()`. Users should be aware that it is up to the owner and other centralized
 * entities to ensure that the `RewardsDistributor` holds enough tokens to distribute the accumulated rewards of users and contributors.
 */
contract RewardsDistributor is
    ExponentialNoError,
    Ownable2StepUpgradeable,
    AccessControlledV8,
    MaxLoopsLimitHelper,
    RewardsDistributorStorage,
    TimeManagerV8
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /// @notice The initial REWARD TOKEN index for a market
    uint224 public constant INITIAL_INDEX = 1e36;

    /// @notice Emitted when REWARD TOKEN is distributed to a supplier
    event DistributedSupplierRewardToken(
        LtToken indexed ltToken,
        address indexed supplier,
        uint256 rewardTokenDelta,
        uint256 rewardTokenTotal,
        uint256 rewardTokenSupplyIndex
    );

    /// @notice Emitted when REWARD TOKEN is distributed to a borrower
    event DistributedBorrowerRewardToken(
        LtToken indexed ltToken,
        address indexed borrower,
        uint256 rewardTokenDelta,
        uint256 rewardTokenTotal,
        uint256 rewardTokenBorrowIndex
    );

    /// @notice Emitted when a new supply-side REWARD TOKEN speed is calculated for a market
    event RewardTokenSupplySpeedUpdated(LtToken indexed ltToken, uint256 newSpeed);

    /// @notice Emitted when a new borrow-side REWARD TOKEN speed is calculated for a market
    event RewardTokenBorrowSpeedUpdated(LtToken indexed ltToken, uint256 newSpeed);

    /// @notice Emitted when REWARD TOKEN is granted by admin
    event RewardTokenGranted(address indexed recipient, uint256 amount);

    /// @notice Emitted when a new REWARD TOKEN speed is set for a contributor
    event ContributorRewardTokenSpeedUpdated(address indexed contributor, uint256 newSpeed);

    /// @notice Emitted when a market is initialized
    event MarketInitialized(address indexed ltToken);

    /// @notice Emitted when a reward token supply index is updated
    event RewardTokenSupplyIndexUpdated(address indexed ltToken);

    /// @notice Emitted when a reward token borrow index is updated
    event RewardTokenBorrowIndexUpdated(address indexed ltToken, Exp marketBorrowIndex);

    /// @notice Emitted when a reward for contributor is updated
    event ContributorRewardsUpdated(address indexed contributor, uint256 rewardAccrued);

    /// @notice Emitted when a reward token last rewarding block for supply is updated
    event SupplyLastRewardingBlockUpdated(address indexed ltToken, uint32 newBlock);

    /// @notice Emitted when a reward token last rewarding block for borrow is updated
    event BorrowLastRewardingBlockUpdated(address indexed ltToken, uint32 newBlock);

    /// @notice Emitted when a reward token last rewarding timestamp for supply is updated
    event SupplyLastRewardingBlockTimestampUpdated(address indexed ltToken, uint256 newTimestamp);

    /// @notice Emitted when a reward token last rewarding timestamp for borrow is updated
    event BorrowLastRewardingBlockTimestampUpdated(address indexed ltToken, uint256 newTimestamp);

    modifier onlyComptroller() {
        require(address(comptroller) == msg.sender, "Only comptroller can call this function");
        _;
    }

    /**
     * @param timeBased_ A boolean indicating whether the contract is based on time or block.
     * @param blocksPerYear_ The number of blocks per year
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(bool timeBased_, uint256 blocksPerYear_) TimeManagerV8(timeBased_, blocksPerYear_) {
        // Note that the contract is upgradeable. Use initialize() or reinitializers
        // to set the state variables.
        _disableInitializers();
    }

    /**
     * @notice RewardsDistributor initializer
     * @dev Initializes the deployer to owner
     * @param comptroller_ Comptroller to attach the reward distributor to
     * @param rewardToken_ Reward token to distribute
     * @param loopsLimit_ Maximum number of iterations for the loops in this contract
     * @param accessControlManager_ AccessControlManager contract address
     */
    function initialize(
        Comptroller comptroller_,
        IERC20Upgradeable rewardToken_,
        uint256 loopsLimit_,
        address accessControlManager_
    ) external initializer {
        comptroller = comptroller_;
        rewardToken = rewardToken_;
        __Ownable2Step_init();
        __AccessControlled_init_unchained(accessControlManager_);

        _setMaxLoopsLimit(loopsLimit_);
    }

    /**
     * @notice Initializes the market state for a specific ltToken
     * @param ltToken The address of the ltToken to be initialized
     * @custom:event MarketInitialized emits on success
     * @custom:access Only Comptroller
     */
    function initializeMarket(address ltToken) external onlyComptroller {
        uint256 blockNumberOrTimestamp = getBlockNumberOrTimestamp();

        isTimeBased
            ? _initializeMarketTimestampBased(ltToken, blockNumberOrTimestamp)
            : _initializeMarketBlockBased(ltToken, safe32(blockNumberOrTimestamp, "block number exceeds 32 bits"));

        emit MarketInitialized(ltToken);
    }

    /*** Reward Token Distribution ***/

    /**
     * @notice Calculate reward token accrued by a borrower and possibly transfer it to them
     *         Borrowers will begin to accrue after the first interaction with the protocol.
     * @dev This function should only be called when the user has a borrow position in the market
     *      (e.g. Comptroller.preBorrowHook, and Comptroller.preRepayHook)
     *      We avoid an external call to check if they are in the market to save gas because this function is called in many places
     * @param ltToken The market in which the borrower is interacting
     * @param borrower The address of the borrower to distribute REWARD TOKEN to
     * @param marketBorrowIndex The current global borrow index of ltToken
     */
    function distributeBorrowerRewardToken(
        address ltToken,
        address borrower,
        Exp memory marketBorrowIndex
    ) external onlyComptroller {
        _distributeBorrowerRewardToken(ltToken, borrower, marketBorrowIndex);
    }

    function updateRewardTokenSupplyIndex(address ltToken) external onlyComptroller {
        _updateRewardTokenSupplyIndex(ltToken);
    }

    /**
     * @notice Transfer REWARD TOKEN to the recipient
     * @dev Note: If there is not enough REWARD TOKEN, we do not perform the transfer all
     * @param recipient The address of the recipient to transfer REWARD TOKEN to
     * @param amount The amount of REWARD TOKEN to (possibly) transfer
     */
    function grantRewardToken(address recipient, uint256 amount) external onlyOwner {
        uint256 amountLeft = _grantRewardToken(recipient, amount);
        require(amountLeft == 0, "insufficient rewardToken for grant");
        emit RewardTokenGranted(recipient, amount);
    }

    function updateRewardTokenBorrowIndex(address ltToken, Exp memory marketBorrowIndex) external onlyComptroller {
        _updateRewardTokenBorrowIndex(ltToken, marketBorrowIndex);
    }

    /**
     * @notice Set REWARD TOKEN borrow and supply speeds for the specified markets
     * @param ltTokens The markets whose REWARD TOKEN speed to update
     * @param supplySpeeds New supply-side REWARD TOKEN speed for the corresponding market
     * @param borrowSpeeds New borrow-side REWARD TOKEN speed for the corresponding market
     */
    function setRewardTokenSpeeds(
        LtToken[] memory ltTokens,
        uint256[] memory supplySpeeds,
        uint256[] memory borrowSpeeds
    ) external {
        _checkAccessAllowed("setRewardTokenSpeeds(address[],uint256[],uint256[])");
        uint256 numTokens = ltTokens.length;
        require(numTokens == supplySpeeds.length && numTokens == borrowSpeeds.length, "invalid setRewardTokenSpeeds");

        for (uint256 i; i < numTokens; ++i) {
            _setRewardTokenSpeed(ltTokens[i], supplySpeeds[i], borrowSpeeds[i]);
        }
    }

    /**
     * @notice Set REWARD TOKEN last rewarding block for the specified markets, used when contract is block based
     * @param ltTokens The markets whose REWARD TOKEN last rewarding block to update
     * @param supplyLastRewardingBlocks New supply-side REWARD TOKEN last rewarding block for the corresponding market
     * @param borrowLastRewardingBlocks New borrow-side REWARD TOKEN last rewarding block for the corresponding market
     */
    function setLastRewardingBlocks(
        LtToken[] calldata ltTokens,
        uint32[] calldata supplyLastRewardingBlocks,
        uint32[] calldata borrowLastRewardingBlocks
    ) external {
        _checkAccessAllowed("setLastRewardingBlocks(address[],uint32[],uint32[])");
        require(!isTimeBased, "Block-based operation only");

        uint256 numTokens = ltTokens.length;
        require(
            numTokens == supplyLastRewardingBlocks.length && numTokens == borrowLastRewardingBlocks.length,
            "RewardsDistributor::setLastRewardingBlocks invalid input"
        );

        for (uint256 i; i < numTokens; ) {
            _setLastRewardingBlock(ltTokens[i], supplyLastRewardingBlocks[i], borrowLastRewardingBlocks[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Set REWARD TOKEN last rewarding block timestamp for the specified markets, used when contract is time based
     * @param ltTokens The markets whose REWARD TOKEN last rewarding block to update
     * @param supplyLastRewardingBlockTimestamps New supply-side REWARD TOKEN last rewarding block timestamp for the corresponding market
     * @param borrowLastRewardingBlockTimestamps New borrow-side REWARD TOKEN last rewarding block timestamp for the corresponding market
     */
    function setLastRewardingBlockTimestamps(
        LtToken[] calldata ltTokens,
        uint256[] calldata supplyLastRewardingBlockTimestamps,
        uint256[] calldata borrowLastRewardingBlockTimestamps
    ) external {
        _checkAccessAllowed("setLastRewardingBlockTimestamps(address[],uint256[],uint256[])");
        require(isTimeBased, "Time-based operation only");

        uint256 numTokens = ltTokens.length;
        require(
            numTokens == supplyLastRewardingBlockTimestamps.length &&
                numTokens == borrowLastRewardingBlockTimestamps.length,
            "RewardsDistributor::setLastRewardingBlockTimestamps invalid input"
        );

        for (uint256 i; i < numTokens; ) {
            _setLastRewardingBlockTimestamp(
                ltTokens[i],
                supplyLastRewardingBlockTimestamps[i],
                borrowLastRewardingBlockTimestamps[i]
            );
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Set REWARD TOKEN speed for a single contributor
     * @param contributor The contributor whose REWARD TOKEN speed to update
     * @param rewardTokenSpeed New REWARD TOKEN speed for contributor
     */
    function setContributorRewardTokenSpeed(address contributor, uint256 rewardTokenSpeed) external onlyOwner {
        // note that REWARD TOKEN speed could be set to 0 to halt liquidity rewards for a contributor
        updateContributorRewards(contributor);
        if (rewardTokenSpeed == 0) {
            // release storage
            delete lastContributorBlock[contributor];
        } else {
            lastContributorBlock[contributor] = getBlockNumberOrTimestamp();
        }
        rewardTokenContributorSpeeds[contributor] = rewardTokenSpeed;

        emit ContributorRewardTokenSpeedUpdated(contributor, rewardTokenSpeed);
    }

    function distributeSupplierRewardToken(address ltToken, address supplier) external onlyComptroller {
        _distributeSupplierRewardToken(ltToken, supplier);
    }

    /**
     * @notice Claim all the rewardToken accrued by holder in all markets
     * @param holder The address to claim REWARD TOKEN for
     */
    function claimRewardToken(address holder) external {
        return claimRewardToken(holder, comptroller.getAllMarkets());
    }

    /**
     * @notice Set the limit for the loops can iterate to avoid the DOS
     * @param limit Limit for the max loops can execute at a time
     */
    function setMaxLoopsLimit(uint256 limit) external onlyOwner {
        _setMaxLoopsLimit(limit);
    }

    /**
     * @notice Calculate additional accrued REWARD TOKEN for a contributor since last accrual
     * @param contributor The address to calculate contributor rewards for
     */
    function updateContributorRewards(address contributor) public {
        uint256 rewardTokenSpeed = rewardTokenContributorSpeeds[contributor];
        uint256 blockNumberOrTimestamp = getBlockNumberOrTimestamp();
        uint256 deltaBlocksOrTimestamp = sub_(blockNumberOrTimestamp, lastContributorBlock[contributor]);
        if (deltaBlocksOrTimestamp > 0 && rewardTokenSpeed > 0) {
            uint256 newAccrued = mul_(deltaBlocksOrTimestamp, rewardTokenSpeed);
            uint256 contributorAccrued = add_(rewardTokenAccrued[contributor], newAccrued);

            rewardTokenAccrued[contributor] = contributorAccrued;
            lastContributorBlock[contributor] = blockNumberOrTimestamp;

            emit ContributorRewardsUpdated(contributor, rewardTokenAccrued[contributor]);
        }
    }

    /**
     * @notice Claim all the rewardToken accrued by holder in the specified markets
     * @param holder The address to claim REWARD TOKEN for
     * @param ltTokens The list of markets to claim REWARD TOKEN in
     */
    function claimRewardToken(address holder, LtToken[] memory ltTokens) public {
        uint256 ltTokensCount = ltTokens.length;

        _ensureMaxLoops(ltTokensCount);

        for (uint256 i; i < ltTokensCount; ++i) {
            LtToken ltToken = ltTokens[i];
            require(comptroller.isMarketListed(ltToken), "market must be listed");
            Exp memory borrowIndex = Exp({ mantissa: ltToken.borrowIndex() });
            _updateRewardTokenBorrowIndex(address(ltToken), borrowIndex);
            _distributeBorrowerRewardToken(address(ltToken), holder, borrowIndex);
            _updateRewardTokenSupplyIndex(address(ltToken));
            _distributeSupplierRewardToken(address(ltToken), holder);
        }
        rewardTokenAccrued[holder] = _grantRewardToken(holder, rewardTokenAccrued[holder]);
    }

    /**
     * @notice Set REWARD TOKEN last rewarding block for a single market.
     * @param ltToken market's whose reward token last rewarding block to be updated
     * @param supplyLastRewardingBlock New supply-side REWARD TOKEN last rewarding block for market
     * @param borrowLastRewardingBlock New borrow-side REWARD TOKEN last rewarding block for market
     */
    function _setLastRewardingBlock(
        LtToken ltToken,
        uint32 supplyLastRewardingBlock,
        uint32 borrowLastRewardingBlock
    ) internal {
        require(comptroller.isMarketListed(ltToken), "rewardToken market is not listed");

        uint256 blockNumber = getBlockNumberOrTimestamp();

        require(supplyLastRewardingBlock > blockNumber, "setting last rewarding block in the past is not allowed");
        require(borrowLastRewardingBlock > blockNumber, "setting last rewarding block in the past is not allowed");

        uint32 currentSupplyLastRewardingBlock = rewardTokenSupplyState[address(ltToken)].lastRewardingBlock;
        uint32 currentBorrowLastRewardingBlock = rewardTokenBorrowState[address(ltToken)].lastRewardingBlock;

        require(
            currentSupplyLastRewardingBlock == 0 || currentSupplyLastRewardingBlock > blockNumber,
            "this RewardsDistributor is already locked"
        );
        require(
            currentBorrowLastRewardingBlock == 0 || currentBorrowLastRewardingBlock > blockNumber,
            "this RewardsDistributor is already locked"
        );

        if (currentSupplyLastRewardingBlock != supplyLastRewardingBlock) {
            rewardTokenSupplyState[address(ltToken)].lastRewardingBlock = supplyLastRewardingBlock;
            emit SupplyLastRewardingBlockUpdated(address(ltToken), supplyLastRewardingBlock);
        }

        if (currentBorrowLastRewardingBlock != borrowLastRewardingBlock) {
            rewardTokenBorrowState[address(ltToken)].lastRewardingBlock = borrowLastRewardingBlock;
            emit BorrowLastRewardingBlockUpdated(address(ltToken), borrowLastRewardingBlock);
        }
    }

    /**
     * @notice Set REWARD TOKEN last rewarding timestamp for a single market.
     * @param ltToken market's whose reward token last rewarding timestamp to be updated
     * @param supplyLastRewardingBlockTimestamp New supply-side REWARD TOKEN last rewarding timestamp for market
     * @param borrowLastRewardingBlockTimestamp New borrow-side REWARD TOKEN last rewarding timestamp for market
     */
    function _setLastRewardingBlockTimestamp(
        LtToken ltToken,
        uint256 supplyLastRewardingBlockTimestamp,
        uint256 borrowLastRewardingBlockTimestamp
    ) internal {
        require(comptroller.isMarketListed(ltToken), "rewardToken market is not listed");

        uint256 blockTimestamp = getBlockNumberOrTimestamp();

        require(
            supplyLastRewardingBlockTimestamp > blockTimestamp,
            "setting last rewarding timestamp in the past is not allowed"
        );
        require(
            borrowLastRewardingBlockTimestamp > blockTimestamp,
            "setting last rewarding timestamp in the past is not allowed"
        );

        uint256 currentSupplyLastRewardingBlockTimestamp = rewardTokenSupplyStateTimeBased[address(ltToken)]
            .lastRewardingTimestamp;
        uint256 currentBorrowLastRewardingBlockTimestamp = rewardTokenBorrowStateTimeBased[address(ltToken)]
            .lastRewardingTimestamp;

        require(
            currentSupplyLastRewardingBlockTimestamp == 0 || currentSupplyLastRewardingBlockTimestamp > blockTimestamp,
            "this RewardsDistributor is already locked"
        );
        require(
            currentBorrowLastRewardingBlockTimestamp == 0 || currentBorrowLastRewardingBlockTimestamp > blockTimestamp,
            "this RewardsDistributor is already locked"
        );

        if (currentSupplyLastRewardingBlockTimestamp != supplyLastRewardingBlockTimestamp) {
            rewardTokenSupplyStateTimeBased[address(ltToken)].lastRewardingTimestamp = supplyLastRewardingBlockTimestamp;
            emit SupplyLastRewardingBlockTimestampUpdated(address(ltToken), supplyLastRewardingBlockTimestamp);
        }

        if (currentBorrowLastRewardingBlockTimestamp != borrowLastRewardingBlockTimestamp) {
            rewardTokenBorrowStateTimeBased[address(ltToken)].lastRewardingTimestamp = borrowLastRewardingBlockTimestamp;
            emit BorrowLastRewardingBlockTimestampUpdated(address(ltToken), borrowLastRewardingBlockTimestamp);
        }
    }

    /**
     * @notice Set REWARD TOKEN speed for a single market.
     * @param ltToken market's whose reward token rate to be updated
     * @param supplySpeed New supply-side REWARD TOKEN speed for market
     * @param borrowSpeed New borrow-side REWARD TOKEN speed for market
     */
    function _setRewardTokenSpeed(LtToken ltToken, uint256 supplySpeed, uint256 borrowSpeed) internal {
        require(comptroller.isMarketListed(ltToken), "rewardToken market is not listed");

        if (rewardTokenSupplySpeeds[address(ltToken)] != supplySpeed) {
            // Supply speed updated so let's update supply state to ensure that
            //  1. REWARD TOKEN accrued properly for the old speed, and
            //  2. REWARD TOKEN accrued at the new speed starts after this block.
            _updateRewardTokenSupplyIndex(address(ltToken));

            // Update speed and emit event
            rewardTokenSupplySpeeds[address(ltToken)] = supplySpeed;
            emit RewardTokenSupplySpeedUpdated(ltToken, supplySpeed);
        }

        if (rewardTokenBorrowSpeeds[address(ltToken)] != borrowSpeed) {
            // Borrow speed updated so let's update borrow state to ensure that
            //  1. REWARD TOKEN accrued properly for the old speed, and
            //  2. REWARD TOKEN accrued at the new speed starts after this block.
            Exp memory borrowIndex = Exp({ mantissa: ltToken.borrowIndex() });
            _updateRewardTokenBorrowIndex(address(ltToken), borrowIndex);

            // Update speed and emit event
            rewardTokenBorrowSpeeds[address(ltToken)] = borrowSpeed;
            emit RewardTokenBorrowSpeedUpdated(ltToken, borrowSpeed);
        }
    }

    /**
     * @notice Calculate REWARD TOKEN accrued by a supplier and possibly transfer it to them.
     * @param ltToken The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute REWARD TOKEN to
     */
    function _distributeSupplierRewardToken(address ltToken, address supplier) internal {
        RewardToken storage supplyState = rewardTokenSupplyState[ltToken];
        TimeBasedRewardToken storage supplyStateTimeBased = rewardTokenSupplyStateTimeBased[ltToken];

        uint256 supplyIndex = isTimeBased ? supplyStateTimeBased.index : supplyState.index;
        uint256 supplierIndex = rewardTokenSupplierIndex[ltToken][supplier];

        // Update supplier's index to the current index since we are distributing accrued REWARD TOKEN
        rewardTokenSupplierIndex[ltToken][supplier] = supplyIndex;

        if (supplierIndex == 0 && supplyIndex >= INITIAL_INDEX) {
            // Covers the case where users supplied tokens before the market's supply state index was set.
            // Rewards the user with REWARD TOKEN accrued from the start of when supplier rewards were first
            // set for the market.
            supplierIndex = INITIAL_INDEX;
        }

        // Calculate change in the cumulative sum of the REWARD TOKEN per ltToken accrued
        Double memory deltaIndex = Double({ mantissa: sub_(supplyIndex, supplierIndex) });

        uint256 supplierTokens = LtToken(ltToken).balanceOf(supplier);

        // Calculate REWARD TOKEN accrued: ltTokenAmount * accruedPerLtToken
        uint256 supplierDelta = mul_(supplierTokens, deltaIndex);

        uint256 supplierAccrued = add_(rewardTokenAccrued[supplier], supplierDelta);
        rewardTokenAccrued[supplier] = supplierAccrued;

        emit DistributedSupplierRewardToken(LtToken(ltToken), supplier, supplierDelta, supplierAccrued, supplyIndex);
    }

    /**
     * @notice Calculate reward token accrued by a borrower and possibly transfer it to them.
     * @param ltToken The market in which the borrower is interacting
     * @param borrower The address of the borrower to distribute REWARD TOKEN to
     * @param marketBorrowIndex The current global borrow index of ltToken
     */
    function _distributeBorrowerRewardToken(address ltToken, address borrower, Exp memory marketBorrowIndex) internal {
        RewardToken storage borrowState = rewardTokenBorrowState[ltToken];
        TimeBasedRewardToken storage borrowStateTimeBased = rewardTokenBorrowStateTimeBased[ltToken];

        uint256 borrowIndex = isTimeBased ? borrowStateTimeBased.index : borrowState.index;
        uint256 borrowerIndex = rewardTokenBorrowerIndex[ltToken][borrower];

        // Update borrowers's index to the current index since we are distributing accrued REWARD TOKEN
        rewardTokenBorrowerIndex[ltToken][borrower] = borrowIndex;

        if (borrowerIndex == 0 && borrowIndex >= INITIAL_INDEX) {
            // Covers the case where users borrowed tokens before the market's borrow state index was set.
            // Rewards the user with REWARD TOKEN accrued from the start of when borrower rewards were first
            // set for the market.
            borrowerIndex = INITIAL_INDEX;
        }

        // Calculate change in the cumulative sum of the REWARD TOKEN per borrowed unit accrued
        Double memory deltaIndex = Double({ mantissa: sub_(borrowIndex, borrowerIndex) });

        uint256 borrowerAmount = div_(LtToken(ltToken).borrowBalanceStored(borrower), marketBorrowIndex);

        // Calculate REWARD TOKEN accrued: ltTokenAmount * accruedPerBorrowedUnit
        if (borrowerAmount != 0) {
            uint256 borrowerDelta = mul_(borrowerAmount, deltaIndex);

            uint256 borrowerAccrued = add_(rewardTokenAccrued[borrower], borrowerDelta);
            rewardTokenAccrued[borrower] = borrowerAccrued;

            emit DistributedBorrowerRewardToken(LtToken(ltToken), borrower, borrowerDelta, borrowerAccrued, borrowIndex);
        }
    }

    /**
     * @notice Transfer REWARD TOKEN to the user.
     * @dev Note: If there is not enough REWARD TOKEN, we do not perform the transfer all.
     * @param user The address of the user to transfer REWARD TOKEN to
     * @param amount The amount of REWARD TOKEN to (possibly) transfer
     * @return The amount of REWARD TOKEN which was NOT transferred to the user
     */
    function _grantRewardToken(address user, uint256 amount) internal returns (uint256) {
        uint256 rewardTokenRemaining = rewardToken.balanceOf(address(this));
        if (amount > 0 && amount <= rewardTokenRemaining) {
            rewardToken.safeTransfer(user, amount);
            return 0;
        }
        return amount;
    }

    /**
     * @notice Accrue REWARD TOKEN to the market by updating the supply index
     * @param ltToken The market whose supply index to update
     * @dev Index is a cumulative sum of the REWARD TOKEN per ltToken accrued
     */
    function _updateRewardTokenSupplyIndex(address ltToken) internal {
        RewardToken storage supplyState = rewardTokenSupplyState[ltToken];
        TimeBasedRewardToken storage supplyStateTimeBased = rewardTokenSupplyStateTimeBased[ltToken];

        uint256 supplySpeed = rewardTokenSupplySpeeds[ltToken];
        uint256 blockNumberOrTimestamp = getBlockNumberOrTimestamp();

        if (!isTimeBased) {
            safe32(blockNumberOrTimestamp, "block number exceeds 32 bits");
        }

        uint256 lastRewardingBlockOrTimestamp = isTimeBased
            ? supplyStateTimeBased.lastRewardingTimestamp
            : uint256(supplyState.lastRewardingBlock);

        if (lastRewardingBlockOrTimestamp > 0 && blockNumberOrTimestamp > lastRewardingBlockOrTimestamp) {
            blockNumberOrTimestamp = lastRewardingBlockOrTimestamp;
        }

        uint256 deltaBlocksOrTimestamp = sub_(
            blockNumberOrTimestamp,
            (isTimeBased ? supplyStateTimeBased.timestamp : uint256(supplyState.block))
        );
        if (deltaBlocksOrTimestamp > 0 && supplySpeed > 0) {
            uint256 supplyTokens = LtToken(ltToken).totalSupply();
            uint256 accruedSinceUpdate = mul_(deltaBlocksOrTimestamp, supplySpeed);
            Double memory ratio = supplyTokens > 0
                ? fraction(accruedSinceUpdate, supplyTokens)
                : Double({ mantissa: 0 });
            uint224 supplyIndex = isTimeBased ? supplyStateTimeBased.index : supplyState.index;
            uint224 index = safe224(
                add_(Double({ mantissa: supplyIndex }), ratio).mantissa,
                "new index exceeds 224 bits"
            );

            if (isTimeBased) {
                supplyStateTimeBased.index = index;
                supplyStateTimeBased.timestamp = blockNumberOrTimestamp;
            } else {
                supplyState.index = index;
                supplyState.block = uint32(blockNumberOrTimestamp);
            }
        } else if (deltaBlocksOrTimestamp > 0) {
            isTimeBased ? supplyStateTimeBased.timestamp = blockNumberOrTimestamp : supplyState.block = uint32(
                blockNumberOrTimestamp
            );
        }

        emit RewardTokenSupplyIndexUpdated(ltToken);
    }

    /**
     * @notice Accrue REWARD TOKEN to the market by updating the borrow index
     * @param ltToken The market whose borrow index to update
     * @param marketBorrowIndex The current global borrow index of ltToken
     * @dev Index is a cumulative sum of the REWARD TOKEN per ltToken accrued
     */
    function _updateRewardTokenBorrowIndex(address ltToken, Exp memory marketBorrowIndex) internal {
        RewardToken storage borrowState = rewardTokenBorrowState[ltToken];
        TimeBasedRewardToken storage borrowStateTimeBased = rewardTokenBorrowStateTimeBased[ltToken];

        uint256 borrowSpeed = rewardTokenBorrowSpeeds[ltToken];
        uint256 blockNumberOrTimestamp = getBlockNumberOrTimestamp();

        if (!isTimeBased) {
            safe32(blockNumberOrTimestamp, "block number exceeds 32 bits");
        }

        uint256 lastRewardingBlockOrTimestamp = isTimeBased
            ? borrowStateTimeBased.lastRewardingTimestamp
            : uint256(borrowState.lastRewardingBlock);

        if (lastRewardingBlockOrTimestamp > 0 && blockNumberOrTimestamp > lastRewardingBlockOrTimestamp) {
            blockNumberOrTimestamp = lastRewardingBlockOrTimestamp;
        }

        uint256 deltaBlocksOrTimestamp = sub_(
            blockNumberOrTimestamp,
            (isTimeBased ? borrowStateTimeBased.timestamp : uint256(borrowState.block))
        );
        if (deltaBlocksOrTimestamp > 0 && borrowSpeed > 0) {
            uint256 borrowAmount = div_(LtToken(ltToken).totalBorrows(), marketBorrowIndex);
            uint256 accruedSinceUpdate = mul_(deltaBlocksOrTimestamp, borrowSpeed);
            Double memory ratio = borrowAmount > 0
                ? fraction(accruedSinceUpdate, borrowAmount)
                : Double({ mantissa: 0 });
            uint224 borrowIndex = isTimeBased ? borrowStateTimeBased.index : borrowState.index;
            uint224 index = safe224(
                add_(Double({ mantissa: borrowIndex }), ratio).mantissa,
                "new index exceeds 224 bits"
            );

            if (isTimeBased) {
                borrowStateTimeBased.index = index;
                borrowStateTimeBased.timestamp = blockNumberOrTimestamp;
            } else {
                borrowState.index = index;
                borrowState.block = uint32(blockNumberOrTimestamp);
            }
        } else if (deltaBlocksOrTimestamp > 0) {
            if (isTimeBased) {
                borrowStateTimeBased.timestamp = blockNumberOrTimestamp;
            } else {
                borrowState.block = uint32(blockNumberOrTimestamp);
            }
        }

        emit RewardTokenBorrowIndexUpdated(ltToken, marketBorrowIndex);
    }

    /**
     * @notice Initializes the market state for a specific ltToken called when contract is block-based
     * @param ltToken The address of the ltToken to be initialized
     * @param blockNumber current block number
     */
    function _initializeMarketBlockBased(address ltToken, uint32 blockNumber) internal {
        RewardToken storage supplyState = rewardTokenSupplyState[ltToken];
        RewardToken storage borrowState = rewardTokenBorrowState[ltToken];

        /*
         * Update market state indices
         */
        if (supplyState.index == 0) {
            // Initialize supply state index with default value
            supplyState.index = INITIAL_INDEX;
        }

        if (borrowState.index == 0) {
            // Initialize borrow state index with default value
            borrowState.index = INITIAL_INDEX;
        }

        /*
         * Update market state block numbers
         */
        supplyState.block = borrowState.block = blockNumber;
    }

    /**
     * @notice Initializes the market state for a specific ltToken called when contract is time-based
     * @param ltToken The address of the ltToken to be initialized
     * @param blockTimestamp current block timestamp
     */
    function _initializeMarketTimestampBased(address ltToken, uint256 blockTimestamp) internal {
        TimeBasedRewardToken storage supplyState = rewardTokenSupplyStateTimeBased[ltToken];
        TimeBasedRewardToken storage borrowState = rewardTokenBorrowStateTimeBased[ltToken];

        /*
         * Update market state indices
         */
        if (supplyState.index == 0) {
            // Initialize supply state index with default value
            supplyState.index = INITIAL_INDEX;
        }

        if (borrowState.index == 0) {
            // Initialize borrow state index with default value
            borrowState.index = INITIAL_INDEX;
        }

        /*
         * Update market state block timestamp
         */
        supplyState.timestamp = borrowState.timestamp = blockTimestamp;
    }
}
