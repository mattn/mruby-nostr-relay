#!/usr/bin/env mruby
# nostr-relay.rb - Standalone Nostr Relay Server for mruby
# Uses: mruby-socket, mruby-poll, mruby-phr, mruby-wslay, mruby-json, mruby-digest, mruby-postgresql

RELAY_HOST = "0.0.0.0"
RELAY_PORT = 8080
MAX_HTTP_REQUEST_SIZE = 16384
MAX_SUBSCRIPTIONS_PER_CLIENT = 32

# --- Storage ---
$subscriptions = {}  # ws_context => { sub_id => [filters...] }
$clients = {}        # socket => client hash
$ws_clients = {}     # ws_context => client hash
$db = nil            # PostgreSQL connection

# --- Logging ---
def log(msg)
  $stderr.puts "[#{Time.now}] #{msg}"
end

# --- Database ---
def db_connect
  database_url = ENV['DATABASE_URL']
  return unless database_url
  $db = Pq.new(database_url)

  $db.exec <<~SQL
    CREATE OR REPLACE FUNCTION tags_to_tagvalues(jsonb) RETURNS text[]
    AS 'SELECT array_agg(t->>1) FROM (SELECT jsonb_array_elements($1) AS t)s WHERE length(t->>0) = 1;'
    LANGUAGE SQL
    IMMUTABLE
    RETURNS NULL ON NULL INPUT;
  SQL

  $db.exec <<~SQL
    CREATE TABLE IF NOT EXISTS event (
      id text NOT NULL,
      pubkey text NOT NULL,
      created_at integer NOT NULL,
      kind integer NOT NULL,
      tags jsonb NOT NULL,
      content text NOT NULL,
      sig text NOT NULL,
      tagvalues text[] GENERATED ALWAYS AS (tags_to_tagvalues(tags)) STORED
    );
  SQL

  $db.exec "CREATE UNIQUE INDEX IF NOT EXISTS ididx ON event USING btree (id text_pattern_ops);"
  $db.exec "CREATE INDEX IF NOT EXISTS pubkeyprefix ON event USING btree (pubkey text_pattern_ops);"
  $db.exec "CREATE INDEX IF NOT EXISTS timeidx ON event (created_at DESC);"
  $db.exec "CREATE INDEX IF NOT EXISTS kindidx ON event (kind);"
  $db.exec "CREATE INDEX IF NOT EXISTS kindtimeidx ON event(kind, created_at DESC);"
  $db.exec "CREATE INDEX IF NOT EXISTS arbitrarytagvalues ON event USING gin (tagvalues);"

  # Verify table exists
  res = $db.exec("SELECT COUNT(*) FROM event")
  log "Connected to PostgreSQL (#{res.getvalue(0, 0)} events)"
rescue => e
  log "Database connection failed: #{e.class}: #{e.message}"
  $db = nil
end

# Run a block of database operations, reconnecting and retrying once when
# the connection has gone away (dropped by the server, a network path
# timeout, ...). Without this a single broken connection turns into a
# permanent outage: every later query fails with "no connection to the
# server". Genuine SQL errors are re-raised without touching the healthy
# connection.
def with_db_retry
  yield
rescue => e
  healthy = begin
    $db.exec("SELECT 1")
    true
  rescue
    false
  end
  raise e if healthy
  log "DB connection lost (#{e.class}: #{e.message}) -- reconnecting"
  db_connect
  raise e unless $db
  yield
end

def db_insert_event(event)
  res = $db.exec(
    "INSERT INTO event (id, pubkey, created_at, kind, tags, content, sig) VALUES ($1, $2, $3::int4, $4::int4, $5::jsonb, $6, $7) ON CONFLICT (id) DO NOTHING RETURNING id",
    event["id"], event["pubkey"], event["created_at"], event["kind"],
    event["tags"].to_json, event["content"], event["sig"]
  )
  res.ntuples > 0
end

def db_delete_by_id_and_pubkey(event_id, pubkey)
  $db.exec("DELETE FROM event WHERE id = $1 AND pubkey = $2", event_id, pubkey)
