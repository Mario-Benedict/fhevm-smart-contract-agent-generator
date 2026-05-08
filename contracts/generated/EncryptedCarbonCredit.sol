// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedCarbonCredit
/// @notice Carbon credit token with private emissions tracking and regulatory compliance
contract EncryptedCarbonCredit is ZamaEthereumConfig, Ownable, Pausable {
    string public name = "Encrypted Carbon Credit";
    string public symbol = "ECC";
    uint8 public decimals = 3;

    mapping(address => euint32) private _credits;
    mapping(address => euint32) private _emissionsBalance; // tonnes CO2
    mapping(address => euint32) private _retiredCredits;
    mapping(address => bool) private _verifiedEmitter;
    mapping(address => address) private _verifier;

    euint32 private _totalCredits;
    euint32 private _totalRetired;

    address[] public registeredVerifiers;
    mapping(address => bool) public isVerifier;

    event CreditIssued(address indexed to, address indexed verifier);
    event CreditRetired(address indexed by);
    event EmissionsReported(address indexed emitter);
    event ComplianceChecked(address indexed emitter);

    constructor() Ownable(msg.sender) {
        _totalCredits = FHE.asEuint32(0);
        FHE.allowThis(_totalCredits);
        _totalRetired = FHE.asEuint32(0);
        FHE.allowThis(_totalRetired);
    }

    function addVerifier(address v) external onlyOwner {
        isVerifier[v] = true;
        registeredVerifiers.push(v);
    }

    function issueCredits(
        address to,
        externalEuint32 calldata encAmount,
        bytes calldata inputProof
    ) external whenNotPaused {
        require(isVerifier[msg.sender], "Not a verifier");
        euint32 amount = FHE.fromExternal(encAmount, inputProof);
        _credits[to] = FHE.add(_credits[to], amount);
        _totalCredits = FHE.add(_totalCredits, amount);
        _verifiedEmitter[to] = true;
        _verifier[to] = msg.sender;

        FHE.allowThis(_credits[to]);
        FHE.allow(_credits[to], to);
        FHE.allow(_credits[to], msg.sender);
        FHE.allowThis(_totalCredits);

        emit CreditIssued(to, msg.sender);
    }

    function reportEmissions(externalEuint32 calldata encTonnes, bytes calldata inputProof) external whenNotPaused {
        euint32 tonnes = FHE.fromExternal(encTonnes, inputProof);
        _emissionsBalance[msg.sender] = FHE.add(_emissionsBalance[msg.sender], tonnes);
        FHE.allowThis(_emissionsBalance[msg.sender]);
        FHE.allow(_emissionsBalance[msg.sender], msg.sender);
        FHE.allow(_emissionsBalance[msg.sender], _verifier[msg.sender]);
        emit EmissionsReported(msg.sender);
    }

    function retireCredits(externalEuint32 calldata encAmount, bytes calldata inputProof) external whenNotPaused {
        euint32 amount = FHE.fromExternal(encAmount, inputProof);
        ebool sufficient = FHE.ge(_credits[msg.sender], amount);
        euint32 actual = FHE.select(sufficient, amount, FHE.asEuint32(0));

        _credits[msg.sender] = FHE.sub(_credits[msg.sender], actual);
        _retiredCredits[msg.sender] = FHE.add(_retiredCredits[msg.sender], actual);
        _totalRetired = FHE.add(_totalRetired, actual);

        // Offset against emissions
        ebool emissionCovered = FHE.ge(_emissionsBalance[msg.sender], actual);
        euint32 offsetted = FHE.select(emissionCovered, actual, _emissionsBalance[msg.sender]);
        _emissionsBalance[msg.sender] = FHE.sub(_emissionsBalance[msg.sender], offsetted);

        FHE.allowThis(_credits[msg.sender]);
        FHE.allow(_credits[msg.sender], msg.sender);
        FHE.allowThis(_retiredCredits[msg.sender]);
        FHE.allow(_retiredCredits[msg.sender], msg.sender);
        FHE.allowThis(_totalRetired);
        FHE.allowThis(_emissionsBalance[msg.sender]);
        FHE.allow(_emissionsBalance[msg.sender], msg.sender);

        emit CreditRetired(msg.sender);
    }

    function transferCredits(address to, externalEuint32 calldata encAmount, bytes calldata inputProof) external whenNotPaused {
        euint32 amount = FHE.fromExternal(encAmount, inputProof);
        ebool sufficient = FHE.ge(_credits[msg.sender], amount);
        euint32 actual = FHE.select(sufficient, amount, FHE.asEuint32(0));
        _credits[msg.sender] = FHE.sub(_credits[msg.sender], actual);
        _credits[to] = FHE.add(_credits[to], actual);
        FHE.allowThis(_credits[msg.sender]);
        FHE.allow(_credits[msg.sender], msg.sender);
        FHE.allowThis(_credits[to]);
        FHE.allow(_credits[to], to);
    }

    function creditsOf(address account) external view returns (euint32) { return _credits[account]; }
    function emissionsOf(address account) external view returns (euint32) { return _emissionsBalance[account]; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
