// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateDebtMarketplace - Encrypted secondary market for trading private credit obligations
contract PrivateDebtMarketplace is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    struct DebtNote {
        address originator;
        address currentHolder;
        euint64 faceValue;
        euint64 outstandingBalance;
        euint8 creditRating;     // 1=AAA … 8=D
        euint16 couponRateBps;
        uint256 maturityDate;
        bool defaulted;
        bool listed;
    }

    struct Listing {
        uint256 noteId;
        euint64 askPrice;
        uint256 listedAt;
        bool active;
    }

    mapping(uint256 => DebtNote) public notes;
    mapping(uint256 => Listing)  public listings;
    mapping(address => uint256[]) public holderNotes;
    uint256 public noteCount;
    uint256 public listingCount;

    event NoteOriginated(uint256 indexed noteId, address indexed originator);
    event NoteListed(uint256 indexed listingId, uint256 indexed noteId);
    event NoteSold(uint256 indexed listingId, address indexed buyer);
    event NoteDefaulted(uint256 indexed noteId);

    constructor() Ownable(msg.sender) {}

    function originateNote(
        address borrower,
        externalEuint64 encFace,   bytes calldata faceProof,
        externalEuint8 encRating, bytes calldata ratingProof,
        externalEuint16 encCoupon, bytes calldata couponProof,
        uint256 maturityDays
    ) external onlyOwner returns (uint256 noteId) {
        noteId = noteCount++;
        DebtNote storage n = notes[noteId];
        n.originator    = msg.sender;
        n.currentHolder = borrower;
        n.faceValue         = FHE.fromExternal(encFace,   faceProof);
        n.outstandingBalance = FHE.fromExternal(encFace,  faceProof);
        n.creditRating      = FHE.fromExternal(encRating, ratingProof);
        n.couponRateBps     = FHE.fromExternal(encCoupon, couponProof);
        n.maturityDate      = block.timestamp + maturityDays * 1 days;
        FHE.allowThis(n.faceValue); FHE.allowThis(n.outstandingBalance);
        FHE.allowThis(n.creditRating); FHE.allowThis(n.couponRateBps);
        FHE.allow(n.faceValue, borrower); FHE.allow(n.creditRating, borrower);
        holderNotes[borrower].push(noteId);
        emit NoteOriginated(noteId, msg.sender);
    }

    function listNote(
        uint256 noteId,
        externalEuint64 encAsk, bytes calldata askProof
    ) external returns (uint256 listingId) {
        DebtNote storage n = notes[noteId];
        require(n.currentHolder == msg.sender, "Not holder");
        require(!n.defaulted, "Defaulted");
        listingId = listingCount++;
        listings[listingId] = Listing({
            noteId: noteId, askPrice: FHE.fromExternal(encAsk, askProof),
            listedAt: block.timestamp, active: true
        });
        n.listed = true;
        FHE.allowThis(listings[listingId].askPrice);
        FHE.allow(listings[listingId].askPrice, msg.sender);
        emit NoteListed(listingId, noteId);
    }

    function purchaseNote(uint256 listingId) external nonReentrant {
        Listing storage l = listings[listingId];
        require(l.active, "Not active");
        DebtNote storage n = notes[l.noteId];
        address seller = n.currentHolder;
        n.currentHolder = msg.sender;
        n.listed = false;
        l.active = false;
        holderNotes[msg.sender].push(l.noteId);
        FHE.allow(n.faceValue, msg.sender);
        FHE.allow(n.creditRating, msg.sender);
        FHE.allow(n.outstandingBalance, msg.sender);
        FHE.allowTransient(l.askPrice, seller);
        emit NoteSold(listingId, msg.sender);
    }

    function markDefault(uint256 noteId) external onlyOwner {
        notes[noteId].defaulted = true;
        notes[noteId].listed    = false;
        emit NoteDefaulted(noteId);
    }
}
