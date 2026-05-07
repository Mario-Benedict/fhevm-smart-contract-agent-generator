// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title VotingReferendum_c2_027 - National referendum with region-level encrypted tallies
contract VotingReferendum_c2_027 is ZamaEthereumConfig, Ownable {
    string public question;
    uint8 public numRegions;
    euint64[] private regionalYes;
    euint64[] private regionalNo;
    euint64 private nationalYes;
    euint64 private nationalNo;
    mapping(address => bool) public hasVoted;
    mapping(address => uint8) public voterRegion;
    bool public votingOpen;

    constructor(string memory _question, uint8 _numRegions) Ownable(msg.sender) {
        question = _question;
        numRegions = _numRegions;
        nationalYes = FHE.asEuint64(0);
        nationalNo = FHE.asEuint64(0);
        FHE.allowThis(nationalYes);
        FHE.allowThis(nationalNo);
        for (uint8 i = 0; i < _numRegions; i++) {
            regionalYes.push(FHE.asEuint64(0));
            regionalNo.push(FHE.asEuint64(0));
            FHE.allowThis(regionalYes[i]);
            FHE.allowThis(regionalNo[i]);
        }
    }

    function registerVoter(address voter, uint8 region) external onlyOwner {
        require(region < numRegions, "Invalid region");
        voterRegion[voter] = region;
    }

    function open() external onlyOwner { votingOpen = true; }
    function close() external onlyOwner { votingOpen = false; }

    function vote(bool yes) external {
        require(votingOpen && !hasVoted[msg.sender], "Invalid");
        hasVoted[msg.sender] = true;
        uint8 region = voterRegion[msg.sender];
        if (yes) {
            regionalYes[region] = FHE.add(regionalYes[region], FHE.asEuint64(1));
            nationalYes = FHE.add(nationalYes, FHE.asEuint64(1));
            FHE.allowThis(regionalYes[region]);
            FHE.allowThis(nationalYes);
        } else {
            regionalNo[region] = FHE.add(regionalNo[region], FHE.asEuint64(1));
            nationalNo = FHE.add(nationalNo, FHE.asEuint64(1));
            FHE.allowThis(regionalNo[region]);
            FHE.allowThis(nationalNo);
        }
    }

    function allowNationalResults(address viewer) external onlyOwner {
        FHE.allow(nationalYes, viewer);
        FHE.allow(nationalNo, viewer);
    }

    function allowRegionalResults(uint8 region, address viewer) external onlyOwner {
        FHE.allow(regionalYes[region], viewer);
        FHE.allow(regionalNo[region], viewer);
    }
}
