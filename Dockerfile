FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc g++ make ruby git ca-certificates \
    libsecp256k1-dev libpq-dev libonig-dev libssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY my-config.rb .
COPY Makefile .

COPY fix-paramformat.patch .
RUN make \
    && cd mruby/build/repos/host/mruby-postgresql && git apply /build/fix-paramformat.patch && cd /build \
    && make

COPY nostr-relay.rb .
COPY public/ public/

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libsecp256k1-1 libpq5 libonig5 libssl3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /build/mruby/build/host/bin/mruby /usr/local/bin/mruby
COPY --from=builder /build/nostr-relay.rb .
COPY --from=builder /build/public/ public/

EXPOSE 8080

CMD ["mruby", "nostr-relay.rb"]
