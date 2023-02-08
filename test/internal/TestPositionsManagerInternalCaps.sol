// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Errors} from "src/libraries/Errors.sol";
import {MorphoStorage} from "src/MorphoStorage.sol";
import {PositionsManagerInternal} from "src/PositionsManagerInternal.sol";

import {Types} from "src/libraries/Types.sol";
import {Constants} from "src/libraries/Constants.sol";

import {TestConfigLib, TestConfig} from "../helpers/TestConfigLib.sol";
import {PoolLib} from "src/libraries/PoolLib.sol";
import {MarketLib} from "src/libraries/MarketLib.sol";

import {MockPriceOracleSentinel} from "../mock/MockPriceOracleSentinel.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IPriceOracleGetter} from "@aave-v3-core/interfaces/IPriceOracleGetter.sol";
import {IPriceOracleSentinel} from "@aave-v3-core/interfaces/IPriceOracleSentinel.sol";
import {IPool, IPoolAddressesProvider} from "@aave-v3-core/interfaces/IPool.sol";

import {SafeTransferLib, ERC20} from "@solmate/utils/SafeTransferLib.sol";

import {DataTypes} from "@aave-v3-core/protocol/libraries/types/DataTypes.sol";
import {ReserveConfiguration} from "@aave-v3-core/protocol/libraries/configuration/ReserveConfiguration.sol";

import {WadRayMath} from "@morpho-utils/math/WadRayMath.sol";
import {PercentageMath} from "@morpho-utils/math/PercentageMath.sol";

import {ERC20} from "@solmate/tokens/ERC20.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import "test/helpers/InternalTest.sol";

