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
        _;
    }

    modifier onlyNode() {
        if (!_nodes[msg.sender]) revert FM_NotNode();
        _;
    }

    modifier whenNotPaused(bytes32 namespaceId) {
        if (_namespacePaused[namespaceId]) revert FM_NamespacePaused();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyLock != 0) revert FM_ReentrantCall();
        _reentrancyLock = 1;
        _;
        _reentrancyLock = 0;
    }

    // -------------------------------------------------------------------------
    // CORE: STORE & SEAL
    // -------------------------------------------------------------------------

    function store(bytes32 slotId, bytes32 contentHash, bytes32 category) external nonReentrant whenNotPaused(FM_NAMESPACE) returns (bool) {
        if (slotId == bytes32(0)) revert FM_ZeroSlot();
        if (contentHash == bytes32(0)) revert FM_ZeroHash();
        if (_slots[slotId].storedAtBlock != 0) revert FM_DuplicateSlot();
        if (slotCount >= FM_MAX_SLOTS) revert FM_MaxSlotsReached();
        if (_slotCountByOwner[msg.sender] >= maxSlotsPerOwner) revert FM_MaxSlotsPerOwnerReached();

        _slots[slotId] = MemorySlot({
            contentHash: contentHash,
            owner: msg.sender,
            storedAtBlock: block.number,
            category: category,
            sealed: false,
            replicaCount: 0
        });
        _slotIds.push(slotId);
        slotCount++;
        _slotIdsByOwner[msg.sender].push(slotId);
        _slotCountByOwner[msg.sender]++;
        _slotIdsByCategory[category].push(slotId);

        emit SlotStored(slotId, contentHash, msg.sender, category, block.number);
        return true;
    }

    function seal(bytes32 slotId) external nonReentrant {
        MemorySlot storage s = _slots[slotId];
        if (s.storedAtBlock == 0) revert FM_SlotNotFound();
        if (s.owner != msg.sender && msg.sender != archivist) revert FM_NotOwner();
        if (s.sealed) revert FM_AlreadySealed();

        s.sealed = true;
        emit SlotSealed(slotId, msg.sender, block.number);
    }

    function attestReplica(bytes32 slotId) external onlyNode nonReentrant {
        MemorySlot storage s = _slots[slotId];
        if (s.storedAtBlock == 0) revert FM_SlotNotFound();
        s.replicaCount++;
        emit ReplicaAttested(slotId, msg.sender, s.replicaCount, block.number);
    }

    function indexChunk(bytes32 slotId, uint256 shardIndex) external onlyNode nonReentrant {
        if (_slots[slotId].storedAtBlock == 0) revert FM_SlotNotFound();
        if (shardIndex >= FM_MAX_SHARDS_PER_SLOT) revert FM_InvalidShardIndex();
        emit ChunkIndexed(slotId, shardIndex, msg.sender, block.number);
    }

    function updateCategory(bytes32 slotId, bytes32 newCategory) external nonReentrant {
        MemorySlot storage s = _slots[slotId];
        if (s.storedAtBlock == 0) revert FM_SlotNotFound();
        if (s.owner != msg.sender && msg.sender != archivist) revert FM_NotOwner();
        if (s.sealed) revert FM_AlreadySealed();

        bytes32 oldTag = s.category;
        s.category = newCategory;
        _slotIdsByCategory[newCategory].push(slotId);
        emit CategoryTagged(slotId, oldTag, newCategory, block.number);
    }

    // -------------------------------------------------------------------------
    // BATCH STORE
    // -------------------------------------------------------------------------

    function batchStore(bytes32[] calldata slotIds, bytes32[] calldata contentHashes, bytes32[] calldata categories) external nonReentrant whenNotPaused(FM_NAMESPACE) returns (uint256 stored) {
        if (slotIds.length != contentHashes.length || contentHashes.length != categories.length) revert FM_InvalidBatchLength();
        if (slotIds.length > FM_MAX_BATCH) revert FM_InvalidBatchLength();
        if (slotCount + slotIds.length > FM_MAX_SLOTS) revert FM_MaxSlotsReached();
        if (_slotCountByOwner[msg.sender] + slotIds.length > maxSlotsPerOwner) revert FM_MaxSlotsPerOwnerReached();

        for (uint256 i = 0; i < slotIds.length; i++) {
            if (slotIds[i] == bytes32(0) || contentHashes[i] == bytes32(0)) continue;
            if (_slots[slotIds[i]].storedAtBlock != 0) continue;

            _slots[slotIds[i]] = MemorySlot({
                contentHash: contentHashes[i],
                owner: msg.sender,
                storedAtBlock: block.number,
                category: categories[i],
                sealed: false,
                replicaCount: 0
            });
            _slotIds.push(slotIds[i]);
            slotCount++;
            _slotIdsByOwner[msg.sender].push(slotIds[i]);
            _slotCountByOwner[msg.sender]++;
            _slotIdsByCategory[categories[i]].push(slotIds[i]);
            stored++;
            emit SlotStored(slotIds[i], contentHashes[i], msg.sender, categories[i], block.number);
        }
        if (stored > 0) emit BatchStored(stored, msg.sender, block.number);
        return stored;
    }

    // -------------------------------------------------------------------------
    // GUARDIAN / ARCHIVIST
    // -------------------------------------------------------------------------

    function setMaxSlotsPerOwner(uint256 newMax) external onlyGuardian {
        uint256 prev = maxSlotsPerOwner;
        maxSlotsPerOwner = newMax > FM_MAX_SLOTS_PER_OWNER ? FM_MAX_SLOTS_PER_OWNER : newMax;
        emit MaxSlotsPerOwnerUpdated(prev, maxSlotsPerOwner, block.number);
    }

    function setNamespacePaused(bytes32 namespaceId, bool paused) external onlyGuardian {
        _namespacePaused[namespaceId] = paused;
        emit NamespacePaused(namespaceId, paused, block.number);
    }

    function purgeSlot(bytes32 slotId) external onlyArchivist nonReentrant {
        MemorySlot storage s = _slots[slotId];
        if (s.storedAtBlock == 0) revert FM_SlotNotFound();
        address owner = s.owner;
        bytes32 category = s.category;
        delete _slots[slotId];
        slotCount--;
        _slotCountByOwner[owner]--;
        emit SlotPurged(slotId, msg.sender, block.number);
    }

    // -------------------------------------------------------------------------
    // VIEW: BY ID
    // -------------------------------------------------------------------------

    function getSlot(bytes32 slotId) external view returns (bytes32 contentHash, address owner, uint256 storedAtBlock, bytes32 category, bool sealed, uint256 replicaCount) {
        MemorySlot storage s = _slots[slotId];
        if (s.storedAtBlock == 0) revert FM_SlotNotFound();
        return (s.contentHash, s.owner, s.storedAtBlock, s.category, s.sealed, s.replicaCount);
    }

    function getContentHash(bytes32 slotId) external view returns (bytes32) {
        MemorySlot storage s = _slots[slotId];
        if (s.storedAtBlock == 0) revert FM_SlotNotFound();
        return s.contentHash;
    }

    function getOwner(bytes32 slotId) external view returns (address) {
        MemorySlot storage s = _slots[slotId];
        if (s.storedAtBlock == 0) revert FM_SlotNotFound();
        return s.owner;
    }

    function getCategory(bytes32 slotId) external view returns (bytes32) {
        MemorySlot storage s = _slots[slotId];
        if (s.storedAtBlock == 0) revert FM_SlotNotFound();
        return s.category;
    }

    function isSealed(bytes32 slotId) external view returns (bool) {
        return _slots[slotId].sealed;
    }

    function getReplicaCount(bytes32 slotId) external view returns (uint256) {
        return _slots[slotId].replicaCount;
    }

    function slotExists(bytes32 slotId) external view returns (bool) {
        return _slots[slotId].storedAtBlock != 0;
    }

    // -------------------------------------------------------------------------
    // VIEW: LISTS
    // -------------------------------------------------------------------------

    function getSlotIdAt(uint256 index) external view returns (bytes32) {
        if (index >= _slotIds.length) revert FM_SlotNotFound();
        return _slotIds[index];
    }

    function getSlotIdsByOwner(address owner) external view returns (bytes32[] memory) {
        return _slotIdsByOwner[owner];
    }

    function getSlotCountByOwner(address owner) external view returns (uint256) {
        return _slotCountByOwner[owner];
    }

    function getSlotIdsByCategory(bytes32 category) external view returns (bytes32[] memory) {
        return _slotIdsByCategory[category];
    }

    function getCategorySlotCount(bytes32 category) external view returns (uint256) {
        return _slotIdsByCategory[category].length;
    }

    function getAllSlotIds() external view returns (bytes32[] memory) {
        return _slotIds;
    }

    function getNodeAt(uint256 index) external view returns (address) {
        if (index >= _nodeList.length) revert FM_NodeNotRegistered();
        return _nodeList[index];
    }

    function isNode(address account) external view returns (bool) {
        return _nodes[account];
    }

    function isNamespacePaused(bytes32 namespaceId) external view returns (bool) {
        return _namespacePaused[namespaceId];
    }

    // -------------------------------------------------------------------------
    // VIEW: BATCH
    // -------------------------------------------------------------------------

    function getSlotsBatch(bytes32[] calldata slotIds) external view returns (
        bytes32[] memory contentHashes,
        address[] memory owners,
        uint256[] memory storedAtBlocks,
        bytes32[] memory categories,
        bool[] memory sealedFlags,
        uint256[] memory replicaCounts
    ) {
        uint256 n = slotIds.length;
        contentHashes = new bytes32[](n);
        owners = new address[](n);
        storedAtBlocks = new uint256[](n);
        categories = new bytes32[](n);
        sealedFlags = new bool[](n);
        replicaCounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            MemorySlot storage s = _slots[slotIds[i]];
            contentHashes[i] = s.contentHash;
            owners[i] = s.owner;
            storedAtBlocks[i] = s.storedAtBlock;
            categories[i] = s.category;
            sealedFlags[i] = s.sealed;
            replicaCounts[i] = s.replicaCount;
        }
    }

    function slotIdsByOwnerPaginated(address owner, uint256 offset, uint256 limit) external view returns (bytes32[] memory out) {
        bytes32[] storage arr = _slotIdsByOwner[owner];
        if (offset >= arr.length) return new bytes32[](0);
        uint256 end = offset + limit;
        if (end > arr.length) end = arr.length;
        out = new bytes32[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            out[i - offset] = arr[i];
