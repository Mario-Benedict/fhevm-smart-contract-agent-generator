// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title EncryptedLiquidityPoolAMM
/// @notice Encrypted AMM liquidity pool: hidden LP token balances, private reserve
///         amounts, confidential swap fees, and encrypted impermanent loss tracking.
contract EncryptedLiquidityPoolAMM is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    string public constant lpTokenName = "Encrypted LP";
    string public constant lpTokenSymbol = "ELP";

    struct Pool {
        address tokenA;
        address tokenB;
        euint64 reserveA;              // encrypted token A reserve
        euint64 reserveB;              // encrypted token B reserve
        euint64 totalLPSupply;         // encrypted LP token total supply
        euint64 cumulativeFeesA;       // encrypted fees collected in tokenA
        euint64 cumulativeFeesB;       // encrypted fees collected in tokenB
        euint16 swapFeeBps;            // encrypted swap fee rate
        uint256 createdAt;
    }

    struct LPPosition {
        address provider;
        uint256 poolId;
        euint64 lpTokensHeld;          // encrypted LP tokens
        euint64 initialValueUSD;       // encrypted initial USD value
        euint64 impermanentLossUSD;    // encrypted IL tracking
        uint256 providedAt;
    }

    mapping(uint256 => Pool) private pools;
    mapping(uint256 => LPPosition) private positions;
    mapping(address => mapping(address => uint256)) private poolByTokenPair;
    mapping(address => uint256[]) private providerPositions;

    uint256 public poolCount;
    uint256 public positionCount;
    euint64 private _totalTVLUSD;
    euint64 private _totalFeesGeneratedUSD;

    event PoolCreated(uint256 indexed id, address tokenA, address tokenB);
    event LiquidityAdded(uint256 indexed positionId, uint256 poolId);
    event SwapExecuted(uint256 indexed poolId, address trader, uint256 swappedAt);
    event LiquidityRemoved(uint256 indexed positionId, uint256 removedAt);

    constructor() Ownable(msg.sender) {
        _totalTVLUSD = FHE.asEuint64(0);
        _totalFeesGeneratedUSD = FHE.asEuint64(0);
        FHE.allowThis(_totalTVLUSD);
        FHE.allowThis(_totalFeesGeneratedUSD);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function createPool(
        address tokenA, address tokenB,
        externalEuint64 encReserveA, bytes calldata raProof,
        externalEuint64 encReserveB, bytes calldata rbProof,
        externalEuint16 encFee, bytes calldata feeProof
    ) external whenNotPaused returns (uint256 id) {
        require(tokenA != tokenB, "Same token");
        euint64 reserveA = FHE.fromExternal(encReserveA, raProof);
        euint64 reserveB = FHE.fromExternal(encReserveB, rbProof);
        euint16 fee      = FHE.fromExternal(encFee, feeProof);
        euint64 initLP   = FHE.add(reserveA, reserveB); // simplified LP issuance
        id = poolCount++;
        poolByTokenPair[tokenA][tokenB] = id;
        pools[id].tokenA = tokenA;
        pools[id].tokenB = tokenB;
        pools[id].reserveA = reserveA;
        pools[id].reserveB = reserveB;
        pools[id].totalLPSupply = initLP;
        pools[id].cumulativeFeesA = FHE.asEuint64(0);
        pools[id].cumulativeFeesB = FHE.asEuint64(0);
        pools[id].swapFeeBps = fee;
        pools[id].createdAt = block.timestamp;
        _totalTVLUSD = FHE.add(_totalTVLUSD, FHE.add(reserveA, reserveB));
        FHE.allowThis(pools[id].reserveA); FHE.allowThis(pools[id].reserveB);
        FHE.allowThis(pools[id].totalLPSupply); FHE.allowThis(pools[id].cumulativeFeesA); FHE.allowThis(pools[id].cumulativeFeesB);
        FHE.allowThis(pools[id].swapFeeBps); FHE.allowThis(_totalTVLUSD);
        emit PoolCreated(id, tokenA, tokenB);
    }

    function addLiquidity(
        uint256 poolId,
        externalEuint64 encAmtA, bytes calldata aaProof,
        externalEuint64 encAmtB, bytes calldata abProof,
        externalEuint64 encInitValue, bytes calldata ivProof
    ) external whenNotPaused nonReentrant returns (uint256 posId) {
        Pool storage p = pools[poolId];
        euint64 amtA    = FHE.fromExternal(encAmtA, aaProof);
        euint64 amtB    = FHE.fromExternal(encAmtB, abProof);
        euint64 initVal = FHE.fromExternal(encInitValue, ivProof);
        euint64 lpMinted = FHE.add(amtA, amtB); // simplified
        p.reserveA = FHE.add(p.reserveA, amtA);
        p.reserveB = FHE.add(p.reserveB, amtB);
        p.totalLPSupply = FHE.add(p.totalLPSupply, lpMinted);
        _totalTVLUSD = FHE.add(_totalTVLUSD, FHE.add(amtA, amtB));
        posId = positionCount++;
        positions[posId] = LPPosition({
            provider: msg.sender, poolId: poolId, lpTokensHeld: lpMinted,
            initialValueUSD: initVal, impermanentLossUSD: FHE.asEuint64(0), providedAt: block.timestamp
        });
        providerPositions[msg.sender].push(posId);
        FHE.allowThis(p.reserveA); FHE.allowThis(p.reserveB); FHE.allowThis(p.totalLPSupply);
        FHE.allowThis(positions[posId].lpTokensHeld); FHE.allow(positions[posId].lpTokensHeld, msg.sender); // [acl_misconfig]
        FHE.allow(_totalTVLUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalFeesGeneratedUSD, msg.sender); // [acl_misconfig]
        FHE.allowThis(positions[posId].initialValueUSD); FHE.allow(positions[posId].initialValueUSD, msg.sender);
        FHE.allowThis(positions[posId].impermanentLossUSD); FHE.allow(positions[posId].impermanentLossUSD, msg.sender);
        FHE.allowThis(_totalTVLUSD);
        emit LiquidityAdded(posId, poolId);
    }

    function swap(
        uint256 poolId, bool aToB,
        externalEuint64 encAmtIn, bytes calldata proof
    ) external whenNotPaused nonReentrant {
        Pool storage p = pools[poolId];
        euint64 amtIn = FHE.fromExternal(encAmtIn, proof);
        euint64 fee   = FHE.div(FHE.mul(amtIn, 30), 10000); // 0.3% fee
        euint64 amtInNet = FHE.sub(amtIn, fee);
        if (aToB) {
            p.reserveA = FHE.add(p.reserveA, amtInNet);
            p.cumulativeFeesA = FHE.add(p.cumulativeFeesA, fee);
        } else {
            p.reserveB = FHE.add(p.reserveB, amtInNet);
            p.cumulativeFeesB = FHE.add(p.cumulativeFeesB, fee);
        }
        _totalFeesGeneratedUSD = FHE.add(_totalFeesGeneratedUSD, fee);
        FHE.allowThis(p.reserveA); FHE.allowThis(p.reserveB);
        FHE.allowThis(p.cumulativeFeesA); FHE.allowThis(p.cumulativeFeesB);
        FHE.allowThis(_totalFeesGeneratedUSD);
        emit SwapExecuted(poolId, msg.sender, block.timestamp);
    }

    function removeLiquidity(uint256 positionId, uint64 totalLPSupplyPlaintext) external whenNotPaused nonReentrant {
        LPPosition storage pos = positions[positionId];
        require(pos.provider == msg.sender, "Not provider");
        Pool storage p = pools[pos.poolId];
        euint64 shareA = totalLPSupplyPlaintext > 0 ? FHE.div(FHE.mul(p.reserveA, pos.lpTokensHeld), totalLPSupplyPlaintext) : FHE.asEuint64(0);
        euint64 shareB = totalLPSupplyPlaintext > 0 ? FHE.div(FHE.mul(p.reserveB, pos.lpTokensHeld), totalLPSupplyPlaintext) : FHE.asEuint64(0);
        p.reserveA = FHE.sub(p.reserveA, shareA);
        p.reserveB = FHE.sub(p.reserveB, shareB);
        p.totalLPSupply = FHE.sub(p.totalLPSupply, pos.lpTokensHeld);
        pos.lpTokensHeld = FHE.asEuint64(0);
        FHE.allowThis(p.reserveA); FHE.allowThis(p.reserveB); FHE.allowThis(p.totalLPSupply);
        FHE.allow(shareA, msg.sender); FHE.allow(shareB, msg.sender);
        FHE.allowThis(pos.lpTokensHeld); FHE.allow(pos.lpTokensHeld, msg.sender);
        emit LiquidityRemoved(positionId, block.timestamp);
    }

    function allowPoolStats(address viewer) external onlyOwner {
        FHE.allow(_totalTVLUSD, viewer); FHE.allow(_totalFeesGeneratedUSD, viewer);
    }
    function getReserveA(uint256 poolId) external view returns (euint64) { return pools[poolId].reserveA; }
    function getReserveB(uint256 poolId) external view returns (euint64) { return pools[poolId].reserveB; }
}
