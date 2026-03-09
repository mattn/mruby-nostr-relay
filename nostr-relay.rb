#!/usr/bin/env mruby
# nostr-relay.rb - Standalone Nostr Relay Server for mruby
# Uses: mruby-socket, mruby-poll, mruby-phr, mruby-wslay, mruby-json, mruby-digest, mruby-postgresql

RELAY_HOST = "0.0.0.0"
RELAY_PORT = 8080

# --- Storage ---
$subscriptions = {}  # ws_context => { sub_id => [filters...] }
$clients = {}        # socket => client hash
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

def db_event_exists?(id)
  res = $db.exec("SELECT 1 FROM event WHERE id = $1", id)
  res.ntuples > 0
end

def db_insert_event(event)
  $db.exec(
    "INSERT INTO event (id, pubkey, created_at, kind, tags, content, sig) VALUES ($1, $2, $3, $4, $5, $6, $7)",
    event["id"], event["pubkey"], event["created_at"].to_s, event["kind"].to_s,
    event["tags"].to_json, event["content"], event["sig"]
  )
end

def db_delete_by_id_and_pubkey(event_id, pubkey)
  $db.exec("DELETE FROM event WHERE id = $1 AND pubkey = $2", event_id, pubkey)
end

def db_delete_replaceable(kind, pubkey)
  $db.exec("DELETE FROM event WHERE kind = $1 AND pubkey = $2", kind.to_s, pubkey)
end

def db_delete_parameterized_replaceable(kind, pubkey, d_val)
  $db.exec(
    "DELETE FROM event WHERE kind = $1 AND pubkey = $2 AND tags @> $3",
    kind.to_s, pubkey, [["d", d_val]].to_json
  )
end

