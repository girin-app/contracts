// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./OracleInterface.sol";
import "./ltTokenInterface.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

contract TimeoutOracle is ResilientOracleInterface, Initializable, UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable {

    event SetOracleEnable(address indexed ltToken, address indexed underlying, bool indexed isEnable);

    mapping(address => uint256) public underlyingToPrices;
    mapping(address => bool) public underlyingToEnabled;
    mapping(address => uint256) public underlyingToLastUpdatedAt;
    uint256 public priceAvailableTime;

    /// @notice Native market address
    address public nativeMarket;

    address private priceInjector;

    /// @notice Set this as asset address for Native token on each chain.This is the underlying for vBNB (on bsc)
    /// and can serve as any underlying asset of a market that supports native tokens
    address public NATIVE_TOKEN_ADDR;

    constructor(){
        _disableInitializers();
    }
    function initialize(address initialOwner_, address priceInjector_, address nativeMarket_) initializer public {
        __Ownable_init();
        transferOwnership(initialOwner_);
        __Pausable_init();
        nativeMarket = nativeMarket_;
        priceInjector = priceInjector_;
        priceAvailableTime = 3 hours;
        NATIVE_TOKEN_ADDR = 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB;
    }
    // for uups
    function _authorizeUpgrade(address) internal override onlyOwner {}

    function updatePrice(address ltToken) external {
        // it is for interface compatibility
    }

    function updateAssetPrice(address asset) external {
        // it is for interface compatibility
    }

    function injectPriceByLtToken(address ltToken, uint256 price) onlyPriceInjector external {
        address underlying = _getUnderlyingAsset(ltToken);
        require(underlying != address(0), "underlying not found");

        underlyingToPrices[underlying] = price;
        underlyingToLastUpdatedAt[underlying] = block.timestamp;
    }

    function injectPriceByUnderlying(address underlying, uint256 price) onlyPriceInjector external {
        underlyingToPrices[underlying] = price;
        underlyingToLastUpdatedAt[underlying] = block.timestamp;
    }

    function injectPricesByLtToken(address[] memory ltTokens, uint256[]memory price) onlyPriceInjector external {
        require(ltTokens.length == price.length, "length not match");
        for (uint256 i = 0; i < ltTokens.length; i++) {
            address underlying = _getUnderlyingAsset(ltTokens[i]);
            require(underlying != address(0), "underlying not found");

            underlyingToPrices[underlying] = price[i];
            underlyingToLastUpdatedAt[underlying] = block.timestamp;
        }
    }

    function injectPricesByUnderlying(address[] memory underlying, uint256[] memory price) onlyPriceInjector external {
        require(underlying.length == price.length, "length not match");
        for (uint256 i = 0; i < underlying.length; i++) {
            underlyingToPrices[underlying[i]] = price[i];
            underlyingToLastUpdatedAt[underlying[i]] = block.timestamp;
        }
    }

    function getUnderlyingPrice(address ltToken) whenNotPaused external view returns (uint256){
        address underlying = _getUnderlyingAsset(ltToken);
        require(underlying != address(0), "underlying not found");

        return _getPrice(underlying);
    }

    function getPrice(address underlying) whenNotPaused external view returns (uint256){
        return _getPrice(underlying);
    }

    function _getPrice(address underlying) onlyUnderlyingEnabled(underlying) internal view returns (uint256){
        if (underlyingToLastUpdatedAt[underlying] + priceAvailableTime < block.timestamp) {
            revert("price not available");
        }
        return underlyingToPrices[underlying];
    }

    function setOracleEnable(address ltToken, bool isEnable) onlyPriceInjectorOrOwner external {
        address underlying = _getUnderlyingAsset(ltToken);
        require(underlying != address(0), "underlying not found");
        underlyingToEnabled[underlying] = isEnable;
        emit SetOracleEnable(ltToken, underlying, isEnable);
    }


    function _getUnderlyingAsset(address ltToken) internal view notNullAddress(ltToken) returns (address asset) {
        if (ltToken == nativeMarket) {
            asset = NATIVE_TOKEN_ADDR;
        } else {
            asset = ltTokenInterface(ltToken).underlying();
        }
    }

    function pause() onlyOwner external {
        _pause();
    }

    function unPause() onlyOwner external {
        _unpause();
    }

    function updatePriceInjector(address _priceInjector) onlyOwner external {
        priceInjector = _priceInjector;
    }

    function updateNativeMarket(address _nativeMarket) onlyOwner external {
        nativeMarket = _nativeMarket;
    }

    function updatePriceAvailableTime(uint256 _priceAvailableTime) onlyOwner external {
        priceAvailableTime = _priceAvailableTime;
    }

    modifier notNullAddress(address someone) {
        if (someone == address(0)) revert("can't be zero address");
        _;
    }

    modifier onlyPriceInjector() {
        require(msg.sender == priceInjector, "only price injector can call this function");
        _;
    }

    modifier onlyPriceInjectorOrOwner() {
        require(msg.sender == priceInjector || msg.sender == owner(), "only price injector or owner can call this function");
        _;
    }

    modifier onlyUnderlyingEnabled(address underlying) {
        require(underlying != address(0), "underlying not found");
        require(underlyingToEnabled[underlying], "underlying not enabled");
        _;
    }
}
