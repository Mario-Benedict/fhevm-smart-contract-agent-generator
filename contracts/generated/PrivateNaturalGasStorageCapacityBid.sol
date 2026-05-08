// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateNaturalGasStorageCapacityBid
/// @notice Natural gas storage open season with encrypted storage injection/
///         withdrawal capacities, working gas volumes, basis differentials,
///         and confidential customer priority rankings for firm service.
contract PrivateNaturalGasStorageCapacityBid is ZamaEthereumConfig, Ownable, ReentrancyGuard {

    enum ServiceType { FIRM_STORAGE, INTERRUPTIBLE_STORAGE, HUB_SERVICES, PARKING_LENDING, NO_NOTICE }
    enum ContractTerm { DAILY, MONTHLY, SEASONAL, ANNUAL, MULTI_YEAR }
    enum StorageStatus { OPEN_SEASON, AWARDED, ACTIVE, EXPIRED, TERMINATED }

    struct StoragePool {
        euint64 totalWorkingGasBCF;        // encrypted total working gas (BCF)
        euint64 availableWorkingGasBCF;    // encrypted available working gas
        euint64 maxInjectionRateMmcfd;     // encrypted max daily injection (MMCFD)
        euint64 maxWithdrawalRateMmcfd;    // encrypted max daily withdrawal (MMCFD)
        euint64 baseReservationCharge;     // encrypted base reservation $/Dth/mo
        euint64 commodityInjectionCharge;  // encrypted injection commodity charge
        euint64 commodityWithdrawalCharge; // encrypted withdrawal commodity charge
        euint64 minimumInventoryRequirementBCF; // encrypted min inventory
        uint256 openSeasonStart;
        uint256 openSeasonEnd;
        bool openSeasonActive;
    }

    struct CapacityBid {
        address bidder;
        ServiceType serviceType;
        ContractTerm term;
        StorageStatus status;
        euint64 workingGasBidBCF;          // encrypted working gas requested
        euint64 injectionCapacityBidMmcfd; // encrypted injection capacity requested
        euint64 withdrawalCapacityBidMmcfd;// encrypted withdrawal capacity requested
        euint64 reservationPriceOffered;   // encrypted price offered per Dth/mo
        euint64 priorityIndex;             // encrypted priority ranking
        euint64 creditSupportPosted;       // encrypted credit support/margin
        euint64 awardedWorkingGasBCF;      // encrypted actually awarded
        uint256 contractStart;
        uint256 contractEnd;
        bool priceAccepted;
    }

    struct CustomerInventory {
        euint64 currentInventoryBCF;       // encrypted current gas held in storage
        euint64 injectedThisMonth;         // encrypted monthly injection
        euint64 withdrawnThisMonth;        // encrypted monthly withdrawal
        euint64 monthlyReservationBill;    // encrypted monthly reservation charge
        euint64 monthlyUsageBill;          // encrypted monthly usage charge
        euint64 totalContractualVolume;    // encrypted total contracted volume
    }

    mapping(bytes32 => CapacityBid) private bids;
    mapping(address => CustomerInventory) private inventories;
    StoragePool private storagePool;

    euint64 private _totalReservationRevenue;   // encrypted total reservation revenue
    euint64 private _totalCommodityRevenue;     // encrypted total commodity revenue
    euint64 private _currentFieldInventoryBCF;  // encrypted real-time field inventory

    event OpenSeasonLaunched(uint256 start, uint256 end);
    event BidSubmitted(bytes32 indexed bidId, address bidder, ServiceType serviceType);
    event CapacityAwarded(bytes32 indexed bidId, address bidder);
    event InventoryInjected(address indexed customer);
    event InventoryWithdrawn(address indexed customer);
    event BillingProcessed(address indexed customer);

    constructor(
        externalEuint64 encTotalWorkingGas, bytes memory twgProof,
        externalEuint64 encMaxInjection, bytes memory miProof,
        externalEuint64 encMaxWithdrawal, bytes memory mwProof,
        externalEuint64 encBaseReservation, bytes memory brProof
    ) Ownable(msg.sender) {
        euint64 twg = FHE.fromExternal(encTotalWorkingGas, twgProof);
        euint64 maxInj = FHE.fromExternal(encMaxInjection, miProof);
        euint64 maxWdl = FHE.fromExternal(encMaxWithdrawal, mwProof);
        euint64 baseRes = FHE.fromExternal(encBaseReservation, brProof);

        storagePool = StoragePool({
            totalWorkingGasBCF: twg,
            availableWorkingGasBCF: twg,
            maxInjectionRateMmcfd: maxInj,
            maxWithdrawalRateMmcfd: maxWdl,
            baseReservationCharge: baseRes,
            commodityInjectionCharge: FHE.asEuint64(0),
            commodityWithdrawalCharge: FHE.asEuint64(0),
            minimumInventoryRequirementBCF: FHE.asEuint64(0),
            openSeasonStart: 0,
            openSeasonEnd: 0,
            openSeasonActive: false
        });

        _totalReservationRevenue = FHE.asEuint64(0);
        _totalCommodityRevenue = FHE.asEuint64(0);
        _currentFieldInventoryBCF = FHE.asEuint64(0);

        FHE.allowThis(twg); FHE.allowThis(maxInj); FHE.allowThis(maxWdl); FHE.allowThis(baseRes);
        FHE.allowThis(storagePool.commodityInjectionCharge);
        FHE.allowThis(storagePool.commodityWithdrawalCharge);
        FHE.allowThis(storagePool.minimumInventoryRequirementBCF);
        FHE.allowThis(_totalReservationRevenue);
        FHE.allowThis(_totalCommodityRevenue);
        FHE.allowThis(_currentFieldInventoryBCF);
    }

    function launchOpenSeason(
        uint256 openSeasonStart,
        uint256 openSeasonEnd,
        externalEuint64 encCommodityInjCharge, bytes calldata cijProof,
        externalEuint64 encCommodityWdlCharge, bytes calldata cwdProof
    ) external onlyOwner {
        require(!storagePool.openSeasonActive, "Open season already active");
        euint64 injCharge = FHE.fromExternal(encCommodityInjCharge, cijProof);
        euint64 wdlCharge = FHE.fromExternal(encCommodityWdlCharge, cwdProof);
        storagePool.commodityInjectionCharge = injCharge;
        storagePool.commodityWithdrawalCharge = wdlCharge;
        storagePool.openSeasonStart = openSeasonStart;
        storagePool.openSeasonEnd = openSeasonEnd;
        storagePool.openSeasonActive = true;
        FHE.allowThis(injCharge); FHE.allowThis(wdlCharge);
        emit OpenSeasonLaunched(openSeasonStart, openSeasonEnd);
    }

    function submitCapacityBid(
        ServiceType serviceType,
        ContractTerm term,
        externalEuint64 encWorkingGas, bytes calldata wgProof,
        externalEuint64 encInjCapacity, bytes calldata icProof,
        externalEuint64 encWdlCapacity, bytes calldata wcProof,
        externalEuint64 encPriceOffered, bytes calldata poProof,
        externalEuint64 encCreditSupport, bytes calldata csProof,
        uint256 contractStart,
        uint256 contractEnd
    ) external nonReentrant returns (bytes32 bidId) {
        require(storagePool.openSeasonActive, "No active open season");
        require(block.timestamp >= storagePool.openSeasonStart &&
                block.timestamp <= storagePool.openSeasonEnd, "Outside open season");

        euint64 workingGas = FHE.fromExternal(encWorkingGas, wgProof);
        euint64 injCapacity = FHE.fromExternal(encInjCapacity, icProof);
        euint64 wdlCapacity = FHE.fromExternal(encWdlCapacity, wcProof);
        euint64 priceOffered = FHE.fromExternal(encPriceOffered, poProof);
        euint64 creditSupport = FHE.fromExternal(encCreditSupport, csProof);

        bidId = keccak256(abi.encodePacked(msg.sender, serviceType, block.timestamp));

        bids[bidId] = CapacityBid({
            bidder: msg.sender,
            serviceType: serviceType,
            term: term,
            status: StorageStatus.OPEN_SEASON,
            workingGasBidBCF: workingGas,
            injectionCapacityBidMmcfd: injCapacity,
            withdrawalCapacityBidMmcfd: wdlCapacity,
            reservationPriceOffered: priceOffered,
            priorityIndex: FHE.asEuint64(0),
            creditSupportPosted: creditSupport,
            awardedWorkingGasBCF: FHE.asEuint64(0),
            contractStart: contractStart,
            contractEnd: contractEnd,
            priceAccepted: false
        });

        FHE.allowThis(workingGas); FHE.allow(workingGas, msg.sender);
        FHE.allowThis(injCapacity); FHE.allow(injCapacity, msg.sender);
        FHE.allowThis(wdlCapacity); FHE.allow(wdlCapacity, msg.sender);
        FHE.allowThis(priceOffered); FHE.allow(priceOffered, msg.sender);
        FHE.allowThis(creditSupport); FHE.allow(creditSupport, msg.sender);
        FHE.allowThis(bids[bidId].priorityIndex);
        FHE.allowThis(bids[bidId].awardedWorkingGasBCF);

        emit BidSubmitted(bidId, msg.sender, serviceType);
    }

    function awardCapacity(
        bytes32 bidId,
        externalEuint64 encAwardedVolume, bytes calldata avProof,
        externalEuint64 encPriorityIndex, bytes calldata piProof
    ) external onlyOwner {
        CapacityBid storage bid = bids[bidId];
        require(bid.status == StorageStatus.OPEN_SEASON, "Not in open season");

        euint64 awardedVolume = FHE.fromExternal(encAwardedVolume, avProof);
        euint64 priorityIndex = FHE.fromExternal(encPriorityIndex, piProof);

        bid.awardedWorkingGasBCF = awardedVolume;
        bid.priorityIndex = priorityIndex;
        bid.status = StorageStatus.AWARDED;
        bid.priceAccepted = true;

        storagePool.availableWorkingGasBCF = FHE.sub(storagePool.availableWorkingGasBCF,
            FHE.select(FHE.ge(storagePool.availableWorkingGasBCF, awardedVolume),
                awardedVolume, storagePool.availableWorkingGasBCF));

        // Initialize customer inventory
        CustomerInventory storage inv = inventories[bid.bidder];
        inv.totalContractualVolume = awardedVolume;
        inv.currentInventoryBCF = FHE.asEuint64(0);
        inv.injectedThisMonth = FHE.asEuint64(0);
        inv.withdrawnThisMonth = FHE.asEuint64(0);
        inv.monthlyReservationBill = bid.reservationPriceOffered;
        inv.monthlyUsageBill = FHE.asEuint64(0);

        FHE.allowThis(awardedVolume); FHE.allow(awardedVolume, bid.bidder);
        FHE.allowThis(priorityIndex); FHE.allow(priorityIndex, bid.bidder);
        FHE.allowThis(storagePool.availableWorkingGasBCF);
        FHE.allowThis(inv.totalContractualVolume); FHE.allow(inv.totalContractualVolume, bid.bidder);
        FHE.allowThis(inv.currentInventoryBCF); FHE.allow(inv.currentInventoryBCF, bid.bidder);
        FHE.allowThis(inv.injectedThisMonth); FHE.allow(inv.injectedThisMonth, bid.bidder);
        FHE.allowThis(inv.withdrawnThisMonth); FHE.allow(inv.withdrawnThisMonth, bid.bidder);
        FHE.allowThis(inv.monthlyReservationBill); FHE.allow(inv.monthlyReservationBill, bid.bidder);
        FHE.allowThis(inv.monthlyUsageBill); FHE.allow(inv.monthlyUsageBill, bid.bidder);

        emit CapacityAwarded(bidId, bid.bidder);
    }

    function recordInjection(
        externalEuint64 encVolumeBCF, bytes calldata volProof
    ) external nonReentrant {
        CustomerInventory storage inv = inventories[msg.sender];
        euint64 volume = FHE.fromExternal(encVolumeBCF, volProof);
        inv.currentInventoryBCF = FHE.add(inv.currentInventoryBCF, volume);
        inv.injectedThisMonth = FHE.add(inv.injectedThisMonth, volume);
        _currentFieldInventoryBCF = FHE.add(_currentFieldInventoryBCF, volume);
        euint64 injFee = FHE.mul(volume, storagePool.commodityInjectionCharge);
        inv.monthlyUsageBill = FHE.add(inv.monthlyUsageBill, injFee);
        FHE.allowThis(inv.currentInventoryBCF); FHE.allow(inv.currentInventoryBCF, msg.sender);
        FHE.allowThis(inv.injectedThisMonth); FHE.allow(inv.injectedThisMonth, msg.sender);
        FHE.allowThis(inv.monthlyUsageBill); FHE.allow(inv.monthlyUsageBill, msg.sender);
        FHE.allowThis(_currentFieldInventoryBCF);
        emit InventoryInjected(msg.sender);
    }

    function recordWithdrawal(
        externalEuint64 encVolumeBCF, bytes calldata volProof
    ) external nonReentrant {
        CustomerInventory storage inv = inventories[msg.sender];
        euint64 volume = FHE.fromExternal(encVolumeBCF, volProof);
        euint64 actualWithdrawal = FHE.select(FHE.ge(inv.currentInventoryBCF, volume),
            volume, inv.currentInventoryBCF);
        inv.currentInventoryBCF = FHE.sub(inv.currentInventoryBCF, actualWithdrawal);
        inv.withdrawnThisMonth = FHE.add(inv.withdrawnThisMonth, actualWithdrawal);
        _currentFieldInventoryBCF = FHE.sub(_currentFieldInventoryBCF, actualWithdrawal);
        euint64 wdlFee = FHE.mul(actualWithdrawal, storagePool.commodityWithdrawalCharge);
        inv.monthlyUsageBill = FHE.add(inv.monthlyUsageBill, wdlFee);
        FHE.allowThis(inv.currentInventoryBCF); FHE.allow(inv.currentInventoryBCF, msg.sender);
        FHE.allowThis(inv.withdrawnThisMonth); FHE.allow(inv.withdrawnThisMonth, msg.sender);
        FHE.allowThis(inv.monthlyUsageBill); FHE.allow(inv.monthlyUsageBill, msg.sender);
        FHE.allowThis(_currentFieldInventoryBCF);
        emit InventoryWithdrawn(msg.sender);
    }

    function processMonthlyBilling(address customer) external onlyOwner {
        CustomerInventory storage inv = inventories[customer];
        euint64 totalBill = FHE.add(inv.monthlyReservationBill, inv.monthlyUsageBill);
        _totalReservationRevenue = FHE.add(_totalReservationRevenue, inv.monthlyReservationBill);
        _totalCommodityRevenue = FHE.add(_totalCommodityRevenue, inv.monthlyUsageBill);
        inv.injectedThisMonth = FHE.asEuint64(0);
        inv.withdrawnThisMonth = FHE.asEuint64(0);
        inv.monthlyUsageBill = FHE.asEuint64(0);
        FHE.allowThis(_totalReservationRevenue);
        FHE.allowThis(_totalCommodityRevenue);
        FHE.allowThis(inv.injectedThisMonth);
        FHE.allowThis(inv.withdrawnThisMonth);
        FHE.allowThis(inv.monthlyUsageBill);
        FHE.allowTransient(totalBill, customer);
        emit BillingProcessed(customer);
    }

    function allowStorageStats(address viewer) external onlyOwner {
        FHE.allow(storagePool.totalWorkingGasBCF, viewer);
        FHE.allow(storagePool.availableWorkingGasBCF, viewer);
        FHE.allow(_totalReservationRevenue, viewer);
        FHE.allow(_totalCommodityRevenue, viewer);
        FHE.allow(_currentFieldInventoryBCF, viewer);
    }
}
