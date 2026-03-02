// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title FluffyMemory
/// @notice Layered recall ledger for sharded attestation and cross-node memory indexing.

contract FluffyMemory {

    // -------------------------------------------------------------------------
    // EVENTS
    // -------------------------------------------------------------------------

    event SlotStored(bytes32 indexed slotId, bytes32 contentHash, address indexed owner, bytes32 indexed category, uint256 atBlock);
    event SlotSealed(bytes32 indexed slotId, address indexed by, uint256 atBlock);
    event ChunkIndexed(bytes32 indexed slotId, uint256 shardIndex, address indexed node, uint256 atBlock);
    event CategoryTagged(bytes32 indexed slotId, bytes32 oldTag, bytes32 newTag, uint256 atBlock);
    event ReplicaAttested(bytes32 indexed slotId, address indexed node, uint256 replicaCount, uint256 atBlock);
    event GuardianRotated(address indexed previous, address indexed next, uint256 atBlock);
    event ArchivistSet(address indexed previous, address indexed next, uint256 atBlock);
    event NodeRegistered(address indexed node, uint256 nodeIndex, uint256 atBlock);
    event SlotPurged(bytes32 indexed slotId, address indexed by, uint256 atBlock);
    event BatchStored(uint256 count, address indexed by, uint256 atBlock);
    event MaxSlotsPerOwnerUpdated(uint256 previous, uint256 next, uint256 atBlock);
    event NamespacePaused(bytes32 indexed namespaceId, bool paused, uint256 atBlock);

    // -------------------------------------------------------------------------
    // ERRORS
    // -------------------------------------------------------------------------

    error FM_ZeroSlot();
    error FM_ZeroHash();
    error FM_ZeroAddress();
    error FM_NotGuardian();
    error FM_NotArchivist();
    error FM_NotNode();
    error FM_SlotNotFound();
    error FM_AlreadySealed();
    error FM_NotSealed();
    error FM_NotOwner();
    error FM_ReentrantCall();
    error FM_MaxSlotsReached();
    error FM_MaxSlotsPerOwnerReached();
    error FM_NamespacePaused();
    error FM_InvalidShardIndex();
    error FM_InvalidBatchLength();
    error FM_DuplicateSlot();
    error FM_NodeNotRegistered();

    // -------------------------------------------------------------------------
    // CONSTANTS
    // -------------------------------------------------------------------------

    uint256 public constant FM_MAX_SLOTS = 500_000;
    uint256 public constant FM_MAX_SLOTS_PER_OWNER = 10_000;
    uint256 public constant FM_MAX_NODES = 128;
    uint256 public constant FM_MAX_BATCH = 64;
    uint256 public constant FM_MAX_SHARDS_PER_SLOT = 32;
    bytes32 public constant FM_NAMESPACE = keccak256("FluffyMemory.FM_NAMESPACE");
    bytes32 public constant FM_VERSION = keccak256("fluffy-memory.v1");

    // -------------------------------------------------------------------------
    // IMMUTABLES
    // -------------------------------------------------------------------------

    address public immutable guardian;
    address public immutable archivist;
