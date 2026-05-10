// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title StakingEncryptedLiquidityBootstrap
/// @notice Encrypted liquidity bootstrapping pool (LBP) for token launches.
///         Initial weights, price trajectory, and participant allocation
///         are encrypted to prevent front-running during the launch phase.
contract StakingEncryptedLiquidityBootstrap is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum LBPPhase { Setup, Active, WindDown, Completed, Cancelled }

    struct LBPPool {
        string tokenName;
        string tokenSymbol;
        euint64 totalTokensForSale;       // encrypted token supply in pool
        euint64 startingPriceCents;       // encrypted initial token price
        euint64 currentPriceCents;        // encrypted current price
        euint64 reserveAssetRaised;       // encrypted reserve (e.g., USDC)
        euint32 startWeightBps;           // encrypted initial project token weight
        euint32 endWeightBps;             // encrypted final weight
        euint32 currentWeightBps;         // encrypted current weight
        euint64 tokensSold;               // encrypted tokens distributed
        euint64 minContributionUSD;       // encrypted min buy size
        euint64 maxContributionUSD;       // encrypted max buy size per wallet
        LBPPhase phase;
        uint256 launchTimestamp;
        uint256 endTimestamp;
    }

    struct ParticipantAllocation {
        euint64 reserveContributed;       // encrypted amount paid
        euint64 tokensAllocated;          // encrypted tokens received
        euint64 averagePricePaid;         // encrypted avg cost basis
        euint32 participationCount;       // encrypted number of buys
        bool claimable;
    }

    mapping(address => ParticipantAllocation) private allocations;
    mapping(address => bool) public isWhitelisted;
    mapping(address => bool) public isProjectTeam;

    LBPPool public pool;
    uint64 public _currentPriceCentsPlain; // plaintext shadow for division
    euint64 private _totalParticipants;
    euint64 private _peakPrice;

    event LBPConfigured(string tokenName, uint256 launchTimestamp);
    event ParticipantBought(address indexed participant);
    event WeightUpdated(uint256 newWeightBps);
    event LBPCompleted(uint256 endTimestamp);
    event TokensClaimed(address indexed participant);

    modifier onlyTeam() {
        require(isProjectTeam[msg.sender] || msg.sender == owner(), "Not project team");
        _;
    }

    constructor() Ownable(msg.sender) {
        _totalParticipants = FHE.asEuint64(0);
        _peakPrice = FHE.asEuint64(0);
        FHE.allowThis(_totalParticipants);
        FHE.allowThis(_peakPrice);
        isProjectTeam[msg.sender] = true;
    }

    function addTeamMember(address t) external onlyOwner { isProjectTeam[t] = true; }
    function whitelistParticipant(address p) external onlyTeam { isWhitelisted[p] = true; }
    function batchWhitelist(address[] calldata participants) external onlyTeam {
        for (uint256 i = 0; i < participants.length; i++) { isWhitelisted[participants[i]] = true; }
    }

    function configureLBP(
        string calldata tokenName,
        string calldata tokenSymbol,
        externalEuint64 encTotalTokens, bytes calldata tokProof,
        externalEuint64 encStartingPrice, bytes calldata priceProof,
        externalEuint32 encStartWeight, bytes calldata swProof,
        externalEuint32 encEndWeight, bytes calldata ewProof,
        externalEuint64 encMinContrib, bytes calldata minProof,
        externalEuint64 encMaxContrib, bytes calldata maxProof,
        uint256 launchTimestamp,
        uint256 endTimestamp,
        uint64 startingPricePlaintext
    ) external onlyTeam {
        require(pool.phase == LBPPhase.Setup || pool.phase == LBPPhase(0), "Already configured");
        pool.tokenName = tokenName;
        pool.tokenSymbol = tokenSymbol;
        pool.totalTokensForSale = FHE.fromExternal(encTotalTokens, tokProof);
        pool.startingPriceCents = FHE.fromExternal(encStartingPrice, priceProof);
        pool.currentPriceCents = pool.startingPriceCents;
        pool.reserveAssetRaised = FHE.asEuint64(0);
        pool.startWeightBps = FHE.fromExternal(encStartWeight, swProof);
        pool.endWeightBps = FHE.fromExternal(encEndWeight, ewProof);
        pool.currentWeightBps = pool.startWeightBps;
        pool.tokensSold = FHE.asEuint64(0);
        pool.minContributionUSD = FHE.fromExternal(encMinContrib, minProof);
        pool.maxContributionUSD = FHE.fromExternal(encMaxContrib, maxProof);
        pool.phase = LBPPhase.Active;
        pool.launchTimestamp = launchTimestamp;
        pool.endTimestamp = endTimestamp;
        _currentPriceCentsPlain = startingPricePlaintext;
        _peakPrice = pool.startingPriceCents;
        FHE.allowThis(pool.totalTokensForSale); FHE.allowThis(pool.startingPriceCents);
        FHE.allowThis(pool.currentPriceCents); FHE.allowThis(pool.reserveAssetRaised);
        FHE.allowThis(pool.startWeightBps); FHE.allowThis(pool.endWeightBps);
        FHE.allowThis(pool.currentWeightBps); FHE.allowThis(pool.tokensSold);
        FHE.allowThis(pool.minContributionUSD); FHE.allowThis(pool.maxContributionUSD);
        FHE.allowThis(_peakPrice);
        emit LBPConfigured(tokenName, launchTimestamp);
    }

    function buyTokens(
        externalEuint64 encContribution, bytes calldata contribProof,
        uint64 newTotalTokensPlaintext
    ) external nonReentrant {
        require(isWhitelisted[msg.sender], "Not whitelisted");
        require(pool.phase == LBPPhase.Active, "LBP not active");
        require(block.timestamp >= pool.launchTimestamp, "Not started");
        require(block.timestamp < pool.endTimestamp, "LBP ended");

        euint64 contribution = FHE.fromExternal(encContribution, contribProof);

        // Check min/max contribution
        ebool aboveMin = FHE.ge(contribution, pool.minContributionUSD);
        ParticipantAllocation storage alloc = allocations[msg.sender];
        euint64 totalSoFar = FHE.add(alloc.reserveContributed, contribution); // [arithmetic_overflow_underflow]
        euint64 contributionScaled = FHE.mul(contribution, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        ebool belowMax = FHE.le(totalSoFar, pool.maxContributionUSD);

        euint64 effectiveContrib = FHE.select(FHE.and(aboveMin, belowMax), contribution, FHE.asEuint64(0));

        // Tokens = contribution / currentPrice
        euint64 tokensToAllocate = _currentPriceCentsPlain > 0 ? FHE.div(effectiveContrib, _currentPriceCentsPlain) : FHE.asEuint64(0);
        // Check remaining tokens
        euint64 remaining = FHE.sub(pool.totalTokensForSale, pool.tokensSold);
        ebool hasStock = FHE.le(tokensToAllocate, remaining);
        euint64 actualTokens = FHE.select(hasStock, tokensToAllocate, remaining);
        euint64 actualContrib = FHE.mul(actualTokens, pool.currentPriceCents);

        // New avg price = (total cost) / (total tokens)
        euint64 newTotalCost = FHE.add(alloc.reserveContributed, actualContrib);
        euint64 newTotalTokens = FHE.add(alloc.tokensAllocated, actualTokens);
        euint64 newAvgPrice = (newTotalTokensPlaintext + 1) > 0 ? FHE.div(newTotalCost, newTotalTokensPlaintext + 1) : FHE.asEuint64(0); // +1 avoid div/0

        bool isNewParticipant = !alloc.claimable;
        alloc.reserveContributed = newTotalCost;
        alloc.tokensAllocated = newTotalTokens;
        alloc.averagePricePaid = newAvgPrice;
        alloc.participationCount = FHE.add(alloc.participationCount, FHE.asEuint32(1));
        alloc.claimable = true;

        pool.reserveAssetRaised = FHE.add(pool.reserveAssetRaised, actualContrib);
        pool.tokensSold = FHE.add(pool.tokensSold, actualTokens);

        if (isNewParticipant) {
            _totalParticipants = FHE.add(_totalParticipants, FHE.asEuint64(1));
            FHE.allowThis(_totalParticipants);
        }

        // Update peak price
        ebool newPeak = FHE.gt(pool.currentPriceCents, _peakPrice);
        _peakPrice = FHE.select(newPeak, pool.currentPriceCents, _peakPrice);

        FHE.allowThis(alloc.reserveContributed); FHE.allow(alloc.reserveContributed, msg.sender);
        FHE.allowThis(alloc.tokensAllocated); FHE.allow(alloc.tokensAllocated, msg.sender);
        FHE.allowThis(alloc.averagePricePaid); FHE.allow(alloc.averagePricePaid, msg.sender);
        FHE.allowThis(alloc.participationCount);
        FHE.allowThis(pool.reserveAssetRaised); FHE.allowThis(pool.tokensSold);
        FHE.allowThis(_peakPrice);

        emit ParticipantBought(msg.sender);
    }

    function updateWeightAndPrice(
        externalEuint32 encNewWeight, bytes calldata weightProof,
        externalEuint64 encNewPrice, bytes calldata priceProof,
        uint64 newPricePlaintext
    ) external onlyTeam {
        _currentPriceCentsPlain = newPricePlaintext;
        pool.currentWeightBps = FHE.fromExternal(encNewWeight, weightProof);
        pool.currentPriceCents = FHE.fromExternal(encNewPrice, priceProof);
        FHE.allowThis(pool.currentWeightBps);
        FHE.allowThis(pool.currentPriceCents);
        emit WeightUpdated(0);
    }

    function completeLBP() external onlyTeam {
        require(block.timestamp >= pool.endTimestamp || pool.phase == LBPPhase.WindDown, "Not ended");
        pool.phase = LBPPhase.Completed;
        emit LBPCompleted(block.timestamp);
    }

    function claimTokens() external nonReentrant {
        require(pool.phase == LBPPhase.Completed, "LBP not completed");
        ParticipantAllocation storage alloc = allocations[msg.sender];
        require(alloc.claimable, "Nothing to claim");
        alloc.claimable = false;
        FHE.allow(alloc.tokensAllocated, msg.sender);
        emit TokensClaimed(msg.sender);
    }

    function allowLBPStats(address viewer) external onlyOwner {
        FHE.allow(pool.reserveAssetRaised, viewer);
        FHE.allow(pool.tokensSold, viewer);
        FHE.allow(pool.currentPriceCents, viewer);
        FHE.allow(_totalParticipants, viewer);
        FHE.allow(_peakPrice, viewer);
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