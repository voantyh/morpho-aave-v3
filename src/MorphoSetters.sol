// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.17;

import {IMorphoSetters} from "./interfaces/IMorpho.sol";
import {IRewardsManager} from "./interfaces/IRewardsManager.sol";
import {IPoolAddressesProvider, IPool} from "./interfaces/aave/IPool.sol";

import {Types} from "./libraries/Types.sol";
import {Events} from "./libraries/Events.sol";
import {Errors} from "./libraries/Errors.sol";
import {MarketLib} from "./libraries/MarketLib.sol";
import {PoolLib} from "./libraries/PoolLib.sol";

import {DataTypes} from "./libraries/aave/DataTypes.sol";
import {ReserveConfiguration} from "./libraries/aave/ReserveConfiguration.sol";

import {Math} from "@morpho-utils/math/Math.sol";
import {WadRayMath} from "@morpho-utils/math/WadRayMath.sol";
import {PercentageMath} from "@morpho-utils/math/PercentageMath.sol";

import {ERC20, SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";

import {MorphoInternal} from "./MorphoInternal.sol";

abstract contract MorphoSetters is IMorphoSetters, MorphoInternal {
    using PoolLib for IPool;
    using MarketLib for Types.Market;
    using SafeTransferLib for ERC20;
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

    using Math for uint256;
    using WadRayMath for uint256;

    /// SETTERS ///

    function initialize(
        address newPositionsManager,
        Types.MaxLoops memory newDefaultMaxLoops,
        uint256 newMaxSortedUsers
    ) external initializer {
        if (newMaxSortedUsers == 0) revert Errors.MaxSortedUsersCannotBeZero();

        __Ownable_init_unchained();

        _positionsManager = newPositionsManager;

        _defaultMaxLoops = newDefaultMaxLoops;
        _maxSortedUsers = newMaxSortedUsers;
    }

    function createMarket(address underlying, uint16 reserveFactor, uint16 p2pIndexCursor) external onlyOwner {
        if (underlying == address(0)) revert Errors.AddressIsZero();
        if (p2pIndexCursor > PercentageMath.PERCENTAGE_FACTOR || reserveFactor > PercentageMath.PERCENTAGE_FACTOR) {
            revert Errors.ExceedsMaxBasisPoints();
        }

        if (!_POOL.getConfiguration(underlying).getActive()) revert Errors.MarketIsNotListedOnAave();

        DataTypes.ReserveData memory reserveData = _POOL.getReserveData(underlying);

        Types.Market storage market = _market[underlying];

        if (market.isCreated()) revert Errors.MarketAlreadyCreated();

        Types.Indexes256 memory indexes;
        indexes.supply.p2pIndex = WadRayMath.RAY;
        indexes.borrow.p2pIndex = WadRayMath.RAY;
        (indexes.supply.poolIndex, indexes.borrow.poolIndex) = _POOL.getCurrentPoolIndexes(underlying);

        market.setIndexes(indexes);
        market.lastUpdateTimestamp = uint32(block.timestamp);

        market.underlying = underlying;
        market.aToken = reserveData.aTokenAddress;
        market.variableDebtToken = reserveData.variableDebtTokenAddress;
        market.reserveFactor = reserveFactor;
        market.p2pIndexCursor = p2pIndexCursor;

        _marketsCreated.push(underlying);

        ERC20(underlying).safeApprove(address(_POOL), type(uint256).max);

        emit Events.MarketCreated(underlying, reserveFactor, p2pIndexCursor);
    }

    function increaseP2PDeltas(address underlying, uint256 amount) external onlyOwner isMarketCreated(underlying) {
        Types.Indexes256 memory indexes = _updateIndexes(underlying);

        Types.Market storage market = _market[underlying];
        Types.Deltas memory deltas = market.deltas;
        uint256 poolSupplyIndex = indexes.supply.poolIndex;
        uint256 poolBorrowIndex = indexes.borrow.poolIndex;

        amount = Math.min(
            amount,
            Math.min(
                deltas.supply.amount.rayMul(indexes.supply.p2pIndex).zeroFloorSub(
                    deltas.supply.delta.rayMul(poolSupplyIndex)
                ),
                deltas.borrow.amount.rayMul(indexes.borrow.p2pIndex).zeroFloorSub(
                    deltas.borrow.delta.rayMul(poolBorrowIndex)
                )
            )
        );
        if (amount == 0) revert Errors.AmountIsZero();

        uint256 newP2PSupplyDelta = deltas.supply.delta + amount.rayDiv(poolSupplyIndex);
        uint256 newP2PBorrowDelta = deltas.borrow.delta + amount.rayDiv(poolBorrowIndex);

        market.deltas.supply.delta = newP2PSupplyDelta;
        market.deltas.borrow.delta = newP2PBorrowDelta;
        emit Events.P2PSupplyDeltaUpdated(underlying, newP2PSupplyDelta);
        emit Events.P2PBorrowDeltaUpdated(underlying, newP2PBorrowDelta);

        _POOL.borrowFromPool(underlying, amount);
        _POOL.supplyToPool(underlying, amount);

        emit Events.P2PDeltasIncreased(underlying, amount);
    }

    function setMaxSortedUsers(uint256 newMaxSortedUsers) external onlyOwner {
        if (newMaxSortedUsers == 0) revert Errors.MaxSortedUsersCannotBeZero();
        _maxSortedUsers = newMaxSortedUsers;
        emit Events.MaxSortedUsersSet(newMaxSortedUsers);
    }

    function setDefaultMaxLoops(Types.MaxLoops calldata defaultMaxLoops) external onlyOwner {
        _defaultMaxLoops = defaultMaxLoops;
        emit Events.DefaultMaxLoopsSet(
            defaultMaxLoops.supply, defaultMaxLoops.borrow, defaultMaxLoops.repay, defaultMaxLoops.withdraw
            );
    }

    function setPositionsManager(address positionsManager) external onlyOwner {
        if (positionsManager == address(0)) revert Errors.AddressIsZero();
        _positionsManager = positionsManager;
        emit Events.PositionsManagerSet(positionsManager);
    }

    function setRewardsManager(address rewardsManager) external onlyOwner {
        if (rewardsManager == address(0)) revert Errors.AddressIsZero();
        _rewardsManager = IRewardsManager(rewardsManager);
        emit Events.RewardsManagerSet(rewardsManager);
    }

    function setReserveFactor(address underlying, uint16 newReserveFactor)
        external
        onlyOwner
        isMarketCreated(underlying)
    {
        if (newReserveFactor > PercentageMath.PERCENTAGE_FACTOR) revert Errors.ExceedsMaxBasisPoints();
        _updateIndexes(underlying);

        _market[underlying].reserveFactor = newReserveFactor;
        emit Events.ReserveFactorSet(underlying, newReserveFactor);
    }

    function setP2PIndexCursor(address underlying, uint16 p2pIndexCursor)
        external
        onlyOwner
        isMarketCreated(underlying)
    {
        if (p2pIndexCursor > PercentageMath.PERCENTAGE_FACTOR) revert Errors.ExceedsMaxBasisPoints();
        _updateIndexes(underlying);

        _market[underlying].p2pIndexCursor = p2pIndexCursor;
        emit Events.P2PIndexCursorSet(underlying, p2pIndexCursor);
    }

    function setIsSupplyPaused(address underlying, bool isPaused) external onlyOwner isMarketCreated(underlying) {
        _market[underlying].pauseStatuses.isSupplyPaused = isPaused;
        emit Events.IsSupplyPausedSet(underlying, isPaused);
    }

    function setIsBorrowPaused(address underlying, bool isPaused) external onlyOwner isMarketCreated(underlying) {
        _market[underlying].pauseStatuses.isBorrowPaused = isPaused;
        emit Events.IsBorrowPausedSet(underlying, isPaused);
    }

    function setIsRepayPaused(address underlying, bool isPaused) external onlyOwner isMarketCreated(underlying) {
        _market[underlying].pauseStatuses.isRepayPaused = isPaused;
        emit Events.IsRepayPausedSet(underlying, isPaused);
    }

    function setIsWithdrawPaused(address underlying, bool isPaused) external onlyOwner isMarketCreated(underlying) {
        _market[underlying].pauseStatuses.isWithdrawPaused = isPaused;
        emit Events.IsWithdrawPausedSet(underlying, isPaused);
    }

    function setIsLiquidateCollateralPaused(address underlying, bool isPaused)
        external
        onlyOwner
        isMarketCreated(underlying)
    {
        _market[underlying].pauseStatuses.isLiquidateCollateralPaused = isPaused;
        emit Events.IsLiquidateCollateralPausedSet(underlying, isPaused);
    }

    function setIsLiquidateBorrowPaused(address underlying, bool isPaused)
        external
        onlyOwner
        isMarketCreated(underlying)
    {
        _market[underlying].pauseStatuses.isLiquidateBorrowPaused = isPaused;
        emit Events.IsLiquidateBorrowPausedSet(underlying, isPaused);
    }

    function setIsPaused(address underlying, bool isPaused) external onlyOwner isMarketCreated(underlying) {
        _setPauseStatus(underlying, isPaused);
    }

    function setIsPausedForAllMarkets(bool isPaused) external onlyOwner {
        uint256 marketsCreatedLength = _marketsCreated.length;
        for (uint256 i; i < marketsCreatedLength; ++i) {
            _setPauseStatus(_marketsCreated[i], isPaused);
        }
    }

    function setIsP2PDisabled(address underlying, bool isP2PDisabled) external onlyOwner isMarketCreated(underlying) {
        _market[underlying].pauseStatuses.isP2PDisabled = isP2PDisabled;
        emit Events.IsP2PDisabledSet(underlying, isP2PDisabled);
    }

    function setIsDeprecated(address underlying, bool isDeprecated) external onlyOwner isMarketCreated(underlying) {
        _market[underlying].pauseStatuses.isDeprecated = isDeprecated;
        emit Events.IsDeprecatedSet(underlying, isDeprecated);
    }
}
