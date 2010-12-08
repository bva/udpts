%%% @author     Max Lapshin <max@erlyvideo.org> [http://erlyvideo.org]
%%% @copyright  2010 Max Lapshin
%%% @doc        UDP TS reader
%%% @reference  See <a href="http://erlyvideo.org/" target="_top">http://erlyvideo.org/</a> for more information
%%% @end
%%%
%%%---------------------------------------------------------------------------------------
-module(udpts_reader).
-author('Max Lapshin <max@erlyvideo.org>').
-behaviour(gen_server).
-include("udpts.hrl").

-define(CMD_OPEN, 1).
-define(CMD_ERRORS, 2).

%% External API
-export([start_link/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).


-export([subscribe/2]).


start_link(Port, Name, Options) ->
  gen_server:start_link(?MODULE, [Port, Name, Options], []).


subscribe(Name, Socket) ->
  case ets:lookup(udpts_streams, Name) of
    [#stream{name = Name, pid = Pid}] ->
      erlang:monitor(process, Pid),
      gen_server:call(Pid, {subscribe, self(), Socket}, 10000);
    [] -> 
      {error, enoent}
  end.
  
-record(reader, {
  socket,
  name,
  port,
  clients = []
}).


%%%------------------------------------------------------------------------
%%% Callback functions from gen_server
%%%------------------------------------------------------------------------

%%----------------------------------------------------------------------
%% @spec (Port::integer()) -> {ok, State}           |
%%                            {ok, State, Timeout}  |
%%                            ignore                |
%%                            {stop, Reason}
%%
%% @doc Called by gen_server framework at process startup.
%%      Create listening socket.
%% @end
%%----------------------------------------------------------------------


init([Port, Name, Options]) ->
  {ok, Socket} = init_driver(Port),
  % {ok, Socket} = init_socket(Socket),
      
  error_logger:info_msg("UDP Listener bound to port: ~p", [Port]),
  erlang:process_flag(trap_exit, true),
  ets:insert(udpts_streams, #stream{name = Name, pid = self()}),
  timer:send_interval(proplists:get_value(error_flush_timeout, Options, 60000), flush_errors),
  {ok, #reader{socket = Socket, port = Port, name = Name}}.


init_driver(Port) ->
  io:format("Load from ~p~n", [code:lib_dir(udpts,ebin)]),
  case erl_ddll:load_driver(code:lib_dir(udpts,ebin), udpts_drv) of
  	ok -> ok;
  	{error, already_loaded} -> ok;
  	{error, Error} -> exit({error, {could_not_load_driver,erl_ddll:format_error(Error)}})
  end,
  Socket = open_port({spawn, udpts_drv}, [binary]),
  <<"ok">> = port_control(Socket, ?CMD_OPEN, list_to_binary(integer_to_list(Port))),
  {ok, Socket}.



%%-------------------------------------------------------------------------
%% @spec (Request, From, State) -> {reply, Reply, State}          |
%%                                 {reply, Reply, State, Timeout} |
%%                                 {noreply, State}               |
%%                                 {noreply, State, Timeout}      |
%%                                 {stop, Reason, Reply, State}   |
%%                                 {stop, Reason, State}
%% @doc Callback for synchronous server calls.  If `{stop, ...}' tuple
%%      is returned, the server is stopped and `terminate/2' is called.
%% @end
%% @private
%%-------------------------------------------------------------------------
handle_call({subscribe, Client, Socket}, _From, #reader{name = Name, clients = Clients} = Reader) ->
  erlang:monitor(process, Client),
  gen_tcp:send(Socket, "HTTP/1.1 200 OK\r\nContent-Type: video/mpeg2\r\n\r\n"),
  ets:update_counter(udpts_streams, Name, {#stream.clients_count, 1}),
  {reply, {ok, self()}, Reader#reader{clients = [{Client,Socket}|Clients]}};
  
handle_call(Request, _From, State) ->
  {stop, {unknown_call, Request}, State}.


%%-------------------------------------------------------------------------
%% @spec (Msg, State) ->{noreply, State}          |
%%                      {noreply, State, Timeout} |
%%                      {stop, Reason, State}
%% @doc Callback for asyncrous server calls.  If `{stop, ...}' tuple
%%      is returned, the server is stopped and `terminate/2' is called.
%% @end
%% @private
%%-------------------------------------------------------------------------
handle_cast(_Msg, State) ->
  {stop, {unknown_cast, _Msg}, State}.

%%-------------------------------------------------------------------------
%% @spec (Msg, State) ->{noreply, State}          |
%%                      {noreply, State, Timeout} |
%%                      {stop, Reason, State}
%% @doc Callback for messages sent directly to server's mailbox.
%%      If `{stop, ...}' tuple is returned, the server is stopped and
%%      `terminate/2' is called.
%% @end
%% @private
%%-------------------------------------------------------------------------
handle_info({'DOWN', _, process, Client, _Reason}, #reader{name = Name, clients = Clients} = Reader) ->
  ets:update_counter(udpts_streams, Name, {#stream.clients_count, -1}),
  {noreply, Reader#reader{clients = lists:keydelete(Client, 1, Clients)}};


handle_info({Socket, {data, Data}}, #reader{socket = Socket} = Reader) ->
  {noreply, handle_ts(Data, Reader)};

handle_info(flush_errors, #reader{socket = Socket, port = Port, name = Name} = Reader) ->
  case port_control(Socket, ?CMD_ERRORS, <<>>) of
    % <<0:32>> -> error_logger:info_msg("~p no errors", [Name]), ok;
    <<0:32>> -> ok;
    <<Count:32/little>> -> error_logger:info_msg("~p ~p error_count: ~p", [Name, Port, Count])
  end,
  {noreply, Reader};

handle_info({inet_reply,_Socket,ok}, Reader) ->
  {noreply, Reader};

handle_info(_Info, State) ->
  ?D({unknown_message, _Info}),
  {noreply, State}.


%%-------------------------------------------------------------------------
%% @spec (Reason, State) -> any
%% @doc  Callback executed on server shutdown. It is only invoked if
%%       `process_flag(trap_exit, true)' is set by the server process.
%%       The return value is ignored.
%% @end
%% @private
%%-------------------------------------------------------------------------
terminate(_Reason, #reader{name = Name}) ->
  ets:delete(udpts_streams, Name),
  ok.

%%-------------------------------------------------------------------------
%% @spec (OldVsn, State, Extra) -> {ok, NewState}
%% @doc  Convert process state when code is changed.
%% @end
%% @private
%%-------------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.



handle_ts(Packet, #reader{clients = Clients} = Reader) ->
  [gen_tcp:send(Socket, Packet) || {_Pid,Socket} <- Clients],
  Reader.





