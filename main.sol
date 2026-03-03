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
        }
    }

    function slotIdsByCategoryPaginated(bytes32 category, uint256 offset, uint256 limit) external view returns (bytes32[] memory out) {
        bytes32[] storage arr = _slotIdsByCategory[category];
        if (offset >= arr.length) return new bytes32[](0);
        uint256 end = offset + limit;
        if (end > arr.length) end = arr.length;
        out = new bytes32[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            out[i - offset] = arr[i];
        }
    }

    // -------------------------------------------------------------------------
    // HASH & INDEX HELPERS
    // -------------------------------------------------------------------------

    function computeSlotId(bytes32 contentHash, address owner, uint256 nonce) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(contentHash, owner, nonce));
    }

    function computeCategoryHash(string calldata label) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(label));
    }

    function verifyContentHash(bytes32 slotId, bytes32 contentHash) external view returns (bool) {
        return _slots[slotId].contentHash == contentHash;
    }

    function namespaceHash() external pure returns (bytes32) {
        return FM_NAMESPACE;
    }

    function versionHash() external pure returns (bytes32) {
        return FM_VERSION;
    }

    function deployBlockNumber() external view returns (uint256) {
        return deployBlock;
    }

    // -------------------------------------------------------------------------
    // NODE REGISTRATION (guardian)
    // -------------------------------------------------------------------------

    function registerNode(address node) external onlyGuardian {
        if (node == address(0)) revert FM_ZeroAddress();
        if (_nodes[node]) return;
        if (_nodeList.length >= FM_MAX_NODES) revert FM_MaxSlotsReached();
        _nodes[node] = true;
        _nodeList.push(node);
        nodeCount = _nodeList.length;
        emit NodeRegistered(node, _nodeList.length - 1, block.number);
    }

    function unregisterNode(address node) external onlyGuardian {
        if (!_nodes[node]) return;
        _nodes[node] = false;
        for (uint256 i = 0; i < _nodeList.length; i++) {
            if (_nodeList[i] == node) {
                _nodeList[i] = _nodeList[_nodeList.length - 1];
                _nodeList.pop();
                break;
            }
        }
        nodeCount = _nodeList.length;
    }

    function getNodeList() external view returns (address[] memory) {
        return _nodeList;
    }

    // -------------------------------------------------------------------------
    // BATCH SEAL & BATCH ATTEST
    // -------------------------------------------------------------------------

    function batchSeal(bytes32[] calldata slotIds) external nonReentrant {
        for (uint256 i = 0; i < slotIds.length && i < FM_MAX_BATCH; i++) {
            MemorySlot storage s = _slots[slotIds[i]];
            if (s.storedAtBlock == 0) continue;
            if (s.owner != msg.sender && msg.sender != archivist) continue;
            if (s.sealed) continue;
            s.sealed = true;
            emit SlotSealed(slotIds[i], msg.sender, block.number);
        }
    }

    function batchAttestReplica(bytes32[] calldata slotIds) external onlyNode nonReentrant {
        for (uint256 i = 0; i < slotIds.length && i < FM_MAX_BATCH; i++) {
            if (_slots[slotIds[i]].storedAtBlock == 0) continue;
            _slots[slotIds[i]].replicaCount++;
            emit ReplicaAttested(slotIds[i], msg.sender, _slots[slotIds[i]].replicaCount, block.number);
        }
    }

    // -------------------------------------------------------------------------
    // VIEW: STATS & FILTERS
    // -------------------------------------------------------------------------

    function totalSlotCount() external view returns (uint256) {
        return _slotIds.length;
    }

    function sealedSlotCount() external view returns (uint256) {
        uint256 c = 0;
        for (uint256 i = 0; i < _slotIds.length; i++) {
            if (_slots[_slotIds[i]].sealed) c++;
        }
        return c;
    }

    function unsealedSlotCount() external view returns (uint256) {
        uint256 c = 0;
        for (uint256 i = 0; i < _slotIds.length; i++) {
            if (!_slots[_slotIds[i]].sealed) c++;
        }
        return c;
    }

    function slotCountInCategory(bytes32 category) external view returns (uint256) {
        return _slotIdsByCategory[category].length;
    }

    function ownerSlotCount(address owner) external view returns (uint256) {
        return _slotCountByOwner[owner];
    }

    function hasSlot(bytes32 slotId) external view returns (bool) {
        return _slots[slotId].storedAtBlock != 0;
    }

    function getStoredAtBlock(bytes32 slotId) external view returns (uint256) {
        return _slots[slotId].storedAtBlock;
    }

    function contentHashMatches(bytes32 slotId, bytes32 hash) external view returns (bool) {
        return _slots[slotId].contentHash == hash;
    }

    function slotOwnerIs(bytes32 slotId, address account) external view returns (bool) {
        return _slots[slotId].owner == account;
    }

    function slotCategoryIs(bytes32 slotId, bytes32 category) external view returns (bool) {
        return _slots[slotId].category == category;
    }

    // -------------------------------------------------------------------------
    // VIEW: PAGINATED GLOBAL
    // -------------------------------------------------------------------------

    function getSlotIdsPaginated(uint256 offset, uint256 limit) external view returns (bytes32[] memory out) {
        if (offset >= _slotIds.length) return new bytes32[](0);
        uint256 end = offset + limit;
        if (end > _slotIds.length) end = _slotIds.length;
        out = new bytes32[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            out[i - offset] = _slotIds[i];
        }
    }

    function getSlotIdsSealedPaginated(uint256 offset, uint256 limit) external view returns (bytes32[] memory out) {
        bytes32[] memory temp = new bytes32[](limit);
        uint256 count = 0;
        for (uint256 i = 0; i < _slotIds.length && count < limit; i++) {
            if (_slots[_slotIds[i]].sealed) {
                if (count >= offset) {
                    temp[count - offset] = _slotIds[i];
                }
                count++;
            }
        }
        uint256 size = count > offset ? count - offset : 0;
        if (size > limit) size = limit;
        out = new bytes32[](size);
        for (uint256 j = 0; j < size; j++) {
            out[j] = temp[j];
        }
    }

    function getSlotIdsUnsealedPaginated(uint256 offset, uint256 limit) external view returns (bytes32[] memory out) {
        bytes32[] memory temp = new bytes32[](limit);
        uint256 count = 0;
        for (uint256 i = 0; i < _slotIds.length && count < offset + limit; i++) {
            if (!_slots[_slotIds[i]].sealed) {
                if (count >= offset && count - offset < limit) {
                    temp[count - offset] = _slotIds[i];
                }
                count++;
            }
        }
        uint256 size = count > offset ? count - offset : 0;
        if (size > limit) size = limit;
        out = new bytes32[](size);
        for (uint256 j = 0; j < size; j++) {
            out[j] = temp[j];
        }
    }

    // -------------------------------------------------------------------------
    // VIEW: BY BLOCK RANGE
    // -------------------------------------------------------------------------

    function slotIdsStoredBetween(uint256 fromBlock, uint256 toBlock) external view returns (bytes32[] memory out) {
        uint256 cap = 256;
        bytes32[] memory temp = new bytes32[](cap);
        uint256 count = 0;
        for (uint256 i = 0; i < _slotIds.length && count < cap; i++) {
            uint256 b = _slots[_slotIds[i]].storedAtBlock;
            if (b >= fromBlock && b <= toBlock) {
                temp[count] = _slotIds[i];
                count++;
            }
        }
        out = new bytes32[](count);
        for (uint256 j = 0; j < count; j++) {
            out[j] = temp[j];
        }
    }

    function slotCountStoredBetween(uint256 fromBlock, uint256 toBlock) external view returns (uint256) {
        uint256 c = 0;
        for (uint256 i = 0; i < _slotIds.length; i++) {
            uint256 b = _slots[_slotIds[i]].storedAtBlock;
            if (b >= fromBlock && b <= toBlock) c++;
        }
        return c;
    }

    // -------------------------------------------------------------------------
    // PURE: HASH HELPERS
    // -------------------------------------------------------------------------

    function hashContent(bytes32 a) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(a));
    }

    function hashContentPair(bytes32 a, bytes32 b) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(a, b));
    }

    function hashSlotIdentity(bytes32 contentHash, address owner, bytes32 category) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(contentHash, owner, category));
    }

    function hashWithNonce(bytes32 data, uint256 nonce) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(data, nonce));
    }

    function hashNamespace(bytes32 ns) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(FM_NAMESPACE, ns));
    }

    // -------------------------------------------------------------------------
    // VIEW: MULTI-GET LIGHT
    // -------------------------------------------------------------------------

    function getContentHashesBatch(bytes32[] calldata slotIds) external view returns (bytes32[] memory) {
        bytes32[] memory out = new bytes32[](slotIds.length);
        for (uint256 i = 0; i < slotIds.length; i++) {
            out[i] = _slots[slotIds[i]].contentHash;
        }
        return out;
    }

    function getOwnersBatch(bytes32[] calldata slotIds) external view returns (address[] memory) {
        address[] memory out = new address[](slotIds.length);
        for (uint256 i = 0; i < slotIds.length; i++) {
            out[i] = _slots[slotIds[i]].owner;
        }
        return out;
    }

    function getCategoriesBatch(bytes32[] calldata slotIds) external view returns (bytes32[] memory) {
        bytes32[] memory out = new bytes32[](slotIds.length);
        for (uint256 i = 0; i < slotIds.length; i++) {
            out[i] = _slots[slotIds[i]].category;
        }
        return out;
    }

    function getSealedBatch(bytes32[] calldata slotIds) external view returns (bool[] memory) {
        bool[] memory out = new bool[](slotIds.length);
        for (uint256 i = 0; i < slotIds.length; i++) {
            out[i] = _slots[slotIds[i]].sealed;
        }
        return out;
    }

    function getReplicaCountsBatch(bytes32[] calldata slotIds) external view returns (uint256[] memory) {
        uint256[] memory out = new uint256[](slotIds.length);
        for (uint256 i = 0; i < slotIds.length; i++) {
            out[i] = _slots[slotIds[i]].replicaCount;
        }
        return out;
    }

    // -------------------------------------------------------------------------
    // VIEW: EXISTS BATCH
    // -------------------------------------------------------------------------

    function slotsExistBatch(bytes32[] calldata slotIds) external view returns (bool[] memory) {
        bool[] memory out = new bool[](slotIds.length);
        for (uint256 i = 0; i < slotIds.length; i++) {
            out[i] = _slots[slotIds[i]].storedAtBlock != 0;
        }
        return out;
    }

    function countExisting(bytes32[] calldata slotIds) external view returns (uint256) {
        uint256 c = 0;
        for (uint256 i = 0; i < slotIds.length; i++) {
            if (_slots[slotIds[i]].storedAtBlock != 0) c++;
        }
        return c;
    }

    // -------------------------------------------------------------------------
    // META & CONSTANTS
    // -------------------------------------------------------------------------

    function maxSlots() external pure returns (uint256) {
        return FM_MAX_SLOTS;
    }

    function maxSlotsPerOwnerLimit() external pure returns (uint256) {
        return FM_MAX_SLOTS_PER_OWNER;
    }

    function maxNodes() external pure returns (uint256) {
        return FM_MAX_NODES;
    }

    function maxBatchSize() external pure returns (uint256) {
        return FM_MAX_BATCH;
    }

    function maxShardsPerSlot() external pure returns (uint256) {
        return FM_MAX_SHARDS_PER_SLOT;
    }

    function currentMaxSlotsPerOwner() external view returns (uint256) {
        return maxSlotsPerOwner;
    }

    function guardianAddress() external view returns (address) {
        return guardian;
    }

    function archivistAddress() external view returns (address) {
        return archivist;
    }

    function nodeAAddress() external view returns (address) {
        return nodeA;
    }

    function nodeBAddress() external view returns (address) {
        return nodeB;
    }

    function nodeCAddress() external view returns (address) {
        return nodeC;
    }

    // -------------------------------------------------------------------------
    // VIEW: CATEGORY ENUMERATION
    // -------------------------------------------------------------------------

    function getFirstSlotIdInCategory(bytes32 category) external view returns (bytes32) {
        bytes32[] storage arr = _slotIdsByCategory[category];
        if (arr.length == 0) return bytes32(0);
        return arr[0];
    }

    function getLastSlotIdInCategory(bytes32 category) external view returns (bytes32) {
        bytes32[] storage arr = _slotIdsByCategory[category];
        if (arr.length == 0) return bytes32(0);
        return arr[arr.length - 1];
    }

    function getSlotIdInCategoryAt(bytes32 category, uint256 index) external view returns (bytes32) {
        bytes32[] storage arr = _slotIdsByCategory[category];
        if (index >= arr.length) revert FM_SlotNotFound();
        return arr[index];
    }

    function getOwnerFirstSlot(address owner) external view returns (bytes32) {
        bytes32[] storage arr = _slotIdsByOwner[owner];
        if (arr.length == 0) return bytes32(0);
        return arr[0];
    }

    function getOwnerLastSlot(address owner) external view returns (bytes32) {
        bytes32[] storage arr = _slotIdsByOwner[owner];
        if (arr.length == 0) return bytes32(0);
        return arr[arr.length - 1];
    }

    function getOwnerSlotAt(address owner, uint256 index) external view returns (bytes32) {
        bytes32[] storage arr = _slotIdsByOwner[owner];
        if (index >= arr.length) revert FM_SlotNotFound();
        return arr[index];
    }

    // -------------------------------------------------------------------------
    // VIEW: REPLICA & SHARD HELPERS
    // -------------------------------------------------------------------------

    function slotsWithMinReplicas(uint256 minReplicas) external view returns (bytes32[] memory out) {
        bytes32[] memory temp = new bytes32[](_slotIds.length);
        uint256 count = 0;
        for (uint256 i = 0; i < _slotIds.length; i++) {
            if (_slots[_slotIds[i]].replicaCount >= minReplicas) {
                temp[count] = _slotIds[i];
                count++;
            }
        }
        out = new bytes32[](count);
        for (uint256 j = 0; j < count; j++) {
            out[j] = temp[j];
        }
    }

    function slotIdsWithZeroReplicas() external view returns (bytes32[] memory out) {
        return slotsWithMinReplicas(0);
    }

    function totalReplicaCount() external view returns (uint256) {
        uint256 t = 0;
        for (uint256 i = 0; i < _slotIds.length; i++) {
            t += _slots[_slotIds[i]].replicaCount;
        }
        return t;
    }

    function averageReplicaCount() external view returns (uint256) {
        if (_slotIds.length == 0) return 0;
        return totalReplicaCount() / _slotIds.length;
    }

    // -------------------------------------------------------------------------
    // PURE: SLOT ID GENERATORS
    // -------------------------------------------------------------------------

    function slotIdFromString(string calldata s) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(s));
    }

    function slotIdFromAddressAndNonce(address account, uint256 nonce) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(account, nonce));
    }

    function slotIdFromHashAndBlock(bytes32 h, uint256 blockNum) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(h, blockNum));
    }

    function categoryFromString(string calldata s) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(s));
    }

    function combinedHash(bytes32 a, bytes32 b, bytes32 c) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(a, b, c));
    }

    // -------------------------------------------------------------------------
    // VIEW: CHECK HELPERS
    // -------------------------------------------------------------------------

    function canStore(address account) external view returns (bool) {
        if (slotCount >= FM_MAX_SLOTS) return false;
        if (_slotCountByOwner[account] >= maxSlotsPerOwner) return false;
        if (_namespacePaused[FM_NAMESPACE]) return false;
        return true;
    }

    function remainingSlotsFor(address account) external view returns (uint256) {
        uint256 used = _slotCountByOwner[account];
        if (used >= maxSlotsPerOwner) return 0;
        uint256 global = FM_MAX_SLOTS > slotCount ? FM_MAX_SLOTS - slotCount : 0;
        uint256 perOwner = maxSlotsPerOwner - used;
        return global < perOwner ? global : perOwner;
    }

    function globalRemainingSlots() external view returns (uint256) {
        return slotCount >= FM_MAX_SLOTS ? 0 : FM_MAX_SLOTS - slotCount;
    }

    function isPaused() external view returns (bool) {
        return _namespacePaused[FM_NAMESPACE];
    }

    // -------------------------------------------------------------------------
    // VIEW: SLOT SUMMARY
    // -------------------------------------------------------------------------

    function getSlotSummary(bytes32 slotId) external view returns (
        bytes32 contentHash_,
        address owner_,
        uint256 storedAtBlock_,
        bytes32 category_,
        bool sealed_,
        uint256 replicaCount_
    ) {
        MemorySlot storage s = _slots[slotId];
        if (s.storedAtBlock == 0) revert FM_SlotNotFound();
        contentHash_ = s.contentHash;
        owner_ = s.owner;
        storedAtBlock_ = s.storedAtBlock;
        category_ = s.category;
        sealed_ = s.sealed;
        replicaCount_ = s.replicaCount;
    }

    function getSlotSummariesBatch(bytes32[] calldata slotIds) external view returns (
        bytes32[] memory contentHashes_,
        address[] memory owners_,
        uint256[] memory storedAtBlocks_,
        bytes32[] memory categories_,
        bool[] memory sealed_,
        uint256[] memory replicaCounts_
    ) {
        uint256 n = slotIds.length;
        contentHashes_ = new bytes32[](n);
        owners_ = new address[](n);
        storedAtBlocks_ = new uint256[](n);
        categories_ = new bytes32[](n);
        sealed_ = new bool[](n);
        replicaCounts_ = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            MemorySlot storage s = _slots[slotIds[i]];
            contentHashes_[i] = s.contentHash;
            owners_[i] = s.owner;
            storedAtBlocks_[i] = s.storedAtBlock;
            categories_[i] = s.category;
            sealed_[i] = s.sealed;
            replicaCounts_[i] = s.replicaCount;
        }
    }

    // -------------------------------------------------------------------------
    // VIEW: INDEX BY CONTENT HASH (linear scan)
    // -------------------------------------------------------------------------

    function slotIdsWithContentHash(bytes32 contentHash) external view returns (bytes32[] memory out) {
        bytes32[] memory temp = new bytes32[](_slotIds.length);
        uint256 count = 0;
        for (uint256 i = 0; i < _slotIds.length; i++) {
            if (_slots[_slotIds[i]].contentHash == contentHash) {
                temp[count] = _slotIds[i];
                count++;
            }
        }
        out = new bytes32[](count);
        for (uint256 j = 0; j < count; j++) {
            out[j] = temp[j];
        }
    }

    function firstSlotIdWithContentHash(bytes32 contentHash) external view returns (bytes32) {
        for (uint256 i = 0; i < _slotIds.length; i++) {
            if (_slots[_slotIds[i]].contentHash == contentHash) return _slotIds[i];
        }
        return bytes32(0);
    }

    function countSlotsWithContentHash(bytes32 contentHash) external view returns (uint256) {
        uint256 c = 0;
        for (uint256 i = 0; i < _slotIds.length; i++) {
            if (_slots[_slotIds[i]].contentHash == contentHash) c++;
        }
        return c;
    }

    // -------------------------------------------------------------------------
    // VIEW: RECENT SLOTS
    // -------------------------------------------------------------------------

    function latestSlotIds(uint256 n) external view returns (bytes32[] memory out) {
        if (n == 0 || _slotIds.length == 0) return new bytes32[](0);
        if (n > _slotIds.length) n = _slotIds.length;
        out = new bytes32[](n);
        uint256 start = _slotIds.length - n;
        for (uint256 i = 0; i < n; i++) {
            out[i] = _slotIds[start + i];
        }
    }

    function oldestSlotIds(uint256 n) external view returns (bytes32[] memory out) {
        if (n == 0 || _slotIds.length == 0) return new bytes32[](0);
        if (n > _slotIds.length) n = _slotIds.length;
        out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = _slotIds[i];
        }
    }

    // -------------------------------------------------------------------------
    // DISTRIBUTED STORAGE HELPERS
    // -------------------------------------------------------------------------

    function nodeCountForSlot(bytes32) external pure returns (uint256) {
        return 0;
    }

    function attestationThreshold() external pure returns (uint256) {
        return 2;
    }

    function isFullyReplicated(bytes32 slotId) external view returns (bool) {
        return _slots[slotId].replicaCount >= 2;
    }

    function slotsFullyReplicated() external view returns (bytes32[] memory out) {
        return slotsWithMinReplicas(2);
    }

    function slotsUnderReplicated() external view returns (bytes32[] memory out) {
        bytes32[] memory temp = new bytes32[](_slotIds.length);
        uint256 count = 0;
        for (uint256 i = 0; i < _slotIds.length; i++) {
            if (_slots[_slotIds[i]].replicaCount < 2) {
                temp[count] = _slotIds[i];
                count++;
            }
        }
        out = new bytes32[](count);
        for (uint256 j = 0; j < count; j++) {
            out[j] = temp[j];
        }
    }

    function underReplicatedCount() external view returns (uint256) {
        uint256 c = 0;
        for (uint256 i = 0; i < _slotIds.length; i++) {
            if (_slots[_slotIds[i]].replicaCount < 2) c++;
        }
        return c;
    }

    // -------------------------------------------------------------------------
    // PURE: CONSTANT HASHES
    // -------------------------------------------------------------------------

    function domainSeparator() external pure returns (bytes32) {
        return keccak256(abi.encodePacked("FluffyMemory", FM_NAMESPACE));
    }

    function slotTypeHash() external pure returns (bytes32) {
        return keccak256("MemorySlot(bytes32 contentHash,address owner,uint256 storedAtBlock,bytes32 category,bool sealed,uint256 replicaCount)");
    }

    function storageLayoutVersion() external pure returns (bytes32) {
        return FM_VERSION;
    }

    // -------------------------------------------------------------------------
    // VIEW: GUARDIAN / ARCHIVIST CHECK
    // -------------------------------------------------------------------------

    function isGuardian(address account) external view returns (bool) {
        return account == guardian;
    }

    function isArchivist(address account) external view returns (bool) {
        return account == archivist;
    }

    function isDefaultNode(address account) external view returns (bool) {
        return account == nodeA || account == nodeB || account == nodeC;
    }

    // -------------------------------------------------------------------------
    // VIEW: BULK SLOT IDS BY OWNER (with limit)
    // -------------------------------------------------------------------------

    function getSlotIdsByOwnerLimit(address owner, uint256 maxReturn) external view returns (bytes32[] memory) {
        bytes32[] storage arr = _slotIdsByOwner[owner];
        uint256 n = arr.length > maxReturn ? maxReturn : arr.length;
        bytes32[] memory out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = arr[i];
        }
        return out;
    }

    function getSlotIdsByCategoryLimit(bytes32 category, uint256 maxReturn) external view returns (bytes32[] memory) {
        bytes32[] storage arr = _slotIdsByCategory[category];
        uint256 n = arr.length > maxReturn ? maxReturn : arr.length;
        bytes32[] memory out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = arr[i];
        }
        return out;
    }

    // -------------------------------------------------------------------------
    // VIEW: BLOCK HELPERS
    // -------------------------------------------------------------------------

    function slotsStoredAtBlock(uint256 blockNum) external view returns (bytes32[] memory out) {
        bytes32[] memory temp = new bytes32[](_slotIds.length);
        uint256 count = 0;
        for (uint256 i = 0; i < _slotIds.length; i++) {
            if (_slots[_slotIds[i]].storedAtBlock == blockNum) {
                temp[count] = _slotIds[i];
                count++;
            }
        }
        out = new bytes32[](count);
        for (uint256 j = 0; j < count; j++) {
            out[j] = temp[j];
        }
    }

    function countSlotsStoredAtBlock(uint256 blockNum) external view returns (uint256) {
        uint256 c = 0;
        for (uint256 i = 0; i < _slotIds.length; i++) {
            if (_slots[_slotIds[i]].storedAtBlock == blockNum) c++;
        }
        return c;
    }

    // -------------------------------------------------------------------------
    // PURE: ENCODING HELPERS
    // -------------------------------------------------------------------------

    function encodeSlotId(bytes32 contentHash, address owner, bytes32 category, uint256 nonce) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(contentHash, owner, category, nonce));
    }

    function encodeCategory(bytes32 a, bytes32 b) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(a, b));
    }

    function encodeContentHash(bytes memory data) external pure returns (bytes32) {
        return keccak256(data);
    }

    // -------------------------------------------------------------------------
    // VIEW: CATEGORY LIST (unique categories from storage - linear)
    // -------------------------------------------------------------------------

    function getCategoriesForSlot(bytes32 slotId) external view returns (bytes32) {
        return _slots[slotId].category;
    }

    function getOwnerForSlot(bytes32 slotId) external view returns (address) {
        return _slots[slotId].owner;
    }

    function getContentHashForSlot(bytes32 slotId) external view returns (bytes32) {
        return _slots[slotId].contentHash;
    }

    function getStoredBlockForSlot(bytes32 slotId) external view returns (uint256) {
        return _slots[slotId].storedAtBlock;
    }

    function getSealedForSlot(bytes32 slotId) external view returns (bool) {
        return _slots[slotId].sealed;
    }

    function getReplicasForSlot(bytes32 slotId) external view returns (uint256) {
        return _slots[slotId].replicaCount;
    }

    // -------------------------------------------------------------------------
    // VIEW: MULTI-CATEGORY
    // -------------------------------------------------------------------------

    function slotIdsInCategories(bytes32[] calldata categories) external view returns (bytes32[] memory out) {
        uint256 total = 0;
        for (uint256 c = 0; c < categories.length; c++) {
            total += _slotIdsByCategory[categories[c]].length;
        }
        if (total > 512) total = 512;
        bytes32[] memory temp = new bytes32[](total);
        uint256 idx = 0;
        for (uint256 c = 0; c < categories.length && idx < total; c++) {
            bytes32[] storage arr = _slotIdsByCategory[categories[c]];
            for (uint256 i = 0; i < arr.length && idx < total; i++) {
                temp[idx] = arr[i];
                idx++;
            }
        }
        out = new bytes32[](idx);
        for (uint256 j = 0; j < idx; j++) {
            out[j] = temp[j];
        }
    }

    function totalSlotsInCategories(bytes32[] calldata categories) external view returns (uint256) {
        uint256 t = 0;
        for (uint256 c = 0; c < categories.length; c++) {
            t += _slotIdsByCategory[categories[c]].length;
        }
        return t;
    }

    // -------------------------------------------------------------------------
    // VIEW: OWNER MULTI
    // -------------------------------------------------------------------------

    function slotIdsForOwners(address[] calldata owners) external view returns (bytes32[] memory out) {
        uint256 total = 0;
        for (uint256 o = 0; o < owners.length; o++) {
            total += _slotIdsByOwner[owners[o]].length;
        }
        if (total > 512) total = 512;
        bytes32[] memory temp = new bytes32[](total);
        uint256 idx = 0;
        for (uint256 o = 0; o < owners.length && idx < total; o++) {
            bytes32[] storage arr = _slotIdsByOwner[owners[o]];
            for (uint256 i = 0; i < arr.length && idx < total; i++) {
                temp[idx] = arr[i];
                idx++;
            }
        }
        out = new bytes32[](idx);
        for (uint256 j = 0; j < idx; j++) {
            out[j] = temp[j];
        }
    }

    function totalSlotsForOwners(address[] calldata owners) external view returns (uint256) {
        uint256 t = 0;
        for (uint256 o = 0; o < owners.length; o++) {
            t += _slotCountByOwner[owners[o]];
        }
        return t;
    }

    // -------------------------------------------------------------------------
    // VIEW: SEALED/UNSEALED PAGINATION FIXED
    // -------------------------------------------------------------------------

    function sealedSlotIds(uint256 offset, uint256 limit) external view returns (bytes32[] memory out) {
        uint256 collected = 0;
        uint256 written = 0;
        uint256 maxOut = limit > 256 ? 256 : limit;
        out = new bytes32[](maxOut);
        for (uint256 i = 0; i < _slotIds.length && written < maxOut; i++) {
            if (_slots[_slotIds[i]].sealed) {
                if (collected >= offset) {
                    out[written] = _slotIds[i];
                    written++;
                }
                collected++;
            }
        }
        if (written < maxOut) {
            bytes32[] memory trimmed = new bytes32[](written);
            for (uint256 j = 0; j < written; j++) trimmed[j] = out[j];
            return trimmed;
        }
        return out;