end

def db_replaceable_newer_exists?(kind, pubkey, created_at)
  res = $db.exec(
    "SELECT 1 FROM event WHERE kind = $1::int4 AND pubkey = $2 AND created_at >= $3::int4 LIMIT 1",
    kind, pubkey, created_at
  )
  res.ntuples > 0
end

def db_delete_replaceable(kind, pubkey)
  $db.exec("DELETE FROM event WHERE kind = $1::int4 AND pubkey = $2", kind, pubkey)
end

def db_parameterized_replaceable_newer_exists?(kind, pubkey, d_val, created_at)
  res = $db.exec(
    "SELECT 1 FROM event WHERE kind = $1::int4 AND pubkey = $2 AND tags @> $3 AND created_at >= $4::int4 LIMIT 1",
    kind, pubkey, [["d", d_val]].to_json, created_at
  )
  res.ntuples > 0
end

def db_delete_parameterized_replaceable(kind, pubkey, d_val)
  $db.exec(
    "DELETE FROM event WHERE kind = $1::int4 AND pubkey = $2 AND tags @> $3",
    kind, pubkey, [["d", d_val]].to_json
  )
end

# Escape LIKE metacharacters so filter prefixes match literally.
def escape_like(str)
  str.gsub("\\") { "\\\\" }.gsub("%") { "\\%" }.gsub("_") { "\\_" }
end

# created_at and kind are stored as int4; values outside this range would
# make the parameter cast raise instead of simply not matching.
INT4_MIN = -2147483648
INT4_MAX = 2147483647

def int4?(v)
  v.is_a?(Integer) && v >= INT4_MIN && v <= INT4_MAX
end

# NIP-40: return true once an event's first valid expiration timestamp has
# passed. Malformed expiration tags are ignored.
def event_expired?(event, now = Time.now.to_i)
  tags = event["tags"] || []
  if tags.is_a?(String)
    begin
      tags = JSON.parse(tags)
    rescue
      return false
    end
  end
  return false unless tags.is_a?(Array)

  tags.each do |tag|
    next unless tag.is_a?(Array) && tag.length >= 2
    next unless tag[0] == "expiration" && tag[1].is_a?(String)
    next unless tag[1] =~ /^\d+$/
    return tag[1].to_i <= now
  end
  false
end

