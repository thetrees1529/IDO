//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract IDO is Ownable, ReentrancyGuard {
    //Status of IDO.
    enum Status{before, inprogress, ended, closed}
    //Has liquidity been added.
    bool _liqAdded;
    //LP receiver.
    address _lpReceiver;

    //The DEX to add liquidity to.
    IUniswapV2Router02 _router;
    //The token being offered.
    IERC20 _token;
    //The collateral token.
    IERC20 _MIS;

    //How many tokens offered.
    uint _offering;
    //How much ONE asked.
    uint _asking;
    //How much collateral required to participate.
    uint _collateralRequired;

    //Token percentage to liquidity.
    uint _tptl;
    //ONE percentage to liquidity;
    uint _optl;
    //Receiver of ONE not diverted to liquidity.
    address _excessONEReceiver;
    

    //Start timestamp.
    uint _startDate;
    //End timestamp.
    uint _endDate;

    //How long tokens are distributed for after IDO ends.
    uint _vestingLength;
    //How long users have to claim once distribution ends until owner is allowed to withdraw unclaimed amounts.
    uint _timeToClaim;

    //How much ONE deposited in total.
    uint _totalDeposited;

    struct User {
        bool collateralised;
        uint deposited;
        bool withdrawn;
        uint claimed;
    }

    //Compiler doesn't like more than some dumb arbitrary number of variables in one call so a couple of things are grouped up.
    struct OfferingAsking {
        uint offering;
        uint asking;
    }
    struct Dates {
        uint startDate;
        uint endDate;
    }
    struct Percentages {
        uint tptl;
        uint optl;
    }

    constructor(IUniswapV2Router02 router, IERC20 token, address lpReceiver, IERC20 MIS, OfferingAsking memory offeringAsking, uint collateralRequired, Percentages memory percentages, address excessONEReceiver, Dates memory dates, uint vestingLength, uint timeToClaim) {
        _router = router;

        _lpReceiver = lpReceiver;

        _token = token;
        _MIS = MIS;

        _offering = offeringAsking.offering;
        _asking = offeringAsking.asking;
        _collateralRequired = collateralRequired;

        _tptl = percentages.tptl;
        _optl = percentages.optl;

        _excessONEReceiver = excessONEReceiver;

        require(!(dates.endDate < dates.startDate), "End date cannot be before the start date.");
        _startDate = dates.startDate;
        _endDate = dates.endDate;

        _vestingLength = vestingLength;
        _timeToClaim = timeToClaim;
    }

    mapping(address => User) _users;

    function status() public view returns(Status) {
        if(block.timestamp >= _endDate + _vestingLength + _timeToClaim) {
            return Status.closed;
        }
        if(block.timestamp >= _endDate) {
            return Status.ended;
        }
        if(block.timestamp >= _startDate) {
            return Status.inprogress;
        }
        return Status.before;
    }


    function claimable(address addr) public view returns(uint amount) {
        if(status() != Status.ended) {
            return 0;
        }

        User storage user = _users[addr];

        (uint tokenAmount,) = fundsToUsers(); 
        uint timeSince = block.timestamp - _endDate;
        uint timeVested = timeSince <= _vestingLength ? timeSince : _vestingLength;

        amount = (user.deposited * tokenAmount) / _totalDeposited;
        amount *= timeVested;
        amount /= _vestingLength;
        amount -= user.claimed;
    }

    function fundsUtilised() public view returns(uint tokenAmount, uint ONEAmount) {
        ONEAmount = _asking > _totalDeposited ? _asking : _totalDeposited;
        tokenAmount = (ONEAmount * _offering) / _asking;  
    }

    function fundsToLiquidity() public view returns(uint tokenAmount, uint ONEAmount) {
        (tokenAmount, ONEAmount) = fundsUtilised();
        tokenAmount *= _tptl;
        tokenAmount /= 100;
        ONEAmount *= _optl;
        ONEAmount /= 100;
    }

    function fundsToUsers() public view returns(uint tokenAmount, uint ONEAmount) {
        ONEAmount = _totalDeposited > _asking ? _totalDeposited - _asking : 0;
        (tokenAmount,) = fundsUtilised();
        uint tptu = 100 - _tptl;
        tokenAmount *= tptu;
        tokenAmount /= 100;
    }

    function depositCollateral() public nonReentrant {
        require(status() == Status.inprogress, "IDO not in progress.");

        User storage user = _users[msg.sender];

        if(user.collateralised) {
            return;
        }

        _token.transferFrom(msg.sender, address(this), _collateralRequired);

        user.collateralised = true;
    }

    function removeCollateral() public nonReentrant {
        require(status() == Status.ended, "Must wait for IDO to end.");

        User storage user = _users[msg.sender];

        require(user.collateralised);

        _token.transfer(msg.sender, _collateralRequired);

        user.collateralised = false;
    }

    function deposit() public payable nonReentrant {
        require(status() == Status.inprogress, "IDO not in progress.");

        User storage user = _users[msg.sender];

        require(user.collateralised, "Need to collateralise first.");

        user.deposited += msg.value;
        _totalDeposited += msg.value;
    }

    function claim() public payable nonReentrant {
        require(status() == Status.ended, "Not able to claim at this time.");

        uint toClaim = claimable(msg.sender);
        _token.transfer(msg.sender, toClaim);

        User storage user = _users[msg.sender];

        user.claimed -= toClaim;
    }

    function addLiquidity() public {
        require(status() == Status.ended, "Must wait for IDO to end before adding liquidity.");
        require(!_liqAdded, "Liquidity already added.");
        (uint tokenAmount, uint ONEAmount) = fundsToLiquidity();
        _router.addLiquidityETH(address(_token), tokenAmount , tokenAmount, ONEAmount, _lpReceiver, block.timestamp);
        _liqAdded = true;
    }

    function withdrawTokens(uint amount) public onlyOwner nonReentrant {
        require(status() == Status.closed);
        _token.transfer(msg.sender, amount);
    }    

    function withdrawMIS(uint amount) public onlyOwner nonReentrant {
        require(status() == Status.closed);
        _MIS.transfer(msg.sender, amount);
    } 
}