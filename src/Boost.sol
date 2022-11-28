// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "openzeppelin-contracts/access/Ownable.sol";
import "openzeppelin-contracts/utils/cryptography/SignatureChecker.sol";
import "openzeppelin-contracts/utils/cryptography/draft-EIP712.sol";

import "./IBoost.sol";

contract Boost is IBoost, EIP712("boost", "1"), Ownable {
    bytes32 public immutable eip712ClaimStructHash =
        keccak256("Claim(uint256 boostId,address recipient,uint256 amount)");

    uint256 public nextBoostId = 1;
    mapping(uint256 => BoostConfig) public boosts;
    mapping(address => mapping(uint256 => bool)) public claimed;

    // Constant eth fee (in gwei) that is the same for all boost creators.
    uint256 public ethFee;
    // The fraction of the total boost deposit that is taken as a fee.
    // represented as an integer denominator (1/x)%
    uint256 public tokenFee;

    constructor(address _protocolOwner, uint256 _ethFee, uint256 _tokenFee) {
        setEthFee(_ethFee);
        setTokenFee(_tokenFee);
        transferOwnership(_protocolOwner);
    }

    function setEthFee(uint256 _ethFee) public override onlyOwner {
        ethFee = _ethFee;
        emit EthFeeSet(_ethFee);
    }

    function setTokenFee(uint256 _tokenFee) public override onlyOwner {
        tokenFee = _tokenFee;
        emit TokenFeeSet(_tokenFee);
    }

    function collectEthFees() external onlyOwner {
        payable(msg.sender).transfer(address(this).balance);
    }

    /// @notice Create a new boost and transfer tokens to it
    function createBoost(
        string calldata _strategyURI,
        IERC20 _token,
        uint256 _amount,
        address _guard,
        uint256 _start,
        uint256 _end,
        address _owner
    ) external payable override {
        if (_amount == 0) revert BoostDepositRequired();
        if (_end <= block.timestamp) revert BoostEndDateInPast();
        if (_start >= _end) revert BoostEndDateBeforeStart();
        if (_guard == address(0)) revert InvalidGuard();
        if (msg.value < ethFee) revert InsufficientEthFee();

        uint256 balance = 0;
        if (tokenFee > 0) {
            uint256 tokenFeeAmount = _amount / tokenFee;
            balance = _amount - tokenFeeAmount;
            _token.transferFrom(msg.sender, owner(), tokenFeeAmount);
        } else {
            balance = _amount;
        }

        uint256 newId = nextBoostId;
        nextBoostId++;
        boosts[newId] = BoostConfig({
            strategyURI: _strategyURI,
            token: _token,
            balance: balance,
            guard: _guard,
            start: _start,
            end: _end,
            owner: _owner
        });

        _token.transferFrom(msg.sender, address(this), balance);

        emit BoostCreated(newId, boosts[newId]);
    }

    /// @notice Top up an existing boost
    function depositTokens(uint256 _boostId, uint256 _amount) external override {
        if (_amount == 0) revert BoostDepositRequired();
        if (boosts[_boostId].owner == address(0)) revert BoostDoesNotExist();
        if (boosts[_boostId].end <= block.timestamp) revert BoostEnded();

        uint256 balanceIncrease = 0;
        if (tokenFee > 0) {
            uint256 tokenFeeAmount = _amount / tokenFee;
            balanceIncrease = _amount - tokenFeeAmount;
            boosts[_boostId].token.transferFrom(msg.sender, owner(), tokenFeeAmount);
        } else {
            balanceIncrease = _amount;
        }

        boosts[_boostId].balance += balanceIncrease;
        boosts[_boostId].token.transferFrom(msg.sender, address(this), balanceIncrease);

        emit TokensDeposited(_boostId, msg.sender, balanceIncrease);
    }

    /// @notice Withdraw remaining tokens from an expired boost
    function withdrawRemainingTokens(uint256 _boostId, address _to) external override {
        if (boosts[_boostId].balance == 0) revert InsufficientBoostBalance();
        if (boosts[_boostId].end > block.timestamp) revert BoostNotEnded(boosts[_boostId].end);
        if (boosts[_boostId].owner != msg.sender) revert OnlyBoostOwner();
        if (_to == address(0)) revert InvalidRecipient();

        uint256 amount = boosts[_boostId].balance;
        boosts[_boostId].balance = 0;

        boosts[_boostId].token.transfer(_to, amount);

        emit RemainingTokensWithdrawn(_boostId, amount);
    }

    /// @notice Claim using a guard signature
    function claimTokens(Claim calldata _claim, bytes calldata _signature) external override {
        if (boosts[_claim.boostId].start > block.timestamp) revert BoostNotStarted(boosts[_claim.boostId].start);
        if (boosts[_claim.boostId].balance < _claim.amount) revert InsufficientBoostBalance();
        if (boosts[_claim.boostId].end <= block.timestamp) revert BoostEnded();
        if (claimed[_claim.recipient][_claim.boostId]) revert RecipientAlreadyClaimed();
        if (_claim.recipient == address(0)) revert InvalidRecipient();

        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(eip712ClaimStructHash, _claim.boostId, _claim.recipient, _claim.amount))
        );

        if (!SignatureChecker.isValidSignatureNow(boosts[_claim.boostId].guard, digest, _signature))
            revert InvalidSignature();

        claimed[_claim.recipient][_claim.boostId] = true;
        boosts[_claim.boostId].balance -= _claim.amount;

        IERC20 token = IERC20(boosts[_claim.boostId].token);
        token.transfer(_claim.recipient, _claim.amount);

        emit TokensClaimed(_claim);
    }
}
