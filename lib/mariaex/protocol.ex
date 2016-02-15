defmodule Mariaex.Protocol do
  @moduledoc false

  alias Mariaex.Cache
  alias Mariaex.LruCache
  alias Mariaex.Query
  import Mariaex.Messages
  import Mariaex.ProtocolHelper
  use DBConnection
  use Bitwise

  @reserved_prefix "MARIAEX_"
  @timeout 5000
  @keepalive_interval 60000
  @keepalive_timeout @timeout
  @cache_size 100

  @maxpacketbytes 50000000
  @mysql_native_password "mysql_native_password"
  @mysql_old_password :mysql_old_password

  @client_long_password     0x00000001
  @client_found_rows        0x00000002
  @client_long_flag         0x00000004
  @client_connect_with_db   0x00000008
  @client_local_files       0x00000080
  @client_protocol_41       0x00000200
  @client_transactions      0x00002000
  @client_secure_connection 0x00008000
  @client_multi_statements  0x00010000
  @client_multi_results     0x00020000
  @client_deprecate_eof     0x01000000

  @capabilities @client_long_password     ||| @client_found_rows        ||| @client_long_flag |||
                @client_local_files       ||| @client_protocol_41       ||| @client_transactions |||
                @client_secure_connection ||| @client_multi_statements  ||| @client_multi_results |||
                @client_deprecate_eof

  defstruct [sock: nil, connection_ref: nil, state: nil, state_data: nil, protocol57: false,
             rows: [], connection_id: nil, opts: [], catch_eof: false, buffer: "", timeout: 0,
             lru_cache: nil, cache: nil, seqnum: 0]

  @doc """
  DBConnection callback
  """
  def connect(opts) do
    sock_type  = (opts[:sock_type] || :tcp) |> Atom.to_string |> String.capitalize()
    sock_mod   = Module.concat(Mariaex.Connection, sock_type)
    opts       = add_default_opts(opts)
    host       = Keyword.fetch!(opts, :hostname)
    host       = if is_binary(host), do: String.to_char_list(host), else: host
    port       = opts[:port] || 3306
    timeout    = opts[:timeout] || @timeout
    cache_size = opts[:cache_size] || @cache_size
    case sock_mod.connect(host, port, opts[:socket_options] || [], timeout) do
      {:ok, sock} ->
        s = %__MODULE__{state: :handshake,
                        connection_id: self,
                        opts: opts,
                        connection_ref: make_ref,
                        sock: {sock_mod, sock},
                        cache: Mariaex.Cache.new(),
                        lru_cache: Mariaex.LruCache.new(cache_size),
                        timeout: timeout}
        handshake_recv(s, %{opts: opts})
      {:error, reason} ->
        {:error, %Mariaex.Error{message: "tcp connect: #{reason}"}}
    end
  end

  defp add_default_opts(opts) do
    opts
    |> Keyword.put_new(:username, System.get_env("MDBUSER") || System.get_env("USER"))
    |> Keyword.put_new(:password, System.get_env("MDBPASSWORD"))
    |> Keyword.put_new(:hostname, System.get_env("MDBHOST") || "localhost")
  end

  def_handle :handshake_recv, :handle_handshake
  defp handle_handshake(packet(seqnum: seqnum, msg: handshake(server_version: server_version, plugin: plugin) = handshake) = _packet,  %{opts: opts}, s) do
    ## It is a little hack here. Because MySQL before 5.7.5 (at least, I need to asume this or test it with versions 5.7.X, where X < 5),
    ## but all points in documentation to changes shows, that changes done in 5.7.5, but haven't tested it further.
    ## In a phase of geting binary protocol resultset ( https://dev.mysql.com/doc/internals/en/binary-protocol-resultset.html )
    ## we get in versions before 5.7.X eof packet after last ColumnDefinition and one for the ending of query.
    ## That means, without differentiation of MySQL versions, we can't know, if eof after last column definition
    ## is resulting eof after result set (which can be none) or simple information, that now results will be coming.
    ## Due to this, we need to difference server version.
    protocol57 = get_3_digits_version(server_version) |> Version.match?("~> 5.7.5")
    handshake(auth_plugin_data1: salt1, auth_plugin_data2: salt2) = handshake
    scramble = case password = opts[:password] do
      nil -> ""
      ""  -> ""
      _   -> password(plugin, password, <<salt1 :: binary, salt2 :: binary>>)
    end
    {database, capabilities} = capabilities(opts)
    msg = handshake_resp(username: :unicode.characters_to_binary(opts[:username]), password: scramble,
                         database: database, capability_flags: capabilities,
                         max_size: @maxpacketbytes, character_set: 8)
    msg_send(msg, s, seqnum + 1)
    handshake_recv(%{s | state: :handshake_send, protocol57: protocol57}, nil)
  end
  defp handle_handshake(packet(msg: ok_resp(affected_rows: _affected_rows, last_insert_id: _last_insert_id)), nil, state) do
    statement = "SET CHARACTER SET " <> (state.opts[:charset] || "utf8")
    query = %Query{type: :text, statement: statement}
    case send_text_query(state, statement) |> text_query_recv(query) do
      {:error, error, _} ->
        {:error, error}
      {:ok, _, state} ->
        activate(%{state | state: :running}, state.buffer)
    end
  end
  defp handle_handshake(packet, query, state) do
    {:error, error, _} = handle_error(packet, query, state)
    {:error, error}
  end

  defp capabilities(opts) do
    case opts[:skip_database] do
      true -> {"", @capabilities}
      _    -> {opts[:database], @capabilities ||| @client_connect_with_db}
    end
  end

  @doc """
  DBConnection callback
  """
  def disconnect(_, _state = %{sock: {sock_mod, sock}}) do
    sock_mod.close(sock)
    _ = sock_mod.recv_active(sock, 0, "")
    :ok
  end

  @doc """
  DBConnection callback
  """
  def checkout(%{buffer: :active_once, sock: {sock_mod, sock}} = s) do
    case setopts(s, [active: :false], :active_once) do
      :ok                       -> sock_mod.recv_active(sock, 0, "") |> handle_recv_buffer(s)
      {:disconnect, _, _} = dis -> dis
    end
  end

  defp handle_recv_buffer({:ok, buffer}, s) do
    {:ok, %{s | buffer: buffer}}
  end
  defp handle_recv_buffer({:disconnect, description}, s) do
    do_disconnect(s, description)
  end

  @doc """
  DBConnection callback
  """
  def checkin(%{buffer: buffer} = s) when is_binary(buffer) do
    activate(s, buffer)
  end

  ## Fake [active: once] if buffer not empty
  defp activate(s, <<>>) do
    case setopts(s, [active: :once], <<>>) do
      :ok  -> {:ok, %{s | buffer: :active_once}}
      other -> other
    end
  end
  defp activate(%{sock: {mod, sock}} = s, buffer) do
    msg = mod.fake_message(sock, buffer)
    send(self(), msg)
    {:ok, s}
  end

  defp setopts(%{sock: {mod, sock}} = s, opts, buffer) do
    case mod.setopts(sock, opts) do
      :ok ->
        :ok
      {:error, reason} ->
        do_disconnect(s, {mod, "setopts", reason, buffer})
    end
  end

  @doc """
  DBConnection callback
  """
  def handle_prepare(%Query{name: @reserved_prefix <> _} = query, _, s) do
    reserved_error(query, s)
  end
  def handle_prepare(%Query{type: nil, statement: statement} = query, opts, s) do
    command = get_command(statement)
    handle_prepare(%{query | type: request_type(command)}, opts, s)
  end
  def handle_prepare(%Query{type: :text} = query, _, s) do
    {:ok, query, s}
  end
  def handle_prepare(%Query{type: :binary, statement: statement} = query, _, %{connection_ref: ref} = s) do
    case cache_lookup(query, s) do
      {id, types, parameter_types} ->
        {:ok, %{query | statement_id: id, types: types, parameter_types: parameter_types, connection_ref: ref}, s}
      nil ->
        msg_send(text_cmd(command: com_stmt_prepare, statement: statement), s, 0)
        prepare_recv(%{s | state: :prepare_send}, query)
    end
  end

  defp cache_lookup(%Query{name: "", statement: statement}, %{lru_cache: lru_cache}) do
    case LruCache.lookup(lru_cache, statement) do
      {_id, _types, _parameter_types} = result ->
        LruCache.update(lru_cache, statement, result)
        result
      nil ->
        nil
    end
  end
  defp cache_lookup(%Query{name: name}, %{cache: cache}) do
    case Cache.lookup(cache, name) do
      {_id, _types, _parameter_types} = result ->
        result
      nil ->
        nil
    end
  end

  defp request_type(command) do
    if command in [:insert, :select, :update, :delete, :replace, :show, :call, :describe] do
      :binary
    else
      :text
    end
  end

  def_handle :prepare_recv, :handle_prepare_send
  defp handle_prepare_send(packet(msg: stmt_prepare_ok(statement_id: id, num_columns: 0, num_params: 0)), query, state) do
    prepare_may_recv_more(%{state | state_data: {0, 0}, catch_eof: false}, %{query | statement_id: id})
  end
  defp handle_prepare_send(packet(msg: stmt_prepare_ok(statement_id: id, num_columns: columns, num_params: params)), query, state) do
    statedata = {columns, params}
    prepare_may_recv_more(%{state | state: :column_definitions, catch_eof: not state.protocol57, state_data: statedata}, %{query | statement_id: id})
  end
  defp handle_prepare_send(packet(msg: column_definition_41() = msg), %{types: types} = query, state) do
    column_definition_41(type: type, name: name) = msg
    query = %{query | types: [{name, type} | types]}
    {query, state} = count_down(query, state)
    prepare_may_recv_more(state, query)
  end
  defp handle_prepare_send(packet(msg: eof_resp()), query, %{state_data: {0, 0}} = state) do
    prepare_may_recv_more(%{state | catch_eof: false}, query)
  end
  defp handle_prepare_send(packet(msg: eof_resp()), query, state) do
    prepare_may_recv_more(state, query)
  end
  defp handle_prepare_send(packet, query, state), do: handle_error(packet, query, state)

  defp prepare_may_recv_more(%{state_data: {0, 0}, catch_eof: false, connection_ref: ref} = state, query) do
    cache_insert(query, state)
    {:ok, %{query | connection_ref: ref}, state}
  end
  defp prepare_may_recv_more(state, query) do
    prepare_recv(%{state | state: :column_definitions}, query)
  end

  defp cache_insert(%{name: ""} = query, %{sock: sock, lru_cache: cache}) do
    %{statement_id: id, statement: statement, types: types, parameter_types: parameter_types} = query
    LruCache.insert(cache, statement, {id, types, parameter_types}, &close_statement(&1, &2, sock))
  end
  defp cache_insert(%{name: name, statement_id: id, types: types, parameter_types: parameter_types}, %{cache: cache}) do
    Cache.insert(cache, name, {id, types, parameter_types})
  end

  defp count_down(query, s = %{state_data: {columns, params}}) when params > 1,
    do: {query, %{s | state_data: {columns, params - 1}}}
  defp count_down(query = %{types: definitions}, s = %{state_data: {columns, 1}}),
    do: {%{query | types: [], parameter_types: Enum.reverse(definitions)}, %{s | state_data: {columns, 0}}}
  defp count_down(query, s = %{state_data: {columns, 0}}),
    do: {query, %{s | state_data: {columns - 1, 0}}}

  @doc """
  DBConnection callback
  """
  def handle_execute_close(query, params, opts, s), do: handle_execute(query, params, opts, s)

  @doc """
  DBConnection callback
  """
  def handle_execute(%Query{name: @reserved_prefix <> _, reserved?: false} = query, _, s) do
    reserved_error(query, s)
  end
  def handle_execute(%Query{type: :text, statement: statement} = query, [], _opts, state) do
    send_text_query(state, statement) |> text_query_recv(query)
  end
  def handle_execute(%Query{type: :binary, statement_id: id, connection_ref: ref} = query, params, _opts, %{connection_ref: ref} = state) do
    msg_send(stmt_execute(command: com_stmt_execute, parameters: params, statement_id: id, flags: 0, iteration_count: 1), state, 0)
    binary_query_recv(%{state | state: :column_count}, query)
  end
  def handle_execute(%Query{type: :binary} = query, params, opts, state) do
    case handle_prepare(query, opts, state) do
      {:ok, query, state} ->
        handle_execute(query, params, opts, state)
      error ->
        error
    end
  end
  def handle_execute(query, params, _opts, state) do
    query_error(state, "unsupported parameterized query #{inspect(query.statement)} parameters #{inspect(params)}")
  end

  def_handle :text_query_recv, :handle_text_query
  defp handle_text_query(packet(msg: ok_resp()) = packet, query, s), do: handle_ok_packet(packet, query, s)
  defp handle_text_query(packet, query, s), do: handle_error(packet, query, s)

  defp handle_error(packet(msg: error_resp(error_code: code, error_message: message)), query, state) do
    abort_statement(state, query, code, message)
  end

  def_handle :binary_query_recv, :handle_binary_query
  defp handle_binary_query(packet(msg: column_count(column_count: count)), query, state) do
    binary_query_recv(%{state | state: :column_definitions, state_data: {count, 0}, rows: []}, %{query | types: []})
  end
  defp handle_binary_query(packet(msg: column_definition_41() = msg), %{types: types} = query, s) do
    column_definition_41(type: type, name: name) = msg
    query = %{query | types: [{name, type} | types]}
    {query, s} = count_down(query, s)
    s = if s.state_data == {0, 0}, do: %{s | state: :bin_rows, catch_eof: not s.protocol57}, else: s
    binary_query_recv(s, query)
  end
  defp handle_binary_query(packet(msg: eof_resp()), %{statement: statement} = query, s = %{catch_eof: catch_eof, state: :bin_rows}) do
    command = get_command(statement)
    cond do
      (command == :call) ->
        binary_query_recv(s, query)
      catch_eof ->
        binary_query_recv(%{s | catch_eof: false}, query)
      true ->
        {:ok, {%Mariaex.Result{rows: s.rows}, query.types}, s}
    end
  end
  defp handle_binary_query(packet(msg: bin_row(row: row)), query, s = %{rows: acc}) do
    binary_query_recv(%{s | rows: [row | acc]}, query)
  end
  defp handle_binary_query(packet(msg: eof_resp()), query, s) do
    binary_query_recv(%{s | state: :bin_rows}, query)
  end
  defp handle_binary_query(packet(msg: ok_resp()) = packet, query, s), do: handle_ok_packet(packet, query, s)
  defp handle_binary_query(packet, query, state), do: handle_error(packet, query, state)

  defp handle_ok_packet(packet(msg: ok_resp(affected_rows: affected_rows, last_insert_id: last_insert_id)), _query, s) do
    {:ok, {%Mariaex.Result{columns: [], rows: s.rows, num_rows: affected_rows, last_insert_id: last_insert_id}, nil}, s}
  end

  @doc """
  DBConnection callback
  """
  def handle_begin(opts, s) do
    case Keyword.get(opts, :mode, :transaction) do
      :transaction ->
        name = @reserved_prefix <> "BEGIN"
        handle_transaction(name, :begin, opts, s)
      :savepoint   ->
        name = @reserved_prefix <> "SAVEPOINT mariaex_savepoint"
        handle_savepoint([name], [:savepoint], opts, s)
    end
  end

  @doc """
  DBConnection callback
  """
  def handle_commit(opts, s) do
    case Keyword.get(opts, :mode, :transaction) do
      :transaction ->
        name = @reserved_prefix <> "COMMIT"
        handle_transaction(name, :commit, opts, s)
      :savepoint ->
        name = @reserved_prefix <> "RELEASE SAVEPOINT mariaex_savepoint"
        handle_savepoint([name], [:release], opts, s)
    end
  end

  @doc """
  DBConnection callback
  """
  def handle_rollback(opts, s) do
    case Keyword.get(opts, :mode, :transaction) do
      :transaction ->
        name = @reserved_prefix <> "ROLLBACK"
        handle_transaction(name, :rollback, opts, s)
      :savepoint ->
        names = [@reserved_prefix <> "ROLLBACK TO SAVEPOINT mariaex_savepoint",
                 @reserved_prefix <> "RELEASE SAVEPOINT mariaex_savepoint"]
        handle_savepoint(names, [:rollback, :release], opts, s)
    end
  end

  defp handle_transaction(name, cmd, opts, state) do
    query = %Query{type: :text, name: name, statement: to_string(cmd), reserved?: true}
    handle_execute(query, [], opts, state)
  end

  defp handle_savepoint(names, cmds, opts, state) do
    Enum.zip(names, cmds) |> Enum.reduce({:ok, nil, state},
      fn({@reserved_prefix <> name, _cmd}, {:ok, _, state}) ->
        query = %Query{type: :text, name: @reserved_prefix <> name, statement: name}
        case handle_execute(query, [], opts, state) do
          {:ok, res, state} ->
            {:ok, res, state}
          other ->
            other
        end
        ({_name, _cmd}, {:error, _, _} = error) ->
          error
    end)
  end

  @doc """
  Do disconnect
  """
  def do_disconnect(s, {tag, action, reason, buffer}) do
    err = Mariaex.Error.exception(tag: tag, action: action, reason: reason)
    do_disconnect(s, err, buffer)
  end

  defp do_disconnect(%{connection_id: connection_id} = state, %Mariaex.Error{} = err, buffer) do
    {:disconnect, %{err | connection_id: connection_id}, %{state | buffer: buffer}}
  end

  def dispatch(packet(msg: :mysql_old_password), state = %{opts: opts, handshake: handshake}) do
    if opts[:insecure_auth] do
      password = opts[:password]
      %{salt: {salt1, salt2}, seqnum: seqnum} = handshake
      password = password(@mysql_old_password, password, <<salt1 :: binary, salt2 :: binary>>)
      # TODO: rethink seqnum handling
      msg_send(old_password(password: password), state, seqnum + 3)
      state
    else
      {:error, %Mariaex.Error{message: "MySQL server is requesting the old and insecure pre-4.1 auth mechanism. " <>
                                       "Upgrade the user password or use the `insecure_auth: true` option."}}
    end
  end

  defp password(@mysql_native_password <> _, password, salt), do: mysql_native_password(password, salt)
  defp password("", password, salt),                  do: mysql_native_password(password, salt)
  defp password(@mysql_old_password, password, salt), do: mysql_old_password(password, salt)

  defp mysql_native_password(password, salt) do
    stage1 = :crypto.hash(:sha, password)
    stage2 = :crypto.hash(:sha, stage1)
    :crypto.hash_init(:sha)
    |> :crypto.hash_update(salt)
    |> :crypto.hash_update(stage2)
    |> :crypto.hash_final
    |> bxor_binary(stage1)
  end

  defp bxor_binary(b1, b2) do
    (for {e1, e2} <- List.zip([:erlang.binary_to_list(b1), :erlang.binary_to_list(b2)]), do: e1 ^^^ e2) |> :erlang.list_to_binary
  end

  def mysql_old_password(password, salt) do
    {p1, p2} = hash(password)
    {s1, s2} = hash(salt)
    seed1 = bxor(p1, s1)
    seed2 = bxor(p2, s2)
    list = rnd(9, seed1, seed2)
    {l, [extra]} = Enum.split(list, 8)
    l |> Enum.map(&bxor(&1, extra - 64)) |> to_string
  end

  defp hash(bin) when is_binary(bin), do: bin |> to_char_list |> hash
  defp hash(s), do: hash(s, 1345345333, 305419889, 7)
  defp hash([c | s], n1, n2, add) do
    n1 = bxor(n1, (((band(n1, 63) + add) * c + n1 * 256)))
    n2 = n2 + (bxor(n2 * 256, n1))
    add = add + c
    hash(s, n1, n2, add)
  end
  defp hash([], n1, n2, _add) do
    mask = bsl(1, 31) - 1
    {band(n1, mask), band(n2, mask)}
  end

  defp rnd(n, seed1, seed2) do
    mod = bsl(1, 30) - 1
    rnd(n, [], rem(seed1, mod), rem(seed2, mod))
  end
  defp rnd(0, list, _, _) do
    Enum.reverse(list)
  end
  defp rnd(n, list, seed1, seed2) do
    mod = bsl(1, 30) - 1
    seed1 = rem((seed1 * 3 + seed2), mod)
    seed2 = rem((seed1 + seed2 + 33), mod)
    float = (seed1 / mod) * 31
    val = trunc(float) + 64
    rnd(n - 1, [val | list], seed1, seed2)
  end

  defp msg_send(msg, %{sock: {sock_mod, sock}}, seqnum), do: msg_send(msg, {sock_mod, sock}, seqnum)

  defp msg_send(msgs, {sock_mod, sock}, seqnum) when is_list(msgs) do
    binaries = Enum.reduce(msgs, [], &[&2 | encode(&1, seqnum)])
    sock_mod.send(sock, binaries)
  end

  defp msg_send(msg, {sock_mod, sock}, seqnum) do
    data = encode(msg, seqnum)
    sock_mod.send(sock, data)
  end

  defp msg_recv(%{sock: sock, state: state, timeout: timeout}) do
    msg_recv(sock, state, timeout)
  end

  defp msg_recv({sock_mod, sock}, decode_state, timeout) do
    case sock_mod.recv(sock, 4, timeout) do
      {:ok, << len :: size(24)-little-integer, _seqnum :: size(8)-integer >> = header} ->
        case sock_mod.recv(sock, len, timeout) do
          {:ok, packet_body} ->
            {packet, ""} = decode(header <> packet_body, decode_state)
            {:ok, packet}
          {:error, _} = error ->
            error
        end
      {:error, _} = error ->
        error
    end
  end

  @doc """
  DBConnection callback
  """
  def ping(s) do
    #msg_send(text_cmd(command: com_ping, statement: ""), s, 0)
    #%{s | state: :ping}
    {:ok, s}
  end

  defp send_text_query(s, statement) do
    msg_send(text_cmd(command: com_query, statement: statement), s, 0)
    %{s | state: :column_count}
  end

  defp query_error(s, msg) do
    {:error, ArgumentError.exception(msg), s}
  end

  defp abort_statement(s, query, code, message) do
    abort_statement(s, query, %Mariaex.Error{mariadb: %{code: code, message: message}})
  end
  defp abort_statement(s, query, error = %Mariaex.Error{}) do
    {:error, error, close_statement(s, query)}
  end

  def close_statement(_statement, {id, _, _}, sock) do
    msg_send(stmt_close(command: com_stmt_close, statement_id: id), sock, 0)
  end

  def close_statement(s = %{sock: sock, lru_cache: cache}, %{statement: statement}) do
    LruCache.delete(cache, statement, &close_statement(&1, &2, sock))
    %{s | state: :running}
  end
  def close_statement(s = %{}, _) do
    %{s | state: :running}
  end

  defp reserved_error(query, s) do
    error = ArgumentError.exception("query #{inspect query} uses reserved name")
    {:error, error, s}
  end

  @doc """
  Get command from statement
  """
  def get_command(statement) when is_binary(statement) do
    statement |> :binary.split([" ", "\n"]) |> hd |> String.downcase |> String.to_atom
  end
  def get_command(nil), do: nil

  defp get_3_digits_version(server_version) do
    server_version
    |> String.split("-", parts: 2)
    |> hd
    |> String.split(".")
    |> Enum.slice(0,3)
    |> Enum.join(".")
  end
end
