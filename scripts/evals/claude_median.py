"""
Median of Two Sorted Arrays
============================
Problem:
    Given two sorted arrays nums1 (size m) and nums2 (size n), return the
    median of the two sorted arrays.

Approach — Binary Search on Partition:
    Instead of merging, we binary-search for the correct partition of both
    arrays simultaneously.

    A median splits the combined virtual sorted array into two equal halves.
    Partitioning nums1 at index i and nums2 at index j, with i+j = (m+n+1)//2,
    we seek the unique i where:

        nums1[i-1] <= nums2[j]   (left of nums1 ≤ right of nums2)
        nums2[j-1] <= nums1[i]   (left of nums2 ≤ right of nums1)

    Binary search is performed only on the smaller array.
    -inf / +inf sentinels handle out-of-bounds comparisons.

    Once the valid partition is found:
        odd total  → median = max(left1, left2)
        even total → median = (max(left1, left2) + min(right1, right2)) / 2

Complexity:
    Time  : O(log(min(m, n)))
    Space : O(1)

Constraints:
    0 <= m, n <= 1000
    -10^6 <= nums1[i], nums2[i] <= 10^6
"""

import math
from typing import List


def findMedianSortedArrays(nums1: List[int], nums2: List[int]) -> float:
    # Always binary-search the smaller array
    if len(nums1) > len(nums2):
        nums1, nums2 = nums2, nums1

    m, n = len(nums1), len(nums2)
    half = (m + n + 1) // 2      # elements needed on the left side

    lo, hi = 0, m
    while lo <= hi:
        i = (lo + hi) // 2       # partition index in nums1
        j = half - i             # partition index in nums2 (derived)

        left1  = nums1[i - 1] if i > 0 else -math.inf
        right1 = nums1[i]     if i < m else  math.inf
        left2  = nums2[j - 1] if j > 0 else -math.inf
        right2 = nums2[j]     if j < n else  math.inf

        if left1 <= right2 and left2 <= right1:
            max_left  = max(left1, left2)
            min_right = min(right1, right2)
            if (m + n) % 2 == 1:
                return float(max_left)
            return (max_left + min_right) / 2.0

        elif left1 > right2:
            hi = i - 1           # i too large, move left
        else:
            lo = i + 1           # i too small, move right

    raise ValueError("Input arrays are not sorted")


# ── Test harness ──────────────────────────────────────────────────────────────

if __name__ == "__main__":
    test_cases = [
        ([1, 3],  [2],     2.0),
        ([1, 2],  [3, 4],  2.5),
        ([0, 0],  [0, 0],  0.0),
        ([],      [1],     1.0),
        ([2],     [],      2.0),
    ]

    all_passed = True
    for nums1, nums2, expected in test_cases:
        result = findMedianSortedArrays(nums1, nums2)
        status = "PASS" if result == expected else "FAIL"
        if status == "FAIL":
            all_passed = False
        print(f"[{status}]  nums1={nums1}, nums2={nums2} → {result}  (expected {expected})")

    print()
    print("All tests passed." if all_passed else "Some tests FAILED.")
