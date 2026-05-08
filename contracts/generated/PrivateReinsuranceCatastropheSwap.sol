// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateReinsuranceCatastropheSwap
/// @notice Confidential CAT bond swap: encrypted attachment/exhaustion points, private risk transfer.
contract PrivateReinsuranceCatastropheSwap is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum PerilType { Hurricane, Earthquake, Flood, Wildfire, Pandemic, CyberAttack }
    enum SwapStatus { Offered, Active, Triggered, Exhausted, Expired }

    struct CATSwap {
        address cedant;
        address reinsurer;
        PerilType peril;
        string territory;
        euint64 attachmentPointUSD;
        euint64 exhaustionPointUSD;
        euint64 limitUSD;
        euint64 premiumUSD;
        euint64 accumulatedLossUSD;
        SwapStatus status;
        uint256 inceptionDate;
    }

    struct LossEvent {
        uint256 swapId;
        string eventId;
        euint64 cedantLossUSD;
        uint256 eventDate;
        bool settled;
    }

    mapping(uint256 => CATSwap) private swaps;
    mapping(uint256 => LossEvent) private lossEvents;
    mapping(address => bool) public isModelingAgent;

    uint256 public swapCount;
    uint256 public lossEventCount;
    euint64 private _totalPremiumsUSD;
    euint64 private _totalLossesSettledUSD;

    event SwapCreated(uint256 indexed id, PerilType peril, string territory);
    event SwapBound(uint256 indexed id, address reinsurer);
    event LossEventReported(uint256 indexed evId, uint256 swapId);

    modifier onlyModelingAgent() {
        require(isModelingAgent[msg.sender] || msg.sender == owner(), "Not modeling agent");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalPremiumsUSD = FHE.asEuint64(0);
        _totalLossesSettledUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalPremiumsUSD);
        FHE.allowThis(_totalLossesSettledUSD);
        isModelingAgent[msg.sender] = true;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function addModelingAgent(address a) external onlyOwner { isModelingAgent[a] = true; }

    function offerSwap(
        PerilType peril,
        string calldata territory,
        externalEuint64 encAttachment, bytes calldata atProof,
        externalEuint64 encExhaustion, bytes calldata exProof,
        externalEuint64 encLimit, bytes calldata limProof,
        externalEuint64 encPremium, bytes calldata pProof
    ) external whenNotPaused returns (uint256 id) {
        euint64 attach = FHE.fromExternal(encAttachment, atProof);
        euint64 exhaust = FHE.fromExternal(encExhaustion, exProof);
        euint64 lim = FHE.fromExternal(encLimit, limProof);
        euint64 premium = FHE.fromExternal(encPremium, pProof);
        id = swapCount++;
        swaps[id] = CATSwap({
            cedant: msg.sender, reinsurer: address(0), peril: peril, territory: territory,
            attachmentPointUSD: attach, exhaustionPointUSD: exhaust, limitUSD: lim,
            premiumUSD: premium, accumulatedLossUSD: FHE.asEuint64(0),
            status: SwapStatus.Offered, inceptionDate: block.timestamp
        });
        FHE.allowThis(swaps[id].attachmentPointUSD); FHE.allow(swaps[id].attachmentPointUSD, msg.sender);
        FHE.allowThis(swaps[id].exhaustionPointUSD); FHE.allow(swaps[id].exhaustionPointUSD, msg.sender);
        FHE.allowThis(swaps[id].limitUSD); FHE.allow(swaps[id].limitUSD, msg.sender);
        FHE.allowThis(swaps[id].premiumUSD); FHE.allow(swaps[id].premiumUSD, msg.sender);
        FHE.allowThis(swaps[id].accumulatedLossUSD);
        emit SwapCreated(id, peril, territory);
    }

    function bindSwap(uint256 swapId) external {
        CATSwap storage s = swaps[swapId];
        require(s.status == SwapStatus.Offered, "Not offered");
        s.reinsurer = msg.sender;
        s.status = SwapStatus.Active;
        _totalPremiumsUSD = FHE.add(_totalPremiumsUSD, s.premiumUSD);
        FHE.allowThis(_totalPremiumsUSD);
        FHE.allow(s.attachmentPointUSD, msg.sender);
        FHE.allow(s.limitUSD, msg.sender);
        FHE.allow(s.premiumUSD, msg.sender);
        emit SwapBound(swapId, msg.sender);
    }

    function reportLossEvent(
        uint256 swapId,
        string calldata eventId,
        externalEuint64 encCedantLoss, bytes calldata clProof
    ) external onlyModelingAgent returns (uint256 evId) {
        CATSwap storage s = swaps[swapId];
        require(s.status == SwapStatus.Active, "Swap not active");
        euint64 cedantLoss = FHE.fromExternal(encCedantLoss, clProof);
        evId = lossEventCount++;
        lossEvents[evId] = LossEvent({
            swapId: swapId, eventId: eventId, cedantLossUSD: cedantLoss,
            eventDate: block.timestamp, settled: false
        });
        s.accumulatedLossUSD = FHE.add(s.accumulatedLossUSD, cedantLoss);
        ebool triggered = FHE.ge(s.accumulatedLossUSD, s.attachmentPointUSD);
        ebool exhausted = FHE.ge(s.accumulatedLossUSD, s.exhaustionPointUSD);
        euint8 statusCode = FHE.select(exhausted, FHE.asEuint8(2), FHE.select(triggered, FHE.asEuint8(1), FHE.asEuint8(0)));
        FHE.allowThis(lossEvents[evId].cedantLossUSD);
        FHE.allow(lossEvents[evId].cedantLossUSD, s.cedant);
        FHE.allowThis(s.accumulatedLossUSD);
        FHE.allow(s.accumulatedLossUSD, s.cedant);
        FHE.allow(s.accumulatedLossUSD, s.reinsurer);
        FHE.allowThis(statusCode);
        emit LossEventReported(evId, swapId);
    }

    function settleLossEvent(uint256 lossEventId) external onlyOwner nonReentrant {
        LossEvent storage ev = lossEvents[lossEventId];
        require(!ev.settled, "Already settled");
        ev.settled = true;
        _totalLossesSettledUSD = FHE.add(_totalLossesSettledUSD, ev.cedantLossUSD);
        FHE.allowThis(_totalLossesSettledUSD);
    }

    function allowMarketStats(address viewer) external onlyOwner {
        FHE.allow(_totalPremiumsUSD, viewer);
        FHE.allow(_totalLossesSettledUSD, viewer);
    }
}
