# DavMail EWS->CalDAV gateway, headless server mode.
# We fetch DavMail's own platform-independent Java zip (pure Java, arch-independent,
# needs no JavaFX) instead of the Debian package, which hard-depends on libopenjfx
# (missing on arm64). Works identically when built for amd64 on the deploy VM.
FROM debian:bookworm-slim

ARG DAVMAIL_URL=https://downloads.sourceforge.net/project/davmail/davmail/6.8.1/davmail-6.8.1-4210.zip

RUN apt-get update \
 && apt-get install -y --no-install-recommends default-jre-headless ca-certificates curl unzip \
 && curl -fsSL --retry 3 -o /tmp/davmail.zip "$DAVMAIL_URL" \
 && mkdir -p /opt/davmail && unzip -q /tmp/davmail.zip -d /opt/davmail \
 && rm /tmp/davmail.zip \
 && apt-get purge -y unzip curl && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*

COPY davmail.properties /etc/davmail/davmail.properties
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# CalDAV
EXPOSE 1080

CMD ["/entrypoint.sh"]