def db_query_events(filters)
  conditions = []
  params = []
  pi = 0

  filters.each do |filter|
    parts = []

    if filter["ids"] && !filter["ids"].empty?
      id_parts = filter["ids"].map do |prefix|
        pi += 1
        params << "#{prefix}%"
        "id LIKE $#{pi}"
      end
      parts << "(#{id_parts.join(' OR ')})"
    end

    if filter["authors"] && !filter["authors"].empty?
      author_parts = filter["authors"].map do |prefix|
        pi += 1
        params << "#{prefix}%"
        "pubkey LIKE $#{pi}"
      end
      parts << "(#{author_parts.join(' OR ')})"
    end

    if filter["kinds"] && !filter["kinds"].empty?
      kind_placeholders = filter["kinds"].map do |k|
        pi += 1
        params << k.to_s
        "$#{pi}"
      end
      parts << "kind IN (#{kind_placeholders.join(',')})"
    end

    if filter["since"]
      pi += 1
      params << filter["since"].to_s
      parts << "created_at >= $#{pi}"
    end

    if filter["until"]
      pi += 1
      params << filter["until"].to_s
      parts << "created_at <= $#{pi}"
    end

    # Tag filters (#e, #p, etc.)
    filter.each do |key, values|
      if key.start_with?("#") && key.length == 2 && values.is_a?(Array)
        tag_vals = values.map { |v| "'#{v.gsub("'", "''")}'" }
        parts << "tagvalues && ARRAY[#{tag_vals.join(',')}]::text[]"
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
    if f["limit"]
      l = f["limit"] < 500 ? f["limit"] : 500
      limit = l if l < limit
    end
  end
  pi += 1
  params << limit.to_s
  sql << " LIMIT $#{pi}"

  log "SQL: #{sql} params=#{params.inspect}"
  res = $db.exec(sql, *params)
  events = []
  row = 0
  while row < res.ntuples
    events << {
      "id" => res.getvalue(row, 0),
      "pubkey" => res.getvalue(row, 1),
      "created_at" => res.getvalue(row, 2).to_i,
      "kind" => res.getvalue(row, 3).to_i,
      "tags" => res.getvalue(row, 4),
      "content" => res.getvalue(row, 5),
      "sig" => res.getvalue(row, 6)
    }
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
  "supported_nips" => [1, 9, 11, 70],
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

  unless File.exist?(filepath)
    resp = http_response("404 Not Found", { "Content-Type" => "text/plain" }, "Not Found")
    client[:socket].write(resp)
    return :close
  end

  body = File.read(filepath)
  ext = filepath.split(".").last
  content_type = CONTENT_TYPES[ext] || "application/octet-stream"
  resp = http_response("200 OK",
    { "Content-Type" => content_type, "Access-Control-Allow-Origin" => "*" },
    body)
  client[:socket].write(resp)
  :close
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
  phr.headers.each do |name, value|
    lname = name.downcase
    ws_key = value if lname == "sec-websocket-key"
    accept_header = value if lname == "accept"
  end

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
  client[:socket]._setnonblock(true)

  callbacks = Wslay::Event::Callbacks.new
  sock = client[:socket]

  callbacks.recv_callback do |buf, len|
    sock.recv_nonblock(len) || ""
  end

  callbacks.send_callback do |data|
    sock.write(data)
    data.bytesize
  end

  callbacks.on_msg_recv_callback do |msg|
    on_ws_message(client, msg)
  end

  client[:ws] = Wslay::Event::Context::Server.new(callbacks)

  $subscriptions[client[:ws]] = {}
  log "WebSocket connection established"
  true
end

# --- Nostr Protocol ---
def on_ws_message(client, msg)
  return if msg.opcode == :close

  begin
    payload = JSON.parse(msg.msg)
  rescue
    ws_send(client[:ws], ["NOTICE", "invalid JSON"])
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

def process_event(ws, event)
  id = event["id"]
  log "EVENT kind=#{event["kind"]} id=#{id[0..7]}..."

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

  kind = event["kind"]

  # NIP-70: Protected Events
  # Reject events with ["-"] tag since this relay does not support NIP-42 AUTH
  if (event["tags"] || []).any? { |t| t[0] == "-" }
    ws_send(ws, ["OK", id, false, "blocked: this relay does not support NIP-42 AUTH, protected events cannot be accepted"])
    return
  end

  if $db
    begin
      # Duplicate check
      log "DB: checking duplicate for #{id[0..7]}..."
      if db_event_exists?(id)
        ws_send(ws, ["OK", id, true, "duplicate:"])
        return
      end

      # NIP-09: Deletion
      if kind == 5
        (event["tags"] || []).each do |tag|
          if tag[0] == "e" && tag[1]
            db_delete_by_id_and_pubkey(tag[1], event["pubkey"])
          end
        end
      end

      # Replaceable events (kind 0, 3, 10000-19999)
      if kind == 0 || kind == 3 || (kind >= 10000 && kind < 20000)
        db_delete_replaceable(kind, event["pubkey"])
      end

      # Parameterized replaceable events (kind 30000-39999)
      if kind >= 30000 && kind < 40000
        d_tag = (event["tags"] || []).find { |t| t[0] == "d" }
        d_val = d_tag ? d_tag[1] : ""
        db_delete_parameterized_replaceable(kind, event["pubkey"], d_val)
      end

      # Ephemeral events (kind 20000-29999) are not stored
      if kind < 20000 || kind >= 30000
        log "DB: inserting event #{id[0..7]}... created_at=#{event["created_at"].class}:#{event["created_at"]} kind=#{event["kind"].class}:#{event["kind"]}"
        db_insert_event(event)
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
    subs.each do |sub_id, filters|
      if match_filters?(event, filters)
        ws_send(sub_ws, ["EVENT", sub_id, event])
      end
    end
  end
end

def subscribe(ws, sub_id, filters)
  log "REQ #{sub_id} filters=#{filters.to_json}"
  $subscriptions[ws] ||= {}
  $subscriptions[ws][sub_id] = filters

  if $db
    events = db_query_events(filters)
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

def match_filters?(event, filters_array)
  filters_array.any? do |filter|
    next false if filter["ids"] && !filter["ids"].any? { |prefix| event["id"].start_with?(prefix) }
    next false if filter["authors"] && !filter["authors"].any? { |prefix| event["pubkey"].start_with?(prefix) }
    next false if filter["kinds"] && !filter["kinds"].include?(event["kind"])
    next false if filter["since"] && event["created_at"] < filter["since"]
    next false if filter["until"] && event["created_at"] > filter["until"]

    # Tag filters (#e, #p, etc.)
    tag_match = true
    filter.each do |key, values|
      if key.start_with?("#") && key.length == 2
        tag_name = key[1]
        event_tag_values = (event["tags"] || []).select { |t| t[0] == tag_name }.map { |t| t[1] }
        unless values.any? { |v| event_tag_values.include?(v) }
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
            data = sock.recv_nonblock(4096)
            if data.nil? || data.empty?
              disconnect(poll, sock)
              next
            end
            client[:buf] << data
            result = try_upgrade(client)
            if result == :error || result == :close
              disconnect(poll, sock)
            end
          elsif client[:state] == :websocket
            ws = client[:ws]
            if ws.want_read?
              begin
                ws.recv
              rescue Errno::EAGAIN, Errno::EWOULDBLOCK
                # no data yet
              rescue => e
                log "Client disconnected: #{e.message}"
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
    $subscriptions.delete(client[:ws]) if client[:ws]
    poll.remove(client[:poll_fd]) if client[:poll_fd]
  end
  sock.close rescue nil
end

# --- Main ---
log "Starting mruby Nostr Relay..."
run_server
