// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IHydrexVotingEscrow {
    struct LockDetails {
        uint256 amount; /// @dev amount of tokens locked
        uint256 startTime; /// @dev when locking started
        uint256 endTime; /// @dev when locking ends
        LockType lockType; /// @dev defines the lock type
    }

    enum LockType {
        NON_PERMANENT, /// non permanent lock
        ROLLING, /// rolling max-lock
        PERMANENT /// permanent lock that burns the underlying
    }

    /**
     * @notice Delegates votes from a specific lock to a delegatee
     * @param _tokenId The ID of the lock token delegating the votes
     * @param delegatee The address to which the votes are being delegated
     */
    function delegate(uint256 _tokenId, address delegatee) external;

    /**
     * @notice Sets approval for an operator to claim rewards on behalf of the caller
     * @param operator The address to approve/disapprove as an operator
     * @param approved Whether the operator is approved or not
     */
    function setClaimRedirectApprovalForAll(address operator, bool approved) external;

    /**
     * @notice Standard operator approval for managing all of the caller's tokens
     * @dev Mirrors ERC-721/1155 style approval semantics
     * @param operator The address to be approved or disapproved
     * @param approved True to approve, false to revoke
     */
    function setApprovalForAll(address operator, bool approved) external;

    /**
     * @notice Merge two veNFT positions
     * @param _from The tokenId to merge from (will be burned)
     * @param _to The tokenId to merge into (will receive balance)
     */
    function merge(uint256 _from, uint256 _to) external;

    /**
     * @notice Sets or updates a conduit type configuration
     * @param actions Array of approval actions to execute for this conduit
     * @param description Human-readable description of the conduit
     */
    function setConduitApprovalConfig(uint8[] calldata actions, string calldata description) external;

    /**
     * @notice Approve or revoke a conduit for a specific veNFT tokenId
     * @param conduitAddress Address of the conduit
     * @param tokenId veNFT id to approve the conduit for
     * @param approve True to approve, false to revoke
     */
    function setConduitApproval(address conduitAddress, uint256 tokenId, bool approve) external;

    /**
     * @notice Creates a lock for a specified address
     * @param _value The value to lock
     * @param _lockDuration The duration of the lock
     * @param _to The address to create the lock for
     * @param _lockType The type of lock (0 = NON_PERMENANT, 1 = ROLLING, 2 = PERMENANT)
     */
    function createLockFor(uint256 _value, uint256 _lockDuration, address _to, uint8 _lockType) external;

    /**
     * @notice Creates a lock for a specified address with a specified delegatee that has claimable permissions
     * @param _value The total assets to be locked over time
     * @param _lockDuration Duration in seconds of the lock
     * @param _to The receiver of the lock
     * @param _delegatee The delegatee of the lock who also gets claim redirect approval
     * @param _lockType Whether the lock is permanent or not
     * @return The id of the newly created token
     */
    function createClaimableLockFor(
        uint256 _value,
        uint256 _lockDuration,
        address _to,
        address _delegatee,
        uint8 _lockType
    ) external returns (uint256);

    /**
     * @notice Gets the lock details for a specific token ID
     * @param _tokenId The ID of the token to query
     * @return The lock details struct containing amount, times, and lock type
     */
    function _lockDetails(uint256 _tokenId) external view returns (LockDetails memory);
}
