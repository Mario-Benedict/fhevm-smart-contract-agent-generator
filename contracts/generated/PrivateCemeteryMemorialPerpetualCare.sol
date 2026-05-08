// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateCemeteryMemorialPerpetualCare
/// @notice Encrypted cemetery perpetual care fund: hidden interment rights pricing,
///         confidential maintenance endowment balances, private family prepayment
///         arrangements, and encrypted memorial service revenue splits.
contract PrivateCemeteryMemorialPerpetualCare is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum IntermentType { GroundBurial, Mausoleum, Columbarium, AshGarden, TreeBurial }
    enum ServicePackage { BasicService, Standard, Premium, GrandMemorial }

    struct IntermentRight {
        address rightHolder;
        address decedent;
        IntermentType intermentType;
        ServicePackage servicePackage;
        string plotRef;
        euint64 intermentRightPriceUSD; // encrypted right price
        euint64 perpetualCareFeeUSD;    // encrypted perpetual care fee
        euint64 servicePackageCostUSD;  // encrypted service package
        euint64 prepaidMemorialUSD;     // encrypted prepaid amount
        euint16 maintenanceScoreBps;    // encrypted maintenance quality
        uint256 purchasedAt;
        bool used;
    }

    mapping(uint256 => IntermentRight) private rights;
    mapping(address => bool) public isCemeteryAdmin;

    uint256 public rightCount;
    euint64 private _totalEndowmentFundUSD;
    euint64 private _totalServiceRevenueUSD;

    event RightPurchased(uint256 indexed id, IntermentType intermentType, ServicePackage pkg);
    event ServiceRendered(uint256 indexed id, uint256 renderedAt);

    modifier onlyCemeteryAdmin() {
        require(isCemeteryAdmin[msg.sender] || msg.sender == owner(), "Not cemetery admin");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalEndowmentFundUSD = FHE.asEuint64(0);
        _totalServiceRevenueUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalEndowmentFundUSD);
        FHE.allowThis(_totalServiceRevenueUSD);
        isCemeteryAdmin[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addAdmin(address a) external onlyOwner { isCemeteryAdmin[a] = true; }

    function purchaseIntermentRight(
        IntermentType intermentType, ServicePackage servicePackage, string calldata plotRef,
        externalEuint64 encRightPrice, bytes calldata rpProof,
        externalEuint64 encPerpetualCare, bytes calldata pcProof,
        externalEuint64 encServicePkg, bytes calldata spProof,
        externalEuint64 encPrepaid, bytes calldata ppProof
    ) external whenNotPaused nonReentrant returns (uint256 id) {
        euint64 rightPrice = FHE.fromExternal(encRightPrice, rpProof);
        euint64 perpetualCare = FHE.fromExternal(encPerpetualCare, pcProof);
        euint64 servicePkg = FHE.fromExternal(encServicePkg, spProof);
        euint64 prepaid = FHE.fromExternal(encPrepaid, ppProof);
        id = rightCount++;
        rights[id] = IntermentRight({
            rightHolder: msg.sender, decedent: address(0), intermentType: intermentType,
            servicePackage: servicePackage, plotRef: plotRef, intermentRightPriceUSD: rightPrice,
            perpetualCareFeeUSD: perpetualCare, servicePackageCostUSD: servicePkg,
            prepaidMemorialUSD: prepaid, maintenanceScoreBps: FHE.asEuint16(10000),
            purchasedAt: block.timestamp, used: false
        });
        _totalEndowmentFundUSD = FHE.add(_totalEndowmentFundUSD, perpetualCare);
        _totalServiceRevenueUSD = FHE.add(_totalServiceRevenueUSD, rightPrice);
        FHE.allowThis(rights[id].intermentRightPriceUSD); FHE.allow(rights[id].intermentRightPriceUSD, msg.sender);
        FHE.allowThis(rights[id].perpetualCareFeeUSD); FHE.allow(rights[id].perpetualCareFeeUSD, msg.sender);
        FHE.allowThis(rights[id].servicePackageCostUSD); FHE.allow(rights[id].servicePackageCostUSD, msg.sender);
        FHE.allowThis(rights[id].prepaidMemorialUSD); FHE.allow(rights[id].prepaidMemorialUSD, msg.sender);
        FHE.allowThis(rights[id].maintenanceScoreBps);
        FHE.allowThis(_totalEndowmentFundUSD);
        FHE.allowThis(_totalServiceRevenueUSD);
        emit RightPurchased(id, intermentType, servicePackage);
    }

    function renderService(uint256 rightId, address decedent) external onlyCemeteryAdmin {
        IntermentRight storage r = rights[rightId];
        require(!r.used, "Already used");
        r.decedent = decedent;
        r.used = true;
        emit ServiceRendered(rightId, block.timestamp);
    }

    function updateMaintenanceScore(
        uint256 rightId,
        externalEuint16 encScore, bytes calldata proof
    ) external onlyCemeteryAdmin {
        rights[rightId].maintenanceScoreBps = FHE.fromExternal(encScore, proof);
        FHE.allowThis(rights[rightId].maintenanceScoreBps); FHE.allow(rights[rightId].maintenanceScoreBps, rights[rightId].rightHolder);
    }

    function allowFundStats(address viewer) external onlyOwner {
        FHE.allow(_totalEndowmentFundUSD, viewer);
        FHE.allow(_totalServiceRevenueUSD, viewer);
    }
}
