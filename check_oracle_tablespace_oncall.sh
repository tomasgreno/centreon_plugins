#!/bin/bash

# ./check_oracle_tablespace_oncall.sh user password 192.168.1.1 1521 nwcd SYSTEM
# ./check_oracle_tablespace_oncall.sh user password 192.168.1.1 1521 nwcd SYSTEM 4096

USER=${1}
PASS=${2}
IP=${3}
PORT=${4}
SERVICE=${5}
TBS=${6}
CRITFREE=${7}
WARNREM=5
IGNOREREM=28

if [[ -z ${USER} ]] ; then
    echo ""
    echo "Manual for check_oracle_tablespace_oncall.sh"
    echo ""
    echo "Author: Tomas Greno"
    echo "Email: tomas.greno[at]gmail[dot]com"
    echo ""
    echo "Nagios/Centreon check."
	echo ""
	echo "Version 1.7 (2022-10-24)"
    echo ""
    echo "Returns free space available in a tablespace including autoextend."
    echo "Additionally provides estimated days until tablespace gets full."
    echo "Oncall aware - free space remaining value triggers critical immediatelly - no warning status"
    echo "             - days remaining until full triggers only warning - no critical"
    echo "             - set oncall notifications for critical status only, warning should not notify"
    echo ""
    echo "Parameters:"
    echo "USER     - used to connect to the database"
    echo "PASS     - used to connect to the database"
    echo "IP       - database server IP/FQDN"
    echo "PORT     - TCP/IP port of the database server"
    echo "SERVICE  - service name of the database"
    echo "TBS      - name of the tablespace"
    echo "CRITFREE - threshold for critical status of tablespace free space in MB"
	echo "         - if checking Standard Edition, there is no TBS daily growth history values stored,hence threshold for CRITFREE is required"
	echo "         - if checking Enterprise Edition, CRITFREE parameter is ignored and set to daily growth value calculated from TBS growth history"
    echo "WARNREM  - threshold for warning status of remaining time until tablespace gets full (hardcoded 5 days)"
    echo "IGNREM   - upper threshold to avoid showing too high numbers in remaining days column (hardcoded 28 days)"
    echo "EDITION  - standard/enterprise - standard (or XE) does not hold tablespace growth statistics (queried from database)"
    echo ""
    echo "Requirements:"
	echo "Poller needs to have Oracle Client or at least Oracle Instant Client installed and path to sqlplus utility added to PATH variable"
	echo ""
    echo "Example for Enterprise Edition:"
    echo "./check_oracle_tablespace_oncall.sh user password 192.168.1.1 1521 nwcd SYSTEM"
    echo ""
	echo "Example for Standard Edition:"
    echo "./check_oracle_tablespace_oncall.sh user password 192.168.1.1 1521 nwcd SYSTEM 4096"
    echo ""
    exit 3
fi

# SQL query can be run in sqlplus for debug, but backslash have to be removed from "database edition" section vDOLLARversion table name
OUTPUTROW=$(sqlplus -L -s $USER/$PASS@$IP:$PORT/$SERVICE <<END
-- clean up sqlplus output
set pagesize 0
set feedback off
set verify off
set heading off
set echo off;
define TBS='$TBS'
-- database edition
SELECT(
   CASE WHEN EXISTS(
      SELECT UPPER(BANNER) FROM V\$VERSION WHERE UPPER(BANNER) LIKE '%ENTERPRISE%')
      THEN 1
      ELSE 2
   END)
AS EDITION FROM DUAL;
-- free space in tablespace including autoextend
SELECT
    ROUND((SUM(DECODE(B.MAXEXTEND, NULL, A.BYTES/(1024*1024),
    B.MAXEXTEND*8192/(1024*1024))) - (SUM(A.BYTES)/(1024*1024) - ROUND(C.FREE/1024/1024))))
FROM
    DBA_DATA_FILES A,
    SYS.filext$ B,
    (SELECT
        D.TABLESPACE_NAME ,SUM(NVL(C.BYTES,0)) FREE
    FROM
        DBA_TABLESPACES D,
        DBA_FREE_SPACE C
    WHERE
        D.TABLESPACE_NAME = C.TABLESPACE_NAME(+)
        AND D.TABLESPACE_NAME = '&TBS'
        GROUP BY D.TABLESPACE_NAME) C
WHERE
    A.FILE_ID = B.FILE#(+)
    AND A.TABLESPACE_NAME = '&TBS'
    AND A.TABLESPACE_NAME = C.TABLESPACE_NAME
GROUP BY A.TABLESPACE_NAME, C.FREE;
-- daily growth of tablespace in last 7 days
SELECT * from (
SELECT   MAX (ROUND ( (TSU.TABLESPACE_USEDSIZE * DT.BLOCK_SIZE) / (1024 * 1024) )) CURRENT_SIZE
FROM     DBA_HIST_TBSPC_SPACE_USAGE TSU,
    DBA_HIST_TABLESPACE_STAT TS,
    DBA_HIST_SNAPSHOT SP,
    DBA_TABLESPACES DT
WHERE    TSU.TABLESPACE_ID = TS.TS#
AND      TSU.SNAP_ID = SP.SNAP_ID
AND      TS.TSNAME = DT.TABLESPACE_NAME
AND      TS.TSNAME = '&TBS'
GROUP BY TO_CHAR (SP.BEGIN_INTERVAL_TIME, 'YYYY-MM-DD')
ORDER BY TO_CHAR (SP.BEGIN_INTERVAL_TIME, 'YYYY-MM-DD') DESC
) WHERE ROWNUM<9;
END
)

if [[ "$OUTPUTROW" = ERROR* ]] ; then
    echo -n "CRITICAL: ${TBS} - Problems connecting to the database. "
	echo $OUTPUTROW
    exit 2
