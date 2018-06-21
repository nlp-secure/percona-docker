#!/bin/bash
set -e

USER_ID=$(id -u)

# if command starts with an option, prepend mysqld
if [ "${1:0:1}" = '-' ]; then
	CMDARG="$@"
fi

if [ -z "${POD_NAMESPACE}" ]; then
	echo >&2 'Error:  You need to specify POD_NAMESPACE'
	exit 1
fi

if [[ -n "$TIMEZONE" && -f "/usr/share/zoneinfo/$TIMEZONE" ]]; then
	cp "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
	dpkg-reconfigure tzdata
fi

# We need this for backup setup, so it's bumped up to here
if [ -z "${MYSQL_ROOT_PASSWORD}" -a -z "$MYSQL_ROOT_PASSWORD_FILE" ]; then
    echo >&2 'error: database is uninitialized and password option is not specified '
    echo >&2 '  You need to specify one of MYSQL_ROOT_PASSWORD, MYSQL_ROOT_PASSWORD_FILE,  MYSQL_ALLOW_EMPTY_PASSWORD or MYSQL_RANDOM_ROOT_PASSWORD'
    exit 1
fi

if [ ! -z "$MYSQL_ROOT_PASSWORD_FILE" -a -z "$MYSQL_ROOT_PASSWORD" ]; then
  MYSQL_ROOT_PASSWORD=$(cat $MYSQL_ROOT_PASSWORD_FILE)
fi

if [[ -n "$AWS_ACCESS_KEY_ID" && -n "$AWS_SECRET_ACCESS_KEY" ]]; then
	mkdir -p ~mysql

	echo '[Credentials]' > ~mysql/.boto
	echo "aws_access_key_id" >> ~mysql/.boto
	echo "aws_secret_access_key=$AWS_SECRET_ACCESS_KEY" >> ~mysql/.boto

	echo '[client]' > ~mysql/.my.cnf
	echo 'user=xtrabackup' >> ~mysql/.my.cnf
	echo "password=\"$XTRABACKUP_PASSWORD\"" >> ~mysql/.my.cnf

	chown -R mysql ~mysql
	chmod 0600 ~mysql/.boto ~mysql/.my.cnf
fi

# Is running in Kubernetes/OpenShift, so find all other pods
# belonging to the namespace
echo "Percona XtraDB Cluster: Finding and configuring peers"
kubectl get pods -n "${POD_NAMESPACE}" -l app="${POD_LABEL_APP}" -o=jsonpath='{range .items[*]}{.status.podIP}{"\n"}' \
    | /usr/bin/configure-pxc.sh

# Get config
DATADIR="$("mysqld" --verbose --wsrep_provider= --help 2>/dev/null | awk '$1 == "datadir" { print $2; exit }')"

mv /usr/bin/clustercheck.sh /tmp/

# This seems to be a consistent issue, even with nothing else going on.
# I don't currently have a good explanation for it, but the fix is straightforwards
# and safe enough that I don't think it deserves a lot of investigation at this
# point.
chown -R 1001 "$DATADIR"

# if we have CLUSTER_JOIN - then we do not need to perform datadir initialize
# the data will be copied from another node
if [ -f "/tmp/cluster_addr.txt" ]; then
	WSREP_CLUSTER_ADDRESS=`cat /tmp/cluster_addr.txt`
	echo "Cluster address set to: $WSREP_CLUSTER_ADDRESS"
fi

if [ -z "$WSREP_CLUSTER_ADDRESS" ]; then
	if [ ! -e "${DATADIR}/mysql" ]; then
		mkdir -p "${DATADIR}"
		chown -R mysql "${DATADIR}"

		echo "Running --initialize-insecure on ${DATADIR}"

		mysqld --initialize-insecure --user=mysql
		echo 'Finished --initialize-insecure'

		mysqld --user=mysql --datadir="${DATADIR}" --skip-networking &
		pid="$!"

		mysql=( mysql --protocol=socket -uroot )

		for i in {30..0}; do
			if echo 'SELECT 1' | "${mysql[@]}" &> /dev/null; then
				break
			fi
			echo 'MySQL init process in progress...'
			sleep 1
		done
		if [ "$i" = 0 ]; then
			echo >&2 'MySQL init process failed.'
			exit 1
		fi

		# sed is for https://bugs.mysql.com/bug.php?id=20545
		mysql_tzinfo_to_sql /usr/share/zoneinfo | sed 's/Local time zone must be set--see zic manual page/FCTY/' | "${mysql[@]}" mysql

		"${mysql[@]}" <<-EOSQL
			-- What's done in this file shouldn't be replicated
			--  or products like mysql-fabric won't work
			SET @@SESSION.SQL_LOG_BIN=0;
			CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
			GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION ;
			ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
			CREATE USER 'xtrabackup'@'localhost' IDENTIFIED BY '$XTRABACKUP_PASSWORD';
			GRANT RELOAD,PROCESS,LOCK TABLES,REPLICATION CLIENT ON *.* TO 'xtrabackup'@'localhost';
			GRANT REPLICATION CLIENT ON *.* TO '${MYSQL_MONITOR_USERNAME}'@'%' IDENTIFIED BY '${MYSQL_MONITOR_PASSWORD}';
			GRANT PROCESS ON *.* TO '${MYSQL_MONITOR_USERNAME}'@localhost IDENTIFIED BY '${MYSQL_MONITOR_PASSWORD}';
			DROP DATABASE IF EXISTS test ;
			FLUSH PRIVILEGES ;
		EOSQL

		mysql+=( -p"${MYSQL_ROOT_PASSWORD}" )

		if [ "$MYSQL_DATABASE" ]; then
			echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" | "${mysql[@]}"
			mysql+=( "$MYSQL_DATABASE" )
		fi

		if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
			echo "CREATE USER '"$MYSQL_USER"'@'%' IDENTIFIED BY '"$MYSQL_PASSWORD"' ;" | "${mysql[@]}"

			if [ "$MYSQL_DATABASE" ]; then
				echo "GRANT ALL ON \`"$MYSQL_DATABASE"\`.* TO '"$MYSQL_USER"'@'%' ;" | "${mysql[@]}"
			fi

			echo 'FLUSH PRIVILEGES ;' | "${mysql[@]}"
		fi

		if ! kill -s TERM "${pid}" || ! wait "${pid}"; then
			echo >&2 'MySQL init process failed.'
			exit 1
		fi

		echo
		echo 'MySQL init process done. Ready for start up.'
		echo
	fi
fi

# Relocate stderr/stdout on our child processes' logs to our process's stdout/stderr
rm -f /var/log/cron

# Allow writing to stdout and stderr for *this* process
chmod 0777 /proc/$$/fd/1 /proc/$$/fd/2

# Link them up to logs for child processes
ln -sf /proc/$$/fd/1 /var/log/cron

mv /tmp/clustercheck.sh /usr/bin/

sed -i'' -e "s#command=/usr/sbin/mysqld.*#command=/usr/sbin/mysqld --user=mysql --wsrep_sst_auth=\"xtrabackup:${XTRABACKUP_PASSWORD}\" ${CMDARG}#g" /etc/supervisord.conf

supervisord -c /etc/supervisord.conf