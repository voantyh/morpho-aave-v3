// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "test/helpers/IntegrationTest.sol";

contract TestIntegrationLiquidate is IntegrationTest {
    using WadRayMath for uint256;
    using stdStorage for StdStorage;
    using PercentageMath for uint256;
    using TestMarketLib for TestMarket;

    struct LiquidateTest {
        uint256 collateralBalanceBefore;
        uint256 borrowedBalanceBefore;
        uint256 repaid;
        uint256 seized;
    }

    function testShouldNotLiquidateHealthyUser(
        address borrower,
        uint256 borrowed,
        uint256 toRepay,
        uint256 healthFactor
    ) public {
        borrower = _boundAddressNotZero(borrower);
        toRepay = bound(toRepay, 1, type(uint256).max);
        healthFactor = bound(healthFactor, Constants.DEFAULT_LIQUIDATION_THRESHOLD.percentAdd(1), type(uint96).max);

        for (uint256 collateralIndex; collateralIndex < collateralUnderlyings.length; ++collateralIndex) {
            for (uint256 borrowedIndex; borrowedIndex < borrowableUnderlyings.length; ++borrowedIndex) {
                _revert();

                TestMarket storage collateralMarket = testMarkets[collateralUnderlyings[collateralIndex]];
                TestMarket storage borrowedMarket = testMarkets[borrowableUnderlyings[borrowedIndex]];

                _createPosition(borrowedMarket, collateralMarket, borrower, borrowed, 0, healthFactor);

                user.approve(borrowedMarket.underlying, toRepay);

                vm.expectRevert(Errors.UnauthorizedLiquidate.selector);
                user.liquidate(borrowedMarket.underlying, collateralMarket.underlying, borrower, toRepay);
            }
        }
    }

    function testShouldNotSeizeCollateralOfUserNotOnCollateralMarket(
        address borrower,
        uint256 borrowed,
        uint256 toRepay,
        uint256 indexShift,
        uint256 healthFactor
    ) public {
        borrower = _boundAddressNotZero(borrower);
        indexShift = bound(indexShift, 1, collateralUnderlyings.length - 1);
        toRepay = bound(toRepay, 1, type(uint256).max);
        healthFactor = bound(
            healthFactor,
            Constants.MIN_LIQUIDATION_THRESHOLD.percentAdd(1),
            Constants.DEFAULT_LIQUIDATION_THRESHOLD.percentSub(1)
        );

        for (uint256 collateralIndex; collateralIndex < collateralUnderlyings.length; ++collateralIndex) {
            for (uint256 borrowedIndex; borrowedIndex < borrowableUnderlyings.length; ++borrowedIndex) {
                _revert();

                TestMarket storage collateralMarket = testMarkets[collateralUnderlyings[collateralIndex]];
                TestMarket storage borrowedMarket = testMarkets[borrowableUnderlyings[borrowedIndex]];

                _createPosition(borrowedMarket, collateralMarket, borrower, borrowed, 0, healthFactor);

                user.approve(borrowedMarket.underlying, toRepay);

                address collateralUnderlying =
                    collateralUnderlyings[(collateralIndex + indexShift) % collateralUnderlyings.length];

                vm.expectRevert(Errors.CollateralIsZero.selector);
                user.liquidate(borrowedMarket.underlying, collateralUnderlying, borrower, toRepay);
            }
        }
    }

    function testShouldNotLiquidateUserNotInBorrowMarket(
        address borrower,
        uint256 borrowed,
        uint256 toRepay,
        uint256 indexShift,
        uint256 healthFactor
    ) public {
        borrower = _boundAddressNotZero(borrower);
        toRepay = bound(toRepay, 1, type(uint256).max);
        indexShift = bound(indexShift, 1, borrowableUnderlyings.length - 1);
        healthFactor = bound(
            healthFactor,
            Constants.MIN_LIQUIDATION_THRESHOLD.percentAdd(1),
            Constants.DEFAULT_LIQUIDATION_THRESHOLD.percentSub(1)
        );

        for (uint256 collateralIndex; collateralIndex < collateralUnderlyings.length; ++collateralIndex) {
            for (uint256 borrowedIndex; borrowedIndex < borrowableUnderlyings.length; ++borrowedIndex) {
                _revert();

                TestMarket storage collateralMarket = testMarkets[collateralUnderlyings[collateralIndex]];
                TestMarket storage borrowedMarket = testMarkets[borrowableUnderlyings[borrowedIndex]];

                _createPosition(borrowedMarket, collateralMarket, borrower, borrowed, 0, healthFactor);

                user.approve(borrowedMarket.underlying, toRepay);

                address borrowedUnderlying =
                    borrowableUnderlyings[(borrowedIndex + indexShift) % borrowableUnderlyings.length];

                vm.expectRevert(Errors.DebtIsZero.selector);
                user.liquidate(borrowedUnderlying, collateralMarket.underlying, borrower, toRepay);
            }
        }
    }

    function testLiquidateUnhealthyUserWhenSentinelAllows(
        address borrower,
        uint256 borrowed,
        uint256 promoted,
        uint256 toRepay,
        uint256 healthFactor
    ) public {
        borrower = _boundAddressNotZero(borrower);
        healthFactor = bound(
            healthFactor,
            Constants.MIN_LIQUIDATION_THRESHOLD.percentAdd(1),
            Constants.DEFAULT_LIQUIDATION_THRESHOLD.percentSub(1)
        );

        LiquidateTest memory test;

        for (uint256 collateralIndex; collateralIndex < collateralUnderlyings.length; ++collateralIndex) {
            for (uint256 borrowedIndex; borrowedIndex < borrowableUnderlyings.length; ++borrowedIndex) {
                _revert();

                TestMarket storage collateralMarket = testMarkets[collateralUnderlyings[collateralIndex]];
                TestMarket storage borrowedMarket = testMarkets[borrowableUnderlyings[borrowedIndex]];

                uint256 promotionFactor = bound(promoted, 0, WadRayMath.WAD);
                toRepay = bound(toRepay, borrowedMarket.minAmount, type(uint256).max);

                (test.borrowedBalanceBefore, test.collateralBalanceBefore) =
                    _createPosition(borrowedMarket, collateralMarket, borrower, borrowed, promotionFactor, healthFactor);

                user.approve(borrowedMarket.underlying, toRepay);

                _assertEvents(address(user), borrower, collateralMarket, borrowedMarket);

                (test.repaid, test.seized) =
                    user.liquidate(borrowedMarket.underlying, collateralMarket.underlying, borrower, toRepay);

                _assertDefaultLiquidation(test, borrowedMarket, collateralMarket, borrower);
            }
        }
    }

    function testShouldNotLiquidateUnhealthyUserWhenSentinelDisallows(
        address borrower,
        uint256 borrowed,
        uint256 toRepay,
        uint256 healthFactor
    ) public {
        borrower = _boundAddressNotZero(borrower);
        toRepay = bound(toRepay, 1, type(uint256).max);
        healthFactor = bound(
            healthFactor,
            Constants.MIN_LIQUIDATION_THRESHOLD.percentAdd(1),
            Constants.DEFAULT_LIQUIDATION_THRESHOLD.percentSub(1)
        );

        oracleSentinel.setLiquidationAllowed(false);

        LiquidateTest memory test;

        for (uint256 collateralIndex; collateralIndex < collateralUnderlyings.length; ++collateralIndex) {
            for (uint256 borrowedIndex; borrowedIndex < borrowableUnderlyings.length; ++borrowedIndex) {
                _revert();

                TestMarket storage collateralMarket = testMarkets[collateralUnderlyings[collateralIndex]];
                TestMarket storage borrowedMarket = testMarkets[borrowableUnderlyings[borrowedIndex]];

                (test.borrowedBalanceBefore, test.collateralBalanceBefore) =
                    _createPosition(borrowedMarket, collateralMarket, borrower, borrowed, 0, healthFactor);

                vm.expectRevert(Errors.SentinelLiquidateNotEnabled.selector);
                user.liquidate(borrowedMarket.underlying, collateralMarket.underlying, borrower, toRepay);
            }
        }
    }

    function testFullLiquidateUnhealthyUserWhenSentinelDisallowsButHealthFactorVeryLow(
        address borrower,
        uint256 borrowed,
        uint256 promoted,
        uint256 toRepay,
        uint256 healthFactor
    ) public {
        borrower = _boundAddressNotZero(borrower);
        healthFactor = bound(healthFactor, 1e12, Constants.MIN_LIQUIDATION_THRESHOLD.percentSub(1));

        LiquidateTest memory test;

        for (uint256 collateralIndex; collateralIndex < collateralUnderlyings.length; ++collateralIndex) {
            for (uint256 borrowedIndex; borrowedIndex < borrowableUnderlyings.length; ++borrowedIndex) {
                _revert();

                TestMarket storage collateralMarket = testMarkets[collateralUnderlyings[collateralIndex]];
                TestMarket storage borrowedMarket = testMarkets[borrowableUnderlyings[borrowedIndex]];

                uint256 promotionFactor = bound(promoted, 0, WadRayMath.WAD);
                (test.borrowedBalanceBefore, test.collateralBalanceBefore) =
                    _createPosition(borrowedMarket, collateralMarket, borrower, borrowed, promotionFactor, healthFactor);
                toRepay = bound(toRepay, test.borrowedBalanceBefore, type(uint256).max);

                user.approve(borrowedMarket.underlying, toRepay);

                _assertEvents(address(user), borrower, collateralMarket, borrowedMarket);

                (test.repaid, test.seized) =
                    user.liquidate(borrowedMarket.underlying, collateralMarket.underlying, borrower, toRepay);

                _assertFullLiquidation(test, borrowedMarket, collateralMarket, borrower);
            }
        }
    }

    function testLiquidateUnhealthyUserWhenSupplyCapExceeded(
        address borrower,
        uint256 borrowed,
        uint256 toRepay,
        uint256 supplyCap,
        uint256 healthFactor
    ) public {
        borrower = _boundAddressNotZero(borrower);
        healthFactor = bound(
            healthFactor,
            Constants.MIN_LIQUIDATION_THRESHOLD.percentAdd(1),
            Constants.DEFAULT_LIQUIDATION_THRESHOLD.percentSub(1)
        );

        LiquidateTest memory test;

        for (uint256 collateralIndex; collateralIndex < collateralUnderlyings.length; ++collateralIndex) {
            for (uint256 borrowedIndex; borrowedIndex < borrowableUnderlyings.length; ++borrowedIndex) {
                _revert();

                TestMarket storage collateralMarket = testMarkets[collateralUnderlyings[collateralIndex]];
                TestMarket storage borrowedMarket = testMarkets[borrowableUnderlyings[borrowedIndex]];

                toRepay = bound(toRepay, borrowedMarket.minAmount, type(uint256).max);

                (test.borrowedBalanceBefore, test.collateralBalanceBefore) =
                    _createPosition(borrowedMarket, collateralMarket, borrower, borrowed, WadRayMath.WAD, healthFactor); // 100% peer-to-peer.

                supplyCap = _boundSupplyCapExceeded(borrowedMarket, test.borrowedBalanceBefore, supplyCap);
                _setSupplyCap(borrowedMarket, supplyCap);

                user.approve(borrowedMarket.underlying, toRepay);

                _assertEvents(address(user), borrower, collateralMarket, borrowedMarket);

                (test.repaid, test.seized) =
                    user.liquidate(borrowedMarket.underlying, collateralMarket.underlying, borrower, toRepay);

                _assertDefaultLiquidation(test, borrowedMarket, collateralMarket, borrower);
            }
        }
    }

    function testLiquidateUnhealthyUserWhenDemotedZero(
        address borrower,
        uint256 borrowed,
        uint256 toRepay,
        uint256 healthFactor
    ) public {
        borrower = _boundAddressNotZero(borrower);
        healthFactor = bound(
            healthFactor,
            Constants.MIN_LIQUIDATION_THRESHOLD.percentAdd(1),
            Constants.DEFAULT_LIQUIDATION_THRESHOLD.percentSub(1)
        );

        LiquidateTest memory test;

        for (uint256 collateralIndex; collateralIndex < collateralUnderlyings.length; ++collateralIndex) {
            for (uint256 borrowedIndex; borrowedIndex < borrowableUnderlyings.length; ++borrowedIndex) {
                _revert();

                TestMarket storage collateralMarket = testMarkets[collateralUnderlyings[collateralIndex]];
                TestMarket storage borrowedMarket = testMarkets[borrowableUnderlyings[borrowedIndex]];

                toRepay = bound(toRepay, borrowedMarket.minAmount, type(uint256).max);

                (test.borrowedBalanceBefore, test.collateralBalanceBefore) =
                    _createPosition(borrowedMarket, collateralMarket, borrower, borrowed, WadRayMath.WAD, healthFactor); // 100% peer-to-peer.

                // Set the max iterations to 0 upon repay to skip demotion and fallback to supply delta.
                morpho.setDefaultIterations(Types.Iterations({repay: 0, withdraw: 10}));

                user.approve(borrowedMarket.underlying, toRepay);

                _assertEvents(address(user), borrower, collateralMarket, borrowedMarket);

                (test.repaid, test.seized) =
                    user.liquidate(borrowedMarket.underlying, collateralMarket.underlying, borrower, toRepay);

                _assertDefaultLiquidation(test, borrowedMarket, collateralMarket, borrower);
            }
        }
    }

    function testFullLiquidateAnyUserOnDeprecatedMarket(
        address borrower,
        uint256 borrowed,
        uint256 promoted,
        uint256 toRepay,
        uint256 healthFactor
    ) public {
        borrower = _boundAddressNotZero(borrower);
        healthFactor = bound(healthFactor, 1e12, type(uint96).max);

        LiquidateTest memory test;

        for (uint256 collateralIndex; collateralIndex < collateralUnderlyings.length; ++collateralIndex) {
            for (uint256 borrowedIndex; borrowedIndex < borrowableUnderlyings.length; ++borrowedIndex) {
                _revert();

                TestMarket storage collateralMarket = testMarkets[collateralUnderlyings[collateralIndex]];
                TestMarket storage borrowedMarket = testMarkets[borrowableUnderlyings[borrowedIndex]];

                uint256 promotionFactor = bound(promoted, 0, WadRayMath.WAD);
                (test.borrowedBalanceBefore, test.collateralBalanceBefore) =
                    _createPosition(borrowedMarket, collateralMarket, borrower, borrowed, promotionFactor, healthFactor);
                toRepay = bound(toRepay, test.borrowedBalanceBefore, type(uint256).max);

                morpho.setIsBorrowPaused(borrowedMarket.underlying, true);
                morpho.setIsDeprecated(borrowedMarket.underlying, true);

                user.approve(borrowedMarket.underlying, toRepay);

                _assertEvents(address(user), borrower, collateralMarket, borrowedMarket);

                (test.repaid, test.seized) =
                    user.liquidate(borrowedMarket.underlying, collateralMarket.underlying, borrower, toRepay);

                _assertFullLiquidation(test, borrowedMarket, collateralMarket, borrower);
            }
        }
    }

    function testShouldUpdateIndexesAfterLiquidate(
        uint256 blocks,
        address borrower,
        uint256 borrowed,
        uint256 toRepay,
        uint256 healthFactor
    ) public {
        blocks = _boundBlocks(blocks);
        borrower = _boundAddressNotZero(borrower);
        healthFactor = bound(healthFactor, 1e6, Constants.DEFAULT_LIQUIDATION_THRESHOLD.percentSub(1));

        for (uint256 collateralIndex; collateralIndex < collateralUnderlyings.length; ++collateralIndex) {
            for (uint256 borrowedIndex; borrowedIndex < borrowableUnderlyings.length; ++borrowedIndex) {
                _revert();

                TestMarket storage collateralMarket = testMarkets[collateralUnderlyings[collateralIndex]];
                TestMarket storage borrowedMarket = testMarkets[borrowableUnderlyings[borrowedIndex]];

                _createPosition(borrowedMarket, collateralMarket, borrower, borrowed, 0, healthFactor);
                toRepay = bound(toRepay, borrowedMarket.minAmount, type(uint256).max);

                _forward(blocks);

                Types.Indexes256 memory futureCollateralIndexes = morpho.updatedIndexes(collateralMarket.underlying);
                Types.Indexes256 memory futureBorrowedIndexes = morpho.updatedIndexes(borrowedMarket.underlying);

                user.approve(borrowedMarket.underlying, toRepay);

                vm.expectEmit(true, true, true, false, address(morpho));
                emit Events.IndexesUpdated(borrowedMarket.underlying, 0, 0, 0, 0);

                if (borrowedMarket.underlying != collateralMarket.underlying) {
                    vm.expectEmit(true, true, true, false, address(morpho));
                    emit Events.IndexesUpdated(collateralMarket.underlying, 0, 0, 0, 0);
                }

                user.liquidate(borrowedMarket.underlying, collateralMarket.underlying, borrower, toRepay);

                _assertMarketUpdatedIndexes(morpho.market(collateralMarket.underlying), futureCollateralIndexes);
                _assertMarketUpdatedIndexes(morpho.market(borrowedMarket.underlying), futureBorrowedIndexes);
            }
        }
    }

    function testShouldRevertWhenCollateralMarketNotCreated(address underlying, address borrower, uint256 amount)
        public
    {
        borrower = _boundAddressNotZero(borrower);
        _assumeNotUnderlying(underlying);

        for (uint256 borrowedIndex; borrowedIndex < borrowableUnderlyings.length; ++borrowedIndex) {
            _revert();

            TestMarket storage borrowedMarket = testMarkets[borrowableUnderlyings[borrowedIndex]];

            vm.expectRevert(); // Indexes calculation revert because indexes are updated before the market created check.
            user.liquidate(borrowedMarket.underlying, underlying, borrower, amount);
        }
    }

    function testShouldRevertWhenBorrowMarketNotCreated(address underlying, address borrower, uint256 amount) public {
        borrower = _boundAddressNotZero(borrower);
        _assumeNotUnderlying(underlying);

        for (uint256 collateralIndex; collateralIndex < collateralUnderlyings.length; ++collateralIndex) {
            _revert();

            TestMarket storage collateralMarket = testMarkets[collateralUnderlyings[collateralIndex]];

            vm.expectRevert(); // Indexes calculation revert because indexes are updated before the market created check.
            user.liquidate(underlying, collateralMarket.underlying, borrower, amount);
        }
    }

    function testShouldRevertWhenLiquidateBorrowIsPaused(address borrower, uint256 amount) public {
        borrower = _boundAddressNotZero(borrower);

        for (uint256 collateralIndex; collateralIndex < collateralUnderlyings.length; ++collateralIndex) {
            for (uint256 borrowedIndex; borrowedIndex < borrowableUnderlyings.length; ++borrowedIndex) {
                _revert();

                TestMarket storage collateralMarket = testMarkets[collateralUnderlyings[collateralIndex]];
                TestMarket storage borrowedMarket = testMarkets[borrowableUnderlyings[borrowedIndex]];

                morpho.setIsLiquidateBorrowPaused(borrowedMarket.underlying, true);

                vm.expectRevert(Errors.LiquidateBorrowIsPaused.selector);
                user.liquidate(borrowedMarket.underlying, collateralMarket.underlying, borrower, amount);
            }
        }
    }

    function testShouldRevertWhenLiquidateCollateralIsPaused(address borrower, uint256 amount) public {
        borrower = _boundAddressNotZero(borrower);

        for (uint256 collateralIndex; collateralIndex < collateralUnderlyings.length; ++collateralIndex) {
            for (uint256 borrowedIndex; borrowedIndex < borrowableUnderlyings.length; ++borrowedIndex) {
                _revert();

                TestMarket storage collateralMarket = testMarkets[collateralUnderlyings[collateralIndex]];
                TestMarket storage borrowedMarket = testMarkets[borrowableUnderlyings[borrowedIndex]];

                morpho.setIsLiquidateCollateralPaused(collateralMarket.underlying, true);

                vm.expectRevert(Errors.LiquidateCollateralIsPaused.selector);
                user.liquidate(borrowedMarket.underlying, collateralMarket.underlying, borrower, amount);
            }
        }
    }

    function testShouldRevertWhenBorrowerZero(uint256 amount) public {
        for (uint256 collateralIndex; collateralIndex < collateralUnderlyings.length; ++collateralIndex) {
            for (uint256 borrowedIndex; borrowedIndex < borrowableUnderlyings.length; ++borrowedIndex) {
                _revert();

                TestMarket storage collateralMarket = testMarkets[collateralUnderlyings[collateralIndex]];
                TestMarket storage borrowedMarket = testMarkets[borrowableUnderlyings[borrowedIndex]];

                vm.expectRevert(Errors.AddressIsZero.selector);
                user.liquidate(borrowedMarket.underlying, collateralMarket.underlying, address(0), amount);
            }
        }
    }

    function _assertDefaultLiquidation(
        LiquidateTest memory test,
        TestMarket storage borrowedMarket,
        TestMarket storage collateralMarket,
        address borrower
    ) internal {
        assertLe(test.repaid, test.borrowedBalanceBefore.percentMul(Constants.DEFAULT_CLOSE_FACTOR));

        assertApproxEqAbs(
            morpho.borrowBalance(borrowedMarket.underlying, borrower) + test.repaid,
            test.borrowedBalanceBefore,
            2,
            "borrowBalanceAfter != borrowedBalanceBefore - repaid"
        );
        assertApproxEqAbs(
            morpho.collateralBalance(collateralMarket.underlying, borrower) + test.seized,
            test.collateralBalanceBefore,
            1,
            "collateralBalanceAfter != collateralBalanceBefore - seized"
        );
    }

    function _assertFullLiquidation(
        LiquidateTest memory test,
        TestMarket storage borrowedMarket,
        TestMarket storage collateralMarket,
        address borrower
    ) internal {
        assertLe(test.repaid, test.borrowedBalanceBefore.percentMul(Constants.MAX_CLOSE_FACTOR));

        assertApproxEqAbs(
            morpho.borrowBalance(borrowedMarket.underlying, borrower) + test.repaid,
            test.borrowedBalanceBefore,
            2,
            "borrowBalanceAfter != borrowedBalanceBefore - repaid"
        );
        assertApproxEqAbs(
            morpho.collateralBalance(collateralMarket.underlying, borrower) + test.seized,
            test.collateralBalanceBefore,
            1,
            "collateralBalanceAfter != collateralBalanceBefore - seized"
        );

        // Either all the collateral got seized, or all the debt got repaid.
        if (morpho.collateralBalance(collateralMarket.underlying, borrower) != 0) {
            assertEq(morpho.borrowBalance(collateralMarket.underlying, borrower), 0, "borrowBalanceAfter != 0");
        }
    }

    function _assertEvents(
        address liquidator,
        address borrower,
        TestMarket storage collateralMarket,
        TestMarket storage borrowedMarket
    ) internal {
        vm.expectEmit(true, true, true, false, address(morpho));
        emit Events.Repaid(liquidator, borrower, borrowedMarket.underlying, 0, 0, 0);

        vm.expectEmit(true, true, true, false, address(morpho));
        emit Events.CollateralWithdrawn(address(user), borrower, liquidator, collateralMarket.underlying, 0, 0);

        vm.expectEmit(true, true, true, false, address(morpho));
        emit Events.Liquidated(address(user), borrower, borrowedMarket.underlying, 0, address(0), 0);
    }

    function _createPosition(
        TestMarket storage borrowedMarket,
        TestMarket storage collateralMarket,
        address borrower,
        uint256 borrowed,
        uint256 promotionFactor,
        uint256 healthFactor
    ) internal returns (uint256 borrowBalance, uint256 collateralBalance) {
        borrowed = _boundBorrow(borrowedMarket, borrowed);

        uint256 collateral;
        (collateral, borrowed) = _borrowWithCollateral(
            borrower, collateralMarket, borrowedMarket, borrowed, borrower, borrower, DEFAULT_MAX_ITERATIONS
        );

        // Otherwise Morpho cannot perform a liquidation because its HF cannot cover the collateral seized.
        _deposit(collateralMarket, collateral, address(morpho));

        _promoteBorrow(promoter1, borrowedMarket, borrowed.wadMul(promotionFactor));

        stdstore.target(address(morpho)).sig("scaledCollateralBalance(address,address)").with_key(
            collateralMarket.underlying
        ).with_key(borrower).checked_write(
            morpho.scaledCollateralBalance(collateralMarket.underlying, borrower).rayMul(
                (collateralMarket.ltv - 1).rayDiv(collateralMarket.lt)
            ).wadMul(healthFactor)
        );

        Types.LiquidityData memory liquidityData = morpho.liquidityData(borrower);
        console2.log(healthFactor, liquidityData.maxDebt.wadDiv(liquidityData.debt));

        borrowBalance = morpho.borrowBalance(borrowedMarket.underlying, borrower);
        collateralBalance = morpho.collateralBalance(collateralMarket.underlying, borrower);
    }
}
