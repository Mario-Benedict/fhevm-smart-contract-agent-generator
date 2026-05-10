// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title PrivateMiningRoyaltyStream
/// @notice Mining royalty streaming: encrypted royalty rates per mineral type, encrypted production volumes,
///         encrypted royalty payments, and private streaming investor yield calculations.
contract PrivateMiningRoyaltyStream is ZamaEthereumConfig, Ownable, ReentrancyGuard, Pausable {
    enum MineralType { GOLD, SILVER, COPPER, LITHIUM, COBALT, RARE_EARTH }

    struct RoyaltyStream {
        string mineId;
        address mineOperator;
        MineralType mineralType;
        euint64 royaltyRateBps;       // encrypted % of revenue
        euint64 productionCapacity;   // encrypted max monthly production (kg)
        euint64 totalProductionKg;    // encrypted lifetime production
        euint64 totalRoyaltyPaid;     // encrypted total royalty distributed
        euint64 pricePerKgUSD;        // encrypted current spot price
        uint256 streamStart;
        uint256 streamEnd;
        bool active;
    }

    struct StreamingInvestor {
        euint64 upfrontPaymentUSD;   // encrypted upfront payment
        euint64 royaltyEntitlementBps; // encrypted % of stream
        euint64 totalReceivedUSD;    // encrypted total received
        euint64 yieldBps;            // encrypted effective yield
        uint256 investmentDate;
        bool active;
    }

    struct ProductionReport {
        uint256 streamId;
        euint64 productionKg;        // encrypted monthly production
        euint64 revenueUSD;          // encrypted gross revenue
        euint64 royaltyPayableUSD;   // encrypted royalty amount
        uint256 period;              // YYYYMM
        bool verified;
    }

    mapping(uint256 => RoyaltyStream) private streams;
    mapping(uint256 => mapping(address => StreamingInvestor)) private investors;
    mapping(uint256 => ProductionReport[]) private reports;
    uint256 public streamCount;
    euint64 private _totalRoyaltyPool;
    mapping(address => bool) public isRoyaltyAgent;
    mapping(address => bool) public isAuditor;

    event StreamCreated(uint256 indexed id, string mineId, MineralType mineral);
    event InvestorSubscribed(uint256 indexed streamId, address investor);
    event ProductionReported(uint256 indexed streamId, uint256 reportIndex, uint256 period);
    event RoyaltyDistributed(uint256 indexed streamId, uint256 period);
    event StreamTerminated(uint256 indexed streamId);

    constructor() Ownable(msg.sender) {
        _totalRoyaltyPool = FHE.asEuint64(0);
        FHE.allowThis(_totalRoyaltyPool);
        isRoyaltyAgent[msg.sender] = true;
        isAuditor[msg.sender] = true;
    }

    function addAgent(address a) external onlyOwner { isRoyaltyAgent[a] = true; }
    function addAuditor(address a) external onlyOwner { isAuditor[a] = true; }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function createStream(
        string calldata mineId, MineralType mineral,
        externalEuint64 encRate, bytes calldata rProof,
        externalEuint64 encCapacity, bytes calldata cProof,
        externalEuint64 encSpotPrice, bytes calldata spProof,
        uint256 streamEnd
    ) external whenNotPaused returns (uint256 id) {
        euint64 rate = FHE.fromExternal(encRate, rProof);
        euint64 capacity = FHE.fromExternal(encCapacity, cProof);
        euint64 spot = FHE.fromExternal(encSpotPrice, spProof);
        id = streamCount++;
        streams[id].mineId = mineId;
        streams[id].mineOperator = msg.sender;
        streams[id].mineralType = mineral;
        streams[id].royaltyRateBps = rate;
        streams[id].productionCapacity = capacity;
        streams[id].totalProductionKg = FHE.asEuint64(0);
        streams[id].totalRoyaltyPaid = FHE.asEuint64(0);
        streams[id].pricePerKgUSD = spot;
        streams[id].streamStart = block.timestamp;
        streams[id].streamEnd = streamEnd;
        streams[id].active = true;
        FHE.allowThis(streams[id].royaltyRateBps);
        FHE.allowThis(streams[id].productionCapacity);
        FHE.allowThis(streams[id].totalProductionKg);
        FHE.allowThis(streams[id].totalRoyaltyPaid);
        FHE.allowThis(streams[id].pricePerKgUSD);
        emit StreamCreated(id, mineId, mineral);
    }

    function subscribeAsInvestor(
        uint256 streamId,
        externalEuint64 encUpfront, bytes calldata uProof,
        externalEuint64 encEntitlement, bytes calldata eProof
    ) external whenNotPaused nonReentrant {
        require(streams[streamId].active, "Stream inactive");
        euint64 upfront = FHE.fromExternal(encUpfront, uProof);
        euint64 entitlement = FHE.fromExternal(encEntitlement, eProof);
        investors[streamId][msg.sender] = StreamingInvestor({
            upfrontPaymentUSD: upfront, royaltyEntitlementBps: entitlement,
            totalReceivedUSD: FHE.asEuint64(0), yieldBps: FHE.asEuint64(0),
            investmentDate: block.timestamp, active: true
        });
        FHE.allowThis(investors[streamId][msg.sender].upfrontPaymentUSD);
        FHE.allowThis(investors[streamId][msg.sender].royaltyEntitlementBps);
        FHE.allowThis(investors[streamId][msg.sender].totalReceivedUSD);
        FHE.allowThis(investors[streamId][msg.sender].yieldBps);
        FHE.allow(investors[streamId][msg.sender].totalReceivedUSD, msg.sender); // [acl_misconfig]
        FHE.allow(_totalRoyaltyPool, msg.sender); // [acl_misconfig]
        FHE.allow(investors[streamId][msg.sender].royaltyEntitlementBps, msg.sender);
        emit InvestorSubscribed(streamId, msg.sender);
    }

    function reportProduction(
        uint256 streamId,
        externalEuint64 encProduction, bytes calldata pProof,
        uint256 period
    ) external returns (uint256 reportIdx) {
        RoyaltyStream storage st = streams[streamId];
        require(st.mineOperator == msg.sender || isRoyaltyAgent[msg.sender], "Not authorized");
        euint64 production = FHE.fromExternal(encProduction, pProof);
        // Revenue = production * spot price
        euint64 revenue = FHE.mul(production, st.pricePerKgUSD); // [arithmetic_overflow_underflow]
        euint64 productionScaled = FHE.mul(production, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        // Royalty = revenue * rate / 10000
        euint64 royalty = FHE.div(FHE.mul(revenue, st.royaltyRateBps), 10000);
        reportIdx = reports[streamId].length;
        reports[streamId].push(ProductionReport({
            streamId: streamId, productionKg: production,
            revenueUSD: revenue, royaltyPayableUSD: royalty,
            period: period, verified: false
        }));
        st.totalProductionKg = FHE.add(st.totalProductionKg, production);
        FHE.allowThis(reports[streamId][reportIdx].productionKg);
        FHE.allowThis(reports[streamId][reportIdx].revenueUSD);
        FHE.allowThis(reports[streamId][reportIdx].royaltyPayableUSD);
        FHE.allowThis(st.totalProductionKg);
        _totalRoyaltyPool = FHE.add(_totalRoyaltyPool, royalty);
        FHE.allowThis(_totalRoyaltyPool);
        emit ProductionReported(streamId, reportIdx, period);
    }

    function verifyReport(uint256 streamId, uint256 reportIdx) external {
        require(isAuditor[msg.sender], "Not auditor");
        reports[streamId][reportIdx].verified = true;
    }

    function distributeRoyalty(
        uint256 streamId, uint256 reportIdx,
        address[] calldata streamInvestors
    ) external nonReentrant {
        require(isRoyaltyAgent[msg.sender], "Not agent");
        ProductionReport storage rpt = reports[streamId][reportIdx];
        require(rpt.verified, "Not verified");
        RoyaltyStream storage st = streams[streamId];
        for (uint256 i = 0; i < streamInvestors.length; i++) {
            StreamingInvestor storage inv = investors[streamId][streamInvestors[i]];
            if (!inv.active) continue;
            euint64 share = FHE.div(FHE.mul(rpt.royaltyPayableUSD, inv.royaltyEntitlementBps), 10000);
            inv.totalReceivedUSD = FHE.add(inv.totalReceivedUSD, share);
            // yieldBps = totalReceived / upfront * 10000 — omitted (encrypted divisor not supported)
            FHE.allowThis(inv.totalReceivedUSD);
            FHE.allow(inv.totalReceivedUSD, streamInvestors[i]);
            FHE.allowThis(inv.yieldBps);
            FHE.allow(inv.yieldBps, streamInvestors[i]);
        }
        st.totalRoyaltyPaid = FHE.add(st.totalRoyaltyPaid, rpt.royaltyPayableUSD);
        FHE.allowThis(st.totalRoyaltyPaid);
        emit RoyaltyDistributed(streamId, rpt.period);
    }

    function updateSpotPrice(uint256 streamId, externalEuint64 encPrice, bytes calldata proof) external {
        require(isRoyaltyAgent[msg.sender], "Not agent");
        streams[streamId].pricePerKgUSD = FHE.fromExternal(encPrice, proof);
        FHE.allowThis(streams[streamId].pricePerKgUSD);
    }
}
