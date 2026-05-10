// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title CarbonTradingExchange
/// @notice Advanced carbon credit exchange: companies trade encrypted carbon quotas,
///         validators certify emission reductions, regulators audit compliance privately.
contract CarbonTradingExchange is ZamaEthereumConfig, Ownable {
    enum CreditType { Forestry, Solar, Wind, CCS, Efficiency }

    struct CarbonCredit {
        address issuer;
        CreditType creditType;
        euint64 quantity;
        euint64 pricePerTon;
        uint256 vintageYear;
        bool verified;
        bool retired;
    }

    struct CompanyAccount {
        euint64 mandatoryQuota;     // must offset this many tons
        euint64 actualEmissions;    // encrypted real emissions
        euint64 ownedCredits;       // balance of purchased credits
        euint64 retiredCredits;     // retired toward compliance
        bool registered;
    }

    mapping(bytes32 => CarbonCredit) private credits;
    mapping(address => CompanyAccount) private companies;
    mapping(address => bool) public isValidator;
    mapping(address => bool) public isRegulator;
    euint64 private _totalMarketVolume;
    uint256 public nextCreditSuffix;

    event CreditIssued(bytes32 indexed creditId);
    event CreditTraded(bytes32 indexed creditId, address buyer);
    event EmissionsReported(address indexed company);
    event ComplianceChecked(address indexed company);

    constructor() Ownable(msg.sender) {
        _totalMarketVolume = FHE.asEuint64(0);
        FHE.allowThis(_totalMarketVolume);
        isValidator[msg.sender] = true;
        isRegulator[msg.sender] = true;
    }

    function registerCompany(
        address company,
        externalEuint64 encQuota, bytes calldata proof
    ) external {
        require(isRegulator[msg.sender], "Not regulator");
        euint64 quota = FHE.fromExternal(encQuota, proof);
        companies[company] = CompanyAccount({
            mandatoryQuota: quota,
            actualEmissions: FHE.asEuint64(0),
            ownedCredits: FHE.asEuint64(0),
            retiredCredits: FHE.asEuint64(0),
            registered: true
        });
        FHE.allowThis(companies[company].mandatoryQuota);
        FHE.allow(companies[company].mandatoryQuota, company);
        FHE.allowThis(companies[company].actualEmissions);
        FHE.allowThis(companies[company].ownedCredits);
        FHE.allow(companies[company].ownedCredits, company);
        FHE.allowThis(companies[company].retiredCredits);
    }

    function issueCredit(
        CreditType creditType,
        externalEuint64 encQty, bytes calldata qProof,
        externalEuint64 encPrice, bytes calldata pProof,
        uint256 vintage
    ) external returns (bytes32 creditId) {
        require(isValidator[msg.sender], "Not validator");
        euint64 qty = FHE.fromExternal(encQty, qProof);
        euint64 price = FHE.fromExternal(encPrice, pProof);
        creditId = keccak256(abi.encodePacked(msg.sender, creditType, vintage, nextCreditSuffix++));
        credits[creditId] = CarbonCredit({
            issuer: msg.sender, creditType: creditType, quantity: qty,
            pricePerTon: price, vintageYear: vintage, verified: true, retired: false
        });
        FHE.allowThis(credits[creditId].quantity);
        FHE.allowThis(credits[creditId].pricePerTon);
        emit CreditIssued(creditId);
    }

    function purchaseCredit(bytes32 creditId) external {
        require(companies[msg.sender].registered, "Not registered");
        CarbonCredit storage c = credits[creditId];
        require(c.verified && !c.retired, "Invalid credit");
        companies[msg.sender].ownedCredits = FHE.add(companies[msg.sender].ownedCredits, c.quantity);
        _totalMarketVolume = FHE.add(_totalMarketVolume, c.quantity);
        FHE.allowThis(companies[msg.sender].ownedCredits);
        FHE.allow(companies[msg.sender].ownedCredits, msg.sender);
        FHE.allowThis(_totalMarketVolume);
        emit CreditTraded(creditId, msg.sender);
    }

    function reportEmissions(externalEuint64 encEmissions, bytes calldata proof) external {
        require(companies[msg.sender].registered, "Not registered");
        euint64 emissions = FHE.fromExternal(encEmissions, proof);
        companies[msg.sender].actualEmissions = emissions;
        FHE.allowThis(companies[msg.sender].actualEmissions);
        FHE.allow(companies[msg.sender].actualEmissions, msg.sender);
        emit EmissionsReported(msg.sender);
    }

    function retireCreditsForCompliance(externalEuint64 encQty, bytes calldata proof) external {
        require(companies[msg.sender].registered, "Not registered");
        euint64 qty = FHE.fromExternal(encQty, proof);
        ebool ok = FHE.le(qty, companies[msg.sender].ownedCredits);
        euint64 actual = FHE.select(ok, qty, FHE.asEuint64(0));
        ebool _safeSub16 = FHE.ge(companies[msg.sender].ownedCredits, actual);
        companies[msg.sender].ownedCredits = FHE.select(_safeSub16, FHE.sub(companies[msg.sender].ownedCredits, actual), FHE.asEuint64(0));
        companies[msg.sender].retiredCredits = FHE.add(companies[msg.sender].retiredCredits, actual);
        FHE.allowThis(companies[msg.sender].ownedCredits);
        FHE.allow(companies[msg.sender].ownedCredits, msg.sender);
        FHE.allowThis(companies[msg.sender].retiredCredits);
        FHE.allow(companies[msg.sender].retiredCredits, msg.sender);
    }

    function checkCompliance(address company) external returns (ebool compliant) {
        require(isRegulator[msg.sender], "Not regulator");
        CompanyAccount storage acc = companies[company];
        ebool _safeSub17 = FHE.ge(acc.actualEmissions, acc.retiredCredits);
        euint64 netEmissions = FHE.select(_safeSub17, FHE.sub(acc.actualEmissions, acc.retiredCredits), FHE.asEuint64(0));
        compliant = FHE.le(netEmissions, acc.mandatoryQuota);
        FHE.allow(compliant, msg.sender);
        FHE.allow(compliant, company);
        FHE.allowThis(compliant);
        emit ComplianceChecked(company);
    }

    function addValidator(address v) external onlyOwner { isValidator[v] = true; }
    function addRegulator(address r) external onlyOwner { isRegulator[r] = true; }

    function allowCompanyData(address company, address viewer) external {
        require(isRegulator[msg.sender], "Not regulator");
        FHE.allow(companies[company].mandatoryQuota, viewer);
        FHE.allow(companies[company].actualEmissions, viewer);
        FHE.allow(companies[company].retiredCredits, viewer);
    }
}
