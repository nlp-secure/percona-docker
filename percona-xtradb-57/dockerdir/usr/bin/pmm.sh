#!/bin/bash

pmm-admin config -c "$DATADIR/pmm.yaml" --server pmm-server --server-insecure-ssl --server-user "$PMM_CLIENT_USER" --server-password "$PMM_CLIENT_PASSWORD"
pmm-admin add mysql:metrics -c "$DATADIR/pmm.yaml" --user="$MYSQL_MONITOR_USERNAME" --password="$MYSQL_MONITOR_PASSWORD"
pmm-admin add mysql:queries -c "$DATADIR/pmm.yaml" --user="$MYSQL_MONITOR_USERNAME" --passowrd="$MYSQL_MONITOR_PASSWORD"

exec /usr/bin/pidproxy /usr/sbin/pmm-admin start --all