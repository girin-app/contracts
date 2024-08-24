// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

interface OracleInterface {
    function getPrice(address asset) external view returns (uint256);
}

interface ResilientOracleInterface is OracleInterface {
    function updatePrice(address ltToken) external;

    function updateAssetPrice(address asset) external;

    function getUnderlyingPrice(address ltToken) external view returns (uint256);
}