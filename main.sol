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
    address public immutable nodeA;
    address public immutable nodeB;
    address public immutable nodeC;
    uint256 public immutable deployBlock;

    // -------------------------------------------------------------------------
    // STATE
    // -------------------------------------------------------------------------

    struct MemorySlot {
        bytes32 contentHash;
        address owner;
        uint256 storedAtBlock;
        bytes32 category;
        bool sealed;
        uint256 replicaCount;
    }

    mapping(bytes32 => MemorySlot) private _slots;
    bytes32[] private _slotIds;
    uint256 public slotCount;

    mapping(address => bytes32[]) private _slotIdsByOwner;
    mapping(address => uint256) private _slotCountByOwner;

    mapping(bytes32 => bytes32[]) private _slotIdsByCategory;
    mapping(address => bool) private _nodes;
    address[] private _nodeList;
    uint256 public nodeCount;

    mapping(bytes32 => bool) private _namespacePaused;
    uint256 public maxSlotsPerOwner = 1_000;
    uint256 private _reentrancyLock;

    // -------------------------------------------------------------------------
    // CONSTRUCTOR
    // -------------------------------------------------------------------------

    constructor() {
        guardian = address(0x4F7aB2c5E8d1F3a6C9e0B4d7A1c8E2f5B9a3D6C0e);
        archivist = address(0x6C1eA9d4F7b0B3E8a2D5c9F1e4A7b0C3d6E9f2A5);
        nodeA = address(0x8E3bD6f9A2c5E0d1F4a7B9c2E5f8A1d4C7e0B3F6);
        nodeB = address(0xA1d4F7b0C3e6E9a2B5c8D1f4A7e0B3D6C9f2E5a8);
        nodeC = address(0x2B5e8A1d4F7c0E3b6D9f2A5c8E1b4D7a0C3F6e9B);
        deployBlock = block.number;
        if (guardian == address(0) || archivist == address(0)) revert FM_ZeroAddress();
        _nodes[nodeA] = true;
        _nodes[nodeB] = true;
        _nodes[nodeC] = true;
        _nodeList.push(nodeA);
        _nodeList.push(nodeB);
        _nodeList.push(nodeC);
        nodeCount = 3;
    }

    // -------------------------------------------------------------------------
    // MODIFIERS
    // -------------------------------------------------------------------------

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert FM_NotGuardian();
        _;
    }

    modifier onlyArchivist() {
        if (msg.sender != archivist) revert FM_NotArchivist();
