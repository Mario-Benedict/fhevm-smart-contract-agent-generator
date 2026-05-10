// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AuctionPrivateEquityStake
/// @notice PE fund stake auction. Investors bid encrypted valuation multiples.
///         Fund manager sets encrypted minimum acceptable multiple and due diligence score.
contract AuctionPrivateEquityStake is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct Stake {
        string fundName;
        euint16 stakePercent;       // encrypted stake size as bps
        euint64 minimumValuation;   // encrypted minimum deal size
        euint8 minDDScore;          // encrypted min due diligence score
        uint256 auctionEnd;
        bool finalized;
        address winner;
        euint64 winningValuation;
    }

    struct InvestorBid {
        euint64 valuationMultiple; // encrypted EV/EBITDA or similar
        euint64 investmentAmount;
        euint8 ddScore;             // encrypted DD quality
        bool placed;
    }

    mapping(uint256 => Stake) private stakes;
    uint256 public stakeCount;
    mapping(uint256 => mapping(address => InvestorBid)) private bids;
    mapping(uint256 => address[]) private investors;
    mapping(address => bool) public isQualifiedInvestor;

    event StakeOffered(uint256 indexed id, string fundName);
    event BidSubmitted(uint256 indexed id, address investor);
    event StakeAwarded(uint256 indexed id, address winner);

    constructor() Ownable(msg.sender) {}

    function qualifyInvestor(address inv) external onlyOwner { isQualifiedInvestor[inv] = true; }

    function offerStake(
        string calldata fundName,
        externalEuint16 encStake, bytes calldata sProof,
        externalEuint64 encMinVal, bytes calldata vProof,
        externalEuint8 encMinDD, bytes calldata dProof,
        uint256 auctionDays
    ) external onlyOwner returns (uint256 id) {
        id = stakeCount++;
        stakes[id].fundName = fundName;
        stakes[id].stakePercent = FHE.fromExternal(encStake, sProof);
        stakes[id].minimumValuation = FHE.fromExternal(encMinVal, vProof);
        stakes[id].minDDScore = FHE.fromExternal(encMinDD, dProof);
        stakes[id].auctionEnd = block.timestamp + auctionDays * 1 days;
        stakes[id].winningValuation = FHE.asEuint64(0);
        FHE.allowThis(stakes[id].stakePercent);
        FHE.allowThis(stakes[id].minimumValuation);
        FHE.allowThis(stakes[id].minDDScore);
        FHE.allowThis(stakes[id].winningValuation);
        emit StakeOffered(id, fundName);
    }

    function submitBid(
        uint256 stakeId,
        externalEuint64 encValuation, bytes calldata vProof,
        externalEuint64 encAmount, bytes calldata aProof,
        externalEuint8 encDD, bytes calldata dProof
    ) external nonReentrant {
        require(isQualifiedInvestor[msg.sender], "Not qualified");
        Stake storage s = stakes[stakeId];
        require(block.timestamp < s.auctionEnd, "Closed");
        require(!bids[stakeId][msg.sender].placed, "Already bid");
        bids[stakeId][msg.sender] = InvestorBid({
            valuationMultiple: FHE.fromExternal(encValuation, vProof),
            investmentAmount: FHE.fromExternal(encAmount, aProof),
            ddScore: FHE.fromExternal(encDD, dProof),
            placed: true
        });
        FHE.allowThis(bids[stakeId][msg.sender].valuationMultiple);
        FHE.allowThis(bids[stakeId][msg.sender].investmentAmount);
        FHE.allowThis(bids[stakeId][msg.sender].ddScore);
        investors[stakeId].push(msg.sender);
        emit BidSubmitted(stakeId, msg.sender);
    }

    function awardStake(uint256 stakeId) external onlyOwner nonReentrant {
        Stake storage s = stakes[stakeId];
        require(block.timestamp >= s.auctionEnd && !s.finalized, "Cannot award");
        s.finalized = true;
        euint64 bestValuation = FHE.asEuint64(0);
        address bestInvestor = address(0);
        address[] storage invs = investors[stakeId];
        for (uint256 i = 0; i < invs.length; i++) {
            InvestorBid storage b = bids[stakeId][invs[i]];
            ebool ddOk = FHE.ge(b.ddScore, s.minDDScore);
            ebool valOk = FHE.ge(b.valuationMultiple, s.minimumValuation);
            ebool valid = FHE.and(ddOk, valOk);
            ebool isBest = FHE.gt(b.valuationMultiple, bestValuation);
            ebool winner = FHE.and(valid, isBest);
            bestValuation = FHE.select(winner, b.valuationMultiple, bestValuation);
            if (FHE.isInitialized(winner)) bestInvestor = invs[i];
        }
        s.winner = bestInvestor;
        s.winningValuation = bestValuation;
        FHE.allowThis(s.winningValuation);
        if (bestInvestor != address(0)) FHE.allow(s.winningValuation, bestInvestor);
        emit StakeAwarded(stakeId, bestInvestor);
    }
}
