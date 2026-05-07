// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title MixedConfidentialWill_b7_009 - Digital will with encrypted beneficiary shares
contract MixedConfidentialWill_b7_009 is ZamaEthereumConfig {
    address public testator;
    bool public executed;

    struct Bequest {
        address beneficiary;
        euint64 amount;
        bool claimed;
    }

    Bequest[] private bequests;
    euint64 private totalEstate;
    address public executor;
    uint256 public executionDelay; // seconds after death declaration

    modifier onlyTestator() {
        require(msg.sender == testator, "Not testator");
        _;
    }

    modifier onlyExecutor() {
        require(msg.sender == executor, "Not executor");
        _;
    }

    constructor(address _executor, uint256 _delayDays) {
        testator = msg.sender;
        executor = _executor;
        executionDelay = _delayDays * 1 days;
        totalEstate = FHE.asEuint64(0);
        FHE.allowThis(totalEstate);
    }

    function addBequest(
        address beneficiary,
        externalEuint64 amountStr,
        bytes calldata proof
    ) public onlyTestator {
        require(!executed, "Will already executed");
        euint64 amount = FHE.fromExternal(amountStr, proof);
        uint256 id = bequests.length;
        bequests.push(Bequest({ beneficiary: beneficiary, amount: amount, claimed: false }));
        totalEstate = FHE.add(totalEstate, amount);
        FHE.allowThis(bequests[id].amount);
        FHE.allowThis(totalEstate);
    }

    function executeWill() public onlyExecutor {
        require(!executed, "Already executed");
        executed = true;
        for (uint256 i = 0; i < bequests.length; i++) {
            FHE.allow(bequests[i].amount, bequests[i].beneficiary);
        }
    }

    function claimBequest(uint256 index) public {
        require(executed, "Will not executed");
        Bequest storage b = bequests[index];
        require(msg.sender == b.beneficiary, "Not beneficiary");
        require(!b.claimed, "Already claimed");
        b.claimed = true;
        FHE.allow(b.amount, msg.sender);
    }

    function allowEstateInfo(address viewer) public onlyExecutor {
        FHE.allow(totalEstate, viewer);
    }

    function getBequestCount() public view returns (uint256) {
        return bequests.length;
    }
}
