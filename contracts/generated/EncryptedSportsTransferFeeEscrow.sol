// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedSportsTransferFeeEscrow
/// @notice Football clubs negotiate encrypted player transfer fees.
///         Add-ons (appearance, goal bonuses) and sell-on clauses remain confidential.
contract EncryptedSportsTransferFeeEscrow is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum TransferStatus { Negotiating, AgreedInPrinciple, Contracted, Completed, Collapsed }

    struct PlayerTransfer {
        address sellingClub;
        address buyingClub;
        string playerName;
        string playerPosition;
        euint64 baseTransferFeeUSD;         // encrypted base fee
        euint64 contingentAddOnsUSD;        // encrypted add-on bonuses
        euint64 sellOnClausePercBps;        // encrypted sell-on percentage
        euint64 totalPaidUSD;               // encrypted total paid to date
        euint32 contractLengthMonths;       // encrypted contract length
        uint256 agreementDate;
        TransferStatus status;
    }

    struct AddOnTrigger {
        uint256 transferId;
        string triggerDescription;          // e.g. "25 appearances"
        euint64 bonusAmountUSD;             // encrypted bonus amount
        bool triggered;
        uint256 triggeredAt;
    }

    mapping(uint256 => PlayerTransfer) private transfers;
    mapping(uint256 => AddOnTrigger[]) private addOns;
    mapping(address => bool) public isRegisteredClub;
    mapping(address => bool) public isFIFADelegate;

    uint256 public transferCount;
    euint64 private _totalTransferMarketUSD;
    euint64 private _totalAddOnsPaidUSD;

    event TransferInitiated(uint256 indexed id, address selling, address buying);
    event TransferCompleted(uint256 indexed id);
    event AddOnTriggered(uint256 indexed transferId, uint256 addOnIndex);

    modifier onlyClub(uint256 id) {
        PlayerTransfer storage t = transfers[id];
        require(msg.sender == t.sellingClub || msg.sender == t.buyingClub, "Not involved club");
        _;
    }

    modifier onlyDelegate() {
        require(isFIFADelegate[msg.sender] || msg.sender == owner(), "Not delegate");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalTransferMarketUSD = FHE.asEuint64(0);
        _totalAddOnsPaidUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalTransferMarketUSD);
        FHE.allowThis(_totalAddOnsPaidUSD);
        isFIFADelegate[msg.sender] = true;
    }

    function registerClub(address c) external onlyOwner { isRegisteredClub[c] = true; }
    function addDelegate(address d) external onlyOwner { isFIFADelegate[d] = true; }

    function initiateTransfer(
        address buyingClub,
        string calldata playerName,
        string calldata position,
        externalEuint64 encBaseFee, bytes calldata bProof,
        externalEuint64 encAddOns, bytes calldata aProof,
        externalEuint64 encSellOn, bytes calldata sProof,
        externalEuint32 encContractLength, bytes calldata cProof
    ) external returns (uint256 id) {
        require(isRegisteredClub[msg.sender] && isRegisteredClub[buyingClub], "Not registered");
        euint64 base = FHE.fromExternal(encBaseFee, bProof);
        euint64 addons = FHE.fromExternal(encAddOns, aProof);
        euint64 sellOn = FHE.fromExternal(encSellOn, sProof);
        euint32 contractLen = FHE.fromExternal(encContractLength, cProof);
        id = transferCount++;
        transfers[id] = PlayerTransfer({
            sellingClub: msg.sender, buyingClub: buyingClub,
            playerName: playerName, playerPosition: position,
            baseTransferFeeUSD: base, contingentAddOnsUSD: addons,
            sellOnClausePercBps: sellOn, totalPaidUSD: FHE.asEuint64(0),
            contractLengthMonths: contractLen,
            agreementDate: block.timestamp, status: TransferStatus.Negotiating
        });
        FHE.allowThis(transfers[id].baseTransferFeeUSD);
        FHE.allow(transfers[id].baseTransferFeeUSD, msg.sender);
        FHE.allow(transfers[id].baseTransferFeeUSD, buyingClub);
        FHE.allowThis(transfers[id].contingentAddOnsUSD);
        FHE.allow(transfers[id].contingentAddOnsUSD, msg.sender);
        FHE.allow(transfers[id].contingentAddOnsUSD, buyingClub);
        FHE.allowThis(transfers[id].sellOnClausePercBps);
        FHE.allow(transfers[id].sellOnClausePercBps, msg.sender);
        FHE.allowThis(transfers[id].totalPaidUSD);
        FHE.allowThis(transfers[id].contractLengthMonths);
        emit TransferInitiated(id, msg.sender, buyingClub);
    }

    function addAddOnClause(
        uint256 transferId,
        string calldata description,
        externalEuint64 encBonus, bytes calldata proof
    ) external onlyClub(transferId) {
        euint64 bonus = FHE.fromExternal(encBonus, proof);
        AddOnTrigger memory trigger = AddOnTrigger({
            transferId: transferId, triggerDescription: description,
            bonusAmountUSD: bonus, triggered: false, triggeredAt: 0
        });
        addOns[transferId].push(trigger);
        FHE.allowThis(bonus);
        FHE.allow(bonus, transfers[transferId].sellingClub);
        FHE.allow(bonus, transfers[transferId].buyingClub);
    }

    function agreeTransfer(uint256 id) external onlyDelegate {
        transfers[id].status = TransferStatus.AgreedInPrinciple;
    }

    function contractTransfer(uint256 id) external onlyDelegate {
        transfers[id].status = TransferStatus.Contracted;
    }

    function completeTransfer(uint256 id) external onlyDelegate nonReentrant {
        PlayerTransfer storage t = transfers[id];
        require(t.status == TransferStatus.Contracted, "Not contracted");
        t.totalPaidUSD = FHE.add(t.totalPaidUSD, t.baseTransferFeeUSD);
        t.status = TransferStatus.Completed;
        _totalTransferMarketUSD = FHE.add(_totalTransferMarketUSD, t.baseTransferFeeUSD);
        FHE.allowThis(t.totalPaidUSD);
        FHE.allow(t.totalPaidUSD, t.sellingClub);
        FHE.allowThis(_totalTransferMarketUSD);
        emit TransferCompleted(id);
    }

    function triggerAddOn(uint256 transferId, uint256 addOnIndex) external onlyDelegate nonReentrant {
        AddOnTrigger storage ao = addOns[transferId][addOnIndex];
        require(!ao.triggered, "Already triggered");
        ao.triggered = true;
        ao.triggeredAt = block.timestamp;
        PlayerTransfer storage t = transfers[transferId];
        t.totalPaidUSD = FHE.add(t.totalPaidUSD, ao.bonusAmountUSD);
        _totalAddOnsPaidUSD = FHE.add(_totalAddOnsPaidUSD, ao.bonusAmountUSD);
        FHE.allowThis(t.totalPaidUSD);
        FHE.allowThis(_totalAddOnsPaidUSD);
        emit AddOnTriggered(transferId, addOnIndex);
    }

    function allowMarketStats(address viewer) external onlyOwner {
        FHE.allow(_totalTransferMarketUSD, viewer);
        FHE.allow(_totalAddOnsPaidUSD, viewer);
    }
}
