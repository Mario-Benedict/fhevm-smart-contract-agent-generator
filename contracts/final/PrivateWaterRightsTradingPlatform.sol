// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateWaterRightsTradingPlatform
/// @notice Western US water rights trading: encrypted acre-foot allocations, encrypted priority dates,
///         encrypted transfer prices, and confidential drought curtailment scores.
contract PrivateWaterRightsTradingPlatform is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum WaterSource { SURFACE, GROUNDWATER, RECYCLED, IMPORTED }
    enum UseType { AGRICULTURAL, MUNICIPAL, INDUSTRIAL, ENVIRONMENTAL }

    struct WaterRight {
        address holder;
        WaterSource source;
        UseType useType;
        euint64 allocatedAcreFeet;   // encrypted annual allocation
        euint64 priorityDateEncoded; // encrypted priority date (YYYYMMDD as uint64)
        euint64 currentAvailable;    // encrypted currently available acre-feet
        euint64 consumedThisSeason;  // encrypted consumed this season
        euint64 estimatedValue;      // encrypted market valuation per acre-foot
        bool seniorRight;            // senior vs junior (public)
        bool transferable;
    }

    struct WaterTransfer {
        uint256 rightId;
        address seller;
        address buyer;
        euint64 acreFeetTransferred; // encrypted volume transferred
        euint64 pricePerAcreFoot;    // encrypted price per acre-foot
        euint64 totalPrice;          // encrypted total transfer price
        uint256 transferDate;
        bool approved;
        bool completed;
    }

    struct DroughtStatus {
        euint8 curtailmentLevel;     // encrypted level 0-5
        euint64 curtailmentPct;      // encrypted curtailment percentage
        uint256 effectiveDate;
        bool active;
    }

    mapping(uint256 => WaterRight) private rights;
    mapping(uint256 => WaterTransfer) private transfers;
    mapping(WaterSource => DroughtStatus) private droughtStatus;
    uint256 public rightCount;
    uint256 public transferCount;
    euint64 private _totalNetworkAllocation;
    mapping(address => bool) public isWaterMaster;
    mapping(address => bool) public isRegulator;

    event RightRegistered(uint256 indexed id, address holder, WaterSource source);
    event TransferRequested(uint256 indexed id, uint256 rightId, address buyer);
    event TransferApproved(uint256 indexed id);
    event TransferCompleted(uint256 indexed id);
    event DroughtDeclared(WaterSource source, uint8 level);
    event ConservationUsageRecorded(uint256 indexed rightId);

    constructor() Ownable(msg.sender) {
        _totalNetworkAllocation = FHE.asEuint64(0);
        FHE.allowThis(_totalNetworkAllocation);
        isWaterMaster[msg.sender] = true;
        isRegulator[msg.sender] = true;
    }

    function addWaterMaster(address wm) external onlyOwner { isWaterMaster[wm] = true; }
    function addRegulator(address r) external onlyOwner { isRegulator[r] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function registerRight(
        WaterSource source, UseType useType,
        externalEuint64 encAlloc, bytes calldata aProof,
        externalEuint64 encPriority, bytes calldata pProof,
        externalEuint64 encValue, bytes calldata vProof,
        bool seniorRight, bool transferable
    ) external whenNotPaused returns (uint256 id) {
        euint64 alloc = FHE.fromExternal(encAlloc, aProof);
        euint64 priority = FHE.fromExternal(encPriority, pProof);
        euint64 value = FHE.fromExternal(encValue, vProof);
        id = rightCount++;
        rights[id].holder = msg.sender;
        rights[id].source = source;
        rights[id].useType = useType;
        rights[id].allocatedAcreFeet = alloc;
        rights[id].priorityDateEncoded = priority;
        rights[id].currentAvailable = alloc;
        rights[id].consumedThisSeason = FHE.asEuint64(0);
        rights[id].estimatedValue = value;
        rights[id].seniorRight = seniorRight;
        rights[id].transferable = transferable;
        _totalNetworkAllocation = FHE.add(_totalNetworkAllocation, alloc);
        FHE.allowThis(rights[id].allocatedAcreFeet);
        FHE.allowThis(rights[id].priorityDateEncoded);
        FHE.allowThis(rights[id].currentAvailable);
        FHE.allowThis(rights[id].consumedThisSeason);
        FHE.allowThis(rights[id].estimatedValue);
        FHE.allow(rights[id].allocatedAcreFeet, msg.sender); // [acl_misconfig]
        FHE.allow(_totalNetworkAllocation, msg.sender); // [acl_misconfig]
        FHE.allow(rights[id].currentAvailable, msg.sender);
        FHE.allowThis(_totalNetworkAllocation);
        emit RightRegistered(id, msg.sender, source);
    }

    function recordUsage(uint256 rightId, externalEuint64 encUsed, bytes calldata proof) external whenNotPaused {
        WaterRight storage wr = rights[rightId];
        require(wr.holder == msg.sender, "Not holder");
        euint64 used = FHE.fromExternal(encUsed, proof);
        ebool hasAvail = FHE.le(used, wr.currentAvailable);
        euint64 actual = FHE.select(hasAvail, used, wr.currentAvailable);
        wr.currentAvailable = FHE.sub(wr.currentAvailable, actual);
        wr.consumedThisSeason = FHE.add(wr.consumedThisSeason, actual);
        FHE.allowThis(wr.currentAvailable);
        FHE.allow(wr.currentAvailable, msg.sender);
        FHE.allowThis(wr.consumedThisSeason);
        emit ConservationUsageRecorded(rightId);
    }

    function requestTransfer(
        uint256 rightId, address buyer,
        externalEuint64 encVolume, bytes calldata vProof,
        externalEuint64 encPrice, bytes calldata pProof
    ) external whenNotPaused nonReentrant returns (uint256 txId) {
        WaterRight storage wr = rights[rightId];
        require(wr.holder == msg.sender && wr.transferable, "Not transferable");
        euint64 vol = FHE.fromExternal(encVolume, vProof);
        euint64 price = FHE.fromExternal(encPrice, pProof);
        ebool hasVol = FHE.le(vol, wr.currentAvailable);
        euint64 actualVol = FHE.select(hasVol, vol, wr.currentAvailable);
        euint64 total = FHE.mul(actualVol, price);
        txId = transferCount++;
        transfers[txId].rightId = rightId;
        transfers[txId].seller = msg.sender;
        transfers[txId].buyer = buyer;
        transfers[txId].acreFeetTransferred = actualVol;
        transfers[txId].pricePerAcreFoot = price;
        transfers[txId].totalPrice = total;
        transfers[txId].transferDate = block.timestamp;
        transfers[txId].approved = false;
        transfers[txId].completed = false;
        FHE.allowThis(transfers[txId].acreFeetTransferred);
        FHE.allowThis(transfers[txId].pricePerAcreFoot);
        FHE.allowThis(transfers[txId].totalPrice);
        emit TransferRequested(txId, rightId, buyer);
    }

    function approveTransfer(uint256 txId) external {
        require(isWaterMaster[msg.sender], "Not water master");
        transfers[txId].approved = true;
        emit TransferApproved(txId);
    }

    function completeTransfer(uint256 txId) external nonReentrant {
        WaterTransfer storage tx_ = transfers[txId];
        require(tx_.approved && !tx_.completed, "Not approved or done");
        require(msg.sender == tx_.buyer, "Not buyer");
        WaterRight storage wr = rights[tx_.rightId];
        wr.currentAvailable = FHE.sub(wr.currentAvailable, tx_.acreFeetTransferred);
        // Create new right for buyer
        uint256 newId = rightCount++;
        rights[newId].holder = tx_.buyer;
        rights[newId].source = wr.source;
        rights[newId].useType = wr.useType;
        rights[newId].allocatedAcreFeet = tx_.acreFeetTransferred;
        rights[newId].priorityDateEncoded = wr.priorityDateEncoded;
        rights[newId].currentAvailable = tx_.acreFeetTransferred;
        rights[newId].consumedThisSeason = FHE.asEuint64(0);
        rights[newId].estimatedValue = tx_.pricePerAcreFoot;
        rights[newId].seniorRight = false;
        rights[newId].transferable = true;
        FHE.allowThis(rights[newId].allocatedAcreFeet);
        FHE.allowThis(rights[newId].currentAvailable);
        FHE.allow(rights[newId].currentAvailable, tx_.buyer);
        tx_.completed = true;
        FHE.allowThis(wr.currentAvailable);
        FHE.allow(tx_.totalPrice, tx_.seller);
        emit TransferCompleted(txId);
    }

    function declareDrought(
        WaterSource source, uint8 level,
        externalEuint8 encLevel, bytes calldata lProof,
        externalEuint64 encCurtailment, bytes calldata cProof
    ) external {
        require(isRegulator[msg.sender], "Not regulator");
        euint8 encL = FHE.fromExternal(encLevel, lProof);
        euint64 curtailment = FHE.fromExternal(encCurtailment, cProof);
        droughtStatus[source] = DroughtStatus({
            curtailmentLevel: encL, curtailmentPct: curtailment,
            effectiveDate: block.timestamp, active: true
        });
        FHE.allowThis(droughtStatus[source].curtailmentLevel);
        FHE.allowThis(droughtStatus[source].curtailmentPct);
        emit DroughtDeclared(source, level);
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