def db_query_events(filters)
  conditions = []
  params = []
  pi = 0

  filters.each do |filter|
    parts = []

    # Malformed filter fields (wrong types) match nothing instead of
    # raising or producing invalid SQL.
    if filter["ids"] && !(filter["ids"].is_a?(Array) && filter["ids"].empty?)
      prefixes = filter["ids"].is_a?(Array) ? filter["ids"].select { |p| p.is_a?(String) } : []
      if prefixes.empty?
        parts << "FALSE"
      else
        id_parts = prefixes.map do |prefix|
          pi += 1
          params << "#{escape_like(prefix)}%"
          "id LIKE $#{pi}"
        end
        parts << "(#{id_parts.join(' OR ')})"
      end
    end

    if filter["authors"] && !(filter["authors"].is_a?(Array) && filter["authors"].empty?)
      prefixes = filter["authors"].is_a?(Array) ? filter["authors"].select { |p| p.is_a?(String) } : []
      if prefixes.empty?
        parts << "FALSE"
      else
        author_parts = prefixes.map do |prefix|
          pi += 1
          params << "#{escape_like(prefix)}%"
          "pubkey LIKE $#{pi}"
        end
        parts << "(#{author_parts.join(' OR ')})"
      end
    end

    if filter["kinds"] && !(filter["kinds"].is_a?(Array) && filter["kinds"].empty?)
      kinds = filter["kinds"].is_a?(Array) ? filter["kinds"].select { |k| int4?(k) } : []
      if kinds.empty?
        parts << "FALSE"
      else
        kind_placeholders = kinds.map do |k|
          pi += 1
          params << k
          "$#{pi}::int4"
        end
        parts << "kind IN (#{kind_placeholders.join(',')})"
      end
    end

    if filter["since"]
      if int4?(filter["since"])
        pi += 1
        params << filter["since"]
        parts << "created_at >= $#{pi}::int4"
      elsif filter["since"].is_a?(Integer) && filter["since"] < INT4_MIN
        # every stored created_at satisfies the bound; no condition needed
      else
        parts << "FALSE"
      end
    end

    if filter["until"]
      if int4?(filter["until"])
        pi += 1
        params << filter["until"]
        parts << "created_at <= $#{pi}::int4"
      elsif filter["until"].is_a?(Integer) && filter["until"] > INT4_MAX
        # every stored created_at satisfies the bound; no condition needed
      else
        parts << "FALSE"
      end
    end

    # Tag filters (#e, #p, etc.)
    filter.each do |key, values|
      if key.start_with?("#") && key.length == 2 && values.is_a?(Array)
        # Only strings can match text[] tagvalues; an empty candidate list
        # can never match anything.
        vals = values.select { |v| v.is_a?(String) }
        if vals.empty?
          parts << "FALSE"
        else
          placeholders = vals.map do |v|
            pi += 1
            params << v
            "$#{pi}"
          end
          parts << "tagvalues && ARRAY[#{placeholders.join(',')}]::text[]"
        end
      end
    end

    conditions << "(#{parts.join(' AND ')})" unless parts.empty?
  end

  sql = "SELECT id, pubkey, created_at, kind, tags, content, sig FROM event"
  sql << " WHERE #{conditions.join(' OR ')}" unless conditions.empty?
  sql << " ORDER BY created_at DESC"

  # Use minimum limit from filters
  limit = 500
  filters.each do |f|
    if f["limit"].is_a?(Integer)
      l = f["limit"] < 500 ? f["limit"] : 500
      limit = l if l < limit
    end
  end
  limit = 0 if limit < 0
  pi += 1
  params << limit
  sql << " LIMIT $#{pi}::int4"

  log "SQL: #{sql} params=#{params.inspect}"
  res = $db.exec(sql, *params)
  events = []
  row = 0
  while row < res.ntuples
    event = {
      "id" => res.getvalue(row, 0),
      "pubkey" => res.getvalue(row, 1),
      "created_at" => res.getvalue(row, 2).to_i,
      "kind" => res.getvalue(row, 3).to_i,
      "tags" => res.getvalue(row, 4),
      "content" => res.getvalue(row, 5),
      "sig" => res.getvalue(row, 6)
    }
    events << event unless event_expired?(event)
    row += 1
  end
  events
end

# --- WebSocket Handshake ---
def create_accept_key(client_key)
  # coder/websocket (used by nak) uses this GUID
  magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  [Digest::SHA1.digest(client_key + magic)].pack("m0")
end

def build_handshake_response(accept_key)
  "HTTP/1.1 101 Switching Protocols\r\n" \
  "Upgrade: websocket\r\n" \
  "Connection: Upgrade\r\n" \
  "Sec-Websocket-Accept: #{accept_key}\r\n" \
  "\r\n"
end

RELAY_INFO = {
  "name" => "mruby-nostr-relay",
  "description" => "A Nostr relay written in mruby",
  "supported_nips" => [1, 4, 9, 11, 26, 40, 66, 70, 78],
  "relay_countries" => (ENV['RELAY_COUNTRIES'] || "JP").split(',').map(&:strip).reject(&:empty?),
  "software" => "mruby-nostr-relay",
  "version" => "0.1.0"
}.to_json

CONTENT_TYPES = {
  "html" => "text/html",
  "css" => "text/css",
  "js" => "application/javascript",
  "json" => "application/json",
  "png" => "image/png",
  "jpg" => "image/jpeg",
  "jpeg" => "image/jpeg",
  "gif" => "image/gif",
  "svg" => "image/svg+xml",
  "ico" => "image/x-icon",
  "txt" => "text/plain"
}

