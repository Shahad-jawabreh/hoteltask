set -euo pipefail

# --- CONFIG ---
PRIMARY_HOST="mysql-primary"
SECONDARY_HOST="mysql-secondary"
MYSQL_USER="root"
MYSQL_PASS="${MYSQL_ROOT_PASSWORD:-rootpassword}"   # override via env if needed
CHECK_INTERVAL=5
FAIL_THRESHOLD=3
PROMOTED_FLAG="/var/run/mysql_promoted.flag"
# --------------

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# Check if a MySQL server responds
is_up() {
  mysqladmin ping -h"$1" -u"$MYSQL_USER" -p"$MYSQL_PASS" --connect-timeout=3 --silent > /dev/null 2>&1
}

# Run SQL command on a given host
run_on() {
  local host="$1"; shift
  mysql -h"$host" -u"$MYSQL_USER" -p"$MYSQL_PASS" -e "$*"
}

# # Promote the replica to writable
# promote_secondary() {
#   log "PROMOTION: Starting promotion of $SECONDARY_HOST"

#   log "Stopping replication threads on $SECONDARY_HOST"
#   run_on "$SECONDARY_HOST" "STOP REPLICA;"

#   log "Resetting replication metadata on $SECONDARY_HOST"
#   run_on "$SECONDARY_HOST" "RESET REPLICA ALL;"

#   log "Disabling read-only mode on $SECONDARY_HOST"
#   run_on "$SECONDARY_HOST" "SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;"

#   touch "$PROMOTED_FLAG"

#   log "PROMOTION: $SECONDARY_HOST is now writable (promoted)."
#   log "NOTE: You must reconfigure the old primary manually if it comes back."
# }

promote_secondary() {
  log "PROMOTION: Starting promotion of $SECONDARY_HOST"

  log "Stopping replication threads on $SECONDARY_HOST"
  run_on "$SECONDARY_HOST" "STOP REPLICA;"

  log "Resetting replication metadata on $SECONDARY_HOST"
  run_on "$SECONDARY_HOST" "RESET REPLICA ALL;"

  log "Disabling read-only mode on $SECONDARY_HOST"
  run_on "$SECONDARY_HOST" "SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;"

  log "Creating users and grants on promoted secondary"
  run_on "$SECONDARY_HOST" "CREATE USER IF NOT EXISTS 'myuser'@'%' IDENTIFIED BY 'mypassword';
                             GRANT ALL PRIVILEGES ON hoteldb.* TO 'myuser'@'%';
                             FLUSH PRIVILEGES;"

  touch "$PROMOTED_FLAG"
  log "PROMOTION: $SECONDARY_HOST is now writable (promoted)."
  log "NOTE: You must reconfigure the old primary manually if it comes back."
}


# --- MAIN LOOP ---
fail_count=0
log "Watchdog started (check every ${CHECK_INTERVAL}s, threshold ${FAIL_THRESHOLD})"

while true; do
  if is_up "$PRIMARY_HOST"; then
    fail_count=0
    if [ -f "$PROMOTED_FLAG" ]; then
      log "Primary is back but $SECONDARY_HOST was promoted. Manual intervention required."
    fi
  else
    fail_count=$((fail_count+1))
    log "Primary unreachable (count=$fail_count/$FAIL_THRESHOLD)"
    if [ "$fail_count" -ge "$FAIL_THRESHOLD" ] && [ ! -f "$PROMOTED_FLAG" ]; then
      log "Threshold reached → promoting $SECONDARY_HOST"
      promote_secondary
    fi
  fi
  sleep "$CHECK_INTERVAL"
done
