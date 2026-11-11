# mruby Nostr Relay

A lightweight, single-binary Nostr relay implementation for mruby.

## NIP Support

This relay supports the following Nostr Implementation Possibilities (NIPs):

- **NIP-01**: Basic protocol flow
- **NIP-09**: Event deletion (kind 5)
- **NIP-11**: Relay Information Document
- **NIP-12**: Generic tag queries (#e, #p, etc)
- **NIP-13**: Proof of Work (minimum difficulty via `MIN_POW_DIFFICULTY`)
- **NIP-16**: Event Treatment (ephemeral events 20000-29999)
- **NIP-20**: Command results (OK messages)
- **NIP-26**: Delegated Event Signing (`delegation` tag verification)
- **NIP-33**: Parameterized Replaceable Events (kind 30000-39999)
- **NIP-70**: Protected Events (reject events with `["-"]` tag)

## Usage

```bash
$DATABASE_URL = "host=localhost dbname=nostr"
make run
```

The relay will start on `ws://localhost:8080` by default.

Set `MIN_POW_DIFFICULTY` to require a minimum NIP-13 proof of work difficulty
(leading zero bits of the event id) for published events. The default is `0`
(disabled).

## Installation

```bash
git clone <repository-url>
cd mruby-nostr-relay

make
```

## Requirements

- GCC / G++
- Ruby (for mruby build system)
- PostgreSQL
- libsecp256k1
- libonig (Oniguruma)
- libssl / libcrypto (OpenSSL)

### Debian/Ubuntu

```bash
sudo apt-get install gcc g++ make ruby git \
  libsecp256k1-dev libpq-dev libonig-dev libssl-dev
```

## Docker

```bash
docker build -t mruby-nostr-relay .
docker run -p 8080:8080 mruby-nostr-relay
```

## License

MIT License

## Author

Yasuhiro Matsumoto (a.k.a. mattn)
