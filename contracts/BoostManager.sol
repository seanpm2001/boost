// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/utils/cryptography/draft-EIP712.sol";
import "./BoostAware.sol";
import "./BoostGuard.sol";

error BoostDoesNotExist();
error BoostDepositRequired();
error BoostEndDateInPast();
error BoostEndDateBeforeStart();
error BoostEnded();
error BoostNotEnded(uint256 end);
error BoostNotStarted(uint256 start);
error OnlyBoostOwner();
error OnlyBoostGuard();
error InvalidRecipient();
error InvalidGuard();
error RecipientAlreadyClaimed();
error InvalidSignature();
error InvalidWhitelistProof();
error InvalidClaim();
error InsufficientBoostBalance();

contract BoostManager is BoostAware, EIP712("boost", "0.1.0") {
  struct Claim {
    uint256 boostId;
    address recipient;
    uint256 amount;
  }

  /// @dev Used for hashing EIP712 claim messages
  bytes32 public immutable claimStructHash =
    keccak256("Claim(uint256 boostId,address recipient,uint256 amount)");

  event BoostCreated(uint256 id, Boost boost);
  event BoostClaimed(Claim claim);
  event BoostDeposited(uint256 id, address sender, uint256 amount);
  event BoostWithdrawn(uint256 id);

  uint256 public nextBoostId = 1;
  mapping(uint256 => Boost) public boosts;
  mapping(address => mapping(uint256 => bool)) public claimed;

  mapping(uint256 => bytes32) public whitelists; // merkle roots

  /// @notice Create a new boost and transfer tokens to it
  function create(Boost calldata boost) external {
    if (boost.balance == 0) revert BoostDepositRequired();
    if (boost.end <= block.timestamp) revert BoostEndDateInPast();
    if (boost.start >= boost.end) revert BoostEndDateBeforeStart();
    if (boost.guard == address(0)) revert InvalidGuard();

    uint256 newId = nextBoostId;
    nextBoostId++;
    boosts[newId] = boost;

    IERC20 token = IERC20(boost.token);
    token.transferFrom(msg.sender, address(this), boost.balance);

    emit BoostCreated(newId, boosts[newId]);
  }

  /// @notice Top up an existing boost
  function deposit(uint256 id, uint256 amount) public {
    if (amount == 0) revert BoostDepositRequired();
    if (boosts[id].owner == address(0)) revert BoostDoesNotExist();
    if (boosts[id].end <= block.timestamp) revert BoostEnded();

    boosts[id].balance += amount;

    emit BoostDeposited(id, msg.sender, amount);

    IERC20 token = IERC20(boosts[id].token);
    token.transferFrom(msg.sender, address(this), amount);
  }

  /// @notice Withdraw remaining tokens from an expired boost
  function withdraw(uint256 id, address to) external {
    if (boosts[id].balance == 0) revert InsufficientBoostBalance();
    if (boosts[id].end > block.timestamp) revert BoostNotEnded(boosts[id].end);
    if (boosts[id].owner != msg.sender) revert OnlyBoostOwner();
    if (to == address(0)) revert InvalidRecipient();

    uint256 amount = boosts[id].balance;
    boosts[id].balance = 0;

    emit BoostWithdrawn(id);

    IERC20 token = IERC20(boosts[id].token);
    token.transfer(to, amount);
  }

  modifier commonClaimChecks(Claim calldata claim) {
    if (boosts[claim.boostId].start > block.timestamp)
      revert BoostNotStarted(boosts[claim.boostId].start);
    if (boosts[claim.boostId].balance < claim.amount) revert InsufficientBoostBalance();
    if (boosts[claim.boostId].end <= block.timestamp) revert BoostEnded();
    if (claimed[claim.recipient][claim.boostId]) revert RecipientAlreadyClaimed();
    if (claim.recipient == address(0)) revert InvalidRecipient();
    _;
  }

  /// @notice Claim using a guard signature
  function claimBySignature(Claim calldata claim, bytes calldata signature)
    external
    commonClaimChecks(claim)
  {
    bytes32 digest = _hashTypedDataV4(
      keccak256(abi.encode(claimStructHash, claim.boostId, claim.recipient, claim.amount))
    );

    if (!SignatureChecker.isValidSignatureNow(boosts[claim.boostId].guard, digest, signature))
      revert InvalidSignature();

    _executeClaim(claim);
  }

  /// @notice Claim using a merkle proof
  function claimByWhitelistProof(Claim calldata claim, bytes32[] calldata proof)
    external
    commonClaimChecks(claim)
  {
    bytes32 leaf = keccak256(abi.encodePacked(claim.recipient, claim.amount));
    if (!MerkleProof.verify(proof, whitelists[claim.boostId], leaf)) {
      revert InvalidWhitelistProof();
    }

    _executeClaim(claim);
  }

  /// @notice Claim using an external guard contract
  function claimByContract(Claim calldata claim) external commonClaimChecks(claim) {
    if (
      claim.amount !=
      BoostGuard(boosts[claim.boostId].guard).getAmount(boosts[claim.boostId], claim.recipient)
    ) {
      revert InvalidClaim();
    }

    _executeClaim(claim);
  }

  /// @dev function to let guard set merkle root for boost
  function setWhitelist(uint256 id, bytes32 whitelist) external {
    if (boosts[id].guard != msg.sender) revert OnlyBoostGuard();
    if (boosts[id].end < block.timestamp) revert BoostEnded();

    whitelists[id] = whitelist;
  }

  function _executeClaim(Claim calldata claim) internal {
    claimed[claim.recipient][claim.boostId] = true;
    boosts[claim.boostId].balance -= claim.amount;

    emit BoostClaimed(claim);

    IERC20 token = IERC20(boosts[claim.boostId].token);
    token.transfer(claim.recipient, claim.amount);
  }
}