def http_response(status, headers, body)
  resp = "HTTP/1.1 #{status}\r\n"
  headers.each { |k, v| resp << "#{k}: #{v}\r\n" }
  resp << "Content-Length: #{body.bytesize}\r\n" if body
  resp << "Connection: close\r\n"
  resp << "\r\n"
  resp << body if body
  resp
end

def serve_nip11(client)
  resp = http_response("200 OK",
    { "Content-Type" => "application/nostr+json", "Access-Control-Allow-Origin" => "*" },
    RELAY_INFO)
  client[:socket].write(resp)
  :close
end

def serve_static(client, path)
  path = "/index.html" if path == "/"
  path = path.gsub("..", "")  # prevent traversal
  filepath = "public#{path}"

  # File.read raises on directories and unreadable files; respond 404
  # instead of dropping the connection without a response.
  body = nil
  begin
    body = File.read(filepath) if File.exist?(filepath)
  rescue
    body = nil
  end

  unless body
    resp = http_response("404 Not Found", { "Content-Type" => "text/plain" }, "Not Found")
    client[:socket].write(resp)
    return :close
  end
  ext = filepath.split(".").last
  content_type = CONTENT_TYPES[ext] || "application/octet-stream"
  resp = http_response("200 OK",
    { "Content-Type" => content_type, "Access-Control-Allow-Origin" => "*" },
    body)
  client[:socket].write(resp)
  :close
end

# Resolve the real client IP from proxy headers, falling back to the peer
# address, or "-" when unknown.
def resolve_client_ip(client, fwd)
  ["cf-connecting-ip", "x-forwarded-for", "x-real-ip"].each do |name|
    value = fwd[name]
    next if value.nil? || value.empty?
    # X-Forwarded-For may be a comma separated list; take the first entry.
    return value.split(",").first.strip
  end
  begin
    client[:socket].peeraddr[3]
  rescue
    "-"
  end
end

def try_upgrade(client)
  phr = Phr.new
  offset = phr.parse_request(client[:buf])
  return false if offset == :incomplete

  if offset == :parser_error
    client[:socket].close rescue nil
    return :error
  end

  ws_key = nil
  accept_header = nil
  fwd = {}
  phr.headers.each do |name, value|
    lname = name.downcase
    ws_key = value if lname == "sec-websocket-key"
    accept_header = value if lname == "accept"
    # Capture proxy headers to resolve the real client IP (Cloudflare Tunnel /
    # reverse proxy) instead of the local proxy address.
    fwd[lname] = value if lname == "cf-connecting-ip" || lname == "x-forwarded-for" || lname == "x-real-ip"
  end

  client[:ip] = resolve_client_ip(client, fwd)

  # NIP-11: Relay Information Document
  unless ws_key
    if accept_header && accept_header.include?("application/nostr+json")
      return serve_nip11(client)
    end
    return serve_static(client, phr.path)
  end

  accept = create_accept_key(ws_key)
  resp = build_handshake_response(accept)
  client[:socket].write(resp)
  client[:buf] = client[:buf][offset..-1] || ""
  client[:state] = :websocket

  callbacks = Wslay::Event::Callbacks.new
  sock = client[:socket]

  callbacks.recv_callback do |buf, len|
    # Serve bytes that arrived together with the handshake request before
    # reading from the socket, or they would be lost.
    pending = client[:buf]
    if pending && !pending.empty?
      client[:buf] = pending[len..-1] || ""
      pending[0, len]
    else
      # The socket stays non-blocking (recv_nonblock would revert it to
      # blocking on return); wslay maps Errno::EAGAIN to would-block.
      data = sock.recv(len)
      if data.nil? || data.empty?
        raise IOError, "connection closed"
      end
      data
    end
  end

  # Return the number of bytes actually sent so wslay can resume partial
  # writes; a blocking write here could stall the whole event loop.
  callbacks.send_callback do |data|
    sock.send(data, 0)
  end

  callbacks.on_msg_recv_callback do |msg|
    on_ws_message(client, msg)
  end

  client[:ws] = Wslay::Event::Context::Server.new(callbacks)

  $subscriptions[client[:ws]] = {}
  $ws_clients[client[:ws]] = client
  log "[#{client[:ip]}] WebSocket connection established"
  true
