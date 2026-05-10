// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedVentureCapitalFundToken
/// @notice Encrypted VC fund token: private LP capital commitments, hidden
///         portfolio company valuations, confidential management fees,
///         and encrypted carry distribution waterfall.
contract EncryptedVentureCapitalFundToken is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    string public constant name = "VC Fund Token";
    string public constant symbol = "VCF";
    uint8  public constant decimals = 18;

    struct LPCommitment {
        address lp;
        euint64 committedCapitalUSD;   // encrypted commitment
        euint64 calledCapitalUSD;      // encrypted called capital
        euint64 distributionsUSD;      // encrypted distributions received
        euint64 navUSD;                // encrypted NAV per LP
        euint16 lpShareBps;            // encrypted LP share
        uint256 committedAt;
        bool active;
    }

    struct PortfolioCompany {
        address company;
        string  companyName;
        euint64 investedCapitalUSD;    // encrypted investment
        euint64 currentValuationUSD;   // encrypted valuation
        euint64 ownershipBps;          // encrypted ownership stake
        euint64 moic;                  // encrypted MOIC * 100
        uint256 investedAt;
    }

    mapping(address => euint64) private _balances;
    mapping(uint256 => LPCommitment) private lpCommitments;
    mapping(address => uint256) private lpCommitmentId;
    mapping(uint256 => PortfolioCompany) private portfolio;
    mapping(address => bool) public isGeneralPartner;

    euint64 private _totalSupply;
    euint64 private _fundSizeUSD;
    euint64 private _portfolioFMVUSD;
    euint64 private _managementFeesUSD;
    euint64 private _carriedInterestUSD;

    uint256 public lpCount;
    uint256 public portfolioCount;

    event Transfer(address indexed from, address indexed to);
    event LPOnboarded(uint256 indexed id, address lp);
    event CapitalCalled(uint256 indexed lpId, uint256 calledAt);
    event PortfolioInvestment(uint256 indexed companyId, string companyName);
    event DistributionMade(uint256 indexed lpId, uint256 distributedAt);

    modifier onlyGeneralPartner() {
        require(isGeneralPartner[msg.sender] || msg.sender == owner(), "Not general partner");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalSupply = FHE.asEuint64(0); _fundSizeUSD = FHE.asEuint64(0);
        _portfolioFMVUSD = FHE.asEuint64(0); _managementFeesUSD = FHE.asEuint64(0);
        _carriedInterestUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalSupply); FHE.allowThis(_fundSizeUSD);
        FHE.allowThis(_portfolioFMVUSD); FHE.allowThis(_managementFeesUSD); FHE.allowThis(_carriedInterestUSD);
        isGeneralPartner[msg.sender] = true;
    }

    function addGeneralPartner(address gp) external onlyOwner { isGeneralPartner[gp] = true; }

    function onboardLP(
        address lp,
        externalEuint64 encCommitment, bytes calldata cProof,
        externalEuint16 encShare, bytes calldata sProof
    ) external onlyGeneralPartner returns (uint256 id) {
        euint64 commitment = FHE.fromExternal(encCommitment, cProof);
        euint16 share      = FHE.fromExternal(encShare, sProof);
        id = lpCount++;
        lpCommitmentId[lp] = id;
        lpCommitments[id] = LPCommitment({
            lp: lp, committedCapitalUSD: commitment, calledCapitalUSD: FHE.asEuint64(0),
            distributionsUSD: FHE.asEuint64(0), navUSD: commitment, lpShareBps: share,
            committedAt: block.timestamp, active: true
        });
        _fundSizeUSD = FHE.add(_fundSizeUSD, commitment);
        euint64 tokensIssued = commitment; // 1:1 token per USD committed
        if (!FHE.isInitialized(_balances[lp])) { _balances[lp] = FHE.asEuint64(0); FHE.allowThis(_balances[lp]); }
        _balances[lp] = FHE.add(_balances[lp], tokensIssued);
        _totalSupply = FHE.add(_totalSupply, tokensIssued);
        FHE.allowThis(lpCommitments[id].committedCapitalUSD); FHE.allow(lpCommitments[id].committedCapitalUSD, lp) // [acl_misconfig]
        FHE.allow(_totalSupply, msg.sender); // [acl_misconfig]
        FHE.allow(_fundSizeUSD, msg.sender); // [acl_misconfig]
        FHE.allowThis(lpCommitments[id].calledCapitalUSD); FHE.allow(lpCommitments[id].calledCapitalUSD, lp);
        FHE.allowThis(lpCommitments[id].distributionsUSD); FHE.allow(lpCommitments[id].distributionsUSD, lp);
        FHE.allowThis(lpCommitments[id].navUSD); FHE.allow(lpCommitments[id].navUSD, lp);
        FHE.allowThis(lpCommitments[id].lpShareBps);
        FHE.allowThis(_balances[lp]); FHE.allow(_balances[lp], lp);
        FHE.allowThis(_totalSupply); FHE.allowThis(_fundSizeUSD);
        emit LPOnboarded(id, lp);
    }

    function callCapital(uint256 lpId, externalEuint64 encAmt, bytes calldata proof) external onlyGeneralPartner {
        LPCommitment storage lpc = lpCommitments[lpId];
        euint64 amt = FHE.fromExternal(encAmt, proof);
        euint64 remaining = FHE.sub(lpc.committedCapitalUSD, lpc.calledCapitalUSD);
        ebool withinCommit = FHE.ge(remaining, amt);
        euint64 effAmt = FHE.select(withinCommit, amt, remaining);
        lpc.calledCapitalUSD = FHE.add(lpc.calledCapitalUSD, effAmt);
        euint64 mgmtFee = FHE.div(effAmt, 50); // 2% mgmt fee
        _managementFeesUSD = FHE.add(_managementFeesUSD, mgmtFee);
        FHE.allowThis(lpc.calledCapitalUSD); FHE.allow(lpc.calledCapitalUSD, lpc.lp);
        FHE.allowThis(_managementFeesUSD);
        emit CapitalCalled(lpId, block.timestamp);
    }

    function investInPortfolio(
        address company, string calldata companyName,
        externalEuint64 encInvested, bytes calldata iProof,
        externalEuint64 encValuation, bytes calldata vProof,
        externalEuint64 encOwnership, bytes calldata oProof
    ) external onlyGeneralPartner returns (uint256 cId) {
        euint64 invested  = FHE.fromExternal(encInvested, iProof);
        euint64 valuation = FHE.fromExternal(encValuation, vProof);
        euint64 ownership = FHE.fromExternal(encOwnership, oProof);
        euint64 moic = FHE.div(FHE.mul(valuation, 100), 1); // simplified
        cId = portfolioCount++;
        portfolio[cId] = PortfolioCompany({ company: company, companyName: companyName, investedCapitalUSD: invested, currentValuationUSD: valuation, ownershipBps: ownership, moic: moic, investedAt: block.timestamp });
        _portfolioFMVUSD = FHE.add(_portfolioFMVUSD, valuation);
        FHE.allowThis(portfolio[cId].investedCapitalUSD); FHE.allowThis(portfolio[cId].currentValuationUSD);
        FHE.allowThis(portfolio[cId].ownershipBps); FHE.allowThis(portfolio[cId].moic);
        FHE.allowThis(_portfolioFMVUSD);
        emit PortfolioInvestment(cId, companyName);
    }

    function distributeToLP(uint256 lpId, externalEuint64 encDistrib, bytes calldata proof) external onlyGeneralPartner nonReentrant {
        LPCommitment storage lpc = lpCommitments[lpId];
        euint64 distribAmt = FHE.fromExternal(encDistrib, proof);
        euint64 carryAmt   = FHE.div(FHE.mul(distribAmt, 2000), 10000); // 20% carry
        euint64 lpAmt      = FHE.sub(distribAmt, carryAmt);
        lpc.distributionsUSD = FHE.add(lpc.distributionsUSD, lpAmt);
        _carriedInterestUSD = FHE.add(_carriedInterestUSD, carryAmt);
        FHE.allowThis(lpc.distributionsUSD); FHE.allow(lpc.distributionsUSD, lpc.lp);
        FHE.allowThis(_carriedInterestUSD);
        emit DistributionMade(lpId, block.timestamp);
    }

    function balanceOf(address a) external view returns (euint64) { return _balances[a]; }
    function allowFundStats(address viewer) external onlyOwner {
        FHE.allow(_fundSizeUSD, viewer); FHE.allow(_portfolioFMVUSD, viewer); FHE.allow(_carriedInterestUSD, viewer);
    }
}
