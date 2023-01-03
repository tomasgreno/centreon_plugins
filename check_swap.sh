#!/bin/bash

# This script checks swap space activity.
# It outputs number of kilobytes moved from swap space to physical (swapin)
# and from physical to swap space (swapoff) in the last DURATION seconds.
#
# Usage: "check_swap.sh -d DURATION(INTEGER) -w WARNING(INTEGER) -c CRITICAL(INTEGER) -a WARNING(INTEGER) -b CRITICAL(INTEGER)"
# Usage: "check_swap.sh -d 10 -w 1000 -c 2000 -a 5000 -b 10000"
#
# WARNING and CRIT are measured in kB/duration
#
# Nagios Status
#
# 0 = OK
# 1 = WARNING
# 2 = CRITICAL
# 3 = UNKNOWN
#

## USAGE MESSAGE
usage() {
cat << EOF
usage: $0 options

This script runs a swap space activity test on the machine.

OPTIONS:
   -h Show this message
   -d Duration in seconds to monitor for swap activity (mandatory)
   -w Warning Level for Swapin (mandatory)
   -c Critical Level for Swapin (mandatory)
   -a Warning Level for Swapout (optional - set only if you want different threshold for swapout)
   -b Critical Level for Swapout (optional - set only if you want different threshold for swapout)

Warning Level should be lower than Critical Level!

EOF
}

SWAP_IN_WARN=
SWAP_IN_CRIT=
SWAP_OUT_WARN=
SWAP_OUT_CRIT=
#SWAPIN_ACTIVITY=
#SWAPOUT_ACTIVITY=
SWAP_ACTIVITY=

## FETCH ARGUMENTS
while getopts "hd:w:c:a:b:" OPTION; do
        case "${OPTION}" in
                h)
                        usage
                        exit 3
                        ;;
                                d)
                                                DURATION=${OPTARG}
                                                ;;
                w)
                        SWAP_IN_WARN=${OPTARG}
                        ;;
                c)
                        SWAP_IN_CRIT=${OPTARG}
                        ;;
                a)
                        SWAP_OUT_WARN=${OPTARG}
                        ;;
                b)
                        SWAP_OUT_CRIT=${OPTARG}
                        ;;
                                ?)
                        usage
                        exit 3
                        ;;
        esac
done

if [ -z ${SWAP_OUT_WARN} ] ; then
                SWAP_OUT_WARN=${SWAP_IN_WARN}
fi

if [ -z ${SWAP_OUT_CRIT} ] ; then
                SWAP_OUT_CRIT=${SWAP_IN_CRIT}
fi

## CHECK FOR EMPTY ARGUMENTS AND WARNING > CRITICAL
if [ -z ${DURATION} ] ||  [ -z ${SWAP_IN_WARN} ] || [ -z ${SWAP_IN_CRIT} ] ||  [ -z ${SWAP_OUT_WARN} ] || [ -z ${SWAP_OUT_CRIT} ] || [ ${SWAP_IN_WARN} -gt ${SWAP_IN_CRIT} ] || [ ${SWAP_OUT_WARN} -gt ${SWAP_OUT_CRIT} ] ; then
                usage
                exit 3
fi

## GET SWAP ACTIVITY INFO FROM VMSTAT "SI" AND "SO" COLUMNS AS TWO VARIABLES
## TO USE THIS, REPLACE STRINGS "SWAP_ACTIVITY[0]" WITH "SWAPIN_ACTIVITY" AND "SWAP_ACTIVITY[1]" WITH "SWAPOUT_ACTIVITY" UNTIL THE END OF THE SCRIPT AND UNCOMMENT LINES 46-47, 95-96 AND COMMENT LINE 99
#SWAPIN_ACTIVITY=$(vmstat ${DURATION} 2 | tail -n 1 | awk '{print $7}')
#SWAPOUT_ACTIVITY=$(vmstat ${DURATION} 2 | tail -n 1 | awk '{print $8}')

## GET SWAP ACTIVITY INFO FROM VMSTAT "SI" AND "SO" COLUMNS AS AN ARRAY
mapfile -t SWAP_ACTIVITY < <( vmstat ${DURATION} 2 | tail -n 1 | awk '{print $7"\n"$8}' )

## CHECK SWAPPING ON MACHINE
if [ ${SWAP_ACTIVITY[0]} -lt ${SWAP_IN_WARN} ] && [ ${SWAP_ACTIVITY[1]} -lt ${SWAP_OUT_WARN} ]; then
        ## SWAP ACTIVITY IS OK
                printf "OK! Swapin / Swapout activity in last ${DURATION} second(s): ${SWAP_ACTIVITY[0]}kB / ${SWAP_ACTIVITY[1]}kB\n\'swapin_size\'=${SWAP_ACTIVITY[0]}kB;${SWAP_IN_WARN};${SWAP_IN_CRIT}\n\'swapout_size\'=${SWAP_ACTIVITY[1]}kB;${SWAP_OUT_WARN};${SWAP_OUT_CRIT}\n| swapin_size=${SWAP_ACTIVITY[0]} swapout_size=${SWAP_ACTIVITY[1]}\n"
        exit 0
elif [ ${SWAP_ACTIVITY[0]} -gt ${SWAP_IN_WARN} ] && [ ${SWAP_ACTIVITY[0]} -lt ${SWAP_IN_CRIT} ] || [ ${SWAP_ACTIVITY[0]} -eq ${SWAP_IN_WARN} ] || [ ${SWAP_ACTIVITY[1]} -gt ${SWAP_OUT_WARN} ] && [ ${SWAP_ACTIVITY[1]} -lt ${SWAP_OUT_CRIT} ] || [ ${SWAP_ACTIVITY[1]} -eq ${SWAP_OUT_WARN} ]; then
        ## SWAP ACTIVITY IS IN WARNING STATE
                printf "WARNING! Swapin / Swapout activity in last ${DURATION} second(s): ${SWAP_ACTIVITY[0]}kB / ${SWAP_ACTIVITY[1]}kB\n\'swapin_size\'=${SWAP_ACTIVITY[0]}kB;${SWAP_IN_WARN};${SWAP_IN_CRIT}\n\'swapout_size\'=${SWAP_ACTIVITY[1]}kB;${SWAP_OUT_WARN};${SWAP_OUT_CRIT}\n| swapin_size=${SWAP_ACTIVITY[0]} swapout_size=${SWAP_ACTIVITY[1]}\n"
        exit 1
elif [ ${SWAP_ACTIVITY[0]} -gt ${SWAP_IN_CRIT} ] || [ ${SWAP_ACTIVITY[0]} -eq ${SWAP_IN_CRIT} ] || [ ${SWAP_ACTIVITY[1]} -gt ${SWAP_OUT_CRIT} ] || [ ${SWAP_ACTIVITY[1]} -eq ${SWAP_OUT_CRIT} ]; then
        ## SWAP ACTIVITY IS IN CRITICAL STATE
                printf "CRITICAL! Swapin / Swapout activity in last ${DURATION} second(s): ${SWAP_ACTIVITY[0]}kB / ${SWAP_ACTIVITY[1]}kB\n\'swapin_size\'=${SWAP_ACTIVITY[0]}kB;${SWAP_IN_WARN};${SWAP_IN_CRIT}\n\'swapout_size\'=${SWAP_ACTIVITY[1]}kB;${SWAP_OUT_WARN};${SWAP_OUT_CRIT}\n| swapin_size=${SWAP_ACTIVITY[0]} swapout_size=${SWAP_ACTIVITY[1]}\n"
        exit 2
else
        ## SHOULD NEVER REACH THIS POINT
                usage
                exit 3
fi
