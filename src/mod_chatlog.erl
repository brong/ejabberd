
%% Type used to identify conversations.
%%
%%	@type chatlogkey() = {Jid, Jid}
%%		Jid = string()

-module(mod_chatlog).
-author('samuel.wejeus@opera.com').

-behaviour(gen_server).
-behaviour(gen_mod).

-include_lib("exmpp/include/exmpp.hrl").
-include("ejabberd.hrl").

%% External API
-export([start/2, stop/1, process_send_packet/3]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%debug
-compile(export_all).

% Check for old conversations every 10 seconds.
-define(RELOAD_INTERVAL, timer:seconds(10)).
% Seconds, different syntax due to unixtime.
-define(INACTIVE_CONVERSATION_INTERVAL, ejabberd_config:get_local_option(chat_idle_timeout)).

-record(state, {state=stopped}).
-record(key,{jid_one,jid_two}). 			 % to force the key for mnesia table to the form of {User, Contact}
-record(chatlog, {key, timestamp, message}). % message = binary() | end_conversation


% TODO: <gone xmlns='http://jabber.org/protocol/chatstates'/>
% TODO: link to some other PID on startup? Add crash recovery? On crash does this bring down system?
% TODO: Date on header of email frontend doesnt match time in chatlog. Even thou first and msg is equal.
% TODO: Server doesnt terminate on ejabberd:stop().
% TODO: git remove files.



%%====================================================================
%% External API
%%====================================================================

%%--------------------------------------------------------------------
%% Function: start(Host, Opts) -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the chatlog server
%%--------------------------------------------------------------------
start(Host, Opts) when is_list(Host) ->
    start(list_to_binary(Host), Opts);
start(_HostB, _Opts) ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
	
stop(_Host) ->
	gen_server:terminate("SHUTDOWN", #state{state=shutdown}).
	
%% @spec (From, To, Packet) -> 
%%		From = exmpp:jid()
%%		To = exmpp:jid()
%%		Packet = exmpp_xml:xmlel()
process_send_packet(From, To, Packet) ->
	case exmpp_message:is_message(Packet) of
		true ->
			Request = {From, To, Packet},
			gen_server:cast(?MODULE, Request);
		_ -> ok
	end.
	

			 

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([]) ->
	?INFO_MSG("Starting chatlog server ...",[]),
	ejabberd_hooks:add(user_send_packet, global, ?MODULE, process_send_packet, 100),
	%% Set up mnesia to hold the chat conversations.
	CreateTableResult = mnesia:create_table(chatlog, [{type, bag}, {disc_copies, [node()]}, {attributes, record_info(fields, chatlog)}]),
	%% Set up an ETS table to hold the logsize of the different conversations. Reason for
	%% having a separate memory based table for this is performance and the inability to 
	%% easily calculate the size of mnesia records. 
	ets:new(chatlog_meta,[named_table, set, public]),
	case CreateTableResult of
		{atomic, ok} -> ok;
		{abort, Reason} -> exit(Reason)
	end,
	%% Set server timeout for synchronizing with backlog server.
	timer:send_interval(?RELOAD_INTERVAL, synchronize_chatlog),
    {ok, #state{state=running}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Request, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast requests
%%--------------------------------------------------------------------
handle_cast(Request, State) ->
	{From, To, MessagePacket} = Request,
	process_message(From, To, MessagePacket),
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(synchronize_chatlog, State) ->
	?DEBUG("Chatlog synchronization timeout.",[]),
	%% Push local chatlog to backend.
	%% After a successfull push just drop current table and start logging from scratch.
	InactiveConversations = select_inactive_conversations(),
	F = fun(ChatlogKey) ->
		push_chatlog(ChatlogKey),
		delete_chatlog(ChatlogKey)
	end,
	lists:map(fun(Key) -> mnesia:transaction(F(Key)) end, InactiveConversations),
	{noreply, State#state{state=running}};
	
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(Reason, _State) -> 
	?INFO_MSG("Stopping chatlog server due to: ~p",[Reason]),
	ejabberd_hooks:remove(user_send_packet, global, ?MODULE, process_send_packet, 100),
	ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) -> {ok, State}.




%%====================================================================
%% Internal functions
%%====================================================================


%% @spec (From, To, Packet) -> 
%%		From = exmpp:jid()
%%		To = exmpp:jid()
%%		Packet = exmpp_xml:xmlel()
%%
%% @doc Determines a key for a conversation between two users by simply sorting their jid's lexicographically.
%%		Filters direct messages only and stores them in mnesia if the users have not exeeded their logsize limit.
%%		If they have, their log is pushed to backend and the message is then stored.
%%		Client cant use chatstates: INACTIVE | ACTIVE | COMPOSING | PAUSED | GONE 
%%		but we cant trust client to send any chatstate for example inactive or gone when leaving conversation due to privacy.
process_message(From, To, MessagePacket) ->
	Type = exmpp_message:get_type(MessagePacket),
	% When client is using chatstates, client can send empty messages containing only current chatstate, filter out messages only.
	HasBody = exmpp_xml:has_element(MessagePacket, body),
	if (Type /= <<"error">>) and (Type /= <<"groupchat">>) and (Type /= <<"headline">>) and (HasBody == true) ->
		%% Create key unique for the two participants in conversation.
		LFrom = exmpp_jid:bare_to_list(From),
		LTo = exmpp_jid:bare_to_list(To),
		ChatlogKey = erlang:list_to_tuple(lists:sort([LFrom, LTo])),
		Message = exmpp_message:get_body(MessagePacket),
		
		case within_logsize_limit(ChatlogKey) of
			false ->
				push_chatlog(ChatlogKey),
				delete_chatlog(ChatlogKey);
			_ -> nothing
		end,
		store_message(ChatlogKey, Message);
		
	true -> ok
	end,
	ok.


%% @spec (ChatlogKey) -> true | false
%%		ChatlogKey = mod_chatlog:chatlogkey()
%%
%% @doc Determines if conversations stored for ChatlogKey is whitin logsize limit.
within_logsize_limit(ChatlogKey) ->
	get_conversation_size(ChatlogKey) < 500000.
		
%% @spec (Message) -> integer()
%%		Message = binary()
%%
%% @doc Determines size of message.
message_size(Message) ->
	erlang:size(Message).

%% @spec (ChatlogKey) -> integer() | undefined
%%		ChatlogKey = mod_chatlog:chatlogkey()
get_conversation_size(ChatlogKey) ->
	case ets:lookup(chatlog_meta, {ChatlogKey, size}) of
		[] -> 0;
		[{{_Key, size}, Size}] -> Size;
		_ -> ?ERROR_MSG("Bad layout of chatlog ETS table.",[]), 0
	end.

%% @spec (ChatlogKey, Size) -> true
%%		ChatlogKey = mod_chatlog:chatlogkey()
%%		Size = integer()
set_conversation_size(ChatlogKey, Size) ->
	ets:insert(chatlog_meta, {{ChatlogKey, size}, Size}).
	
%% @spec (ChatlogKey) -> true
%%		ChatlogKey = mod_chatlog:chatlogkey()
%%
%% @doc Updates current timestamp on converation with current unixtime.
timestamp_conversation(ChatlogKey) ->
	ets:insert(chatlog_meta, {{ChatlogKey, timestamp}, make_timestamp()}).
	
%% @spec (ChatlogKey) -> integer()
%%		ChatlogKey = mod_chatlog:chatlogkey()
%%
%% @doc Retrieves lates timestamp on conversation. Timestamp in unixtime.
get_conversation_timestamp(ChatlogKey) ->
	case ets:lookup(chatlog_meta, {ChatlogKey, timestamp}) of
		[] -> undefined;
		[{{_Key, timestamp}, Timestamp}] -> Timestamp;
		_ -> ?ERROR_MSG("Bad layout of chatlog ETS table.",[]), 0
	end.

%% @spec (ChatlogKey) -> true
%%		ChatlogKey = mod_chatlog:chatlogkey()
%%
%% @doc Deletes all metadata for the conversation identified by ChatlogKey.
clear_chatlog_meta(ChatlogKey) ->
	ets:delete(chatlog_meta, {ChatlogKey, size}),
	ets:delete(chatlog_meta, {ChatlogKey, timestamp}).
	
	
%% @spec () -> [mod_chatlog:chatlogkey()]
%%
%% @doc Retrieves the chatlog keys for conversations older than ?INACTIVE_CONVERSATION_INTERVAL.
select_inactive_conversations() ->
	CurrentTime = make_timestamp(),
	Match = {{'$1', timestamp}, '$2'},
	Guard = {'>',{'-', CurrentTime, '$2'}, ?INACTIVE_CONVERSATION_INTERVAL},
	ets:select(chatlog_meta, [{Match, [Guard], ['$1']}]).

%% @spec (ChatlogKey, MessagePacket) -> {atomic, ok} | {aborted, Reason}
%%		ChatlogKey = mod_chatlog:chatlogkey()
%%		Message = binary()
%%
%% @doc Stores a new message for a conversation in mnesia.
store_message(ChatlogKey, Message) ->
	Timestamp = make_timestamp(),
	Row = #chatlog{key=ChatlogKey, timestamp=Timestamp, message=Message},
	Size = message_size(Message),
	% Do all db related operations in transaction to avoid race condition.
	F = fun() ->
			% Store conversation and update table of conversation size.
			mnesia:write(Row),
			Cur = get_conversation_size(ChatlogKey),
			New = Size + Cur,
			timestamp_conversation(ChatlogKey),
			set_conversation_size(ChatlogKey, New)
			
		end,
	mnesia:transaction(F).

%% @spec (ChatlogKey) -> ok | aborted
%%		ChatlogKey = mod_chatlog:chatlogkey()
%%
%% @doc 
delete_chatlog(ChatlogKey) ->
	F = fun() ->
		mnesia:delete({chatlog, ChatlogKey})
	end,
	Result = mnesia:transaction(F),
	clear_chatlog_meta(ChatlogKey),
	Result.


%% @spec (ChatlogKey) -> ok | aborted
%%		ChatlogKey = mod_chatlog:chatlogkey()
%%
%% @doc Pushes a single conversation between two users to backend.
push_chatlog(ChatlogKey) ->
	F = fun() ->
		mnesia:select(chatlog, [{#chatlog{key=ChatlogKey, timestamp='$1', message='$2'},[],[{{'$1','$2'}}]}])
	end,
	case mnesia:transaction(F) of
		{atomic, Result} ->
			Record = {ChatlogKey, Result},
			push_opera_server(Record);
		{aborted, Reason} ->
			?ERROR_MSG("Failed to push single chatlog to backend. Reason: ~p",[Reason]),
			aborted
	end.
	

%% @spec (Record) -> ok | aborted
%%		Record = {#key, [{{Timestamp},Message}]}
%%		Timestamp = UNIXTIME
%%		Message = binary()
%%
%% @doc Stores a conversation between two users. A separete copy is stored for each user.
push_opera_server(Record) ->
	{{JidOne,JidTwo}, Messages} = Record,
	R1 = opera_api:store_chatlog(JidOne, JidTwo, Messages),
	R2 = opera_api:store_chatlog(JidTwo, JidOne, Messages),
	case (R1 == ok) and (R2 == ok) of
		true -> ok;
		_ -> aborted
	end.

%% @doc Creates a UNIXTIME timestamp.
make_timestamp() ->	
	{Mega, Secs, _} = now(),
	Mega*1000000 + Secs.



