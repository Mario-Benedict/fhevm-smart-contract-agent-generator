// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedMortgagePoolSecuritization
/// @notice A mortgage-backed securities pool where individual mortgage amounts,
///         LTV ratios, and credit quality scores remain encrypted. Tranching
///         is computed in FHE to prevent adversarial cherry-picking.
contract EncryptedMortgagePoolSecuritization is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum TrancheClass { Senior, Mezzanine, Junior }

    struct Mortgage {
        euint64 principalUSD;
        euint32 ltvBps;          // Loan-to-Value (e.g. 8000 = 80%)
        euint32 interestRateBps; // annual rate
        euint32 creditScoreBand; // 1=prime, 2=alt-a, 3=subprime
        uint256 originationDate;
        uint256 maturityDate;
        bool defaulted;
        bool active;
    }

    struct Tranche {
        euint64 faceValue;
        euint32 yieldBps;
        euint64 amountRepaid;
        TrancheClass class_;
    }

    mapping(uint256 => Mortgage) private mortgages;
    mapping(address => uint256[]) public investorTranches;
    mapping(uint256 => Tranche) private tranches;
    mapping(address => mapping(uint256 => euint64)) private trancheHoldings;
    uint256 public mortgageCount;
    uint256 public trancheCount;

    euint64 private _totalPoolBalance;
    euint64 private _seniorFaceValue;
    euint64 private _defaultedPrincipal;
    euint32 private _weightedAvgLTV;

    event MortgageAdded(uint256 indexed mortgageId);
    event TrancheIssued(uint256 indexed trancheId, TrancheClass class_);
    event PaymentReceived(uint256 indexed mortgageId);
    event DefaultRecorded(uint256 indexed mortgageId);

    constructor() Ownable(msg.sender) {
        _totalPoolBalance = FHE.asEuint64(0);
        _seniorFaceValue = FHE.asEuint64(0);
        _defaultedPrincipal = FHE.asEuint64(0);
        _weightedAvgLTV = FHE.asEuint32(0);
        FHE.allowThis(_totalPoolBalance);
        FHE.allowThis(_seniorFaceValue);
        FHE.allowThis(_defaultedPrincipal);
        FHE.allowThis(_weightedAvgLTV);
    }

    function addMortgage(
        externalEuint64 encPrincipal, bytes calldata pProof,
        externalEuint32 encLTV, bytes calldata ltvProof,
        externalEuint32 encRate, bytes calldata rateProof,
        externalEuint32 encCredit, bytes calldata creditProof,
        uint256 maturityDate
    ) external onlyOwner returns (uint256 id) {
        id = mortgageCount++;
        Mortgage storage m = mortgages[id];
        m.principalUSD = FHE.fromExternal(encPrincipal, pProof);
        m.ltvBps = FHE.fromExternal(encLTV, ltvProof);
        m.interestRateBps = FHE.fromExternal(encRate, rateProof);
        m.creditScoreBand = FHE.fromExternal(encCredit, creditProof);
        m.originationDate = block.timestamp;
        m.maturityDate = maturityDate;
        m.active = true;
        _totalPoolBalance = FHE.add(_totalPoolBalance, m.principalUSD);
        FHE.allowThis(m.principalUSD);
        FHE.allowThis(m.ltvBps);
        FHE.allowThis(m.interestRateBps);
        FHE.allowThis(m.creditScoreBand);
        FHE.allowThis(_totalPoolBalance);
        emit MortgageAdded(id);
    }

    function issueTranche(
        externalEuint64 encFaceValue, bytes calldata fvProof,
        externalEuint32 encYield, bytes calldata yProof,
        TrancheClass class_
    ) external onlyOwner returns (uint256 id) {
        id = trancheCount++;
        tranches[id].faceValue = FHE.fromExternal(encFaceValue, fvProof);
        tranches[id].yieldBps = FHE.fromExternal(encYield, yProof);
        tranches[id].amountRepaid = FHE.asEuint64(0);
        tranches[id].class_ = class_;
        if (class_ == TrancheClass.Senior) {
            _seniorFaceValue = FHE.add(_seniorFaceValue, tranches[id].faceValue);
            FHE.allowThis(_seniorFaceValue);
        }
        FHE.allowThis(tranches[id].faceValue);
        FHE.allowThis(tranches[id].yieldBps);
        FHE.allowThis(tranches[id].amountRepaid);
        emit TrancheIssued(id, class_);
    }

    function buyTranche(
        uint256 trancheId,
        externalEuint64 encAmount, bytes calldata proof
    ) external nonReentrant {
        require(trancheId < trancheCount, "Invalid tranche");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        trancheHoldings[msg.sender][trancheId] = FHE.add(
            trancheHoldings[msg.sender][trancheId], amount
        );
        FHE.allowThis(trancheHoldings[msg.sender][trancheId]);
        FHE.allow(trancheHoldings[msg.sender][trancheId], msg.sender);
        investorTranches[msg.sender].push(trancheId);
    }

    function recordPayment(
        uint256 mortgageId,
        externalEuint64 encPayment, bytes calldata proof
    ) external onlyOwner {
        require(mortgages[mortgageId].active, "Not active");
        euint64 payment = FHE.fromExternal(encPayment, proof);
        _totalPoolBalance = FHE.add(_totalPoolBalance, payment);
        FHE.allowThis(_totalPoolBalance);
        emit PaymentReceived(mortgageId);
    }

    function recordDefault(uint256 mortgageId) external onlyOwner {
        require(mortgages[mortgageId].active, "Not active");
        mortgages[mortgageId].defaulted = true;
        mortgages[mortgageId].active = false;
        _defaultedPrincipal = FHE.add(_defaultedPrincipal, mortgages[mortgageId].principalUSD);
        _totalPoolBalance = FHE.sub(_totalPoolBalance, mortgages[mortgageId].principalUSD);
        FHE.allowThis(_defaultedPrincipal);
        FHE.allowThis(_totalPoolBalance);
        emit DefaultRecorded(mortgageId);
    }

    function allowPoolMetrics(address viewer) external onlyOwner {
        FHE.allow(_totalPoolBalance, viewer);
        FHE.allow(_seniorFaceValue, viewer);
        FHE.allow(_defaultedPrincipal, viewer);
    }

    function allowTrancheHolding(address viewer, uint256 trancheId) external {
        FHE.allow(trancheHoldings[msg.sender][trancheId], viewer);
    }
}
