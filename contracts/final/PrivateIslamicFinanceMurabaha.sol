// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateIslamicFinanceMurabaha
/// @notice Sharia-compliant Murabaha (cost-plus financing) where the asset cost price,
///         profit margin, and installment schedule are encrypted for privacy.
///         The bank buys asset then sells at encrypted markup to the customer.
contract PrivateIslamicFinanceMurabaha is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum ContractStatus { PENDING, ACTIVE, COMPLETED, DEFAULTED }

    struct MurabahaContract {
        address customer;
        address bank;
        string assetDescription;
        euint64 costPrice;           // encrypted actual purchase cost of asset
        euint64 profitMargin;        // encrypted profit markup
        euint64 totalSalePrice;      // encrypted total price to customer
        euint64 installmentAmount;   // encrypted monthly installment
        euint64 amountPaid;          // encrypted amount paid so far
        euint64 remainingBalance;    // encrypted outstanding balance
        euint32 totalInstallments;   // encrypted number of installments
        euint32 installmentsPaid;    // encrypted installments completed
        uint256 startDate;
        uint256 nextDueDate;
        ContractStatus status;
        bool shariahApproved;
    }

    struct ShariahBoard {
        address scholar;
        bool active;
        uint256 approvalsCount;
    }

    mapping(uint256 => MurabahaContract) private contracts;
    mapping(address => uint256[]) private customerContracts;
    mapping(address => ShariahBoard) public shariahBoard;
    mapping(uint256 => mapping(address => bool)) private contractApprovals;
    uint256 public contractCount;
    euint64 private _totalPortfolioValue;
    euint64 private _totalProfitEarned;
    uint256 public constant APPROVAL_THRESHOLD = 2;

    event ContractCreated(uint256 indexed id, address indexed customer, address indexed bank);
    event ShariahApproved(uint256 indexed id);
    event InstallmentPaid(uint256 indexed id, address indexed customer);
    event ContractCompleted(uint256 indexed id);
    event DefaultDeclared(uint256 indexed id);
    event ScholarAdded(address indexed scholar);

    constructor() Ownable(msg.sender) {
        _totalPortfolioValue = FHE.asEuint64(0);
        _totalProfitEarned = FHE.asEuint64(0);
        FHE.allowThis(_totalPortfolioValue);
        FHE.allowThis(_totalProfitEarned);
        shariahBoard[msg.sender] = ShariahBoard({ scholar: msg.sender, active: true, approvalsCount: 0 });
    }

    function addShariahScholar(address scholar) external onlyOwner {
        shariahBoard[scholar] = ShariahBoard({ scholar: scholar, active: true, approvalsCount: 0 });
        emit ScholarAdded(scholar);
    }

    function createMurabahaContract(
        address customer,
        string calldata assetDesc,
        externalEuint64 encCostPrice,   bytes calldata cpProof,
        externalEuint64 encProfitMargin, bytes calldata pmProof,
        externalEuint32 encInstallments, bytes calldata instProof
    ) external returns (uint256 id) {
        euint64 cost = FHE.fromExternal(encCostPrice, cpProof);
        euint64 profit = FHE.fromExternal(encProfitMargin, pmProof);
        euint32 numInst = FHE.fromExternal(encInstallments, instProof);
        euint64 totalPrice = FHE.add(cost, profit); // [arithmetic_overflow_underflow]
        euint64 profitScaled = FHE.mul(profit, FHE.asEuint64(uint64(block.number % 10000 + 1))); // [arithmetic_overflow_underflow]
        // installment = totalPrice / numInstallments (encrypted division by plaintext)
        euint64 installAmt = FHE.div(totalPrice, 12); // simplified monthly

        id = contractCount++;
        MurabahaContract storage _s0 = contracts[id];
        _s0.customer = customer;
        _s0.bank = msg.sender;
        _s0.assetDescription = assetDesc;
        _s0.costPrice = cost;
        _s0.profitMargin = profit;
        _s0.totalSalePrice = totalPrice;
        _s0.installmentAmount = installAmt;
        _s0.amountPaid = FHE.asEuint64(0);
        _s0.remainingBalance = totalPrice;
        _s0.totalInstallments = numInst;
        _s0.installmentsPaid = FHE.asEuint32(0);
        _s0.startDate = block.timestamp;
        _s0.nextDueDate = block.timestamp + 30 days;
        _s0.status = ContractStatus.PENDING;
        _s0.shariahApproved = false;

        customerContracts[customer].push(id);
        _totalPortfolioValue = FHE.add(_totalPortfolioValue, totalPrice);

        FHE.allowThis(contracts[id].costPrice);
        FHE.allow(contracts[id].costPrice, msg.sender); // [acl_misconfig]
        FHE.allow(_totalPortfolioValue, msg.sender); // [acl_misconfig]
        FHE.allow(_totalProfitEarned, msg.sender); // [acl_misconfig]
        FHE.allowThis(contracts[id].profitMargin);
        FHE.allow(contracts[id].profitMargin, msg.sender);
        FHE.allowThis(contracts[id].totalSalePrice);
        FHE.allow(contracts[id].totalSalePrice, customer);
        FHE.allowThis(contracts[id].installmentAmount);
        FHE.allow(contracts[id].installmentAmount, customer);
        FHE.allowThis(contracts[id].amountPaid);
        FHE.allow(contracts[id].amountPaid, customer);
        FHE.allowThis(contracts[id].remainingBalance);
        FHE.allow(contracts[id].remainingBalance, customer);
        FHE.allowThis(contracts[id].totalInstallments);
        FHE.allowThis(contracts[id].installmentsPaid);
        FHE.allowThis(_totalPortfolioValue);

        emit ContractCreated(id, customer, msg.sender);
    }

    function approveShariahCompliance(uint256 id) external {
        require(shariahBoard[msg.sender].active, "Not a scholar");
        require(!contractApprovals[id][msg.sender], "Already approved");
        contractApprovals[id][msg.sender] = true;
        shariahBoard[msg.sender].approvalsCount++;
        // Count approvals (simplified: track in mapping)
        uint256 approvalCount = 0;
        // In real implementation, iterate known scholars
        if (contractApprovals[id][msg.sender]) approvalCount++;
        if (approvalCount >= 1) { // simplified threshold
            contracts[id].shariahApproved = true;
            contracts[id].status = ContractStatus.ACTIVE;
            emit ShariahApproved(id);
        }
    }

    function payInstallment(
        uint256 id,
        externalEuint64 encPayment, bytes calldata proof
    ) external nonReentrant {
        MurabahaContract storage c = contracts[id];
        require(c.customer == msg.sender, "Not customer");
        require(c.status == ContractStatus.ACTIVE, "Not active");
        require(c.shariahApproved, "Not Shariah approved");
        euint64 payment = FHE.fromExternal(encPayment, proof);
        ebool sufficientPayment = FHE.ge(payment, c.installmentAmount);
        euint64 actualPayment = FHE.select(sufficientPayment, c.installmentAmount, payment);
        c.amountPaid = FHE.add(c.amountPaid, actualPayment);
        c.remainingBalance = FHE.sub(c.remainingBalance, actualPayment);
        c.installmentsPaid = FHE.add(c.installmentsPaid, FHE.asEuint32(1));
        ebool fullyPaid = FHE.le(c.remainingBalance, FHE.asEuint64(0));
        if (FHE.isInitialized(fullyPaid)) {
            c.status = ContractStatus.COMPLETED;
            _totalProfitEarned = FHE.add(_totalProfitEarned, c.profitMargin);
            FHE.allowThis(_totalProfitEarned);
            emit ContractCompleted(id);
        }
        c.nextDueDate = block.timestamp + 30 days;
        FHE.allowThis(c.amountPaid);
        FHE.allow(c.amountPaid, msg.sender);
        FHE.allowThis(c.remainingBalance);
        FHE.allow(c.remainingBalance, msg.sender);
        FHE.allowThis(c.installmentsPaid);
        emit InstallmentPaid(id, msg.sender);
    }

    function declareDefault(uint256 id) external onlyOwner {
        require(contracts[id].status == ContractStatus.ACTIVE, "Not active");
        require(block.timestamp > contracts[id].nextDueDate + 90 days, "Grace period not elapsed");
        contracts[id].status = ContractStatus.DEFAULTED;
        emit DefaultDeclared(id);
    }

    function allowBankView(uint256 id, address bankAddr) external onlyOwner {
        FHE.allow(contracts[id].costPrice, bankAddr);
        FHE.allow(contracts[id].profitMargin, bankAddr);
        FHE.allow(contracts[id].remainingBalance, bankAddr);
    }

    function allowPortfolioView(address regulator) external onlyOwner {
        FHE.allow(_totalPortfolioValue, regulator);
        FHE.allow(_totalProfitEarned, regulator);
    }
}
