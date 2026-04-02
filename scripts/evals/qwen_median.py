from typing import List

def findMedianSortedArrays(nums1: List[int], nums2: List[int]) -> float:
    """
    Find the median of two sorted arrays with O(log(min(m,n))) time complexity.
    
    Algorithm: Binary Search Partitioning
    - We partition both arrays such that all elements on the left are <= all on the right
    - The median is determined by the boundary elements of the partitions
    
    Time Complexity: O(log(min(m, n)))
    Space Complexity: O(1)

    Author: Qwen3.5-27B-Claude-4.6-Opus-Reasoning-Distilled
    """
    
    # Ensure nums1 is the smaller array for O(log(min(m,n))) complexity
    if len(nums1) > len(nums2):
        nums1, nums2 = nums2, nums1
    
    m, n = len(nums1), len(nums2)
    
    # Binary search on the smaller array
    left, right = 0, m
    
    while left <= right:
        # Partition point in nums1
        partition1 = (left + right) // 2
        
        # Partition point in nums2 (ensures left half has half or half+1 elements)
        partition2 = (m + n + 1) // 2 - partition1
        
        # Handle edge cases with infinity
        # Max of left partition and min of right partition for each array
        max_left_1 = float('-inf') if partition1 == 0 else nums1[partition1 - 1]
        min_right_1 = float('inf') if partition1 == m else nums1[partition1]
        
        max_left_2 = float('-inf') if partition2 == 0 else nums2[partition2 - 1]
        min_right_2 = float('inf') if partition2 == n else nums2[partition2]
        
        # Check if we found the correct partition
        # All elements on left must be <= all elements on right
        if max_left_1 <= min_right_2 and max_left_2 <= min_right_1:
            # Found correct partition
            
            # If total length is odd, median is the max of left partitions
            if (m + n) % 2 == 1:
                return float(max(max_left_1, max_left_2))
            # If total length is even, median is average of max of left and min of right
            else:
                return (max(max_left_1, max_left_2) + min(min_right_1, min_right_2)) / 2.0
        elif max_left_1 > min_right_2:
            # Partition1 is too far right, move it left
            right = partition1 - 1
        else:
            # Partition1 is too far left, move it right
            left = partition1 + 1
    
    # This should never be reached if inputs are valid
    raise ValueError("Input arrays are not sorted or invalid")


# =============================================================================
# Test Harness
# =============================================================================

def run_tests():
    """Run all test cases and report results."""
    
    test_cases = [
        {"nums1": [1, 3], "nums2": [2], "expected": 2.0, "desc": "Example 1"},
        {"nums1": [1, 2], "nums2": [3, 4], "expected": 2.5, "desc": "Example 2"},
        {"nums1": [0, 0], "nums2": [0, 0], "expected": 0.0, "desc": "All zeros"},
        {"nums1": [], "nums2": [1], "expected": 1.0, "desc": "First array empty"},
        {"nums1": [2], "nums2": [], "expected": 2.0, "desc": "Second array empty"},
    ]
    
    print("=" * 60)
    print("Running Test Cases for findMedianSortedArrays")
    print("=" * 60)
    
    all_passed = True
    
    for i, tc in enumerate(test_cases, 1):
        nums1, nums2, expected, desc = tc["nums1"], tc["nums2"], tc["expected"], tc["desc"]
        
        result = findMedianSortedArrays(nums1, nums2)
        passed = abs(result - expected) < 1e-9  # Floating point comparison
        
        status = "✓ PASS" if passed else "✗ FAIL"
        all_passed = all_passed and passed
        
        print(f"\nTest {i}: {desc}")
        print(f"  nums1 = {nums1}")
        print(f"  nums2 = {nums2}")
        print(f"  Expected: {expected}")
        print(f"  Got:      {result}")
        print(f"  {status}")
    
    print("\n" + "=" * 60)
    if all_passed:
        print("All tests PASSED ✓")
    else:
        print("Some tests FAILED ✗")
    print("=" * 60)
    
    return all_passed


if __name__ == "__main__":
    run_tests()
