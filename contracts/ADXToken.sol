pragma solidity ^0.4.11;

// QUESTIONS FOR AUDITORS:
// - Considering we inherit from VestedToken, how much does that hit at our gas price?
// - Ensure max supply is 100,000,000
// - Ensure that even if not totalSupply is sold, tokens would still be transferrable after (we will up to totalSupply by creating adEx tokens)

// Instead of minting/minting period, implement the following changes
// #1) ADX contract knows his owner (AdExContrib) - minter
// #2) ADX contract allows transfer() when "from" is owner (AdExContrib), even if non transferrable period
// #3) non transferrable period only affected by now > end
// #4) all tokens 100,000,000 created at constructor of token sale, with owner being AdExContrib

// vesting: 365 days, 365 days / 4 vesting

import "../zeppelin-solidity/contracts/SafeMath.sol";
import "../zeppelin-solidity/contracts/token/VestedToken.sol";

contract ADXToken is VestedToken {
  //FIELDS
  string public name = "AdEx";
  string public symbol = "ADX";
  uint public decimals = 4;

  //CONSTANTS
  //Time limits
  uint public constant STAGE_ONE_TIME_END = 24 hours; // first day bonus
  uint public constant STAGE_TWO_TIME_END = 1 weeks; // first week bonus
  uint public constant STAGE_THREE_TIME_END = 4 weeks;
  
  // Multiplier for the decimals
  uint private constant DECIMALS = 10000;

  //Prices of ADX
  uint public constant PRICE_STANDARD    = 900*DECIMALS; // ADX received per one ETH; MAX_SUPPLY / (valuation / ethPrice)
  uint public constant PRICE_STAGE_ONE   = PRICE_STANDARD * 100/130;
  uint public constant PRICE_STAGE_TWO   = PRICE_STANDARD * 100/115;
  uint public constant PRICE_STAGE_THREE = PRICE_STANDARD;
  uint public constant PRICE_PREBUY      = PRICE_STANDARD * 100/120; // 20% bonus will be given from illiquid tokens-

  //ADX Token Limits
  uint public constant ALLOC_TEAM =         16000000*DECIMALS; // team + advisors
  uint public constant ALLOC_BOUNTIES =      2000000*DECIMALS;
  uint public constant ALLOC_WINGS =         2000000*DECIMALS;
  uint public constant ALLOC_CROWDSALE =    80000000*DECIMALS;
  uint public constant PREBUY_PORTION_MAX = 32 * DECIMALS * PRICE_PREBUY;
  
  //ASSIGNED IN INITIALIZATION
  //Start and end times
  uint public publicStartTime; // Time in seconds public crowd fund starts.
  uint public privateStartTime; // Time in seconds when pre-buy can purchase up to 31250 ETH worth of ADX;
  uint public publicEndTime; // Time in seconds crowdsale ends
  
  //Special Addresses
  address public prebuyAddress; // Address used by pre-buy
  address public multisigAddress; // Address to which all ether flows.
  address public adexAddress; // Address to which ALLOC_TEAM, ALLOC_BOUNTIES, ALLOC_WINGS is (ultimately) sent to.
  address public ownerAddress; // Address of the contract owner. Can halt the crowdsale.

  //Running totals
  uint public etherRaised; // Total Ether raised.
  uint public ADXSold; // Total ADX created
  uint public prebuyPortionTotal; // Total of Tokens purchased by pre-buy. Not to exceed PREBUY_PORTION_MAX.
  
  //booleans
  bool public halted; // halts the crowd sale if true.

  // MODIFIERS
  //Is currently in the period after the private start time and before the public start time.
  modifier is_pre_crowdfund_period() {
    if (now >= publicStartTime || now < privateStartTime) throw;
    _;
  }

  //Is currently the crowdfund period
  modifier is_crowdfund_period() {
    if (now < publicStartTime || now >= publicEndTime) throw;
    _;
  }

  // Is completed
  modifier is_crowdfund_completed() {
    if (now < publicEndTime && ADXSold < ALLOC_CROWDSALE) throw;
    _;
  }

  //May only be called by pre-buy
  modifier only_prebuy() {
    if (msg.sender != prebuyAddress) throw;
    _;
  }

  //May only be called by the owner address
  modifier only_owner() {
    if (msg.sender != ownerAddress) throw;
    _;
  }

  //May only be called if the crowdfund has not been halted
  modifier is_not_halted() {
    if (halted) throw;
    _;
  }

  // EVENTS
  event PreBuy(uint _amount);
  event Buy(address indexed _recipient, uint _amount);

  // Initialization contract assigns address of crowdfund contract and end time.
  function ADXToken(
    address _prebuy,
    address _multisig,
    address _adex,
    uint _publicStartTime,
    uint _privateStartTime
  ) {
    ownerAddress = msg.sender;
    publicStartTime = _publicStartTime;
    privateStartTime = _privateStartTime;
    publicEndTime = _publicStartTime + 4 weeks;
    prebuyAddress = _prebuy;
    multisigAddress = _multisig;
    adexAddress = _adex;

    balances[adexAddress] += ALLOC_BOUNTIES;
    balances[adexAddress] += ALLOC_WINGS;

    balances[ownerAddress] += ALLOC_TEAM;

    balances[ownerAddress] += ALLOC_CROWDSALE;
  }

  // Transfer amount of tokens from sender account to recipient.
  // Only callable after the crowd fund is completed
  function transfer(address _to, uint _value)
    is_crowdfund_completed
  {
    super.transfer(_to, _value);
  }

  // Transfer amount of tokens from a specified address to a recipient.
  // Transfer amount of tokens from sender account to recipient.
  function transferFrom(address _from, address _to, uint _value)
    is_crowdfund_completed
  {
    super.transferFrom(_from, _to, _value);
  }

  //constant function returns the current ADX price.
  function getPriceRate()
      constant
      returns (uint o_rate)
  {
      uint delta = SafeMath.sub(now, publicStartTime);

      if (delta > STAGE_TWO_TIME_END) return PRICE_STAGE_THREE;
      if (delta > STAGE_ONE_TIME_END) return PRICE_STAGE_TWO;

      return (PRICE_STAGE_ONE);
  }
  
  // Given the rate of a purchase and the remaining tokens in this tranche, it
  // will throw if the sale would take it past the limit of the tranche.
  // Returns `amount` in scope as the number of ADX tokens that it will purchase.
  function processPurchase(uint _rate, uint _remaining)
    internal
    returns (uint o_amount)
  {
    o_amount = SafeMath.div(SafeMath.mul(msg.value, _rate), 1 ether);

    if (o_amount > _remaining) throw;
    if (!multisigAddress.send(msg.value)) throw;

    balances[ownerAddress] = balances[ownerAddress].sub(o_amount);
    balances[msg.sender] = balances[msg.sender].add(o_amount);

    ADXSold += o_amount;
    etherRaised += msg.value;
  }

  //Special Function can only be called by pre-buy and only during the pre-crowdsale period.
  //Allows the purchase of up to 125000 Ether worth of ADX Tokens.
  function preBuy()
    payable
    is_pre_crowdfund_period
    only_prebuy
    is_not_halted
  {
    uint amount = processPurchase(PRICE_PREBUY, SafeMath.sub(PREBUY_PORTION_MAX, prebuyPortionTotal));
    prebuyPortionTotal += amount;
    PreBuy(amount);
  }

  //Default function called by sending Ether to this address with no arguments.
  //Results in creation of new ADX Tokens if transaction would not exceed hard limit of ADX Token.
  function()
    payable
    is_crowdfund_period
    is_not_halted
  {
    uint amount = processPurchase(getPriceRate(), SafeMath.sub(ALLOC_CROWDSALE, ADXSold));
    Buy(msg.sender, amount);
  }

  // To be called at the end of crowdfund period
  function grantVested()
    is_crowdfund_completed
    only_owner
    is_not_halted
  {
    // Grant tokens allocated for the team
    grantVestedTokens(
      adexAddress, ALLOC_TEAM,
      uint64(now), uint64(now) + ( 3 * 30 days ), uint64(now) + ( 12 * 30 days ), 
      false, false
    );
  }

  //May be used by owner of contract to halt crowdsale and no longer except ether.
  function toggleHalt(bool _halted)
    only_owner
  {
    halted = _halted;
  }

  //failsafe drain
  function drain()
    only_owner
  {
    if (!ownerAddress.send(this.balance)) throw;
  }
}