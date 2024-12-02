// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./OracleInterface.sol";
import "./LtTokenInterface.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract RouterOracle is ResilientOracleInterface, Initializable, UUPSUpgradeable, OwnableUpgradeable {

    constructor(){
        _disableInitializers();
    }

    mapping(address => address) public underlyingToOracleAddress;
    address private oracleInjector;


    function initialize(address initialOwner_, address oracleInjector_) initializer public {
        __Ownable_init();
        transferOwnership(initialOwner_);
        oracleInjector = oracleInjector_;
    }

    // for uups
    function _authorizeUpgrade(address) internal override onlyOwner {}

    function setLtTokenToOracle(address ltToken, address oracle) onlyOracleInjector external {
        _setLtTokenToOracle(ltToken, oracle);
    }

    function updatePrice(address ltToken) external {
        address oracle = _getLtTokenToOracle(ltToken);
        return ResilientOracleInterface(oracle).updatePrice(ltToken);
    }

    function updateAssetPrice(address asset) external {
        address oracle = underlyingToOracleAddress[asset];
        require(oracle != address(0), "oracle not found");

        return ResilientOracleInterface(oracle).updateAssetPrice(asset);
    }

    function getUnderlyingPrice(address ltToken) external view returns (uint256){
        address oracle = _getLtTokenToOracle(ltToken);
        return ResilientOracleInterface(oracle).getUnderlyingPrice(ltToken);
    }

    function getPrice(address asset) external view returns (uint256){
        address oracle = underlyingToOracleAddress[asset];
        require(oracle != address(0), "oracle not found");

        return ResilientOracleInterface(oracle).getPrice(asset);
    }

    function updateOracleInjector(address oracleInjector_) onlyOwner external {
        oracleInjector = oracleInjector_;
    }

    // internal
    function _setLtTokenToOracle(address ltToken, address oracle) internal {
        address underlying = _getUnderlyingAsset(ltToken);
        underlyingToOracleAddress[underlying] = oracle;
    }

    function _getLtTokenToOracle(address ltToken) internal view returns (address oracle) {
        address underlying = _getUnderlyingAsset(ltToken);
        return underlyingToOracleAddress[underlying];
    }


    function _getUnderlyingAsset(address ltToken) internal view notNullAddress(ltToken) returns (address asset) {
        return LtTokenInterface(ltToken).underlying();
    }


    // modifier
    modifier notNullAddress(address someone) {
        if (someone == address(0)) revert("can't be zero address");
        _;
    }

    modifier onlyOracleInjector() {
        require(msg.sender == oracleInjector, "only oracle injector can call this function");
        _;
    }

}