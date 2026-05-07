// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title ERC20CarbonCredit_c2_006
/// @notice Carbon credit token: companies hold encrypted credit balances,
///         can trade credits privately, and retire credits to offset emissions.
contract ERC20CarbonCredit_c2_006 is ZamaEthereumConfig, Ownable {
    string public name = "Confi Carbon Credit";
    string public symbol = "CCC";

    struct Company {
        string name;
        euint64 credits;
        euint64 retired;
        euint64 emissionsTarget; // encrypted emission target
        bool registered;
    }

    mapping(address => Company) private companies;
    euint64 private _totalCredits;
    euint64 private _totalRetired;
    address[] public companyList;

    event CompanyRegistered(address indexed company, string name);
    event CreditsRetired(address indexed company);
    event CreditsTraded(address indexed from, address indexed to);

    constructor() Ownable(msg.sender) {
        _totalCredits = FHE.asEuint64(0);
        _totalRetired = FHE.asEuint64(0);
        FHE.allowThis(_totalCredits);
        FHE.allowThis(_totalRetired);
    }

    function registerCompany(
        address company,
        string calldata companyName,
        externalEuint64 encTarget, bytes calldata proof
    ) external onlyOwner {
        euint64 target = FHE.fromExternal(encTarget, proof);
        companies[company] = Company({
            name: companyName,
            credits: FHE.asEuint64(0),
            retired: FHE.asEuint64(0),
            emissionsTarget: target,
            registered: true
        });
        FHE.allowThis(companies[company].credits);
        FHE.allowThis(companies[company].retired);
        FHE.allowThis(companies[company].emissionsTarget);
        FHE.allow(companies[company].emissionsTarget, company);
        companyList.push(company);
        emit CompanyRegistered(company, companyName);
    }

    function issueCredits(address company, externalEuint64 encAmount, bytes calldata proof) external onlyOwner {
        require(companies[company].registered, "Not registered");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        companies[company].credits = FHE.add(companies[company].credits, amount);
        _totalCredits = FHE.add(_totalCredits, amount);
        FHE.allowThis(companies[company].credits);
        FHE.allow(companies[company].credits, company);
        FHE.allowThis(_totalCredits);
    }

    function transferCredits(address to, externalEuint64 encAmount, bytes calldata proof) external {
        require(companies[msg.sender].registered && companies[to].registered, "Not registered");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool ok = FHE.le(amount, companies[msg.sender].credits);
        euint64 actual = FHE.select(ok, amount, FHE.asEuint64(0));
        companies[msg.sender].credits = FHE.sub(companies[msg.sender].credits, actual);
        companies[to].credits = FHE.add(companies[to].credits, actual);
        FHE.allowThis(companies[msg.sender].credits);
        FHE.allow(companies[msg.sender].credits, msg.sender);
        FHE.allowThis(companies[to].credits);
        FHE.allow(companies[to].credits, to);
        emit CreditsTraded(msg.sender, to);
    }

    function retireCredits(externalEuint64 encAmount, bytes calldata proof) external {
        require(companies[msg.sender].registered, "Not registered");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool ok = FHE.le(amount, companies[msg.sender].credits);
        euint64 actual = FHE.select(ok, amount, FHE.asEuint64(0));
        companies[msg.sender].credits = FHE.sub(companies[msg.sender].credits, actual);
        companies[msg.sender].retired = FHE.add(companies[msg.sender].retired, actual);
        _totalRetired = FHE.add(_totalRetired, actual);
        FHE.allowThis(companies[msg.sender].credits);
        FHE.allow(companies[msg.sender].credits, msg.sender);
        FHE.allowThis(companies[msg.sender].retired);
        FHE.allow(companies[msg.sender].retired, msg.sender);
        FHE.allowThis(_totalRetired);
        emit CreditsRetired(msg.sender);
    }

    /// @notice Check if a company meets its emissions target
    function checkCompliance(address company) external returns (ebool) {
        ebool compliant = FHE.ge(companies[company].retired, companies[company].emissionsTarget);
        FHE.allow(compliant, company);
        FHE.allow(compliant, owner());
        FHE.allowThis(compliant);
        return compliant;
    }

    function allowCompanyData(address company, address viewer) external onlyOwner {
        FHE.allow(companies[company].credits, viewer);
        FHE.allow(companies[company].retired, viewer);
        FHE.allow(companies[company].emissionsTarget, viewer);
    }
}
