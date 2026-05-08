// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity ^0.8.24;

import "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PrivateRealEstateDebtFund
/// @notice Real estate private debt fund: encrypted LTV ratios, encrypted interest coverage,
///         encrypted loan origination fees, and confidential borrower underwriting scores.
contract PrivateRealEstateDebtFund is ZamaEthereumConfig, Ownable, ReentrancyGuard {
    enum PropertyType { MULTIFAMILY, OFFICE, RETAIL, INDUSTRIAL, HOTEL, MIXED_USE, LAND }
    enum LoanStatus { ORIGINATED, PERFORMING, WATCH_LIST, DEFAULTED, REPAID }

    struct RealEstateLoan {
        string loanId;
        address borrower;
        PropertyType propertyType;
        euint64 loanAmountUSD;        // encrypted loan amount
        euint64 propertyValueUSD;     // encrypted property value
        euint64 ltvRatioBps;          // encrypted LTV ratio
        euint64 interestRateBps;      // encrypted interest rate
        euint64 originationFeeBps;    // encrypted origination fee
        euint64 dscr;                 // encrypted debt service coverage ratio scaled 100
        euint64 borrowerCreditScore;  // encrypted borrower credit score
        euint64 accrualBalance;       // encrypted accrued interest
        LoanStatus status;
        uint256 originationDate;
        uint256 maturityDate;
    }

    struct FundMetrics {
        euint64 totalDeployedUSD;     // encrypted total deployed
        euint64 totalCommittedUSD;    // encrypted total committed
        euint64 weightedAvgRate;      // encrypted WAR
        euint64 weightedAvgLTV;       // encrypted WAL TV
        euint64 netInterestIncome;    // encrypted NII
        euint64 lossProvision;        // encrypted loan loss provision
    }

    struct Investor {
        euint64 commitment;          // encrypted investor commitment
        euint64 drawnCapital;        // encrypted drawn amount
        euint64 distributionReceived;// encrypted distributions
        euint64 unrealizedGain;      // encrypted unrealized gain
        uint256 investmentDate;
        bool active;
    }

    mapping(uint256 => RealEstateLoan) private loans;
    mapping(address => Investor) private investors;
    FundMetrics private fundMetrics;
    uint256 public loanCount;
    mapping(address => bool) public isLoanOfficer;
    mapping(address => bool) public isFundManager;
    euint64 private _totalFundNAV;

    event LoanOriginated(uint256 indexed id, string loanId, address borrower, PropertyType ptype);
    event LoanStatusChanged(uint256 indexed id, LoanStatus status);
    event InterestAccrued(uint256 indexed loanId);
    event DistributionPaid(address indexed investor);
    event InvestorCommitted(address indexed investor);

    constructor(
        externalEuint64 encInitialNAV, bytes calldata proof
    ) Ownable(msg.sender) {
        _totalFundNAV = FHE.fromExternal(encInitialNAV, proof);
        fundMetrics = FundMetrics({
            totalDeployedUSD: FHE.asEuint64(0), totalCommittedUSD: FHE.asEuint64(0),
            weightedAvgRate: FHE.asEuint64(0), weightedAvgLTV: FHE.asEuint64(0),
            netInterestIncome: FHE.asEuint64(0), lossProvision: FHE.asEuint64(0)
        });
        FHE.allowThis(_totalFundNAV);
        FHE.allowThis(fundMetrics.totalDeployedUSD);
        FHE.allowThis(fundMetrics.totalCommittedUSD);
        FHE.allowThis(fundMetrics.netInterestIncome);
        FHE.allowThis(fundMetrics.lossProvision);
        isLoanOfficer[msg.sender] = true;
        isFundManager[msg.sender] = true;
    }

    function addOfficer(address o) external onlyOwner { isLoanOfficer[o] = true; }
    function addManager(address m) external onlyOwner { isFundManager[m] = true; }

    function originateLoan(
        string calldata loanId, address borrower, PropertyType ptype,
        externalEuint64 encLoan, bytes calldata lProof,
        externalEuint64 encValue, bytes calldata vProof,
        externalEuint64 encRate, bytes calldata rProof,
        externalEuint64 encFee, bytes calldata fProof,
        externalEuint64 encDSCR, bytes calldata dscrProof,
        externalEuint64 encCredit, bytes calldata crProof,
        uint256 maturity
    ) external returns (uint256 id) {
        require(isLoanOfficer[msg.sender], "Not officer");
        euint64 loanAmt = FHE.fromExternal(encLoan, lProof);
        euint64 propValue = FHE.fromExternal(encValue, vProof);
        euint64 rate = FHE.fromExternal(encRate, rProof);
        euint64 fee = FHE.fromExternal(encFee, fProof);
        euint64 dscr = FHE.fromExternal(encDSCR, dscrProof);
        euint64 credit = FHE.fromExternal(encCredit, crProof);
        euint64 ltv = FHE.div(FHE.mul(loanAmt, FHE.asEuint64(10000)), propValue);
        id = loanCount++;
        loans[id] = RealEstateLoan({
            loanId: loanId, borrower: borrower, propertyType: ptype,
            loanAmountUSD: loanAmt, propertyValueUSD: propValue, ltvRatioBps: ltv,
            interestRateBps: rate, originationFeeBps: fee, dscr: dscr,
            borrowerCreditScore: credit, accrualBalance: FHE.asEuint64(0),
            status: LoanStatus.ORIGINATED, originationDate: block.timestamp, maturityDate: maturity
        });
        fundMetrics.totalDeployedUSD = FHE.add(fundMetrics.totalDeployedUSD, loanAmt);
        FHE.allowThis(loans[id].loanAmountUSD);
        FHE.allowThis(loans[id].propertyValueUSD);
        FHE.allowThis(loans[id].ltvRatioBps);
        FHE.allowThis(loans[id].interestRateBps);
        FHE.allowThis(loans[id].dscr);
        FHE.allowThis(loans[id].borrowerCreditScore);
        FHE.allowThis(loans[id].accrualBalance);
        FHE.allow(loans[id].ltvRatioBps, borrower);
        FHE.allow(loans[id].loanAmountUSD, borrower);
        FHE.allowThis(fundMetrics.totalDeployedUSD);
        emit LoanOriginated(id, loanId, borrower, ptype);
    }

    function accrueInterest(uint256 loanId) external {
        require(isFundManager[msg.sender], "Not manager");
        RealEstateLoan storage loan = loans[loanId];
        require(loan.status == LoanStatus.PERFORMING, "Not performing");
        euint64 monthlyInterest = FHE.div(FHE.mul(loan.loanAmountUSD, loan.interestRateBps), 120000);
        loan.accrualBalance = FHE.add(loan.accrualBalance, monthlyInterest);
        fundMetrics.netInterestIncome = FHE.add(fundMetrics.netInterestIncome, monthlyInterest);
        FHE.allowThis(loan.accrualBalance);
        FHE.allow(loan.accrualBalance, loan.borrower);
        FHE.allowThis(fundMetrics.netInterestIncome);
        emit InterestAccrued(loanId);
    }

    function changeLoanStatus(uint256 loanId, LoanStatus newStatus) external {
        require(isLoanOfficer[msg.sender], "Not officer");
        RealEstateLoan storage loan = loans[loanId];
        loan.status = newStatus;
        if (newStatus == LoanStatus.DEFAULTED) {
            euint64 provision = FHE.div(loan.loanAmountUSD, FHE.asEuint64(2));
            fundMetrics.lossProvision = FHE.add(fundMetrics.lossProvision, provision);
            FHE.allowThis(fundMetrics.lossProvision);
        }
        emit LoanStatusChanged(loanId, newStatus);
    }

    function commitInvestor(
        address investor,
        externalEuint64 encCommitment, bytes calldata proof
    ) external {
        require(isFundManager[msg.sender], "Not manager");
        euint64 commitment = FHE.fromExternal(encCommitment, proof);
        investors[investor] = Investor({
            commitment: commitment, drawnCapital: FHE.asEuint64(0),
            distributionReceived: FHE.asEuint64(0), unrealizedGain: FHE.asEuint64(0),
            investmentDate: block.timestamp, active: true
        });
        fundMetrics.totalCommittedUSD = FHE.add(fundMetrics.totalCommittedUSD, commitment);
        FHE.allowThis(investors[investor].commitment);
        FHE.allowThis(investors[investor].drawnCapital);
        FHE.allowThis(investors[investor].distributionReceived);
        FHE.allow(investors[investor].commitment, investor);
        FHE.allowThis(fundMetrics.totalCommittedUSD);
        emit InvestorCommitted(investor);
    }

    function distributeToInvestor(
        address investor,
        externalEuint64 encAmount, bytes calldata proof
    ) external nonReentrant {
        require(isFundManager[msg.sender], "Not manager");
        euint64 amount = FHE.fromExternal(encAmount, proof);
        investors[investor].distributionReceived = FHE.add(investors[investor].distributionReceived, amount);
        _totalFundNAV = FHE.sub(_totalFundNAV, amount);
        FHE.allowThis(investors[investor].distributionReceived);
        FHE.allow(investors[investor].distributionReceived, investor);
        FHE.allow(amount, investor);
        FHE.allowThis(_totalFundNAV);
        emit DistributionPaid(investor);
    }

    function updateFundNAV(externalEuint64 encNAV, bytes calldata proof) external {
        require(isFundManager[msg.sender], "Not manager");
        _totalFundNAV = FHE.fromExternal(encNAV, proof);
        FHE.allowThis(_totalFundNAV);
        FHE.allow(_totalFundNAV, owner());
    }
}
