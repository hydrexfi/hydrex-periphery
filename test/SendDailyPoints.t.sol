// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SendDailyPoints} from "../contracts/send/SendDailyPoints.sol";

contract SendDailyPointsTest is Test {
    SendDailyPoints internal points;

    address internal alice;
    address internal bob;
    address internal carol;

    event CheckedIn(
        address indexed user,
        uint256 indexed day,
        uint32 currentStreak,
        uint32 longestStreak,
        uint32 totalCheckIns
    );

    uint256 internal constant DAY = 1 days;
    /// @dev Jan 1 2025 00:00:00 UTC (exact UTC day boundary, day 20089)
    uint256 internal constant START = 1_735_689_600;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");

        points = new SendDailyPoints();

        vm.warp(START);
    }

    function _today() internal view returns (uint256) {
        return vm.getBlockTimestamp() / DAY;
    }

    /*//////////////////////////////////////////////////////////////
                              BASIC CHECK-IN
    //////////////////////////////////////////////////////////////*/

    function test_firstCheckIn_setsStreakToOne() public {
        uint256 day = _today();

        vm.expectEmit(true, true, false, true);
        emit CheckedIn(alice, day, 1, 1, 1);

        vm.prank(alice);
        uint32 streak = points.checkIn();

        assertEq(streak, 1);
        assertEq(points.currentStreakOf(alice), 1);
        assertEq(points.longestStreakOf(alice), 1);
        assertEq(points.totalCheckInsOf(alice), 1);
        assertEq(points.lastCheckInDayOf(alice), uint32(day));
        assertTrue(points.hasCheckedInToday(alice));
        assertEq(points.totalUsers(), 1);
        assertEq(points.totalCheckIns(), 1);
    }

    function test_sameDay_reverts() public {
        vm.prank(alice);
        points.checkIn();

        vm.expectRevert(SendDailyPoints.AlreadyCheckedInToday.selector);
        vm.prank(alice);
        points.checkIn();
    }

    function test_sameDay_reverts_atEndOfDay() public {
        vm.prank(alice);
        points.checkIn();

        vm.warp(vm.getBlockTimestamp() + DAY - 1);

        vm.expectRevert(SendDailyPoints.AlreadyCheckedInToday.selector);
        vm.prank(alice);
        points.checkIn();
    }

    /*//////////////////////////////////////////////////////////////
                               STREAKS
    //////////////////////////////////////////////////////////////*/

    function test_consecutiveDays_extendStreak() public {
        uint256 t = vm.getBlockTimestamp();
        for (uint32 i = 1; i <= 7; i++) {
            vm.warp(t);
            vm.prank(alice);
            uint32 streak = points.checkIn();
            assertEq(streak, i);
            assertEq(points.currentStreakOf(alice), i);
            assertEq(points.longestStreakOf(alice), i);
            assertEq(points.totalCheckInsOf(alice), i);
            t += DAY;
        }
    }

    function test_missOneDay_resetsStreakOnNextCheckIn() public {
        vm.prank(alice);
        points.checkIn(); // day 0, streak 1

        vm.warp(vm.getBlockTimestamp() + DAY);
        vm.prank(alice);
        points.checkIn(); // day 1, streak 2

        vm.warp(vm.getBlockTimestamp() + 2 * DAY); // skip day 2 entirely

        vm.prank(alice);
        uint32 streak = points.checkIn(); // day 3, streak resets to 1

        assertEq(streak, 1);
        assertEq(points.currentStreakOf(alice), 1);
        assertEq(points.longestStreakOf(alice), 2); // still recorded
        assertEq(points.totalCheckInsOf(alice), 3);
    }

    function test_missManyDays_resetsStreak() public {
        vm.prank(alice);
        points.checkIn();

        vm.warp(vm.getBlockTimestamp() + 365 * DAY);

        vm.prank(alice);
        uint32 streak = points.checkIn();
        assertEq(streak, 1);
    }

    function test_longestStreak_persistsAfterReset() public {
        uint256 t = vm.getBlockTimestamp();
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(t);
            vm.prank(alice);
            points.checkIn();
            t += DAY;
        }
        assertEq(points.longestStreakOf(alice), 10);

        t += 5 * DAY;
        vm.warp(t);
        vm.prank(alice);
        points.checkIn();
        assertEq(points.currentStreakOf(alice), 1);
        assertEq(points.longestStreakOf(alice), 10);

        for (uint256 i = 0; i < 4; i++) {
            t += DAY;
            vm.warp(t);
            vm.prank(alice);
            points.checkIn();
        }
        assertEq(points.currentStreakOf(alice), 5);
        assertEq(points.longestStreakOf(alice), 10);
    }

    /*//////////////////////////////////////////////////////////////
                         LIVE VIEW RESET BEHAVIOR
    //////////////////////////////////////////////////////////////*/

    function test_currentStreakOf_zeroForNeverCheckedIn() public view {
        assertEq(points.currentStreakOf(alice), 0);
    }

    function test_currentStreakOf_stillValidDayAfterCheckIn() public {
        vm.prank(alice);
        points.checkIn();

        // Same day
        assertEq(points.currentStreakOf(alice), 1);

        // Next day (they can still check in and extend)
        vm.warp(vm.getBlockTimestamp() + DAY);
        assertEq(points.currentStreakOf(alice), 1);
    }

    function test_currentStreakOf_zeroAfterMissedDay_withoutTx() public {
        vm.prank(alice);
        points.checkIn();
        vm.warp(vm.getBlockTimestamp() + DAY);
        vm.prank(alice);
        points.checkIn();
        assertEq(points.currentStreakOf(alice), 2);

        // Jump two full days — streak is now broken but no tx submitted
        vm.warp(vm.getBlockTimestamp() + 2 * DAY);
        assertEq(points.currentStreakOf(alice), 0);
        // Storage still holds 2 until next check-in writes over it
        assertEq(points.longestStreakOf(alice), 2);
    }

    function test_hasCheckedInToday_rollsOverAtMidnight() public {
        vm.prank(alice);
        points.checkIn();
        assertTrue(points.hasCheckedInToday(alice));

        // 1 second before midnight UTC rollover
        vm.warp((vm.getBlockTimestamp() / DAY) * DAY + DAY - 1);
        assertTrue(points.hasCheckedInToday(alice));

        // Cross midnight
        vm.warp(vm.getBlockTimestamp() + 1);
        assertFalse(points.hasCheckedInToday(alice));
    }

    /*//////////////////////////////////////////////////////////////
                               GET STATS
    //////////////////////////////////////////////////////////////*/

    function test_getStats_neverCheckedIn() public view {
        (uint32 cs, uint32 ls, uint32 tc, uint256 lastAt, uint256 nextAt, bool today) = points.getStats(alice);
        assertEq(cs, 0);
        assertEq(ls, 0);
        assertEq(tc, 0);
        assertEq(lastAt, 0);
        assertEq(nextAt, vm.getBlockTimestamp(), "eligible now");
        assertFalse(today);
    }

    function test_getStats_afterCheckIn() public {
        vm.prank(alice);
        points.checkIn();
        vm.warp(vm.getBlockTimestamp() + DAY);
        vm.prank(alice);
        points.checkIn();

        (uint32 cs, uint32 ls, uint32 tc, uint256 lastAt, uint256 nextAt, bool today) = points.getStats(alice);
        assertEq(cs, 2);
        assertEq(ls, 2);
        assertEq(tc, 2);
        assertEq(lastAt, _today() * DAY, "lastAt is 00:00 UTC of today");
        assertEq(nextAt, (_today() + 1) * DAY, "next rollover tomorrow 00:00 UTC");
        assertTrue(today);
    }

    function test_getStats_reflectsLiveReset() public {
        vm.prank(alice);
        points.checkIn();
        vm.warp(vm.getBlockTimestamp() + 5 * DAY);

        (uint32 cs, uint32 ls, uint32 tc, uint256 lastAt, uint256 nextAt, bool today) = points.getStats(alice);
        assertEq(cs, 0, "live streak should be 0");
        assertEq(ls, 1);
        assertEq(tc, 1);
        assertEq(lastAt, START, "last check-in was at START");
        assertEq(nextAt, vm.getBlockTimestamp(), "eligible now");
        assertFalse(today);
    }

    function test_lastCheckInAt_zeroForNeverCheckedIn() public view {
        assertEq(points.lastCheckInAt(alice), 0);
    }

    function test_lastCheckInAt_returnsDayBoundary() public {
        vm.warp(START + 6 hours);
        vm.prank(alice);
        points.checkIn();
        assertEq(points.lastCheckInAt(alice), START, "snaps to 00:00 UTC, not tx time");
    }

    /*//////////////////////////////////////////////////////////////
                          MULTI-USER ISOLATION
    //////////////////////////////////////////////////////////////*/

    function test_multipleUsers_independentStreaks() public {
        uint256 start = vm.getBlockTimestamp();

        vm.prank(alice);
        points.checkIn();
        vm.prank(bob);
        points.checkIn();

        vm.warp(start + 1 * DAY);

        vm.prank(alice);
        points.checkIn();
        // bob does not check in

        vm.warp(start + 2 * DAY);

        vm.prank(alice);
        points.checkIn();
        vm.prank(bob);
        points.checkIn();

        assertEq(points.currentStreakOf(alice), 3);
        assertEq(points.currentStreakOf(bob), 1); // streak broken, reset
        assertEq(points.longestStreakOf(bob), 1);
        assertEq(points.totalCheckInsOf(bob), 2);

        assertEq(points.totalUsers(), 2);
        assertEq(points.totalCheckIns(), 5);
    }

    /*//////////////////////////////////////////////////////////////
                              UTILITY VIEWS
    //////////////////////////////////////////////////////////////*/

    function test_currentDay_matchesTimestampDiv() public view {
        assertEq(points.currentDay(), vm.getBlockTimestamp() / DAY);
    }

    function test_secondsUntilNextDay_atBoundary() public view {
        // setUp warps to exact midnight UTC
        assertEq(points.secondsUntilNextDay(), DAY);
    }

    function test_secondsUntilNextDay_midDay() public {
        vm.warp(vm.getBlockTimestamp() + 6 hours);
        assertEq(points.secondsUntilNextDay(), 18 hours);
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev Arbitrary sequence of day-gaps; streak should equal the length of
    ///      the current trailing run of gap==1.
    function testFuzz_streakMatchesConsecutiveRun(uint8[16] memory gaps) public {
        uint32 expectedStreak;
        uint32 expectedLongest;
        uint32 expectedTotal;

        for (uint256 i = 0; i < gaps.length; i++) {
            uint256 gap = uint256(gaps[i]) % 5; // 0..4
            if (gap == 0) {
                // Same day as previous check-in (or first-ever) → simulate the
                // "advance at least 1 day" requirement.
                gap = 1;
            }
            vm.warp(vm.getBlockTimestamp() + gap * DAY);

            if (gap == 1 && expectedTotal > 0) {
                expectedStreak += 1;
            } else {
                expectedStreak = 1;
            }
            if (expectedStreak > expectedLongest) expectedLongest = expectedStreak;
            expectedTotal += 1;

            vm.prank(alice);
            uint32 s = points.checkIn();

            assertEq(s, expectedStreak, "streak mismatch");
            assertEq(points.currentStreakOf(alice), expectedStreak);
            assertEq(points.longestStreakOf(alice), expectedLongest);
            assertEq(points.totalCheckInsOf(alice), expectedTotal);
        }
    }

    function testFuzz_missedDaysAlwaysReset(uint16 daysToSkip) public {
        vm.assume(daysToSkip >= 2);

        vm.prank(alice);
        points.checkIn();

        vm.warp(vm.getBlockTimestamp() + uint256(daysToSkip) * DAY);
        assertEq(points.currentStreakOf(alice), 0);

        vm.prank(alice);
        uint32 s = points.checkIn();
        assertEq(s, 1);
    }
}
