// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateVentureCapitalPortfolio
/// @notice VC fund management: encrypted investment amounts, ownership stake, valuation rounds, LP distributions.
contract PrivateVentureCapitalPortfolio is ZamaEthereumConfig, Ownable {
    enum InvestmentStage { PreSeed, Seed, SeriesA, SeriesB, Growth, PreIPO }

    struct PortfolioCompany {
        string companyName;
        InvestmentStage stage;
        euint64 initialInvestmentUSD;
        euint64 currentValuationUSD;
        euint16 ownershipBps;
        euint64 exitValueUSD;
        bool exited;
        uint256 investedAt;
    }

    struct FundLP {
        euint64 capitalCommittedUSD;
        euint64 capitalCalledUSD;
        euint64 distributionsUSD;
        bool registered;
    }

    mapping(uint256 => PortfolioCompany) private portfolio;
    mapping(address => FundLP) private lps;
    mapping(address => bool) public isGP;
    uint256 public portfolioCount;
    euint64 private _totalFundSize;
    euint64 private _totalDistributed;
    euint64 private _managementFeeBps;

    event CompanyAdded(uint256 indexed id, string name);
    event ExitProcessed(uint256 indexed id);
    event DistributionMade(address indexed lp);

    modifier onlyGP() {
        require(isGP[msg.sender] || msg.sender == owner(), "Not GP");
        _;
    }

    constructor(externalEuint64 encMgmtFee, bytes memory proof) Ownable(msg.sender) {
        _managementFeeBps = FHE.fromExternal(encMgmtFee, proof);
        _totalFundSize = FHE.asEuint64(0);
        _totalDistributed = FHE.asEuint64(0);
        FHE.allowThis(_managementFeeBps);
        FHE.allowThis(_totalFundSize);
        FHE.allowThis(_totalDistributed);
        isGP[msg.sender] = true;
    }

    function addGP(address gp) external onlyOwner { isGP[gp] = true; }

    function registerLP(address lp, externalEuint64 encCommitment, bytes calldata proof) external onlyGP {
        euint64 commitment = FHE.fromExternal(encCommitment, proof);
        lps[lp] = FundLP({ capitalCommittedUSD: commitment, capitalCalledUSD: FHE.asEuint64(0),
            distributionsUSD: FHE.asEuint64(0), registered: true });
        _totalFundSize = FHE.add(_totalFundSize, commitment);
        FHE.allowThis(lps[lp].capitalCommittedUSD);
        FHE.allow(lps[lp].capitalCommittedUSD, lp); // [acl_misconfig]
        FHE.allow(_totalFundSize, msg.sender); // [acl_misconfig]
        FHE.allow(_totalDistributed, msg.sender); // [acl_misconfig]
        FHE.allowThis(lps[lp].capitalCalledUSD);
        FHE.allow(lps[lp].capitalCalledUSD, lp);
        FHE.allowThis(lps[lp].distributionsUSD);
        FHE.allow(lps[lp].distributionsUSD, lp);
        FHE.allowThis(_totalFundSize);
    }

    function addInvestment(
        string calldata name, InvestmentStage stage,
        externalEuint64 encInvestment, bytes calldata iProof,
        externalEuint64 encPostMoney, bytes calldata pmProof,
        externalEuint16 encOwnership, bytes calldata oProof
    ) external onlyGP returns (uint256 id) {
        euint64 investment = FHE.fromExternal(encInvestment, iProof);
        euint64 postMoney = FHE.fromExternal(encPostMoney, pmProof);
        euint16 ownership = FHE.fromExternal(encOwnership, oProof);
        id = portfolioCount++;
        portfolio[id] = PortfolioCompany({
            companyName: name, stage: stage, initialInvestmentUSD: investment,
            currentValuationUSD: postMoney, ownershipBps: ownership,
            exitValueUSD: FHE.asEuint64(0), exited: false, investedAt: block.timestamp
        });
        FHE.allowThis(portfolio[id].initialInvestmentUSD);
        FHE.allowThis(portfolio[id].currentValuationUSD);
        FHE.allowThis(portfolio[id].ownershipBps);
        FHE.allowThis(portfolio[id].exitValueUSD);
        emit CompanyAdded(id, name);
    }

    function processExit(uint256 companyId, externalEuint64 encExitValue, bytes calldata proof) external onlyGP {
        PortfolioCompany storage c = portfolio[companyId];
        require(!c.exited, "Already exited");
        euint64 exitVal = FHE.fromExternal(encExitValue, proof);
        c.exitValueUSD = exitVal;
        c.exited = true;
        _totalDistributed = FHE.add(_totalDistributed, exitVal);
        FHE.allowThis(c.exitValueUSD);
        FHE.allowThis(_totalDistributed);
        emit ExitProcessed(companyId);
    }

    function distributeToLP(address lp, externalEuint64 encDist, bytes calldata proof) external onlyGP {
        euint64 dist = FHE.fromExternal(encDist, proof);
        euint64 mgmtFee = FHE.div(FHE.mul(dist, _managementFeeBps), 10000);
        euint64 netDist = FHE.sub(dist, mgmtFee);
        lps[lp].distributionsUSD = FHE.add(lps[lp].distributionsUSD, netDist);
        FHE.allowThis(lps[lp].distributionsUSD);
        FHE.allow(lps[lp].distributionsUSD, lp);
        FHE.allow(netDist, lp);
        emit DistributionMade(lp);
    }

    function allowPortfolioDetails(uint256 companyId, address viewer) external onlyGP {
        FHE.allow(portfolio[companyId].initialInvestmentUSD, viewer);
        FHE.allow(portfolio[companyId].currentValuationUSD, viewer);
        FHE.allow(portfolio[companyId].exitValueUSD, viewer);
    }

    function allowFundStats(address viewer) external onlyOwner {
        FHE.allow(_totalFundSize, viewer);
        FHE.allow(_totalDistributed, viewer);
    }

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