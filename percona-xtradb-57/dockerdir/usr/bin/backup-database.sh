#!/bin/bash

set -x
set -e

BACKUP_BASE=/tmp/db_backup
EXTRA_XTRABACKUP_OPTIONS="--compress --encrypt=$BACKUP_ENCRYPTION_ALGORITHM --encrypt-key=$BACKUP_ENCRYPTION_KEY"
BUCKET="$DATABASE_S3_BUCKET"
CONNECT_TIMEOUT=10
MYSQL_CMDLINE="mysql -nNE --connect-timeout=${CONNECT_TIMEOUT} --user=${MYSQL_MONITOR_USERNAME} --password=${MYSQL_MONITOR_PASSWORD}"

wsrep_status() {
    $MYSQL_CMDLINE -e "SHOW GLOBAL STATUS LIKE 'wsrep_%';" \
        | grep -A 1 -E 'wsrep_local_state$|wsrep_cluster_status$' \
        | sed -n -e '2p'  -e '5p' | tr '\n' ' '
}

is_read_only() {
    READ_ONLY=$($MYSQL_CMDLINE -e "SHOW GLOBAL VARIABLES LIKE 'read_only';" \
        | tail -1)

    echo [ "$READ_ONLY" == "ON" ]
}

wsrep_index() {
    $MYSQL_CMDLINE -e "SHOW GLOBAL STATUS LIKE 'wsrep_local_index';" \
        | grep -A 1 -E '^wsrep_local_index$' \
        | sed -n -e '2p' -e '5p' | tr '\n' ' '
}

check_status() {
    WSREP_STATUS=$(wsrep_status)
    READ_ONLY=$(is_read_only)
    WSREP_INDEX=$(wsrep_index)

    echo "WSREP_STATUS: $WSREP_STATUS."
    echo "READ_ONLY: $READ_ONLY."
    echo "WSREP_INDEX: $WSREP_INDEX."

    if [[ ! ${WSREP_STATUS[1]} == 'Primary' || ! ( ${WSREP_STATUS[0]} -eq 4 || ${WSREP_STATUS[0]} -eq 2 ) ]]; then
        return 0
    fi

    if [ $READ_ONLY ]; then
        return 0
    fi

    return 1
}

remove_incremental_backups() {
    rm -rf "$BACKUP_BASE"/incremental-*
}

remove_base_backup() {
    rm -rf "$BACKUP_BASE/base"
}

upload_backup() {
    BUCKET_PATH="$(hostname)-$(date +%F)"

    TEMP_PATH=$(mktemp -d)
    UPLOAD_PATH="$TEMP_PATH/$BUCKET_PATH"
    mkdir -p "$UPLOAD_PATH"
    cp -a "$1" "$UPLOAD_PATH/"
    s3put -b "$BUCKET" -p "$TEMP_PATH" "$UPLOAD_PATH"
    rm -rf "$TEMP_PATH"
}

incremental_backup() {
    if [ ! -f "$BACKUP_BASE/incremental-index" ]; then
        INCREMENTAL_BASEDIR="$BACKUP_BASE/base"
        INCREMENTAL_INDEX="01"
    else
        LAST_INCREMENTAL_INDEX=$(cat "$BACKUP_BASE/incremental-index")
        INCREMENTAL_BASEDIR="$BACKUP_BASE/incremental-$LAST_INCREMENTAL_INDEX"
        INCREMENTAL_INDEX=$(printf "%02d" $((1+10#$LAST_INCREMENTAL_INDEX)))
    fi

    if [ ! -f "$INCREMENTAL_BASEDIR/xtrabackup_checkpoints" ]; then
        remove_incremental_backups
        INCREMENTAL_BASEDIR="$BACKUP_BASE/base"
        INCREMENTAL_INDEX="01"
    fi

    TARGET_DIR="$BACKUP_BASE/incremental-$INCREMENTAL_INDEX"
    TARGET_ARGUMENT="--target-dir=$BACKUP_BASE/incremental-$INCREMENTAL_INDEX"
    INCREMENTAL_BASE_ARGUMENT="--incremental-basedir=$INCREMENTAL_BASEDIR"

    if [ -d "$TARGET_DIR" ]; then
        rm -rf "$TARGET_DIR"
    fi

    mkdir -p "$TARGET_DIR"

    xtrabackup $EXTRA_XTRABACKUP_OPTIONS --backup "$TARGET_ARGUMENT" "$INCREMENTAL_BASE_ARGUMENT"
    echo "$INCREMENTAL_INDEX" > "$BACKUP_BASE/incremental-index"

    upload_backup "$TARGET_DIR"
}

base_backup() {
    TARGET_DIR="$BACKUP_BASE/base"
    TARGET_ARGUMENT="--target-dir=$TARGET_DIR"

    mkdir -p "$TARGET_DIR"

    xtrabackup $EXTRA_XTRABACKUP_OPTIONS --backup "$TARGET_ARGUMENT"

    upload_backup "$TARGET_DIR"
}

if [ "$1" == "--full" ]; then
    if check_status; then
        remove_base_backup
        remove_incremental_backups
        base_backup
    fi
elif [ "$1" == "--incremental" ]; then
    if check_status; then
        incremental_backup
    fi
else
    echo "Required argument is either --full or --incremental."
fi