end

# --- Nostr Protocol ---
def on_ws_message(client, msg)
  # Only text frames carry nostr messages. Control frames (:ping, :pong,
  # :connection_close) are answered by the websocket layer but still reach
  # this callback; parsing a ping payload as JSON made the relay send
  # bogus "message must be a JSON array" notices to every client.
  return unless msg.opcode == :text_frame

  log "[#{client[:ip]}] Received: #{msg.msg}"

  begin
    payload = JSON.parse(msg.msg)
  rescue
    log "[#{client[:ip]}] Failed to parse JSON: #{msg.msg}"
    ws_send(client[:ws], ["NOTICE", "invalid JSON"])
    return
  end

  # Client messages must be JSON arrays; scalars like null would raise on
  # payload[0].
  unless payload.is_a?(Array)
    ws_send(client[:ws], ["NOTICE", "invalid: message must be a JSON array"])
    return
  end

  type = payload[0]

  case type
  when "EVENT"
    process_event(client[:ws], payload[1])
  when "REQ"
    sub_id = payload[1]
    filters = payload[2..-1]
    subscribe(client[:ws], sub_id, filters)
  when "CLOSE"
    sub_id = payload[1]
    unsubscribe(client[:ws], sub_id)
  else
    ws_send(client[:ws], ["NOTICE", "unknown command: #{type}"])
  end
end

def ws_send(ws, msg)
  ws.queue_msg(msg.to_json, :text_frame)
end

# Flush queued frames to a client outside its own poll iteration (e.g. events
# broadcast while handling another client's message) and keep its poll events
# in sync so remaining data is written once the socket becomes writable.
def flush_ws(ws)
  client = $ws_clients[ws]
  return unless client
  begin
    ws.send if ws.want_write?
  rescue Errno::EAGAIN, Errno::EWOULDBLOCK
    # socket busy; poll will retry when writable
  rescue
    # broken connection; cleaned up when poll reports it
    return
  end
  client[:poll_fd].events = ws.want_write? ? (Poll::In | Poll::Out) : Poll::In
end

# --- NIP-26: Delegated Event Signing ---
# Conditions is an &-separated query string, e.g. "kind=1&created_at>1&created_at<9999999999".
def validate_delegation_conditions(event, conditions)
  kinds = []

  conditions.split("&").each do |condition|
    if condition.start_with?("kind=")
      value = condition["kind=".length..-1]
      return false unless value =~ /\A-?\d+\z/
      kinds << value.to_i
    elsif condition.start_with?("created_at<")
      value = condition["created_at<".length..-1]
      return false unless value =~ /\A-?\d+\z/
      return false unless event["created_at"] < value.to_i
    elsif condition.start_with?("created_at>")
      value = condition["created_at>".length..-1]
      return false unless value =~ /\A-?\d+\z/
      return false unless event["created_at"] > value.to_i
    else
      # Unknown or malformed conditions must invalidate the delegation
      # rather than silently widen it.
      return false
    end
  end

  # Multiple kind conditions form an OR set; no kind condition means the
  # delegation does not restrict kinds.
  kinds.empty? || kinds.include?(event["kind"])
end

# Verify the delegation token "nostr:delegation:<delegatee pubkey>:<conditions>"
# was signed (BIP-340 Schnorr over its SHA-256 hash) by the delegator.
def verify_delegation_signature(delegatee_pubkey, delegator_pubkey, conditions, signature)
  return false unless signature.length == 128 && signature =~ /\A[0-9a-fA-F]+\z/
  token = "nostr:delegation:#{delegatee_pubkey}:#{conditions}"
  hash = Digest::SHA256.digest(token)
  pubkey_bin = [delegator_pubkey].pack("H*")
  sig_bin = [signature].pack("H*")
  Secp256k1.schnorr_verify(pubkey_bin, sig_bin, hash)
rescue
  false
end

