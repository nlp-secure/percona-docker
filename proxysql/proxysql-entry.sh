#!/bin/bash

chown -R 1001 /var/lib/proxysql

gosu $GOSU_USER /usr/bin/add_cluster_nodes.sh

gosu $GOSU_USER /usr/bin/proxysql --initial -f -c /etc/proxysql.cnf