contract TestInternalPositionsManagerInternalCaps is InternalTest, PositionsManagerInternal {
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;
    using EnumerableSet for EnumerableSet.AddressSet;
    using WadRayMath for uint256;
    using PercentageMath for uint256;
    using TestConfigLib for TestConfig;
    using PoolLib for IPool;
    using MarketLib for Types.Market;
    using SafeTransferLib for ERC20;
    using Math for uint256;

    uint256 constant MIN_AMOUNT = 1 ether;
    uint256 constant MAX_AMOUNT = type(uint96).max / 2;

    uint256 daiTokenUnit;

    IPriceOracleGetter internal priceOracle;
    address internal poolOwner;

    function setUp() public virtual override {
        poolOwner = Ownable(address(addressesProvider)).owner();

        _defaultMaxIterations = Types.MaxIterations(10, 10);

        _createMarket(dai, 0, 3_333);
        _createMarket(wbtc, 0, 3_333);
        _createMarket(usdc, 0, 3_333);
        _createMarket(usdt, 0, 3_333);
        _createMarket(wNative, 0, 3_333);

        _setBalances(address(this), type(uint256).max);

        _POOL.supplyToPool(dai, 100 ether);
        _POOL.supplyToPool(wbtc, 1e8);
        _POOL.supplyToPool(usdc, 1e8);
        _POOL.supplyToPool(usdt, 1e8);
        _POOL.supplyToPool(wNative, 1 ether);

        priceOracle = IPriceOracleGetter(_ADDRESSES_PROVIDER.getPriceOracle());

        daiTokenUnit = 10 ** _POOL.getConfiguration(dai).getDecimals();
    }

    function testAuthorizeBorrowWithNoBorrowCap(uint256 amount, uint256 totalP2P, uint256 delta) public {
        Types.Market storage market = _market[dai];
        (, Types.Indexes256 memory indexes) = _computeIndexes(dai);

        totalP2P = bound(totalP2P, 0, MAX_AMOUNT);
        delta = bound(delta, 0, totalP2P);
        amount = bound(amount, 1e10, MAX_AMOUNT);

        _setBorrowCap(dai, 0);

        market.deltas.borrow.scaledDeltaPool = delta.rayDiv(indexes.borrow.poolIndex);
        market.deltas.borrow.scaledTotalP2P = totalP2P.rayDiv(indexes.borrow.p2pIndex);

        _userCollaterals[address(this)].add(dai);
        _marketBalances[dai].collateral[address(this)] = (amount * 10).rayDiv(indexes.supply.poolIndex);

        this.authorizeBorrow(dai, amount, address(this));
    }

    function testAuthorizeBorrowShouldRevertIfExceedsBorrowCap(
        uint256 amount,
        uint256 totalP2P,
        uint256 delta,
        uint256 borrowCap
    ) public {
        Types.Market storage market = _market[dai];
        (, Types.Indexes256 memory indexes) = _computeIndexes(dai);

        uint256 poolDebt = ERC20(market.variableDebtToken).totalSupply() + ERC20(market.stableDebtToken).totalSupply();

        borrowCap = bound(
            borrowCap,
            (poolDebt / daiTokenUnit).zeroFloorSub(1_000),
            Math.min(ReserveConfiguration.MAX_VALID_BORROW_CAP, MAX_AMOUNT / daiTokenUnit)
        );
        totalP2P = bound(totalP2P, 0, ReserveConfiguration.MAX_VALID_BORROW_CAP * daiTokenUnit - poolDebt);
        delta = bound(delta, 0, totalP2P);
        amount = bound(
            amount, (borrowCap * daiTokenUnit).zeroFloorSub(totalP2P - delta).zeroFloorSub(poolDebt) + 1e10, MAX_AMOUNT
        );

        _setBorrowCap(dai, borrowCap);

        market.deltas.borrow.scaledDeltaPool = delta.rayDiv(indexes.borrow.poolIndex);
        market.deltas.borrow.scaledTotalP2P = totalP2P.rayDiv(indexes.borrow.p2pIndex);

        _userCollaterals[address(this)].add(dai);
        _marketBalances[dai].collateral[address(this)] = (amount * 10).rayDiv(indexes.supply.poolIndex);

        vm.expectRevert(abi.encodeWithSelector(Errors.ExceedsBorrowCap.selector));
        this.authorizeBorrow(dai, amount, address(this));
    }

    function testAccountBorrowShouldDecreaseIdleSupplyIfIdleSupplyExists(uint256 amount, uint256 idleSupply) public {
        Types.Market storage market = _market[dai];
        (, Types.Indexes256 memory indexes) = _computeIndexes(dai);

        _setBorrowCap(dai, 0);

        amount = bound(amount, 1e10, MAX_AMOUNT);
        idleSupply = bound(idleSupply, 1, MAX_AMOUNT);

        market.idleSupply = idleSupply;

        _userCollaterals[address(this)].add(dai);
        _marketBalances[dai].collateral[address(this)] = (amount * 10).rayDiv(indexes.supply.poolIndex);

        Types.BorrowWithdrawVars memory vars = this.accountBorrow(dai, amount, address(this), 10);
        assertEq(market.idleSupply, idleSupply.zeroFloorSub(amount));
        // TODO: add assert for borrow withdraw vars
        assertEq(vars.toBorrow, amount.zeroFloorSub(idleSupply));
        assertEq(vars.toWithdraw, 0);
    }

    function testAccountRepayShouldIncreaseIdleSupplyIfSupplyCapReached(uint256 amount, uint256 supplyCap) public {
        Types.Market storage market = _market[dai];

        uint256 totalPoolSupply = ERC20(market.aToken).totalSupply();
        supplyCap = bound(
            supplyCap,
            // Should be at least 1, but also cover some cases where supply cap is less than the current supplied.
            (totalPoolSupply / daiTokenUnit).zeroFloorSub(1_000) + 1,
            Math.min(ReserveConfiguration.MAX_VALID_SUPPLY_CAP, MAX_AMOUNT / daiTokenUnit)
        );
        // We are testing the case the supply cap is reached, so the min should be greater than the amount needed to reach the supply cap.
        amount = bound(amount, (supplyCap * daiTokenUnit).zeroFloorSub(totalPoolSupply) + 1e10, MAX_AMOUNT);

        _updateSupplierInDS(dai, address(1), 0, MAX_AMOUNT, false);
        _updateBorrowerInDS(dai, address(this), 0, MAX_AMOUNT, false);

        _setSupplyCap(dai, supplyCap);

        Types.SupplyRepayVars memory vars = this.accountRepay(dai, amount, address(this), 10);

        assertEq(market.idleSupply, amount - ((supplyCap * daiTokenUnit).zeroFloorSub(totalPoolSupply)));
        assertEq(vars.toRepay, 0);
        assertEq(vars.toSupply, amount - market.idleSupply);
    }

    function testAccountWithdrawShouldDecreaseIdleSupplyIfIdleSupplyExistsWhenSupplyInP2P(
        uint256 amount,
        uint256 idleSupply
    ) public {
        Types.Market storage market = _market[dai];
        (, Types.Indexes256 memory indexes) = _computeIndexes(dai);

        amount = bound(amount, 1e10, MAX_AMOUNT);
        idleSupply = bound(idleSupply, 1, MAX_AMOUNT);

        _updateSupplierInDS(dai, address(this), 0, MAX_AMOUNT, false);

        market.idleSupply = idleSupply;

        _userCollaterals[address(this)].add(dai);
        _marketBalances[dai].collateral[address(this)] = (amount * 10).rayDiv(indexes.supply.poolIndex);

        Types.BorrowWithdrawVars memory vars = this.accountWithdraw(dai, amount, address(this), 10);
        assertEq(market.idleSupply, idleSupply.zeroFloorSub(amount));
        assertEq(vars.toBorrow, amount.zeroFloorSub(idleSupply));
        assertEq(vars.toWithdraw, 0);
    }

    function testAccountWithdrawShouldNotDecreaseIdleSupplyIfIdleSupplyExistsWhenSupplyOnPool(
        uint256 amount,
        uint256 idleSupply
    ) public {
        Types.Market storage market = _market[dai];

        amount = bound(amount, 1, MAX_AMOUNT);
        idleSupply = bound(idleSupply, 1, amount);

        _updateSupplierInDS(dai, address(this), MAX_AMOUNT, 0, false);

        market.idleSupply = idleSupply;

        Types.BorrowWithdrawVars memory vars = this.accountWithdraw(dai, amount, address(this), 10);
        assertEq(market.idleSupply, idleSupply);
        assertEq(vars.toBorrow, 0);
        assertEq(vars.toWithdraw, amount);
    }

    function authorizeBorrow(address underlying, uint256 onPool, address borrower) external view {
        (, Types.Indexes256 memory indexes) = _computeIndexes(underlying);
        _authorizeBorrow(underlying, onPool, borrower, indexes);
    }

    function accountBorrow(address underlying, uint256 amount, address borrower, uint256 maxIterations)
        external
        returns (Types.BorrowWithdrawVars memory vars)
    {
        (, Types.Indexes256 memory indexes) = _computeIndexes(underlying);
        vars = _accountBorrow(underlying, amount, borrower, maxIterations, indexes);
    }

    function accountRepay(address underlying, uint256 amount, address onBehalf, uint256 maxIterations)
        external
        returns (Types.SupplyRepayVars memory vars)
    {
        (, Types.Indexes256 memory indexes) = _computeIndexes(underlying);
        vars = _accountRepay(underlying, amount, onBehalf, maxIterations, indexes);
    }

    function accountWithdraw(address underlying, uint256 amount, address supplier, uint256 maxIterations)
        external
        returns (Types.BorrowWithdrawVars memory vars)
    {
        (, Types.Indexes256 memory indexes) = _computeIndexes(underlying);
        vars = _accountWithdraw(underlying, amount, supplier, maxIterations, indexes);
    }
}
