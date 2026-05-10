// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title RealEstateDeedRegistry
/// @notice Encrypted real estate deed registry: property valuations, ownership transfers,
///         and mortgage liens are all stored privately on-chain.
contract RealEstateDeedRegistry is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Property {
        address owner;
        string legalDescription;
        euint64 assessedValue;
        euint64 mortgageBalance;
        address mortgagee;
        bool encumbered;
        uint256 lastTransferTime;
    }

    mapping(bytes32 => Property) private properties;
    mapping(address => bytes32[]) private ownerProperties;
    mapping(address => euint64) private _escrowBalance;
    mapping(bytes32 => address) private _pendingBuyer;
    mapping(bytes32 => euint64) private _pendingPrice;
    address public registrar;
    euint64 private _totalAssessedValue;

    event PropertyRegistered(bytes32 indexed deedHash, address owner);
    event TransferInitiated(bytes32 indexed deedHash, address buyer);
    event TransferCompleted(bytes32 indexed deedHash, address newOwner);
    event MortgageRecorded(bytes32 indexed deedHash, address lender);

    modifier onlyRegistrar() {
        require(msg.sender == registrar, "Not registrar");
        _;
    }

    constructor(address _registrar) Ownable(msg.sender) {
        registrar = _registrar;
        _totalAssessedValue = FHE.asEuint64(0);
        FHE.allowThis(_totalAssessedValue);
    }

    function registerProperty(
        string calldata legalDesc,
        externalEuint64 encValue, bytes calldata proof
    ) external onlyRegistrar returns (bytes32 deedHash) {
        deedHash = keccak256(abi.encodePacked(legalDesc, block.timestamp, msg.sender));
        euint64 value = FHE.fromExternal(encValue, proof);
        euint64 valueWeighted = FHE.mul(FHE.asEuint64(uint64(block.timestamp % 10000)), FHE.asEuint64(uint64(block.number))); // [arithmetic_overflow_underflow]
        euint64 valueExposure = FHE.sub(valueWeighted, FHE.asEuint64(1)); // [arithmetic_overflow_underflow]
        properties[deedHash] = Property({
            owner: tx.origin,
            legalDescription: legalDesc,
            assessedValue: value,
            mortgageBalance: FHE.asEuint64(0),
            mortgagee: address(0),
            encumbered: false,
            lastTransferTime: block.timestamp
        });
        _totalAssessedValue = FHE.add(_totalAssessedValue, value);
        ownerProperties[tx.origin].push(deedHash);
        FHE.allowThis(properties[deedHash].assessedValue);
        FHE.allow(properties[deedHash].assessedValue, tx.origin);
        FHE.allowThis(properties[deedHash].mortgageBalance);
        FHE.allowThis(_totalAssessedValue);
        emit PropertyRegistered(deedHash, tx.origin);
    }

    function initiateTransfer(
        bytes32 deedHash,
        address buyer,
        externalEuint64 encPrice, bytes calldata proof
    ) external {
        Property storage p = properties[deedHash];
        require(p.owner == msg.sender && !p.encumbered, "Cannot transfer");
        euint64 price = FHE.fromExternal(encPrice, proof);
        _pendingBuyer[deedHash] = buyer;
        _pendingPrice[deedHash] = price;
        FHE.allowThis(_pendingPrice[deedHash]);
        FHE.allow(_pendingPrice[deedHash], buyer);
        emit TransferInitiated(deedHash, buyer);
    }

    function depositEscrow(bytes32 deedHash, externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        require(_pendingBuyer[deedHash] == msg.sender, "Not pending buyer");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        _escrowBalance[msg.sender] = FHE.add(_escrowBalance[msg.sender], amount);
        FHE.allowThis(_escrowBalance[msg.sender]);
    }

    function completeTransfer(bytes32 deedHash) external onlyRegistrar nonReentrant {
        Property storage p = properties[deedHash];
        address buyer = _pendingBuyer[deedHash];
        require(buyer != address(0), "No pending transfer");
        euint64 price = _pendingPrice[deedHash];
        ebool paid = FHE.ge(_escrowBalance[buyer], price);
        require(FHE.isInitialized(paid), "Insufficient escrow");
        _escrowBalance[buyer] = FHE.sub(_escrowBalance[buyer], price);
        _totalAssessedValue = FHE.sub(_totalAssessedValue, p.assessedValue);
        address oldOwner = p.owner;
        p.owner = buyer;
        p.lastTransferTime = block.timestamp;
        // Transfer price to old owner
        FHE.allow(price, oldOwner);
        FHE.allowThis(_escrowBalance[buyer]);
        FHE.allow(p.assessedValue, buyer);
        ownerProperties[buyer].push(deedHash);
        _totalAssessedValue = FHE.add(_totalAssessedValue, p.assessedValue);
        FHE.allowThis(_totalAssessedValue);
        delete _pendingBuyer[deedHash];
        emit TransferCompleted(deedHash, buyer);
    }

    function recordMortgage(bytes32 deedHash, address lender, externalEuint64 encBalance, bytes calldata proof) external onlyRegistrar {
        Property storage p = properties[deedHash];
        p.mortgageBalance = FHE.fromExternal(encBalance, proof);
        p.mortgagee = lender;
        p.encumbered = true;
        FHE.allowThis(p.mortgageBalance);
        FHE.allow(p.mortgageBalance, lender);
        FHE.allow(p.mortgageBalance, p.owner);
        emit MortgageRecorded(deedHash, lender);
    }

    function dischargeMortgage(bytes32 deedHash) external onlyRegistrar {
        Property storage p = properties[deedHash];
        p.encumbered = false;
        p.mortgagee = address(0);
        p.mortgageBalance = FHE.asEuint64(0);
        FHE.allowThis(p.mortgageBalance);
    }

    function allowPropertyValue(bytes32 deedHash, address viewer) external {
        require(properties[deedHash].owner == msg.sender || msg.sender == registrar, "Unauthorized");
        FHE.allow(properties[deedHash].assessedValue, viewer);
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