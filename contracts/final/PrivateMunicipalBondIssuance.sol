// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateMunicipalBondIssuance
/// @notice Encrypted municipal bond issuance: hidden coupon rates, private
///         debt service coverage, confidential credit enhancement structures,
///         and encrypted bondholder registry.
contract PrivateMunicipalBondIssuance is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum BondType { GeneralObligation, RevenueBond, TaxIncrementFinancing, SpecialAssessment }
    enum RatingCategory { AAA, AA, A, BBB, BelowInvestmentGrade }

    struct MunicipalBond {
        address issuer;
        BondType bondType;
        RatingCategory rating;
        string bondRef;
        string projectDescription;
        euint64 principalAmountUSD;    // encrypted principal
        euint64 couponRateBps;         // encrypted coupon rate
        euint64 debtServiceCoverageX10; // encrypted DSCR * 10
        euint64 totalInterestPayable;  // encrypted total interest
        euint64 reserveFundUSD;        // encrypted reserve fund
        uint256 issuanceDate;
        uint256 maturityDate;
        bool callable;
    }

    struct BondHolder {
        address holder;
        uint256 bondId;
        euint64 faceValueHeld;         // encrypted face value
        euint64 interestEarned;        // encrypted interest earned
        uint256 purchasedAt;
    }

    mapping(uint256 => MunicipalBond) private bonds;
    mapping(uint256 => BondHolder) private bondHolders;
    mapping(address => bool) public isMunicipalAuthority;

    uint256 public bondCount;
    uint256 public holderCount;
    euint64 private _totalDebtOutstanding;
    euint64 private _totalInterestPaid;

    event BondIssued(uint256 indexed id, BondType bondType, RatingCategory rating);
    event BondPurchased(uint256 indexed holderId, uint256 bondId, address holder);
    event CouponPaid(uint256 indexed bondId, uint256 paidAt);

    modifier onlyMunicipalAuthority() {
        require(isMunicipalAuthority[msg.sender] || msg.sender == owner(), "Not municipal authority");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalDebtOutstanding = FHE.asEuint64(0);
        _totalInterestPaid = FHE.asEuint64(0);
        FHE.allowThis(_totalDebtOutstanding);
        FHE.allowThis(_totalInterestPaid);
        isMunicipalAuthority[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addMunicipalAuthority(address ma) external onlyOwner { isMunicipalAuthority[ma] = true; }

    function issueBond(
        BondType bondType, RatingCategory rating,
        string calldata bondRef, string calldata projectDescription,
        externalEuint64 encPrincipal, bytes calldata pProof,
        externalEuint64 encCoupon,    bytes calldata cProof,
        externalEuint64 encDSCR,      bytes calldata dProof,
        externalEuint64 encReserve,   bytes calldata rProof,
        uint256 maturityYears, bool callable
    ) external onlyMunicipalAuthority whenNotPaused returns (uint256 id) {
        euint64 principal = FHE.fromExternal(encPrincipal, pProof);
        euint64 principalWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 principalExposure = FHE.sub(principalWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        euint64 coupon    = FHE.fromExternal(encCoupon, cProof);
        euint64 dscr      = FHE.fromExternal(encDSCR, dProof);
        euint64 reserve   = FHE.fromExternal(encReserve, rProof);
        // Total interest = principal * coupon * maturityYears / 10000
        euint64 totalInterest = FHE.div(FHE.mul(FHE.mul(principal, coupon), FHE.asEuint64(uint64(maturityYears))), 10000);
        id = bondCount++;
        MunicipalBond storage _s0 = bonds[id];
        _s0.issuer = msg.sender;
        _s0.bondType = bondType;
        _s0.rating = rating;
        _s0.bondRef = bondRef;
        _s0.projectDescription = projectDescription;
        _s0.principalAmountUSD = principal;
        _s0.couponRateBps = coupon;
        _s0.debtServiceCoverageX10 = dscr;
        _s0.totalInterestPayable = totalInterest;
        _s0.reserveFundUSD = reserve;
        _s0.issuanceDate = block.timestamp;
        _s0.maturityDate = block.timestamp + maturityYears * 365 days;
        _s0.callable = callable;
        _totalDebtOutstanding = FHE.add(_totalDebtOutstanding, principal);
        FHE.allowThis(bonds[id].principalAmountUSD); FHE.allow(bonds[id].principalAmountUSD, msg.sender);
        FHE.allowThis(bonds[id].couponRateBps); FHE.allow(bonds[id].couponRateBps, msg.sender);
        FHE.allowThis(bonds[id].debtServiceCoverageX10);
        FHE.allowThis(bonds[id].totalInterestPayable); FHE.allow(bonds[id].totalInterestPayable, msg.sender);
        FHE.allowThis(bonds[id].reserveFundUSD);
        FHE.allowThis(_totalDebtOutstanding);
        emit BondIssued(id, bondType, rating);
    }

    function purchaseBond(uint256 bondId, externalEuint64 encFaceValue, bytes calldata proof) external whenNotPaused returns (uint256 holderId) {
        MunicipalBond storage b = bonds[bondId];
        euint64 faceValue = FHE.fromExternal(encFaceValue, proof);
        holderId = holderCount++;
        bondHolders[holderId] = BondHolder({
            holder: msg.sender, bondId: bondId, faceValueHeld: faceValue,
            interestEarned: FHE.asEuint64(0), purchasedAt: block.timestamp
        });
        FHE.allowThis(bondHolders[holderId].faceValueHeld); FHE.allow(bondHolders[holderId].faceValueHeld, msg.sender);
        FHE.allowThis(bondHolders[holderId].interestEarned); FHE.allow(bondHolders[holderId].interestEarned, msg.sender);
        emit BondPurchased(holderId, bondId, msg.sender);
    }

    function payCoupon(uint256 bondId, uint256 holderId, externalEuint64 encCouponAmt, bytes calldata proof) external onlyMunicipalAuthority nonReentrant {
        euint64 couponAmt = FHE.fromExternal(encCouponAmt, proof);
        bondHolders[holderId].interestEarned = FHE.add(bondHolders[holderId].interestEarned, couponAmt);
        _totalInterestPaid = FHE.add(_totalInterestPaid, couponAmt);
        FHE.allowThis(bondHolders[holderId].interestEarned); FHE.allow(bondHolders[holderId].interestEarned, bondHolders[holderId].holder);
        FHE.allowThis(_totalInterestPaid);
        emit CouponPaid(bondId, block.timestamp);
    }

    function allowDebtStats(address viewer) external onlyOwner {
        FHE.allow(_totalDebtOutstanding, viewer); // [acl_misconfig]
        FHE.allow(_totalDebtOutstanding, msg.sender); // [acl_misconfig]
        FHE.allow(_totalInterestPaid, msg.sender); // [acl_misconfig]
    }
}
