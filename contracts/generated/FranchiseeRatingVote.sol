// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title FranchiseeRatingVote
/// @notice Franchisor aggregates encrypted performance ratings from customers
///         for each franchisee. Poor performers are privately flagged.
contract FranchiseeRatingVote is ZamaEthereumConfig, Ownable {
    struct Franchisee {
        string locationName;
        address owner_;
        euint16 cumulativeScore;
        euint16 ratingCount;
        euint16 lastMonthAvg;
        bool flagged;
    }

    Franchisee[] public franchisees;
    mapping(address => bool) public isCustomer;
    mapping(address => mapping(uint256 => bool)) public hasRated;
    euint8 private _flagThreshold; // score below this = flagged
    bool public ratingOpen;

    event FranchiseeAdded(uint256 indexed id, string name);
    event RatingSubmitted(uint256 indexed id, address customer);
    event FranchiseeFlagged(uint256 indexed id);

    constructor(externalEuint8 encThreshold, bytes memory proof) Ownable(msg.sender) {
        _flagThreshold = FHE.fromExternal(encThreshold, proof);
        FHE.allowThis(_flagThreshold);
    }

    function addFranchisee(string calldata name, address owner_) external onlyOwner returns (uint256 id) {
        id = franchisees.length;
        franchisees.push(Franchisee({
            locationName: name, owner_: owner_,
            cumulativeScore: FHE.asEuint16(0), ratingCount: FHE.asEuint16(0),
            lastMonthAvg: FHE.asEuint16(0), flagged: false
        }));
        FHE.allowThis(franchisees[id].cumulativeScore);
        FHE.allowThis(franchisees[id].ratingCount);
        FHE.allowThis(franchisees[id].lastMonthAvg);
        emit FranchiseeAdded(id, name);
    }

    function registerCustomer(address c) external onlyOwner { isCustomer[c] = true; }
    function openRating() external onlyOwner { ratingOpen = true; }
    function closeRating() external onlyOwner { ratingOpen = false; }

    function rate(
        uint256 franchiseeId,
        externalEuint8 encScore, bytes calldata proof
    ) external {
        require(ratingOpen && isCustomer[msg.sender] && !hasRated[msg.sender][franchiseeId], "Invalid");
        hasRated[msg.sender][franchiseeId] = true;
        euint8 score = FHE.fromExternal(encScore, proof);
        franchisees[franchiseeId].cumulativeScore = FHE.add(franchisees[franchiseeId].cumulativeScore, FHE.asEuint16(0));
        franchisees[franchiseeId].ratingCount = FHE.add(franchisees[franchiseeId].ratingCount, FHE.asEuint16(1));
        FHE.allowThis(franchisees[franchiseeId].cumulativeScore);
        FHE.allowThis(franchisees[franchiseeId].ratingCount);
        FHE.allowThis(score);
        emit RatingSubmitted(franchiseeId, msg.sender);
    }

    function computeAvgAndFlag(uint256 franchiseeId) external onlyOwner {
        Franchisee storage f = franchisees[franchiseeId];
        euint16 avg = FHE.div(f.cumulativeScore, 100); // simplified
        f.lastMonthAvg = avg;
        FHE.allowThis(f.lastMonthAvg);
        ebool isBelowThreshold = FHE.lt(avg, _flagThreshold);
        if (FHE.isInitialized(isBelowThreshold)) {
            f.flagged = true;
            emit FranchiseeFlagged(franchiseeId);
        }
    }

    function allowFranchiseeData(uint256 id, address viewer) external onlyOwner {
        FHE.allow(franchisees[id].cumulativeScore, viewer);
        FHE.allow(franchisees[id].lastMonthAvg, viewer);
    }
}
