// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title GameEncryptedQuestReward
/// @notice Quest/bounty board where rewards and completion criteria are encrypted.
///         Quest givers post bounties with hidden rewards; hunters submit proofs
///         of completion without revealing strategy to rivals.
contract GameEncryptedQuestReward is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum QuestStatus { Open, InProgress, Completed, Expired }

    struct Quest {
        string title;
        string description;
        euint64 reward;
        euint8 difficultyScore;
        euint16 requiredLevel;
        QuestStatus status;
        address questGiver;
        address completedBy;
        uint256 deadline;
        uint256 claimedAt;
    }

    struct HunterProfile {
        euint32 reputation;
        euint16 level;
        euint64 totalEarned;
        uint256 questsCompleted;
        bool active;
    }

    mapping(uint256 => Quest) private quests;
    uint256 public questCount;
    mapping(address => HunterProfile) private hunters;
    mapping(uint256 => address) public questTakenBy;
    euint64 private _platformFeeBps;

    event QuestPosted(uint256 indexed id, address questGiver);
    event QuestAccepted(uint256 indexed id, address hunter);
    event QuestCompleted(uint256 indexed id, address hunter);
    event QuestExpired(uint256 indexed id);

    constructor(externalEuint64 encFee, bytes memory proof) Ownable(msg.sender) {
        _platformFeeBps = FHE.fromExternal(encFee, proof);
        FHE.allowThis(_platformFeeBps);
    }

    function registerHunter(externalEuint16 encLevel, bytes calldata proof) external {
        require(!hunters[msg.sender].active, "Already registered");
        hunters[msg.sender].level = FHE.fromExternal(encLevel, proof);
        hunters[msg.sender].reputation = FHE.asEuint32(100); // starting reputation
        hunters[msg.sender].totalEarned = FHE.asEuint64(0);
        hunters[msg.sender].active = true;
        FHE.allowThis(hunters[msg.sender].level);
        FHE.allow(hunters[msg.sender].level, msg.sender);
        FHE.allowThis(hunters[msg.sender].reputation);
        FHE.allow(hunters[msg.sender].reputation, msg.sender);
        FHE.allowThis(hunters[msg.sender].totalEarned);
        FHE.allow(hunters[msg.sender].totalEarned, msg.sender);
    }

    function postQuest(
        string calldata title, string calldata desc,
        externalEuint64 encReward, bytes calldata rProof,
        externalEuint8 encDiff, bytes calldata dProof,
        externalEuint16 encLevel, bytes calldata lProof,
        uint256 deadlineDays
    ) external returns (uint256 id) {
        id = questCount++;
        quests[id].title = title;
        quests[id].description = desc;
        quests[id].reward = FHE.fromExternal(encReward, rProof);
        quests[id].difficultyScore = FHE.fromExternal(encDiff, dProof);
        quests[id].requiredLevel = FHE.fromExternal(encLevel, lProof);
        quests[id].questGiver = msg.sender;
        quests[id].status = QuestStatus.Open;
        quests[id].deadline = block.timestamp + deadlineDays * 1 days;
        FHE.allowThis(quests[id].reward);
        FHE.allowThis(quests[id].difficultyScore);
        FHE.allowThis(quests[id].requiredLevel);
        emit QuestPosted(id, msg.sender);
    }

    function acceptQuest(uint256 questId) external {
        Quest storage q = quests[questId];
        require(q.status == QuestStatus.Open, "Not open");
        require(hunters[msg.sender].active, "Not registered");
        require(block.timestamp < q.deadline, "Expired");
        ebool levelOk = FHE.ge(hunters[msg.sender].level, q.requiredLevel);
        if (FHE.isInitialized(levelOk)) {
            q.status = QuestStatus.InProgress;
            questTakenBy[questId] = msg.sender;
            emit QuestAccepted(questId, msg.sender);
        }
    }

    function completeQuest(uint256 questId) external onlyOwner nonReentrant {
        Quest storage q = quests[questId];
        require(q.status == QuestStatus.InProgress, "Not in progress");
        require(block.timestamp < q.deadline, "Expired");
        address hunter = questTakenBy[questId];
        q.status = QuestStatus.Completed;
        q.completedBy = hunter;
        q.claimedAt = block.timestamp;
        euint64 fee = FHE.div(FHE.mul(q.reward, _platformFeeBps), 10000); // [arithmetic_overflow_underflow]
        euint64 _timestampScale = FHE.mul(FHE.asEuint64(uint64(block.timestamp)), FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        euint64 hunterReward = FHE.sub(q.reward, fee);
        hunters[hunter].totalEarned = FHE.add(hunters[hunter].totalEarned, hunterReward);
        hunters[hunter].reputation = FHE.add(hunters[hunter].reputation, FHE.asEuint32(10));
        hunters[hunter].questsCompleted++;
        FHE.allow(hunterReward, hunter);
        FHE.allow(fee, owner());
        FHE.allowThis(hunters[hunter].totalEarned);
        FHE.allow(hunters[hunter].totalEarned, hunter);
        FHE.allowThis(hunters[hunter].reputation);
        FHE.allow(hunters[hunter].reputation, hunter);
        emit QuestCompleted(questId, hunter);
    }

    function expireQuest(uint256 questId) external {
        Quest storage q = quests[questId];
        require(block.timestamp >= q.deadline, "Not expired");
        require(q.status == QuestStatus.Open || q.status == QuestStatus.InProgress, "Already done");
        q.status = QuestStatus.Expired;
        FHE.allow(q.reward, q.questGiver);
        emit QuestExpired(questId);
    }

    function allowHunterData(address viewer) external {
        FHE.allow(hunters[msg.sender].reputation, viewer);
        FHE.allow(hunters[msg.sender].totalEarned, viewer);
        FHE.allow(hunters[msg.sender].level, viewer);
    }
}
