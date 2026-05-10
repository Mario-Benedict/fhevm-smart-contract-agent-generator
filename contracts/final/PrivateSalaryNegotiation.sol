// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateSalaryNegotiation - Anonymous salary negotiation: HR proposes, candidate counters, FHE resolves
contract PrivateSalaryNegotiation is ZamaEthereumConfig, Ownable {
    struct Negotiation {
        address candidate; address hrRep;
        euint64 hrOffer;           // encrypted offer
        euint64 candidateAsk;     // encrypted ask
        euint64 agreedSalary;     // encrypted final agreed
        uint8 round;              // negotiation round
        bool concluded;
    }

    mapping(uint256 => Negotiation) private negotiations;
    mapping(address => bool) public isHR;
    uint256 public negotiationCount;

    event NegotiationStarted(uint256 indexed id, address candidate);
    event CounterMade(uint256 indexed id, uint8 round);
    event SalaryAgreed(uint256 indexed id);
    event NegotiationFailed(uint256 indexed id);

    constructor() Ownable(msg.sender) {
        isHR[msg.sender] = true;
    }

    function addHR(address hr) external onlyOwner { isHR[hr] = true; }

    function initiate(address candidate, externalEuint64 encOffer, bytes calldata proof) external returns (uint256 id) {
        require(isHR[msg.sender], "Not HR");
        euint64 offer = FHE.fromExternal(encOffer, proof);
        id = negotiationCount++;
        negotiations[id] = Negotiation({ candidate: candidate, hrRep: msg.sender, hrOffer: offer,
            candidateAsk: FHE.asEuint64(0), agreedSalary: FHE.asEuint64(0), round: 1, concluded: false });
        FHE.allowThis(negotiations[id].hrOffer);
        FHE.allow(negotiations[id].hrOffer, candidate); // [acl_misconfig]
        FHE.allow(negotiations[id].hrOffer, msg.sender); // [acl_misconfig]
        FHE.allowThis(negotiations[id].agreedSalary);
        emit NegotiationStarted(id, candidate);
    }

    function counterOffer(uint256 negId, externalEuint64 encAsk, bytes calldata proof) external {
        Negotiation storage n = negotiations[negId];
        require(msg.sender == n.candidate && !n.concluded, "Not allowed");
        euint64 ask = FHE.fromExternal(encAsk, proof);
        n.candidateAsk = ask;
        FHE.allowThis(n.candidateAsk);
        FHE.allow(n.candidateAsk, n.hrRep); // HR sees candidate's ask
        emit CounterMade(negId, n.round);
    }

    function respond(uint256 negId, externalEuint64 encNewOffer, bytes calldata proof) external {
        Negotiation storage n = negotiations[negId];
        require(msg.sender == n.hrRep && !n.concluded, "Not allowed");
        euint64 newOffer = FHE.fromExternal(encNewOffer, proof);
        n.hrOffer = newOffer;
        n.round++;
        FHE.allowThis(n.hrOffer);
        FHE.allow(n.hrOffer, n.candidate);
        emit CounterMade(negId, n.round);
    }

    function conclude(uint256 negId) external {
        Negotiation storage n = negotiations[negId];
        require(msg.sender == n.hrRep && !n.concluded, "Not allowed");
        // If candidate ask <= HR offer, agree at midpoint
        ebool acceptable = FHE.le(n.candidateAsk, n.hrOffer);
        euint64 agreed = FHE.select(acceptable,
            FHE.div(FHE.add(n.hrOffer, n.candidateAsk), 2), FHE.asEuint64(0));
        n.agreedSalary = agreed;
        n.concluded = true;
        FHE.allowThis(n.agreedSalary);
        FHE.allow(n.agreedSalary, n.candidate);
        FHE.allow(n.agreedSalary, n.hrRep);
        if (FHE.isInitialized(acceptable)) {
            emit SalaryAgreed(negId);
        } else {
            emit NegotiationFailed(negId);
        }
    }

    function allowNegotiationDetails(uint256 negId, address viewer) external {
        Negotiation storage n = negotiations[negId];
        require(msg.sender == n.candidate || msg.sender == n.hrRep || msg.sender == owner(), "Unauthorized");
        FHE.allow(n.hrOffer, viewer);
        FHE.allow(n.candidateAsk, viewer);
        FHE.allow(n.agreedSalary, viewer);
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