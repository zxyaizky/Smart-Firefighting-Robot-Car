# B / PH1P35: use with the reduced local-effect top (median/Sobel/cartoon off).
# Source after commit_param -step place/route; GUI phy_1 does this automatically.
# Reducing logic is essential: the full-effect top did not meet the 20-min target.
# No pin/clock/CDC exception is added. Final setup and hold checks remain required.
set_param flow speedup_effort 3
set_param place pr_strategy 1
set_param route effort normal
set_param route fix_hold on

# A physical constraint cannot guarantee a wall-clock routing deadline.
# build_candidate.py route --timeout-seconds 1200 enforces a hard test limit;
# a timeout is a failed/incomplete route, never a successful implementation.