fi

# SQL query return values in line, parsing output to indexed array (column)
mapfile -t OUTPUTCOL < <( echo $OUTPUTROW | awk '{print $1"\n"$2"\n"$3"\n"$9}' )

# parse values to variables
EDITION=${OUTPUTCOL[0]}
FREESPACE=${OUTPUTCOL[1]}
WEEKLYGROW=$((${OUTPUTCOL[2]}-${OUTPUTCOL[3]}))
DAILYGROW=$(((${WEEKLYGROW}/7)+1))
if [[ "$DAILYGROW" = 0 ]] ; then
    DAILYGROW=1
fi
DAYSREM=$((${FREESPACE}/${DAILYGROW}))

# following IF until following ELSE:
# if edition is not enterprise (assuming standard), there is no tablespace growth history data available
if [[ "$EDITION" != 1 ]] ; then
    if (( "${FREESPACE}" <= $CRITFREE )) ; then
        echo "CRITICAL: ${TBS} - ${FREESPACE} MB of free space. Remaining days: N/A. | free_space=${FREESPACE}"
        exit 2
    elif (( "${FREESPACE}" <= ($CRITFREE + $CRITFREE) )) ; then
        echo "WARNING: ${TBS} - ${FREESPACE} MB of free space. Remaining days: N/A. | free_space=${FREESPACE}"
        exit 1
    elif (( "${FREESPACE}" > $CRITFREE )) ; then
        echo "OK: ${TBS} - ${FREESPACE} MB of free space. Remaining days: N/A. | free_space=${FREESPACE}"
        exit 0
    else
        echo "UNKNOWN: ${TBS} - Returned value of free space remaining did not meet any condition. Returned values: ${FREESPACE}, ${CRITFREE}."
        exit 3
    fi
else
# ELSE starting in a row above is for enterprise edition databases
# following 5 lines override CRITFREE variable to get CRITICAL state once there is less than 1 day to full
# this acts as a safety measure to keep CRITFREE on a value of at least 4096 because of tablespacing getting very slowly to being full
	if (( "${DAILYGROW}" > 4096 )) ; then
		CRITFREE=$DAILYGROW
	else
		CRITFREE=4096
	fi
# CRITFREE is set to true daily grow or hardcoded 4096, whichever is higher
    if (( "${FREESPACE}" <= $CRITFREE )) ; then
        if [[ -z ${OUTPUTCOL[1]} || -z ${OUTPUTCOL[2]} ]] ; then
            echo "CRITICAL: ${TBS} - ${FREESPACE} MB of free space. Unable to get tablespace growth statistics. | free_space=${FREESPACE}"
            exit 2
        else
            if (( "$DAILYGROW" < 256 && "$DAYSREM" > $IGNOREREM )) ; then
                echo "WARNING: ${TBS} - ${FREESPACE} MB of free space. More than $IGNOREREM days until tablespace gets full ($DAYSREM days), but triggered by absolute value of free space. Daily growth is ${DAILYGROW} MB. | free_space=${FREESPACE} daily_grow=${DAILYGROW} days_to_full=$DAYSREM"
                exit 1
            else
                echo "CRITICAL: ${TBS} - ${FREESPACE} MB of free space. $DAYSREM days until tablespace gets full. Daily growth is ${DAILYGROW} MB. | free_space=${FREESPACE} daily_grow=${DAILYGROW} days_to_full=$DAYSREM"
                exit 2
            fi
        fi
    elif (( "${FREESPACE}" > $CRITFREE )) ; then
        if [[ -z ${OUTPUTCOL[1]} || -z ${OUTPUTCOL[2]} ]] ; then
            echo "CRITICAL: ${TBS} - ${FREESPACE} MB of free space. Unable to get tablespace growth statistics. | free_space=${FREESPACE}"
            exit 2
        elif (( "$DAYSREM" < 0 )) ; then
            echo "OK: ${TBS} - ${FREESPACE} MB of free space. Tablespace has decreasing size trend (More than $IGNOREREM days until full). Daily growth is ${DAILYGROW} MB. | free_space=${FREESPACE} daily_grow=${DAILYGROW} days_to_full=$DAYSREM"
            exit 0
        elif (( "$DAYSREM" <= $WARNREM )) ; then
            echo "WARNING: ${TBS} - ${FREESPACE} MB of free space. $DAYSREM days until tablespace gets full. Daily growth is ${DAILYGROW} MB. | free_space=${FREESPACE} daily_grow=${DAILYGROW} days_to_full=$DAYSREM"
            exit 1
        elif (( "$DAYSREM" > $WARNREM && "$DAYSREM" <= $IGNOREREM )) ; then
            echo "OK: ${TBS} - ${FREESPACE} MB of free space. $DAYSREM days until tablespace gets full. Daily growth is ${DAILYGROW} MB. | free_space=${FREESPACE} daily_grow=${DAILYGROW} days_to_full=$DAYSREM"
            exit 0
        elif (( "$DAYSREM" > $WARNREM && "$DAYSREM" > $IGNOREREM )) ; then
            echo "OK: ${TBS} - ${FREESPACE} MB of free space. More than $IGNOREREM days until tablespace gets full ($DAYSREM days). Daily growth is ${DAILYGROW} MB. | free_space=${FREESPACE} daily_grow=${DAILYGROW} days_to_full=$DAYSREM"
            exit 0
        else
            echo "UNKNOWN: ${TBS} - Returned value of free space remaining or days remaining until full did not meet any condition. Returned values: ${FREESPACE}, ${DAILYGROW}, ${DAYSREM}."
            exit 3
        fi
    else
        echo "UNKNOWN: ${TBS} - Returned value of free space remaining did not meet any condition. Returned value: ${FREESPACE}."
        exit 3
    fi
fi
