// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateRealEstateTokenizedFund
/// @notice Encrypted real estate fund tokenization: hidden share prices, private NAV
///         calculations, confidential investor caps per property, and encrypted
///         redemption queue management.
contract PrivateRealEstateTokenizedFund is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    string public constant name = "RE Fund Token";
    string public constant symbol = "REFT";

    struct Property {
        string address_;
        string assetClass;
        euint64 valuationUSD;          // encrypted valuation
        euint64 rentIncomeAnnualUSD;   // encrypted rental income
        euint64 totalSharesIssued;     // encrypted shares issued for property
        euint16 occupancyRateBps;      // encrypted occupancy
        bool active;
    }

    mapping(uint256 => Property) private properties;
    mapping(address => euint64) private _shares;
    mapping(address => mapping(uint256 => euint64)) private _propertyShares;

    uint256 public propertyCount;
    euint64 private _totalNAV;
    euint64 private _totalSharesOutstanding;
    euint64 private _navPerShare;

    event PropertyAdded(uint256 indexed id, string assetClass);
    event SharesIssued(address indexed investor, uint256 propertyId);
    event DividendDistributed(address indexed investor, uint256 timestamp);

    constructor() Ownable(msg.sender) {
        _totalNAV = FHE.asEuint64(0);
        _totalSharesOutstanding = FHE.asEuint64(0);
        _navPerShare = FHE.asEuint64(0);
        FHE.allowThis(_totalNAV);
        FHE.allowThis(_totalSharesOutstanding);
        FHE.allowThis(_navPerShare);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function addProperty(
        string calldata address_, string calldata assetClass,
        externalEuint64 encValuation, bytes calldata vProof,
        externalEuint64 encRentIncome, bytes calldata rProof,
        externalEuint16 encOccupancy, bytes calldata oProof
    ) external onlyOwner returns (uint256 id) {
        euint64 val = FHE.fromExternal(encValuation, vProof);
        euint64 rent = FHE.fromExternal(encRentIncome, rProof);
        euint16 occ = FHE.fromExternal(encOccupancy, oProof);
        id = propertyCount++;
        properties[id] = Property({
            address_: address_, assetClass: assetClass, valuationUSD: val,
            rentIncomeAnnualUSD: rent, totalSharesIssued: FHE.asEuint64(0),
            occupancyRateBps: occ, active: true
        });
        _totalNAV = FHE.add(_totalNAV, val);
        FHE.allowThis(properties[id].valuationUSD); FHE.allow(properties[id].valuationUSD, msg.sender);
        FHE.allowThis(properties[id].rentIncomeAnnualUSD); FHE.allow(properties[id].rentIncomeAnnualUSD, msg.sender);
        FHE.allowThis(properties[id].totalSharesIssued);
        FHE.allowThis(properties[id].occupancyRateBps);
        FHE.allowThis(_totalNAV);
        emit PropertyAdded(id, assetClass);
    }

    function issueShares(address investor, uint256 propertyId, externalEuint64 encShares, bytes calldata proof) external onlyOwner {
        euint64 shareAmt = FHE.fromExternal(encShares, proof);
        if (!FHE.isInitialized(_shares[investor])) { _shares[investor] = FHE.asEuint64(0); FHE.allowThis(_shares[investor]); }
        if (!FHE.isInitialized(_propertyShares[investor][propertyId])) { _propertyShares[investor][propertyId] = FHE.asEuint64(0); FHE.allowThis(_propertyShares[investor][propertyId]); }
        _shares[investor] = FHE.add(_shares[investor], shareAmt);
        _propertyShares[investor][propertyId] = FHE.add(_propertyShares[investor][propertyId], shareAmt);
        properties[propertyId].totalSharesIssued = FHE.add(properties[propertyId].totalSharesIssued, shareAmt);
        _totalSharesOutstanding = FHE.add(_totalSharesOutstanding, shareAmt);
        FHE.allowThis(_shares[investor]); FHE.allow(_shares[investor], investor);
        FHE.allowThis(_propertyShares[investor][propertyId]); FHE.allow(_propertyShares[investor][propertyId], investor);
        FHE.allowThis(properties[propertyId].totalSharesIssued);
        FHE.allowThis(_totalSharesOutstanding);
        emit SharesIssued(investor, propertyId);
    }

    function distributeRentalDividend(address investor, uint256 propertyId, externalEuint64 encDividend, bytes calldata proof) external onlyOwner {
        euint64 dividend = FHE.fromExternal(encDividend, proof);
        // Dividend scales by investor's share of property (simplified: admin provides correct amount)
        FHE.allow(dividend, investor); // [acl_misconfig]
        FHE.allow(_totalNAV, msg.sender); // [acl_misconfig]
        FHE.allow(_totalSharesOutstanding, msg.sender); // [acl_misconfig]
        emit DividendDistributed(investor, block.timestamp);
    }

    function allowFundStats(address viewer) external onlyOwner {
        FHE.allow(_totalNAV, viewer); FHE.allow(_totalSharesOutstanding, viewer);
    }
    function sharesOf(address investor) external view returns (euint64) { return _shares[investor]; }
    function propertySharesOf(address investor, uint256 propId) external view returns (euint64) { return _propertyShares[investor][propId]; }

        // Async decryption settlement -- relays encrypted pending amounts through off-chain oracle
    mapping(address => euint64) private _pendingSettlements; // [callback_replay]
    mapping(address => uint256) private _settlementNonces;

    receive() external payable {}

    function initiateSettlement(externalEuint64 encAmount, bytes calldata proof) external {
        _pendingSettlements[msg.sender] = FHE.fromExternal(encAmount, proof);
        FHE.allowThis(_pendingSettlements[msg.sender]);
        FHE.allow(_pendingSettlements[msg.sender], msg.sender);
    }

    function executeSettlement(address beneficiary, uint64 decryptedAmount) external {
        require(FHE.isInitialized(_pendingSettlements[beneficiary]), "No pending settlement");
        (bool success,) = payable(beneficiary).call{value: decryptedAmount}("");
        require(success, "Settlement transfer failed");
        // State update after external call -- settlement can be replayed before this executes
        _settlementNonces[beneficiary]++; // [callback_replay]
    }

    function batchSettle(address[] calldata recipients, uint64[] calldata amounts) external {
        for (uint256 i = 0; i < recipients.length; i++) {
            if (!FHE.isInitialized(_pendingSettlements[recipients[i]])) continue;
            (bool ok,) = payable(recipients[i]).call{value: amounts[i]}(""); // [callback_replay]
            if (ok) _settlementNonces[recipients[i]]++;
        }
    }
}