// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./OracleInterface.sol";
import "./LtTokenInterface.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract SlotMuxOracle is ResilientOracleInterface, Initializable, UUPSUpgradeable, OwnableUpgradeable, PausableUpgradeable {

    event SetOracleEnable(address indexed ltToken, address indexed underlying, bool indexed isEnable);
    event OracleInjectorUpdated(address indexed oldInjector, address indexed newInjector);
    event PriceAvailableTimeUpdated(uint256 indexed oldAvailableTime, uint256 indexed newAvailableTime);
    event OraclePriceInjected(address[] ltTokens, uint128[] prices);

    uint256[] public packedAssetNumberToPrices;
    uint256[] public packedAssetNumberToLastUpdatedAt;
    uint256 public lastUsedAssetNumber;
    mapping(address => bool) public underlyingToEnabled;
    mapping(address => uint256) public underlyingToAssetNumber;
    uint256 public priceAvailableTime;

    address private priceInjector;

    constructor(){
        _disableInitializers();
    }
    function initialize(address initialOwner_, address priceInjector_) initializer public {
        __Ownable_init();
        transferOwnership(initialOwner_);
        __Pausable_init();
        priceInjector = priceInjector_;
        priceAvailableTime = 3 hours;

        // initialize asset number
        // 기본값 이슈를 피하기위해 assetNumberToPrice에서 0,1 은 사용하지 않습니다.
        lastUsedAssetNumber = 1;
        packedAssetNumberToPrices.push(0);
        packedAssetNumberToLastUpdatedAt.push(0);
    }
    // for uups
    function _authorizeUpgrade(address) internal override onlyOwner {}

    function updatePrice(address ltToken) external {
        // 다른 컨트랙트에서 오라클 데이터 업데이트요청에는 아무 행동도 하지않습니다.
        // 인터페이스 맞추기위해 함수만 남겨놓습니다.
    }

    function updateAssetPrice(address asset) external {
        // 다른 컨트랙트에서 오라클 데이터 업데이트요청에는 아무 행동도 하지않습니다.
        // 인터페이스 맞추기위해 함수만 남겨놓습니다.
    }


    function injectPricesByLtToken(address[] memory ltTokens, uint128[]memory prices) onlyPriceInjector external {
        require(ltTokens.length == prices.length, "length not match");
        for (uint256 i = 0; i < ltTokens.length; i++) {
            address currentLoopUnderlying = _getUnderlyingAsset(ltTokens[i]);
            uint256 currentLoopAssetNumber = _getOrGenerateAssetNumber(currentLoopUnderlying);
            // 마지막 루프는 짝수개가아니므로 어차피 혼자처리
            if (i == ltTokens.length - 1) {
                _injectPrice(currentLoopAssetNumber, prices[i]);
                break;
            }

            address nextLoopUnderlying = _getUnderlyingAsset(ltTokens[i + 1]);
            uint256 nextLoopAssetNumber = _getOrGenerateAssetNumber(nextLoopUnderlying);
            // 연속된 assetNumber이고 짝수,홀수 번째로 이루어졌다면 ( e.g. 2,3 or 4,5 or 6,7 )
            // 한번에 묶어서 넣을 수 있습니다. 아니면 각각 저장합니다.
            if (currentLoopAssetNumber + 1 == nextLoopAssetNumber && currentLoopAssetNumber % 2 == 0) {
                _injectContinuousAssetPrice(
                    currentLoopAssetNumber, nextLoopAssetNumber,
                    prices[i], prices[i + 1]
                );
                i++;
                continue;
            } else {
                _injectPrice(currentLoopAssetNumber, prices[i]);
            }
        }
        emit OraclePriceInjected(ltTokens, prices);
    }

    function _getOrGenerateAssetNumber(address underlying) internal returns (uint256) {
        if (underlyingToAssetNumber[underlying] == 0) {
            lastUsedAssetNumber++;
            underlyingToAssetNumber[underlying] = lastUsedAssetNumber;
        }
        return underlyingToAssetNumber[underlying];
    }

    function _injectPrice(uint256 _assetNumber, uint128 price) internal {
        uint256 packedUpdatedAt;
        uint256 packedPrice;

        if (_assetNumber / 2 < packedAssetNumberToPrices.length) {
            if (_assetNumber % 2 == 0) {
                packedUpdatedAt = uint256(block.timestamp) << 128 | uint128(packedAssetNumberToLastUpdatedAt[_assetNumber / 2]);
                packedPrice = uint256(price) << 128 | uint128(packedAssetNumberToPrices[_assetNumber / 2]);
            } else {
                packedUpdatedAt = (packedAssetNumberToLastUpdatedAt[_assetNumber / 2] >> 128) << 128 | uint128(block.timestamp);
                packedPrice = (packedAssetNumberToPrices[_assetNumber / 2] >> 128) << 128 | price;
            }
            packedAssetNumberToPrices[_assetNumber / 2] = packedPrice;
            packedAssetNumberToLastUpdatedAt[_assetNumber / 2] = packedUpdatedAt;
        } else if (_assetNumber / 2 == packedAssetNumberToPrices.length) {
            if (_assetNumber % 2 == 0) {
                packedUpdatedAt = uint256(block.timestamp) << 128;
                packedPrice = uint256(price) << 128;
            } else {
                packedUpdatedAt = uint256(block.timestamp);
                packedPrice = uint256(price);
            }
            packedAssetNumberToPrices.push(packedPrice);
            packedAssetNumberToLastUpdatedAt.push(packedUpdatedAt);
        } else {
            revert("asset number 1 out of range");
        }
    }


    function _injectContinuousAssetPrice(
        uint256 _assetNumber1, uint256 _assetNumber2,
        uint128 price1, uint128 price2
    ) internal {
        require(_assetNumber1 % 2 == 0, "asset number 1 must be even");
        require(_assetNumber2 % 2 == 1, "asset number 2 must be odd");
        uint256 packedPrice = (uint256(price1) << 128) | uint256(price2);
        uint256 packedUpdatedAt = (uint256(block.timestamp) << 128) | uint256(block.timestamp);

        if (_assetNumber1 / 2 < packedAssetNumberToPrices.length) {
            packedAssetNumberToPrices[_assetNumber1 / 2] = packedPrice;
            packedAssetNumberToLastUpdatedAt[_assetNumber1 / 2] = packedUpdatedAt;
        } else if (_assetNumber1 / 2 == packedAssetNumberToPrices.length) {
            packedAssetNumberToPrices.push(packedPrice);
            packedAssetNumberToLastUpdatedAt.push(packedUpdatedAt);
        } else {
            revert("asset number 1 out of range");
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
        uint256 assetNumber = underlyingToAssetNumber[underlying];
        uint256 packedPrice = packedAssetNumberToPrices[assetNumber / 2];
        uint256 packedUpdatedAt = packedAssetNumberToLastUpdatedAt[assetNumber / 2];
        uint256 lastUpdatedAt;
        uint256 price;
        if (assetNumber % 2 == 0) {
            price = packedPrice >> 128;
            lastUpdatedAt = packedUpdatedAt >> 128;
        } else {
            price = uint256(uint128(packedPrice));
            lastUpdatedAt = uint256(uint128(packedUpdatedAt));
        }

        if (lastUpdatedAt + priceAvailableTime < block.timestamp) {
            revert("price not available");
        }

        return price * 10 ** (18 - IERC20Metadata(underlying).decimals());
    }

    function setOracleEnable(address ltToken, bool isEnable) onlyPriceInjectorOrOwner external {
        address underlying = _getUnderlyingAsset(ltToken);
        require(underlying != address(0), "underlying not found");
        _getOrGenerateAssetNumber(underlying);
        underlyingToEnabled[underlying] = isEnable;
        emit SetOracleEnable(ltToken, underlying, isEnable);
    }


    function _getUnderlyingAsset(address ltToken) internal view notNullAddress(ltToken) returns (address asset) {
        return LtTokenInterface(ltToken).underlying();
    }

    function pause() onlyOwner external {
        _pause();
    }

    function unPause() onlyOwner external {
        _unpause();
    }

    function updatePriceInjector(address _priceInjector) onlyOwner external {
        address oldPriceInjector = priceInjector;
        priceInjector = _priceInjector;
        emit OracleInjectorUpdated(oldPriceInjector, _priceInjector);
    }

    function updatePriceAvailableTime(uint256 _priceAvailableTime) onlyOwner external {
        uint256 oldPriceAvailableTime = priceAvailableTime;
        priceAvailableTime = _priceAvailableTime;
        emit PriceAvailableTimeUpdated(oldPriceAvailableTime, _priceAvailableTime);
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
