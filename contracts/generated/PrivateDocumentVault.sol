// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title PrivateDocumentVault - Encrypted document storage with private access tiers and expiring shares
contract PrivateDocumentVault is ZamaEthereumConfig, Ownable {
    struct Document {
        euint256 encryptedContentHash;  // encrypted IPFS hash or content digest
        euint8 sensitivityLevel;        // 1=public, 2=confidential, 3=secret, 4=top-secret
        address owner_;
        uint256 uploadedAt;
        bool exists;
    }

    struct ShareGrant {
        address grantee;
        uint256 expiresAt;
        euint8 maxAccessLevel; // encrypted max sensitivity they can see
        bool active;
    }

    mapping(bytes32 => Document) private documents;
    mapping(bytes32 => ShareGrant[]) private shares;
    mapping(address => bytes32[]) private ownerDocs;
    mapping(address => bool) public isTrustedIssuer;

    event DocumentStored(bytes32 indexed docId, address owner_);
    event AccessGranted(bytes32 indexed docId, address grantee, uint256 expires);
    event AccessRevoked(bytes32 indexed docId, address grantee);

    constructor() Ownable(msg.sender) {
        isTrustedIssuer[msg.sender] = true;
    }

    function addIssuer(address i) external onlyOwner { isTrustedIssuer[i] = true; }

    function storeDocument(
        externalEuint256 encHash, bytes calldata hProof,
        externalEuint8 encSensitivity, bytes calldata sProof
    ) external returns (bytes32 docId) {
        euint256 hash = FHE.fromExternal(encHash, hProof);
        euint8 sensitivity = FHE.fromExternal(encSensitivity, sProof);
        docId = keccak256(abi.encodePacked(msg.sender, block.timestamp, ownerDocs[msg.sender].length));
        documents[docId] = Document({ encryptedContentHash: hash, sensitivityLevel: sensitivity,
            owner_: msg.sender, uploadedAt: block.timestamp, exists: true });
        FHE.allowThis(documents[docId].encryptedContentHash);
        FHE.allow(documents[docId].encryptedContentHash, msg.sender);
        FHE.allowThis(documents[docId].sensitivityLevel);
        FHE.allow(documents[docId].sensitivityLevel, msg.sender);
        ownerDocs[msg.sender].push(docId);
        emit DocumentStored(docId, msg.sender);
    }

    function grantAccess(bytes32 docId, address grantee, uint256 durationDays,
                         externalEuint8 encMaxLevel, bytes calldata proof) external {
        require(documents[docId].owner_ == msg.sender, "Not owner");
        euint8 maxLevel = FHE.fromExternal(encMaxLevel, proof);
        shares[docId].push(ShareGrant({ grantee: grantee,
            expiresAt: block.timestamp + durationDays * 1 days, maxAccessLevel: maxLevel, active: true }));
        uint256 idx = shares[docId].length - 1;
        FHE.allowThis(shares[docId][idx].maxAccessLevel);
        FHE.allow(shares[docId][idx].maxAccessLevel, grantee);
        // Grant access to document hash
        FHE.allow(documents[docId].encryptedContentHash, grantee);
        emit AccessGranted(docId, grantee, block.timestamp + durationDays * 1 days);
    }

    function revokeAccess(bytes32 docId, uint256 shareIndex) external {
        require(documents[docId].owner_ == msg.sender, "Not owner");
        shares[docId][shareIndex].active = false;
        emit AccessRevoked(docId, shares[docId][shareIndex].grantee);
    }

    function isAccessValid(bytes32 docId, uint256 shareIndex) external view returns (bool) {
        ShareGrant storage sg = shares[docId][shareIndex];
        return sg.active && block.timestamp < sg.expiresAt;
    }

    function getDocumentCount(address owner_) external view returns (uint256) {
        return ownerDocs[owner_].length;
    }

    function allowDocumentToViewer(bytes32 docId, address viewer) external {
        require(documents[docId].owner_ == msg.sender || isTrustedIssuer[msg.sender], "Unauthorized");
        FHE.allow(documents[docId].encryptedContentHash, viewer);
        FHE.allow(documents[docId].sensitivityLevel, viewer);
    }
}
