# Apache Fineract (pinned release) built from the ASF binary distribution, because no
# apache/fineract image is published for this release. The download is verified against the
# SHA-512 published by the Apache Software Foundation. The build fails if it does not match.
#
# NOT YET RUN: written while Docker Desktop could not start on the author's machine (WSL2 not
# installed). Verify with `docker compose -f parity/docker-compose.yml build` before relying on it.
ARG FINERACT_VERSION=1.16.1

FROM alpine:3.20 AS fetch
ARG FINERACT_VERSION
RUN apk add --no-cache curl
WORKDIR /dist
RUN set -eu; \
    base="https://downloads.apache.org/fineract/${FINERACT_VERSION}"; \
    f="apache-fineract-bin-${FINERACT_VERSION}.tar.gz"; \
    curl -fsSL -o "$f" "$base/$f" || curl -fsSL -o "$f" "https://archive.apache.org/dist/fineract/${FINERACT_VERSION}/$f"; \
    curl -fsSL -o "$f.sha512" "$base/$f.sha512" || curl -fsSL -o "$f.sha512" "https://archive.apache.org/dist/fineract/${FINERACT_VERSION}/$f.sha512"; \
    expected="$(sed 's/^[^:]*://' "$f.sha512" | tr -d ' \r\n' | tr 'A-F' 'a-f')"; \
    actual="$(sha512sum "$f" | cut -d' ' -f1)"; \
    [ "$expected" = "$actual" ] || { echo "SHA-512 mismatch for $f" >&2; exit 1; }; \
    mkdir /fineract && tar -xzf "$f" -C /fineract

FROM eclipse-temurin:25-jre
RUN useradd --system --uid 1000 --create-home fineract
COPY --from=fetch /fineract /opt/fineract
WORKDIR /opt/fineract
USER fineract
EXPOSE 8443
ARG FINERACT_VERSION
ENV FINERACT_VERSION=${FINERACT_VERSION}
# The jar's location inside the distribution is resolved at start-up, so a layout change in a
# future release fails loudly here rather than silently. (The distribution also holds javadoc,
# sources and client jars, so the exact file name is matched.)
CMD ["sh", "-c", "exec java -jar \"$(find /opt/fineract -name \"fineract-provider-${FINERACT_VERSION}.jar\" | head -n 1)\""]
