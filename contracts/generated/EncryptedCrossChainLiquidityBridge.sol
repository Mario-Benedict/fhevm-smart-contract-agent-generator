// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedCrossChainLiquidityBridge
/// @notice Privacy-preserving cross-chain bridge where liquidity provider positions,
///         bridge fees, and routing amounts are encrypted. Relayers cannot front-run
///         transactions because amounts remain hidden until settlement.
contract EncryptedCrossChainLiquidityBridge is ZamaEthereumConfig, AccessControl, ReentrancyGuard, Pausable {
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE");

    enum BridgeState { Pending, Relaying, Completed, Failed, Refunded }

    struct BridgeRequest {
        address sender;
        address recipient;          // recipient on destination chain
        euint64 amount;             // encrypted bridge amount
        euint32 feeEncrypted;       // encrypted protocol fee
        uint32 destinationChainId;
        uint256 nonce;
        uint256 requestTime;
        BridgeState state;
        uint8 validationsReceived;
    }

    uint256 public nextNonce;
    mapping(uint256 => BridgeRequest) private requests;
    mapping(address => euint64) private lpPositions;    // encrypted LP liquidity
    mapping(address => uint256[]) private senderHistory;

    euint64 private _totalLiquidity;
    euint32 private _defaultFeeBps;

    uint8 public constant VALIDATION_THRESHOLD = 3;

    event BridgeRequested(uint256 indexed nonce, address sender, uint32 destChain);
    event ValidationReceived(uint256 indexed nonce, address validator);
    event BridgeCompleted(uint256 indexed nonce);
    event BridgeFailed(uint256 indexed nonce);
    event LiquidityAdded(address indexed lp);

    constructor(externalEuint32 encDefaultFee, bytes memory feeProof) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(RELAYER_ROLE, msg.sender);
        _grantRole(VALIDATOR_ROLE, msg.sender);
        _defaultFeeBps = FHE.fromExternal(encDefaultFee, feeProof);
        _totalLiquidity = FHE.asEuint64(0);
        FHE.allowThis(_defaultFeeBps);
        FHE.allowThis(_totalLiquidity);
    }

    function addLiquidity(externalEuint64 encAmount, bytes calldata proof) external whenNotPaused {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        lpPositions[msg.sender] = FHE.add(lpPositions[msg.sender], amount);
        _totalLiquidity = FHE.add(_totalLiquidity, amount);
        FHE.allowThis(lpPositions[msg.sender]);
        FHE.allow(lpPositions[msg.sender], msg.sender);
        FHE.allowThis(_totalLiquidity);
        emit LiquidityAdded(msg.sender);
    }

    function removeLiquidity(externalEuint64 encAmount, bytes calldata proof) external nonReentrant {
        euint64 amount = FHE.fromExternal(encAmount, proof);
        ebool hasSufficient = FHE.ge(lpPositions[msg.sender], amount);
        euint64 actual = FHE.select(hasSufficient, amount, lpPositions[msg.sender]);
        lpPositions[msg.sender] = FHE.sub(lpPositions[msg.sender], actual);
        _totalLiquidity = FHE.sub(_totalLiquidity, actual);
        FHE.allowThis(lpPositions[msg.sender]);
        FHE.allow(lpPositions[msg.sender], msg.sender);
        FHE.allowThis(_totalLiquidity);
    }

    function requestBridge(
        address recipient,
        externalEuint64 encAmount,
        bytes calldata amountProof,
        uint32 destinationChainId
    ) external whenNotPaused nonReentrant returns (uint256 nonce) {
        nonce = nextNonce++;
        euint64 amount = FHE.fromExternal(encAmount, amountProof);
        euint32 fee = _defaultFeeBps;

        requests[nonce] = BridgeRequest({
            sender: msg.sender,
            recipient: recipient,
            amount: amount,
            feeEncrypted: fee,
            destinationChainId: destinationChainId,
            nonce: nonce,
            requestTime: block.timestamp,
            state: BridgeState.Pending,
            validationsReceived: 0
        });

        FHE.allowThis(requests[nonce].amount);
        FHE.allow(requests[nonce].amount, msg.sender);
        FHE.allowThis(requests[nonce].feeEncrypted);

        senderHistory[msg.sender].push(nonce);
        emit BridgeRequested(nonce, msg.sender, destinationChainId);
    }

    function validateBridge(uint256 nonce) external onlyRole(VALIDATOR_ROLE) {
        BridgeRequest storage r = requests[nonce];
        require(r.state == BridgeState.Pending || r.state == BridgeState.Relaying, "Invalid state");
        r.validationsReceived++;
        r.state = BridgeState.Relaying;
        emit ValidationReceived(nonce, msg.sender);

        if (r.validationsReceived >= VALIDATION_THRESHOLD) {
            r.state = BridgeState.Completed;
            FHE.allow(r.amount, r.sender);
            emit BridgeCompleted(nonce);
        }
    }

    function markFailed(uint256 nonce) external onlyRole(RELAYER_ROLE) {
        requests[nonce].state = BridgeState.Failed;
        emit BridgeFailed(nonce);
    }

    function allowLPView(address viewer) external {
        FHE.allow(lpPositions[msg.sender], viewer);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }
}
