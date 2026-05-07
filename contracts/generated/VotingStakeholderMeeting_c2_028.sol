// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingStakeholderMeeting_c2_028 - Corporate annual meeting with share-weighted private votes
contract VotingStakeholderMeeting_c2_028 is ZamaEthereumConfig, Ownable {
    struct Resolution {
        string description;
        euint64 votesFor;
        euint64 votesAgainst;
        euint64 votesAbstain;
        bool closed;
    }

    mapping(address => euint64) private _shares;
    mapping(address => bool) public isShareholder;
    Resolution[] public resolutions;
    mapping(address => mapping(uint256 => bool)) public hasVotedOn;
    bool public meetingOpen;

    constructor() Ownable(msg.sender) {}

    function registerShareholder(address holder, externalEuint64 encShares, bytes calldata proof) external onlyOwner {
        euint64 shares = FHE.fromExternal(encShares, proof);
        _shares[holder] = shares;
        isShareholder[holder] = true;
        FHE.allowThis(_shares[holder]);
        FHE.allow(_shares[holder], holder);
    }

    function addResolution(string calldata desc) external onlyOwner returns (uint256 id) {
        id = resolutions.length;
        resolutions.push(Resolution({
            description: desc,
            votesFor: FHE.asEuint64(0),
            votesAgainst: FHE.asEuint64(0),
            votesAbstain: FHE.asEuint64(0),
            closed: false
        }));
        FHE.allowThis(resolutions[id].votesFor);
        FHE.allowThis(resolutions[id].votesAgainst);
        FHE.allowThis(resolutions[id].votesAbstain);
    }

    function openMeeting() external onlyOwner { meetingOpen = true; }
    function closeMeeting() external onlyOwner { meetingOpen = false; }

    function voteOnResolution(uint256 resId, uint8 choice) external {
        require(meetingOpen && isShareholder[msg.sender], "Invalid");
        require(!hasVotedOn[msg.sender][resId], "Already voted");
        require(!resolutions[resId].closed, "Closed");
        hasVotedOn[msg.sender][resId] = true;
        if (choice == 1) {
            resolutions[resId].votesFor = FHE.add(resolutions[resId].votesFor, _shares[msg.sender]);
            FHE.allowThis(resolutions[resId].votesFor);
        } else if (choice == 2) {
            resolutions[resId].votesAgainst = FHE.add(resolutions[resId].votesAgainst, _shares[msg.sender]);
            FHE.allowThis(resolutions[resId].votesAgainst);
        } else {
            resolutions[resId].votesAbstain = FHE.add(resolutions[resId].votesAbstain, _shares[msg.sender]);
            FHE.allowThis(resolutions[resId].votesAbstain);
        }
    }

    function closeResolution(uint256 resId) external onlyOwner { resolutions[resId].closed = true; }

    function allowResolutionResults(uint256 resId, address viewer) external onlyOwner {
        FHE.allow(resolutions[resId].votesFor, viewer);
        FHE.allow(resolutions[resId].votesAgainst, viewer);
        FHE.allow(resolutions[resId].votesAbstain, viewer);
    }
}
