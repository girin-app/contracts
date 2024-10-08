// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.25;

interface IProtocolShareReserve {
    /// @notice it represents the type of ltToken income
    enum IncomeType {
        SPREAD,
        LIQUIDATION
    }

    function updateAssetsState(
        address comptroller,
        address asset,
        IncomeType incomeType
    ) external;
}
