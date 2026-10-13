-- Runs once on the bootstrap node (galera1) via /docker-entrypoint-initdb.d.
-- Creates the SST user that mariabackup uses to stream a full snapshot to joiners.
-- It is created on the donor and then replicated to every joiner via the SST itself.
CREATE USER IF NOT EXISTS 'mariabackup'@'localhost' IDENTIFIED BY 'sstpw123';
GRANT RELOAD, PROCESS, LOCK TABLES, BINLOG MONITOR ON *.* TO 'mariabackup'@'localhost';
FLUSH PRIVILEGES;
