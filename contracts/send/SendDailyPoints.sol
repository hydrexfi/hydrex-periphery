// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/*
  ______   ________  __    __  _______  
 /      \ |        \|  \  |  \|       \ 
|  $$$$$$\| $$$$$$$$| $$\ | $$| $$$$$$$\
| $$___\$$| $$__    | $$$\| $$| $$  | $$
 \$$    \ | $$  \   | $$$$\ $$| $$  | $$
 _\$$$$$$\| $$$$$   | $$\$$ $$| $$  | $$
|  \__| $$| $$_____ | $$ \$$$$| $$__/ $$
 \$$    $$| $$     \| $$  \$$$| $$    $$
  \$$$$$$  \$$$$$$$$ \$$   \$$ \$$$$$$$        
*/

/**
 * @title SendDailyPoints
 * @notice Free, permissionless daily check-in for Send.
 * @dev Days are indexed as `block.timestamp / 1 days` (unix epoch day number).
 */
contract SendDailyPoints {
    struct Record {
        uint32 lastCheckInDay;
        uint32 currentStreak;
        uint32 longestStreak;
        uint32 totalCheckIns;
    }

    mapping(address => Record) private _records;

    uint256 public totalUsers;
    uint256 public totalCheckIns;

    event CheckedIn(
        address indexed user,
        uint256 indexed day,
        uint32 currentStreak,
        uint32 longestStreak,
        uint32 totalCheckIns
    );

    error AlreadyCheckedInToday();

    /*//////////////////////////////////////////////////////////////
                               CHECK-IN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Record today's check-in for the caller.
     * @dev Reverts with {AlreadyCheckedInToday} if caller already checked in
     *      during the current UTC day. Streak continues only if the previous
     *      check-in was yesterday; any larger gap resets streak to 1.
     * @return currentStreak Caller's streak after this check-in
     */
    function checkIn() external returns (uint32 currentStreak) {
        uint32 today = uint32(block.timestamp / 1 days);
        Record storage r = _records[msg.sender];

        uint32 last = r.lastCheckInDay;
        if (last == today) revert AlreadyCheckedInToday();

        if (last == 0) {
            totalUsers += 1;
            currentStreak = 1;
        } else if (last + 1 == today) {
            currentStreak = r.currentStreak + 1;
        } else {
            currentStreak = 1;
        }

        uint32 longest = r.longestStreak;
        if (currentStreak > longest) longest = currentStreak;

        uint32 total = r.totalCheckIns + 1;

        r.lastCheckInDay = today;
        r.currentStreak = currentStreak;
        r.longestStreak = longest;
        r.totalCheckIns = total;

        unchecked {
            totalCheckIns += 1;
        }

        emit CheckedIn(msg.sender, today, currentStreak, longest, total);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Current UTC day number (seconds since epoch / 86400).
     */
    function currentDay() public view returns (uint256) {
        return block.timestamp / 1 days;
    }

    /**
     * @notice True if `user` has already checked in during the current UTC day.
     */
    function hasCheckedInToday(address user) public view returns (bool) {
        return _records[user].lastCheckInDay == uint32(block.timestamp / 1 days);
    }

    /**
     * @notice Live streak for `user`. Returns 0 if they've never checked in or
     *         missed a full UTC day — regardless of what's in storage.
     */
    function currentStreakOf(address user) public view returns (uint32) {
        Record storage r = _records[user];
        uint32 last = r.lastCheckInDay;
        if (last == 0) return 0;

        uint32 today = uint32(block.timestamp / 1 days);
        if (today == last || today == last + 1) return r.currentStreak;

        return 0;
    }

    /**
     * @notice All-time longest streak for `user`.
     */
    function longestStreakOf(address user) external view returns (uint32) {
        return _records[user].longestStreak;
    }

    /**
     * @notice Lifetime check-in count for `user`.
     */
    function totalCheckInsOf(address user) external view returns (uint32) {
        return _records[user].totalCheckIns;
    }

    /**
     * @notice Unix timestamp (seconds) of the 00:00 UTC boundary of `user`'s
     *         most recent check-in day. Returns 0 if the user has never checked
     *         in. Feed directly into JS: `new Date(value * 1000)`.
     */
    function lastCheckInAt(address user) external view returns (uint256) {
        uint256 day = _records[user].lastCheckInDay;
        if (day == 0) return 0;
        return day * 1 days;
    }

    /**
     * @notice Raw UTC day index (unix seconds / 86400) of `user`'s most recent
     *         check-in. 0 if never. Matches the `day` topic on {CheckedIn}, so
     *         this is the value to filter event logs by.
     */
    function lastCheckInDayOf(address user) external view returns (uint32) {
        return _records[user].lastCheckInDay;
    }

    /**
     * @notice Full snapshot of `user`'s check-in state, in frontend-friendly
     *         units.
     * @return currentStreak       Live streak (0 if expired without a tx)
     * @return longestStreak       All-time best streak
     * @return totalCheckIns_      Lifetime check-ins
     * @return lastCheckInAt_      Unix timestamp (seconds) of the 00:00 UTC
     *                             boundary of the last check-in day; 0 if never
     * @return nextCheckInAt       Unix timestamp (seconds) at which `user` can
     *                             check in again: now if eligible, otherwise
     *                             the next 00:00 UTC rollover
     * @return checkedInToday      Whether `user` has checked in this UTC day
     */
    function getStats(
        address user
    )
        external
        view
        returns (
            uint32 currentStreak,
            uint32 longestStreak,
            uint32 totalCheckIns_,
            uint256 lastCheckInAt_,
            uint256 nextCheckInAt,
            bool checkedInToday
        )
    {
        Record storage r = _records[user];
        uint32 today = uint32(block.timestamp / 1 days);
        uint32 last = r.lastCheckInDay;

        longestStreak = r.longestStreak;
        totalCheckIns_ = r.totalCheckIns;
        checkedInToday = (last == today);
        lastCheckInAt_ = last == 0 ? 0 : uint256(last) * 1 days;

        if (last != 0 && (today == last || today == last + 1)) {
            currentStreak = r.currentStreak;
        }

        nextCheckInAt = checkedInToday ? (uint256(today) + 1) * 1 days : block.timestamp;
    }

    /**
     * @notice Seconds remaining until the next UTC day rollover (00:00 UTC).
     */
    function secondsUntilNextDay() external view returns (uint256) {
        return 1 days - (block.timestamp % 1 days);
    }
}
