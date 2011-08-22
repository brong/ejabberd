
% Purpose (opera_http_request).

% Sets up inets, receives a string that is pressumed to be json
% encodes using mochijson, creates a http request object, execute the request, interpret 
% response, decode response using mochijson, return mochijson object.

%% TODO implement callback for 'restart' only skeleton exists.

-module(opera_http_request).
-author('samuel.wejeus@opera.com').

-behaviour(gen_server).
-include("ejabberd.hrl"). % For macros: ?INFO_MSG, ?DEBUG

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([start/0, stop/0, restart/0, exec_json_request/1, get_callback_url/0]). 

-record(state, {state=stopped, url}).


%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

start() ->
	case gen_server:start({local, ?MODULE}, ?MODULE, [], []) of
		{ok, State} ->
			?INFO_MSG("Http request server started. State: ~p",[State]);
		{error, Error} ->
			?ERROR_MSG("Could not start http request server due to: ~p",[Error])
    end.
    
stop() ->
	gen_server:cast(?MODULE, stop).

restart() ->
	gen_server:cast(?MODULE, restart).

%% @spec (Request) -> mochijson:json_term()
%%		 Request = [{Key, Value}]
%%
%% @doc Expects a list of JSON key-value tuples: Request = [{Key, Value}], where Key and Value are strings().
%%		TODO: before all occurences of proplists:get_value() use proplists:is_defined().
%%		TODO: is the return value allways a list?
exec_json_request(Request) ->
	Response = gen_server:call(?MODULE, {exec_json_request, Request}),
	case Response of
		{ok, Result} ->
			{ok, Result};
		{error, Reason} ->
			{error, Reason};
		_ -> 
			{error, "Unknown error in http request.~n"}
	end.

get_callback_url() ->
	gen_server:call(?MODULE, get_callback_url).
	
%% SERVER STATES: running | startup | stopped | restarting

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
	Url = ejabberd_config:get_local_option(json_api_server),
	?INFO_MSG("Starting inets and http request server. Callback server for JSON requests: ~p",[Url]),
	inets:start(),
    {ok, #state{state=running, url=Url}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({exec_json_request, Request} , _From, #state{state=running, url=Url} = State) ->
	Reply = exec_json_request(Url, Request),
    {reply, Reply, State};

%% TODO
handle_call(restart, _From, #state{state=running} = State) ->
	?INFO_MSG("This command will restart the http request server.",[]),
    Reply = ok,
    {reply, Reply, State};
    
handle_call(get_callback_url, _From, #state{state=running, url=Url} = State) ->
    Reply = Url,
    {reply, Reply, State};
    
handle_call(_Request, _From, State) ->
    Reply = {error, "Error! Unreckognized call."},
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Request, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast requests
%%--------------------------------------------------------------------
handle_cast(stop, #state{state=State}) ->
	case State of
		running ->
			?INFO_MSG("Sending stop signal to server ...",[]),
			{stop, shutdown, #state{}};
		startup ->
			?INFO_MSG("Can't stop server in startup state.",[]),
			{noreply, State};
		restarting ->
			?INFO_MSG("Can't stop server in restart state.",[]),
			{noreply, State};
		stopped ->
			?INFO_MSG("Server is stopped but gen_server is still alive.",[])
	end;

handle_cast(stop, _State) ->
    ?ERROR_MSG("Could not stop server since its not started.",[]);
    
handle_cast(_Request, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(restart, State) ->
	?INFO_MSG("Restarting http request server ...",[]),
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
	?INFO_MSG("Http request server is terminating due to: ~p",[Reason]),
	inets:stop(),
	ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) -> {ok, State}.





%%%----------------------------------------------------------------------
%%% Internal
%%%----------------------------------------------------------------------

%% @spec (Url, Request) ->  {ok, Result} | {error, Reason}
%% 		Url = string()
%%		Request = string()
exec_json_request(Url, Request) ->
    % Encode into JSON
	JsonRequest = prepare(Request),
	try
		HTTPResponse = make_request(Url, JsonRequest),
		{struct, ReceivedData} = mochijson:decode(HTTPResponse),
		case proplists:get_value("Status", ReceivedData) of
			"OK" -> 
				{ok, ReceivedData};
			"ERROR" ->
				Error = proplists:get_value("Error", ReceivedData),
				{error, Error};
			undefined ->
				% If we get an actual JSON response but it doesn't contain the key <<Status>>. 
				{error, "Could not find key 'Status' in JSON response. Is the response really JSON?"};
			Reason ->
				{error, Reason}
		end
	catch
		% This could be due to an internal error in mochijson, probably the response was not JSON syntax,
		% could happen if we get for instance, a HTTP 500. In otherwords response contains no JSON data =)
		_:ErrorReason -> 
			?ERROR_MSG("Could not complete a HTTP/JSON request. Reason: ~p", [ErrorReason]),
			{error, ErrorReason}
	end.
	
%% @spec (Url, Request) -> Result
%%		Url = string()
%%		Request = string()
%%
%% @doc Every http request made by module 'http' spawns a separate process. Resulting in the best of the best
%% 		handling of requests =) A request is blocking for a user but nonblocking for rest of system.
make_request(Url, Request) ->
	%% Prepare HTTP HEADERS, add content(i.e: JSON request).
	Headers = [{"Connection", "close"}, {"Content-Length", string:len(Request)}],
	HTTPOptions = [{version, "HTTP/1.0"}],
	Options = [{body_format, string}],
	Type = "application/json",
	case http:request(post, {Url, Headers, Type, Request}, HTTPOptions, Options) of
		{ok, {_,_Headers, Result}} -> 
			Result;
		{error, Reason} -> 
			% Better to throw an 'exit' instead of 'error' since error contains stacktrace.
			% Save us a few cpu cycles.
			throw({exit, Reason})
	end.

%% @spec (Objects) -> JSON String
%%		Object = [{Key, Value}]
%%		Key = atom()
%%		Value = string() | {Key, Value}
prepare(Objects) ->
	%% Transform key-value tuples into JSON using a format mochijson likes (usage of #struct).
	EncodedData = mochijson:encode({struct,Objects}),
	%% mochijson uses with escape chars and ", use flatten to convert to a more suitable string representation.
	lists:flatten(EncodedData).

