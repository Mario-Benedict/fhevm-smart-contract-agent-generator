// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DeFiPrivateOptionsVault
/// @notice Options vault where strike prices and premiums are encrypted.
///         Option writers lock collateral; buyers pay encrypted premiums.
///         Exercise is possible when underlying price exceeds encrypted strike.
contract DeFiPrivateOptionsVault is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum OptionType { Call, Put }

    struct Option {
        OptionType optionType;
        address writer;
        address buyer;
        euint64 strikePrice;
        euint64 premium;
        euint64 collateral;
        uint256 expiry;
        bool exercised;
        bool expired;
    }

    mapping(uint256 => Option) private options;
    uint256 public optionCount;
    euint64 private _totalCollateralLocked;
    euint64 private _totalPremiumsCollected;

    event OptionWritten(uint256 indexed id, address writer, OptionType optType);
    event OptionBought(uint256 indexed id, address buyer);
    event OptionExercised(uint256 indexed id);
    event OptionExpired(uint256 indexed id);

    constructor() Ownable(msg.sender) {
        _totalCollateralLocked = FHE.asEuint64(0);
        _totalPremiumsCollected = FHE.asEuint64(0);
        FHE.allowThis(_totalCollateralLocked);
        FHE.allowThis(_totalPremiumsCollected);
    }

    function writeOption(
        OptionType optType,
        externalEuint64 encStrike, bytes calldata sProof,
        externalEuint64 encPremium, bytes calldata pProof,
        externalEuint64 encCollateral, bytes calldata cProof,
        uint256 expiryDays
    ) external nonReentrant returns (uint256 id) {
        id = optionCount++;
        euint64 strike = FHE.fromExternal(encStrike, sProof);
        euint64 premium = FHE.fromExternal(encPremium, pProof);
        euint64 collateral = FHE.fromExternal(encCollateral, cProof);
        options[id].optionType = optType;
        options[id].writer = msg.sender;
        options[id].buyer = address(0);
        options[id].strikePrice = strike;
        options[id].premium = premium;
        options[id].collateral = collateral;
        options[id].expiry = block.timestamp + expiryDays * 1 days;
        options[id].exercised = false;
        options[id].expired = false;
        _totalCollateralLocked = FHE.add(_totalCollateralLocked, collateral);
        FHE.allowThis(options[id].strikePrice);
        FHE.allow(options[id].strikePrice, msg.sender);
        FHE.allowThis(options[id].premium);
        FHE.allowThis(options[id].collateral);
        FHE.allow(options[id].collateral, msg.sender);
        FHE.allowThis(_totalCollateralLocked);
        emit OptionWritten(id, msg.sender, optType);
    }

    function buyOption(uint256 id) external nonReentrant {
        Option storage opt = options[id];
        require(opt.buyer == address(0), "Already bought");
        require(block.timestamp < opt.expiry, "Expired");
        opt.buyer = msg.sender;
        _totalPremiumsCollected = FHE.add(_totalPremiumsCollected, opt.premium);
        FHE.allow(opt.strikePrice, msg.sender);
        FHE.allow(opt.premium, msg.sender);
        FHE.allowThis(_totalPremiumsCollected);
        emit OptionBought(id, msg.sender);
    }

    function exercise(uint256 id, externalEuint64 encCurrentPrice, bytes calldata proof) external nonReentrant {
        Option storage opt = options[id];
        require(opt.buyer == msg.sender, "Not buyer");
        require(!opt.exercised && !opt.expired, "Not active");
        require(block.timestamp < opt.expiry, "Expired");
        euint64 currentPrice = FHE.fromExternal(encCurrentPrice, proof);
        ebool profitable;
        if (opt.optionType == OptionType.Call) {
            profitable = FHE.gt(currentPrice, opt.strikePrice);
        } else {
            profitable = FHE.lt(currentPrice, opt.strikePrice);
        }
        euint64 payout = FHE.select(profitable, opt.collateral, FHE.asEuint64(0));
        opt.exercised = true;
        ebool _safeSub124 = FHE.ge(_totalCollateralLocked, opt.collateral);
        _totalCollateralLocked = FHE.select(_safeSub124, FHE.sub(_totalCollateralLocked, opt.collateral), FHE.asEuint64(0));
        FHE.allow(payout, msg.sender);
        FHE.allowThis(_totalCollateralLocked);
        emit OptionExercised(id);
    }

    function expireOption(uint256 id) external onlyOwner {
        Option storage opt = options[id];
        require(!opt.exercised && !opt.expired, "Not active");
        require(block.timestamp >= opt.expiry, "Not expired");
        opt.expired = true;
        ebool _safeSub125 = FHE.ge(_totalCollateralLocked, opt.collateral);
        _totalCollateralLocked = FHE.select(_safeSub125, FHE.sub(_totalCollateralLocked, opt.collateral), FHE.asEuint64(0));
        FHE.allow(opt.collateral, opt.writer);
        FHE.allowThis(_totalCollateralLocked);
        emit OptionExpired(id);
    }

    function allowVaultStats(address viewer) external onlyOwner {
        FHE.allow(_totalCollateralLocked, viewer);
        FHE.allow(_totalPremiumsCollected, viewer);
    }
}
