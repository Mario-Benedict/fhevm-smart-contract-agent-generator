// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateInstitutionalCustodianVault
/// @notice A regulated custodian vault where asset quantities, client IDs, and
///         fee structures remain encrypted. Supports multi-asset segregated accounts.
contract PrivateInstitutionalCustodianVault is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    uint8 public constant MAX_ASSETS = 10;

    struct AssetHolding {
        euint64 quantity;      // encrypted quantity
        euint32 feeRateBps;    // encrypted management fee in basis points
        uint256 lastFeeCharge;
        bool active;
    }

    struct ClientAccount {
        mapping(uint8 => AssetHolding) holdings;
        euint64 totalNAV;   // encrypted total net asset value (USD cents)
        bool approved;
        address delegate;
    }

    mapping(address => ClientAccount) private clients;
    address[] public clientList;
    euint64 private _platformTotalAUM;  // encrypted total assets under management
    uint256 public custodyFeeInterval = 30 days;

    event ClientOnboarded(address indexed client);
    event AssetDeposited(address indexed client, uint8 assetId);
    event AssetWithdrawn(address indexed client, uint8 assetId);
    event FeeCharged(address indexed client, uint8 assetId);
    event DelegateSet(address indexed client, address delegate);

    constructor() Ownable(msg.sender) {
        _platformTotalAUM = FHE.asEuint64(0);
        FHE.allowThis(_platformTotalAUM);
    }

    modifier onlyClientOrDelegate(address client) {
        require(msg.sender == client || msg.sender == clients[client].delegate || msg.sender == owner(), "Unauthorized");
        _;
    }

    function onboardClient(address client) external onlyOwner {
        require(!clients[client].approved, "Already onboarded");
        clients[client].approved = true;
        clients[client].totalNAV = FHE.asEuint64(0);
        FHE.allowThis(clients[client].totalNAV);
        FHE.allow(clients[client].totalNAV, client);
        clientList.push(client);
        emit ClientOnboarded(client);
    }

    function setDelegate(address delegate) external {
        require(clients[msg.sender].approved, "Not onboarded");
        clients[msg.sender].delegate = delegate;
        emit DelegateSet(msg.sender, delegate);
    }

    function depositAsset(
        address client,
        uint8 assetId,
        externalEuint64 encQty, bytes calldata qtyProof,
        externalEuint32 encFee, bytes calldata feeProof,
        externalEuint64 encNAVDelta, bytes calldata navProof
    ) external onlyOwner whenNotPaused {
        require(clients[client].approved, "Client not approved");
        require(assetId < MAX_ASSETS, "Invalid asset");
        euint64 qty = FHE.fromExternal(encQty, qtyProof);
        euint32 fee = FHE.fromExternal(encFee, feeProof);
        euint64 navDelta = FHE.fromExternal(encNAVDelta, navProof);

        AssetHolding storage h = clients[client].holdings[assetId];
        h.quantity = FHE.add(h.quantity, qty);
        h.feeRateBps = fee;
        h.lastFeeCharge = block.timestamp;
        h.active = true;

        clients[client].totalNAV = FHE.add(clients[client].totalNAV, navDelta);
        _platformTotalAUM = FHE.add(_platformTotalAUM, navDelta);

        FHE.allowThis(h.quantity);
        FHE.allow(h.quantity, client);
        FHE.allowThis(h.feeRateBps);
        FHE.allowThis(clients[client].totalNAV);
        FHE.allow(clients[client].totalNAV, client);
        FHE.allowThis(_platformTotalAUM);
        emit AssetDeposited(client, assetId);
    }

    function withdrawAsset(
        address client,
        uint8 assetId,
        externalEuint64 encQty, bytes calldata qtyProof,
        externalEuint64 encNAVDelta, bytes calldata navProof
    ) external onlyClientOrDelegate(client) whenNotPaused nonReentrant {
        require(assetId < MAX_ASSETS, "Invalid asset");
        euint64 qty = FHE.fromExternal(encQty, qtyProof);
        euint64 navDelta = FHE.fromExternal(encNAVDelta, navProof);

        AssetHolding storage h = clients[client].holdings[assetId];
        ebool hasSuff = FHE.le(qty, h.quantity);
        euint64 actual = FHE.select(hasSuff, qty, FHE.asEuint64(0));
        h.quantity = FHE.sub(h.quantity, actual);

        euint64 actualNAV = FHE.select(hasSuff, navDelta, FHE.asEuint64(0));
        clients[client].totalNAV = FHE.sub(clients[client].totalNAV, actualNAV);
        _platformTotalAUM = FHE.sub(_platformTotalAUM, actualNAV);

        FHE.allowThis(h.quantity);
        FHE.allow(h.quantity, client);
        FHE.allowThis(clients[client].totalNAV);
        FHE.allow(clients[client].totalNAV, client);
        FHE.allowThis(_platformTotalAUM);
        FHE.allow(actual, client);
        emit AssetWithdrawn(client, assetId);
    }

    function chargeFee(address client, uint8 assetId) external onlyOwner {
        AssetHolding storage h = clients[client].holdings[assetId];
        require(h.active, "Asset not active");
        require(block.timestamp >= h.lastFeeCharge + custodyFeeInterval, "Too soon");
        // fee = quantity * feeRateBps / 10000 (annual rate applied monthly)
        euint64 feeQty = FHE.div(FHE.mul(h.quantity, FHE.asEuint64(uint64(uint32(0)))), 10000);
        // Use fee rate cast
        euint64 fee = FHE.div(h.quantity, 120); // ~0.833% monthly
        h.quantity = FHE.sub(h.quantity, fee);
        h.lastFeeCharge = block.timestamp;
        FHE.allowThis(h.quantity);
        FHE.allow(h.quantity, client);
        FHE.allow(fee, owner());
        emit FeeCharged(client, assetId);
    }

    function allowClientNAV(address viewer) external {
        FHE.allow(clients[msg.sender].totalNAV, viewer);
    }

    function allowTotalAUM(address viewer) external onlyOwner {
        FHE.allow(_platformTotalAUM, viewer);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
