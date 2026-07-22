#!/bin/sh
# Locate the DavMail jar (zip layout varies by version) and run headless server mode.
set -e

: "${EXCHANGE_EWS_URL:?EXCHANGE_EWS_URL is required (set EXCHANGE_HOST in .env)}"

# The shipped properties file carries a placeholder, not a real host — the EWS URL
# is injected here at start so it never lives in git.
CONF=/tmp/davmail.properties
sed "s|__EXCHANGE_EWS_URL__|${EXCHANGE_EWS_URL}|" /etc/davmail/davmail.properties > "$CONF"

JAR=$(find /opt/davmail -name davmail.jar | head -1)
DIR=$(dirname "$JAR")
exec java -Djava.awt.headless=true -cp "$JAR:$DIR/lib/*" \
  davmail.DavGateway "$CONF"
