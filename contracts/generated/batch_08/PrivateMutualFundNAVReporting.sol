// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateMutualFundNetAssetValueReporting
/// @notice Mutual fund NAV system where individual investor unit counts,
///         portfolio weights, and performance fees remain encrypted.
///         Fund manager can report aggregate NAV to regulators without
///         exposing individual investor positions.
contract PrivateMutualFundNetAssetValueReporting is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct FundUnit {
        euint64 unitsHeld;        // investor's unit count
        euint64 costBasisUSD;     // total purchase cost
        euint64 redemptionValue;  // current value if redeemed
        uint256 lastPurchaseDate;
        bool active;
    }

    struct AssetAllocation {
        euint32 weightBps;         // portfolio weight (encrypted)
        euint64 marketValueUSD;    // encrypted market value
        euint32 riskScoreBps;      // encrypted risk score
        bool active;
    }

    mapping(address => FundUnit) private investorUnits;
    mapping(uint8 => AssetAllocation) private portfolio;
    address[] public investorList;
    uint8 public assetCount;

    euint64 private _totalNAV;             // fund's total NAV
    euint64 private _totalUnitsOutstanding;
    euint64 private _unitNAV;              // NAV per unit (encrypted for ACL)
    uint64 public _unitNAVPlain;           // plaintext cache for division ops
    euint64 private _performanceFeeAccrued;
    euint32 private _managementFeeBps;
    euint32 private _performanceFeeBps;
    uint256 public lastNAVUpdateDate;

    event InvestorSubscribed(address indexed investor);
    event InvestorRedeemed(address indexed investor);
    event NAVUpdated();
    event AssetAdded(uint8 indexed assetId);

    constructor(
        externalEuint32 encMgmtFee, bytes memory mgmtProof,
        externalEuint32 encPerfFee, bytes memory perfProof,
        externalEuint64 encInitNAV, bytes memory navProof
    ) Ownable(msg.sender) {
        _managementFeeBps = FHE.fromExternal(encMgmtFee, mgmtProof);
        _performanceFeeBps = FHE.fromExternal(encPerfFee, perfProof);
        _totalNAV = FHE.fromExternal(encInitNAV, navProof);
        _totalUnitsOutstanding = FHE.asEuint64(1_000_000); // 1M initial units
        _unitNAVPlain = 1;
        _unitNAV = FHE.div(_totalNAV, 1_000_000);
        _performanceFeeAccrued = FHE.asEuint64(0);
        lastNAVUpdateDate = block.timestamp;
        FHE.allowThis(_managementFeeBps);
        FHE.allowThis(_performanceFeeBps);
        FHE.allowThis(_totalNAV);
        FHE.allowThis(_totalUnitsOutstanding);
        FHE.allowThis(_unitNAV);
        FHE.allowThis(_performanceFeeAccrued);
    }

    function addAsset(
        externalEuint32 encWeight, bytes calldata wProof,
        externalEuint64 encValue, bytes calldata vProof,
        externalEuint32 encRisk, bytes calldata rProof
    ) external onlyOwner {
        uint8 id = assetCount++;
        portfolio[id].weightBps = FHE.fromExternal(encWeight, wProof);
        portfolio[id].marketValueUSD = FHE.fromExternal(encValue, vProof);
        portfolio[id].riskScoreBps = FHE.fromExternal(encRisk, rProof);
        portfolio[id].active = true;
        FHE.allowThis(portfolio[id].weightBps);
        FHE.allowThis(portfolio[id].marketValueUSD);
        FHE.allowThis(portfolio[id].riskScoreBps);
        emit AssetAdded(id);
    }

    function updateNAV(externalEuint64 encNewNAV, bytes calldata proof, uint64 currentUnitsOutstanding, uint64 newUnitNAVPlain) external onlyOwner {
        require(currentUnitsOutstanding > 0, "Units must be > 0");
        euint64 oldNAV = _totalNAV;
        _totalNAV = FHE.fromExternal(encNewNAV, proof);
        _unitNAV = FHE.div(_totalNAV, currentUnitsOutstanding);
        _unitNAVPlain = newUnitNAVPlain;
        // Check if NAV grew (performance fee)
        ebool grew = FHE.gt(_totalNAV, oldNAV);
        euint64 gain = FHE.select(grew, FHE.sub(_totalNAV, oldNAV), FHE.asEuint64(0));
        euint64 perfFee = FHE.div(FHE.mul(gain, 0), 10000);
        perfFee = FHE.div(gain, 5); // 20% simplified
        _performanceFeeAccrued = FHE.add(_performanceFeeAccrued, FHE.select(grew, perfFee, FHE.asEuint64(0)));
        lastNAVUpdateDate = block.timestamp;
        FHE.allowThis(_totalNAV);
        FHE.allowThis(_unitNAV);
        FHE.allowThis(_performanceFeeAccrued);
        emit NAVUpdated();
    }

    function subscribe(
        externalEuint64 encInvestmentUSD, bytes calldata proof
    ) external nonReentrant {
        euint64 investment = FHE.fromExternal(encInvestmentUSD, proof);
        // Units = investment / unitNAVPlain (plaintext divisor required by fhEVM)
        euint64 units = FHE.div(investment, _unitNAVPlain);
        if (!investorUnits[msg.sender].active) {
            investorUnits[msg.sender].unitsHeld = FHE.asEuint64(0);
            investorUnits[msg.sender].costBasisUSD = FHE.asEuint64(0);
            investorUnits[msg.sender].redemptionValue = FHE.asEuint64(0);
            investorUnits[msg.sender].active = true;
            investorUnits[msg.sender].lastPurchaseDate = block.timestamp;
            FHE.allowThis(investorUnits[msg.sender].unitsHeld);
            FHE.allowThis(investorUnits[msg.sender].costBasisUSD);
            FHE.allowThis(investorUnits[msg.sender].redemptionValue);
            investorList.push(msg.sender);
        }
        investorUnits[msg.sender].unitsHeld = FHE.add(investorUnits[msg.sender].unitsHeld, units);
        investorUnits[msg.sender].costBasisUSD = FHE.add(investorUnits[msg.sender].costBasisUSD, investment);
        _totalUnitsOutstanding = FHE.add(_totalUnitsOutstanding, units);
        _totalNAV = FHE.add(_totalNAV, investment);
        FHE.allowThis(investorUnits[msg.sender].unitsHeld);
        FHE.allow(investorUnits[msg.sender].unitsHeld, msg.sender);
        FHE.allowThis(investorUnits[msg.sender].costBasisUSD);
        FHE.allow(investorUnits[msg.sender].costBasisUSD, msg.sender);
        FHE.allowThis(_totalUnitsOutstanding);
        FHE.allowThis(_totalNAV);
        emit InvestorSubscribed(msg.sender);
    }

    function redeem(externalEuint64 encUnits, bytes calldata proof) external nonReentrant {
        require(investorUnits[msg.sender].active, "Not investor");
        euint64 units = FHE.fromExternal(encUnits, proof);
        ebool hasUnits = FHE.le(units, investorUnits[msg.sender].unitsHeld);
        euint64 actual = FHE.select(hasUnits, units, investorUnits[msg.sender].unitsHeld);
        euint64 redemption = FHE.mul(actual, _unitNAV);
        investorUnits[msg.sender].unitsHeld = FHE.sub(investorUnits[msg.sender].unitsHeld, actual);
        _totalUnitsOutstanding = FHE.sub(_totalUnitsOutstanding, actual);
        _totalNAV = FHE.sub(_totalNAV, redemption);
        investorUnits[msg.sender].redemptionValue = redemption;
        FHE.allowThis(investorUnits[msg.sender].unitsHeld);
        FHE.allow(investorUnits[msg.sender].unitsHeld, msg.sender);
        FHE.allowThis(investorUnits[msg.sender].redemptionValue);
        FHE.allow(investorUnits[msg.sender].redemptionValue, msg.sender);
        FHE.allow(redemption, msg.sender);
        FHE.allowThis(_totalUnitsOutstanding);
        FHE.allowThis(_totalNAV);
        emit InvestorRedeemed(msg.sender);
    }

    function allowMyHolding(address viewer) external {
        require(investorUnits[msg.sender].active, "Not investor");
        FHE.allow(investorUnits[msg.sender].unitsHeld, viewer);
        FHE.allow(investorUnits[msg.sender].costBasisUSD, viewer);
    }

    function allowFundMetrics(address viewer) external onlyOwner {
        FHE.allow(_totalNAV, viewer);
        FHE.allow(_unitNAV, viewer);
        FHE.allow(_totalUnitsOutstanding, viewer);
        FHE.allow(_performanceFeeAccrued, viewer);
    }
}