def validate_delegation(event)
  delegation_tag = (event["tags"] || []).find { |t| t.length >= 4 && t[0] == "delegation" }
  return true unless delegation_tag
  return false unless delegation_tag.length == 4

  delegator_pubkey = delegation_tag[1]
  conditions = delegation_tag[2]
  signature = delegation_tag[3]

  return false unless delegator_pubkey.is_a?(String) && conditions.is_a?(String) && signature.is_a?(String)
  return false if delegator_pubkey.empty? || conditions.empty? || signature.empty?
  return false unless delegator_pubkey.length == 64 && delegator_pubkey =~ /\A[0-9a-fA-F]+\z/
  return false unless validate_delegation_conditions(event, conditions)
  return false unless verify_delegation_signature(event["pubkey"], delegator_pubkey, conditions, signature)

  true
end

# NIP-01 requires all these fields with these exact types; anything else
# would raise while hashing, storing, or matching the event.
def valid_event_structure?(event)
  event.is_a?(Hash) &&
    event["pubkey"].is_a?(String) &&
    event["sig"].is_a?(String) &&
    event["kind"].is_a?(Integer) &&
    event["created_at"].is_a?(Integer) &&
    event["content"].is_a?(String) &&
    event["tags"].is_a?(Array) &&
    event["tags"].all? { |t| t.is_a?(Array) && t.all? { |v| v.is_a?(String) } }
end

def process_event(ws, event)
  unless event.is_a?(Hash) && event["id"].is_a?(String)
    ws_send(ws, ["NOTICE", "invalid: malformed event"])
    return
  end

  id = event["id"]
  log "EVENT kind=#{event["kind"]} id=#{id[0..7]}..."

  unless valid_event_structure?(event)
    ws_send(ws, ["OK", id, false, "invalid: malformed event"])
    return
  end

  # Validate event id
  serialized = [0, event["pubkey"], event["created_at"], event["kind"], event["tags"], event["content"]].to_json
  expected_id = Digest::SHA256.digest(serialized).unpack1("H*")
  unless id == expected_id
    ws_send(ws, ["OK", id, false, "invalid: bad event id"])
    return
  end

  # Schnorr signature verification (BIP-340)
  begin
    pubkey_bin = [event["pubkey"]].pack("H*")
    sig_bin = [event["sig"]].pack("H*")
    id_bin = [id].pack("H*")
    unless Secp256k1.schnorr_verify(pubkey_bin, sig_bin, id_bin)
      ws_send(ws, ["OK", id, false, "invalid: bad signature"])
      return
    end
  rescue => e
    ws_send(ws, ["OK", id, false, "invalid: signature verification failed: #{e.message}"])
    return
  end

  # NIP-26: Delegated Event Signing
  unless validate_delegation(event)
    ws_send(ws, ["OK", id, false, "invalid: bad delegation"])
    return
  end

  kind = event["kind"]

  if event_expired?(event)
    ws_send(ws, ["OK", id, false, "invalid: event is expired"])
    return
  end

  # NIP-70: Protected Events
  # Reject events with ["-"] tag since this relay does not support NIP-42 AUTH
  if (event["tags"] || []).any? { |t| t[0] == "-" }
    ws_send(ws, ["OK", id, false, "blocked: this relay does not support NIP-42 AUTH, protected events cannot be accepted"])
    return
  end

  if $db
    begin
      # The whole sequence is retried on a lost connection; every statement
      # in it is idempotent (deletes, newer-exists checks, insert with ON
      # CONFLICT DO NOTHING), so a mid-way retry is safe.
      with_db_retry do
        # NIP-09: Deletion
        if kind == 5
          (event["tags"] || []).each do |tag|
            if tag[0] == "e" && tag[1]
              db_delete_by_id_and_pubkey(tag[1], event["pubkey"])
            end
          end
        end

        # Replaceable events (kind 0, 3, 10000-19999): only the latest
        # event may replace stored ones; ignore older submissions.
        if kind == 0 || kind == 3 || (kind >= 10000 && kind < 20000)
          if db_replaceable_newer_exists?(kind, event["pubkey"], event["created_at"])
            ws_send(ws, ["OK", id, true, "duplicate: have a newer or equal event"])
            return
          end
          db_delete_replaceable(kind, event["pubkey"])
        end

        # Parameterized replaceable events (kind 30000-39999)
        if kind >= 30000 && kind < 40000
          d_tag = (event["tags"] || []).find { |t| t[0] == "d" }
          d_val = d_tag ? d_tag[1] : ""
          if db_parameterized_replaceable_newer_exists?(kind, event["pubkey"], d_val, event["created_at"])
            ws_send(ws, ["OK", id, true, "duplicate: have a newer or equal event"])
            return
          end
          db_delete_parameterized_replaceable(kind, event["pubkey"], d_val)
        end

        # Ephemeral events (kind 20000-29999) are not stored
        if kind < 20000 || kind >= 30000
          unless db_insert_event(event)
            ws_send(ws, ["OK", id, true, "duplicate:"])
            return
          end
        end
      end
      log "DB: success"
    rescue => e
      log "DB error: #{e.class}: #{e.message}"
      ws_send(ws, ["OK", id, false, "error: database error"])
      return
    end
  end

  ws_send(ws, ["OK", id, true, ""])

  # Deliver to all subscribers
  $subscriptions.each do |sub_ws, subs|
    queued = false
    subs.each do |sub_id, filters|
      if match_filters?(event, filters)
        ws_send(sub_ws, ["EVENT", sub_id, event])
        queued = true
      end
    end
    flush_ws(sub_ws) if queued && !sub_ws.equal?(ws)
  end
