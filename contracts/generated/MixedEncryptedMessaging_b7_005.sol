// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title MixedEncryptedMessaging_b7_005 - Encrypted on-chain messaging with token gate
contract MixedEncryptedMessaging_b7_005 is ZamaEthereumConfig {
    address public admin;

    struct Message {
        address sender;
        euint8 contentHash1; // first byte of encrypted hash
        euint8 contentHash2; // second byte of encrypted hash
        uint256 timestamp;
        bool exists;
    }

    mapping(bytes32 => Message) private messages;
    mapping(address => euint64) private tokenBalance;
    uint64 public messageFee;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor(uint64 _fee) {
        admin = msg.sender;
        messageFee = _fee;
    }

    function depositTokens(externalEuint64 amountStr, bytes calldata proof) public {
        euint64 amount = FHE.fromExternal(amountStr, proof);
        tokenBalance[msg.sender] = FHE.add(tokenBalance[msg.sender], amount);
        FHE.allowThis(tokenBalance[msg.sender]);
    }

    function sendMessage(
        address recipient,
        externalEuint8 hash1Str, bytes calldata h1Proof,
        externalEuint8 hash2Str, bytes calldata h2Proof
    ) public returns (bytes32 msgId) {
        ebool hasFunds = FHE.ge(tokenBalance[msg.sender], FHE.asEuint64(messageFee));
        euint64 fee = FHE.select(hasFunds, FHE.asEuint64(messageFee), FHE.asEuint64(0));
        tokenBalance[msg.sender] = FHE.sub(tokenBalance[msg.sender], fee);
        FHE.allowThis(tokenBalance[msg.sender]);

        euint8 h1 = FHE.fromExternal(hash1Str, h1Proof);
        euint8 h2 = FHE.fromExternal(hash2Str, h2Proof);

        msgId = keccak256(abi.encodePacked(msg.sender, recipient, block.timestamp));
        messages[msgId] = Message({
            sender: msg.sender,
            contentHash1: h1,
            contentHash2: h2,
            timestamp: block.timestamp,
            exists: true
        });
        FHE.allowThis(messages[msgId].contentHash1);
        FHE.allowThis(messages[msgId].contentHash2);
        FHE.allow(messages[msgId].contentHash1, recipient);
        FHE.allow(messages[msgId].contentHash2, recipient);
        FHE.allow(messages[msgId].contentHash1, msg.sender);
        FHE.allow(messages[msgId].contentHash2, msg.sender);
    }

    function setFee(uint64 newFee) public onlyAdmin {
        messageFee = newFee;
    }

    function allowTokenBalance(address viewer) public {
        FHE.allow(tokenBalance[msg.sender], viewer);
    }
}
