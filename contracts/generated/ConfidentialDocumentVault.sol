// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title ConfidentialDocumentVault - Encrypted document access control with time-limited sharing
contract ConfidentialDocumentVault is ZamaEthereumConfig, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    struct Document {
        address owner;
        string ipfsCid;          // IPFS content address (plaintext pointer)
        euint8 classificationLevel; // 1=public, 2=internal, 3=confidential, 4=secret
        euint32 createdAt;
        bool exists;
        EnumerableSet.AddressSet readers;
        mapping(address => uint256) readerExpiry;
    }

    mapping(bytes32 => Document) private documents;
    mapping(address => bytes32[]) private ownerDocs;
    mapping(address => euint8) public userClearance;

    event DocumentStored(bytes32 indexed docId, address indexed owner);
    event ReadAccessGranted(bytes32 indexed docId, address indexed reader, uint256 expiry);
    event ReadAccessRevoked(bytes32 indexed docId, address indexed reader);
    event ClearanceLevelSet(address indexed user);

    constructor() Ownable(msg.sender) {}

    function setClearance(address user, externalEuint8 calldata encLevel, bytes calldata inputProof)
        external
        onlyOwner
    {
        userClearance[user] = FHE.fromExternal(encLevel, inputProof);
        FHE.allowThis(userClearance[user]);
        FHE.allow(userClearance[user], user);
        emit ClearanceLevelSet(user);
    }

    function storeDocument(
        string calldata ipfsCid,
        externalEuint8 calldata encClassification,
        bytes calldata inputProof
    ) external returns (bytes32 docId) {
        docId = keccak256(abi.encodePacked(msg.sender, ipfsCid, block.timestamp));
        Document storage d = documents[docId];
        require(!d.exists, "Already stored");
        d.owner = msg.sender;
        d.ipfsCid = ipfsCid;
        d.classificationLevel = FHE.fromExternal(encClassification, inputProof);
        d.createdAt = FHE.asEuint32(uint32(block.timestamp));
        d.exists = true;
        FHE.allowThis(d.classificationLevel);
        FHE.allowThis(d.createdAt);
        FHE.allow(d.classificationLevel, msg.sender);
        ownerDocs[msg.sender].push(docId);
        emit DocumentStored(docId, msg.sender);
    }

    function grantReadAccess(bytes32 docId, address reader, uint256 expiryTimestamp) external {
        Document storage d = documents[docId];
        require(d.exists && d.owner == msg.sender, "Not owner");
        d.readers.add(reader);
        d.readerExpiry[reader] = expiryTimestamp;
        FHE.allowTransient(d.classificationLevel, reader);
        emit ReadAccessGranted(docId, reader, expiryTimestamp);
    }

    function revokeReadAccess(bytes32 docId, address reader) external {
        Document storage d = documents[docId];
        require(d.exists && d.owner == msg.sender, "Not owner");
        d.readers.remove(reader);
        d.readerExpiry[reader] = 0;
        emit ReadAccessRevoked(docId, reader);
    }

    function canRead(bytes32 docId, address reader) external view returns (bool) {
        Document storage d = documents[docId];
        if (!d.exists) return false;
        if (d.owner == reader) return true;
        return d.readers.contains(reader) && block.timestamp <= d.readerExpiry[reader];
    }

    function getOwnerDocCount(address owner) external view returns (uint256) {
        return ownerDocs[owner].length;
    }
}
