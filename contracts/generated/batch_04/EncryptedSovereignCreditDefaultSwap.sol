// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EncryptedSovereignCreditDefaultSwap
/// @notice On-chain sovereign CDS where notional amounts, premium rates, and
///         credit event payouts are encrypted. Protection buyer and seller
///         agree on terms without revealing exposure sizes.
contract EncryptedSovereignCreditDefaultSwap is ZamaEthereumConfig, AccessControl, ReentrancyGuard {
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");

    enum SwapState { Active, DefaultTriggered, Settled, Expired }

    struct CDS {
        address protectionBuyer;
        address protectionSeller;
        euint64 notionalUSD;        // encrypted notional
        euint32 premiumBps;         // encrypted annual premium in basis points
        euint64 accruedPremium;     // encrypted premium accrued
        uint256 maturityTimestamp;
        uint256 lastPremiumTimestamp;
        SwapState state;
        string referenceEntity;     // e.g. "Country-X sovereign bond"
    }

    uint256 public nextSwapId;
    mapping(uint256 => CDS) private swaps;
    mapping(address => uint256[]) private buyerSwaps;
    mapping(address => uint256[]) private sellerSwaps;

    event SwapCreated(uint256 indexed id, address buyer, address seller, string entity);
    event PremiumPaid(uint256 indexed id);
    event DefaultTriggered(uint256 indexed id);
    event SwapSettled(uint256 indexed id);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ORACLE_ROLE, msg.sender);
        _grantRole(SETTLEMENT_ROLE, msg.sender);
    }

    function createSwap(
        address seller,
        externalEuint64 encNotional,
        bytes calldata notionalProof,
        externalEuint32 encPremiumBps,
        bytes calldata premiumProof,
        uint256 maturityDays,
        string calldata referenceEntity
    ) external returns (uint256 swapId) {
        swapId = nextSwapId++;
        euint64 notional = FHE.fromExternal(encNotional, notionalProof);
        euint32 bps = FHE.fromExternal(encPremiumBps, premiumProof);

        swaps[swapId].protectionBuyer = msg.sender;
        swaps[swapId].protectionSeller = seller;
        swaps[swapId].notionalUSD = notional;
        swaps[swapId].premiumBps = bps;
        swaps[swapId].accruedPremium = FHE.asEuint64(0);
        swaps[swapId].maturityTimestamp = block.timestamp + maturityDays * 1 days;
        swaps[swapId].lastPremiumTimestamp = block.timestamp;
        swaps[swapId].state = SwapState.Active;
        swaps[swapId].referenceEntity = referenceEntity;

        FHE.allowThis(swaps[swapId].notionalUSD);
        FHE.allow(swaps[swapId].notionalUSD, msg.sender);
        FHE.allow(swaps[swapId].notionalUSD, seller);
        FHE.allowThis(swaps[swapId].premiumBps);
        FHE.allowThis(swaps[swapId].accruedPremium);

        buyerSwaps[msg.sender].push(swapId);
        sellerSwaps[seller].push(swapId);
        emit SwapCreated(swapId, msg.sender, seller, referenceEntity);
    }

    /// @notice Pay quarterly premium (encrypted accrual tracking)
    function payPremium(uint256 swapId) external nonReentrant {
        CDS storage s = swaps[swapId];
        require(s.state == SwapState.Active, "Not active");
        require(msg.sender == s.protectionBuyer, "Only buyer");
        require(block.timestamp < s.maturityTimestamp, "Matured");

        uint256 elapsed = block.timestamp - s.lastPremiumTimestamp;
        // Annual premium = notional * bps / 10000
        // Quarterly = / 4
        // premium = notional * bps * elapsed / (365 days * 10000)
        // Simplified: store accrual encrypted
        euint64 quarterlyPremium = FHE.div(
            FHE.mul(s.notionalUSD, FHE.asEuint64(s.premiumBps)),
            40000
        );
        s.accruedPremium = FHE.add(s.accruedPremium, quarterlyPremium);
        FHE.allowThis(s.accruedPremium);
        FHE.allow(s.accruedPremium, s.protectionBuyer);
        FHE.allow(s.accruedPremium, s.protectionSeller);
        s.lastPremiumTimestamp = block.timestamp;
        emit PremiumPaid(swapId);
    }

    /// @notice Oracle triggers credit event (default)
    function triggerDefault(uint256 swapId) external onlyRole(ORACLE_ROLE) {
        CDS storage s = swaps[swapId];
        require(s.state == SwapState.Active, "Not active");
        s.state = SwapState.DefaultTriggered;
        emit DefaultTriggered(swapId);
    }

    function settleSwap(uint256 swapId) external onlyRole(SETTLEMENT_ROLE) nonReentrant {
        CDS storage s = swaps[swapId];
        require(s.state == SwapState.DefaultTriggered, "Not triggered");
        s.state = SwapState.Settled;
        FHE.allow(s.notionalUSD, s.protectionBuyer);
        FHE.allow(s.notionalUSD, s.protectionSeller);
        emit SwapSettled(swapId);
    }

    function allowSwapView(uint256 swapId, address viewer) external {
        CDS storage s = swaps[swapId];
        require(msg.sender == s.protectionBuyer || msg.sender == s.protectionSeller, "Unauthorized");
        FHE.allow(s.notionalUSD, viewer);
        FHE.allow(s.accruedPremium, viewer);
    }
}