end

def subscribe(ws, sub_id, filters)
  log "REQ #{sub_id} filters=#{filters.to_json}"
  # Ignore filters that are not JSON objects; they would raise while
  # querying or matching.
  filters = (filters || []).select { |f| f.is_a?(Hash) }
  # A REQ needs at least one filter; without this check the stored query
  # would dump events while live matching would never match anything.
  if filters.empty?
    ws_send(ws, ["CLOSED", sub_id, "error: no valid filters"])
    return
  end
  $subscriptions[ws] ||= {}
  if !$subscriptions[ws].key?(sub_id) && $subscriptions[ws].size >= MAX_SUBSCRIPTIONS_PER_CLIENT
    ws_send(ws, ["CLOSED", sub_id, "error: too many subscriptions"])
    return
  end
  $subscriptions[ws][sub_id] = filters

  if $db
    begin
      events = with_db_retry { db_query_events(filters) }
    rescue => e
      log "REQ #{sub_id} query error: #{e.class}: #{e.message}"
      $subscriptions[ws].delete(sub_id)
      ws_send(ws, ["CLOSED", sub_id, "error: could not query stored events"])
      return
    end
    log "REQ #{sub_id} found #{events.size} events"
    events.reverse.each do |event|
      log "REQ #{sub_id} sending event #{event["id"][0..7]}..."
      ws_send(ws, ["EVENT", sub_id, event])
    end
  else
    log "REQ #{sub_id} no database connection"
  end
  log "REQ #{sub_id} sending EOSE"
  ws_send(ws, ["EOSE", sub_id])
  log "REQ #{sub_id} done"
end

def unsubscribe(ws, sub_id)
  $subscriptions[ws]&.delete(sub_id)
end

# Malformed filter fields (wrong types) never match instead of raising:
# a bad filter from one client must not break processing for another.
def match_filters?(event, filters_array)
  filters_array.any? do |filter|
    next false unless filter.is_a?(Hash)
    next false if event_expired?(event)
    next false if filter["ids"] && !(filter["ids"].is_a?(Array) && filter["ids"].any? { |prefix| prefix.is_a?(String) && event["id"].start_with?(prefix) })
    next false if filter["authors"] && !(filter["authors"].is_a?(Array) && filter["authors"].any? { |prefix| prefix.is_a?(String) && event["pubkey"].start_with?(prefix) })
    next false if filter["kinds"] && !(filter["kinds"].is_a?(Array) && filter["kinds"].include?(event["kind"]))
    next false if filter["since"] && !(filter["since"].is_a?(Integer) && event["created_at"] >= filter["since"])
    next false if filter["until"] && !(filter["until"].is_a?(Integer) && event["created_at"] <= filter["until"])

    # Tag filters (#e, #p, etc.)
    tag_match = true
    filter.each do |key, values|
      if key.start_with?("#") && key.length == 2
        tag_name = key[1]
        event_tag_values = (event["tags"] || []).select { |t| t[0] == tag_name }.map { |t| t[1] }
        unless values.is_a?(Array) && values.any? { |v| event_tag_values.include?(v) }
          tag_match = false
          break
        end
      end
    end
    next false unless tag_match

    true
  end
end

# --- Event Loop ---
def run_server
  db_connect

  server = TCPServer.new(RELAY_HOST, RELAY_PORT)
  log "Nostr Relay listening on #{RELAY_HOST}:#{RELAY_PORT}"

  poll = Poll.new
  poll.add(server, Poll::In)

  loop do
    poll.wait(-1) do |ready|
      sock = ready.socket

      if sock == server
        begin
          client_sock = server.accept_nonblock
          # Keep the client socket non-blocking for its whole lifetime; a
          # blocking read or write would stall every other connection.
          client_sock._setnonblock(true)
          pfd = poll.add(client_sock, Poll::In)
          $clients[client_sock] = {
            socket: client_sock,
            state: :http,
            buf: "",
            ws: nil,
            poll_fd: pfd
          }
        rescue => e
          log "Accept error: #{e.message}"
        end
      else
        client = $clients[sock]
        next unless client

        begin
          if client[:state] == :http
            begin
              data = sock.recv(4096)
            rescue Errno::EAGAIN, Errno::EWOULDBLOCK
              next
            end
            if data.nil? || data.empty?
              disconnect(poll, sock)
              next
            end
            client[:buf] << data
            if client[:buf].bytesize > MAX_HTTP_REQUEST_SIZE
              log "[#{client[:ip] || "-"}] HTTP request too large"
              disconnect(poll, sock)
              next
            end
            result = try_upgrade(client)
            if result == :error || result == :close
              disconnect(poll, sock)
            elsif result == true && !client[:buf].empty?
              # Process WebSocket frames pipelined with the handshake now;
              # the socket may never become readable again.
              begin
                client[:ws].recv
              rescue Errno::EAGAIN, Errno::EWOULDBLOCK
                # buffered data consumed; wait for more
              end
              flush_ws(client[:ws])
            end
          elsif client[:state] == :websocket
            ws = client[:ws]
            if ws.want_read? && ready.readable?
              begin
                ws.recv
              rescue Errno::EAGAIN, Errno::EWOULDBLOCK
                # no data yet
              rescue => e
                normal_close = e.is_a?(IOError) && e.message == "connection closed"
                normal_close ||= e.respond_to?(:errno) && e.errno == 0
                log "[#{client[:ip] || "-"}] Client error: #{e.message}" unless normal_close
                disconnect(poll, sock)
                next
              end
            end
            if ws.want_write?
              begin
                ws.send
              rescue Errno::EAGAIN, Errno::EWOULDBLOCK
                # can't write yet
              end
            end
            # Update poll events: watch for write readiness when data is pending
            if ws.want_write?
              client[:poll_fd].events = Poll::In | Poll::Out
            else
              client[:poll_fd].events = Poll::In
            end
            if ws.close_received? && ws.close_sent?
              disconnect(poll, sock)
            end
          end
        rescue => e
          log "Client error: #{e.class}: #{e.message}"
          disconnect(poll, sock)
        end
      end
    end
  end
end

def disconnect(poll, sock)
  client = $clients.delete(sock)
  if client
    log "[#{client[:ip] || "-"}] Client disconnected" if client[:ws]
    $subscriptions.delete(client[:ws]) if client[:ws]
    $ws_clients.delete(client[:ws]) if client[:ws]
    poll.remove(client[:poll_fd]) if client[:poll_fd]
  end
  sock.close rescue nil
end

# --- Main ---
log "Starting mruby Nostr Relay..."
run_server
