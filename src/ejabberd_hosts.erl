

-module(ejabberd_hosts).
-behaviour(gen_server).

-include("ejabberd.hrl").
-include("ejabberd_commands.hrl").
-include("ejabberd_config.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

%% External API
-export([start_link/0,reload/0]).
%% Host Registration API
-export([register/1,register/2,registered/1,running/1,registered/0,remove/1,update_host_conf/2]).
%% Host control API
-export([start_host/1,start_hosts/1,stop_host/1,stop_hosts/1]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
%% Additional API
-export([is_dynamic_vhost/1, is_static_vhost/1, get_dynamic_hosts/0, get_static_hosts/0]).

-record(state, {state=stopped}).
-record(hosts, {host, clusterid, config}).

-define(RELOAD_INTERVAL, timer:seconds(500)).

%% The vhost where the table 'hosts' is stored
%% The table 'hosts' is defined in gen_storage as being for the "localhost" vhost
-define(HOSTS_HOST, list_to_binary(?MYNAME)).


%%====================================================================
%% API
%%====================================================================

reload() ->
    ?MODULE ! reload.

%% Creates a static vhost in the system.
register(Host) when is_list(Host) -> ?MODULE:register(Host, "").
register(Host, Config) when is_list(Host), is_list(Config) ->
    true = exmpp_stringprep:is_node(Host),
    ID = get_clusterid(),
    H = #hosts{host = Host, clusterid = ID, config = Config},
    ok = gen_storage:dirty_write(?HOSTS_HOST, H),
    reload(),
    ok.

%% Updates static host configuration
update_host_conf(Host, Config) when is_list(Host), is_list(Config) ->
    true = exmpp_stringprep:is_node(Host),
    case registered(Host) of
	false -> {error, host_process_not_registered};
	true ->
	    remove_host_info(Host),
	    ?MODULE:register(Host, Config)
    end.

%% Removes a static vhost from the system,
remove(Host) when is_list(Host) ->
    HostB = list_to_binary(Host),
    ejabberd_hooks:run(remove_host, HostB, [HostB]),
    remove_host_info(Host).

remove_host_info(Host) ->
    true = exmpp_stringprep:is_node(Host),
    ID = get_clusterid(),
    gen_storage:dirty_delete_where(
	?HOSTS_HOST, hosts,
	[{'andalso',
	    {'==', clusterid, ID},
	    {'==', host, Host}}]),
    reload(),
    ok.

%% Returns a list of currently running hosts, this list is made up of static hosts + dynamic hosts.
registered() ->
	StaticHosts = get_static_hosts(),
	AllHosts = lists:append(StaticHosts, get_dynamic_hosts()),
	AllHosts.
	
%% Traverse static hosts then dynamic hosts to determine if a host is running.
registered(Host) when is_list(Host) ->
	case mnesia:dirty_read({local_config, {Host, host}}) of
        [{local_config, {Host, host}, _}] -> true;
        [] -> lists:member(Host, get_dynamic_hosts())
    end.

running(global) -> true;
running(HostString) when is_list(HostString) ->
    Host = list_to_binary(HostString),
    Routes = [H
              || {H, _, {apply, ejabberd_local, route}} <- ejabberd_router:read_route(Host),
                 H =:= Host],
    Routes =/= [].





%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

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
    % Updates ejabberd_config to indicate which hosts are static and thereby permanent.
    configure_static_hosts(),
    get_clusterid(),  %% this is to report an error if the option wasn't configured
    ejabberd_commands:register_commands(commands()),
    % Issue a preemptive startup call to mod_http_request since we need that to retrive dynamic hosts.
    %mod_http_request:start("localhost",""), %% read options from config.
    % Set up a memory based table to hold dynamic hosts. Memory based since we need to handle A LOT of
    % of virtual hosts and performance is a virtue.
    ets:new(dynamic_hosts,[named_table]),
    % Set state=startup to let gen_server retrieve and start dynamic hosts in next step.
    {ok, #state{state=startup}, timer:seconds(1)}.

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
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(timeout, State = #state{state=startup}) ->
	?INFO_MSG("Initializing virtualhosts (this could take some time if you have many virtual hosts) ...",[]),
    try 
		reload_dynamic_hosts(),
		case length(get_dynamic_hosts()) of
			0 ->
				?INFO_MSG("No virtual hosts added, are you sure this is what you wanted?", []);
			N ->
				?INFO_MSG("Added ~p virtual hosts, good boy!!", [N])
		end
    catch
        Class:Error ->
            StackTrace = erlang:get_stacktrace(),
            ?ERROR_MSG("~p while synchonising running vhosts with database: ~p~n~p", [Class, Error, StackTrace])
    end,
	timer:send_interval(?RELOAD_INTERVAL, reload),
	{noreply, State#state{state=running}};
            
handle_info(timeout, State=#state{state=running}) ->
    ?WARNING_MSG("Spurious timeout message when server is already running.", []),
    {noreply, State};

handle_info(reload, State = #state{state=running}) ->
    ?DEBUG("Reload call, state=running",[]),
    try reload_dynamic_hosts()
    catch
        Class:Error ->
            StackTrace = erlang:get_stacktrace(),
            ?ERROR_MSG("~p while synchonising running vhosts with database: ~p~n~p", [Class, Error, StackTrace])
    end,
	{noreply,State};


handle_info({reload, Host}, State = #state{state=running}) ->
    try reload_host(Host)
    catch
        Class:Error ->
            StackTrace = erlang:get_stacktrace(),
            ?ERROR_MSG("~p while synchonising running ~p with database: ~p~n~p", [Host, Class, Error, StackTrace])
    end,
    {noreply, State};


handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ejabberd_commands:unregister_commands(commands()),
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.





%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

% For legacy compability.
%get_hosts(ejabberd) -> ?MODULE:registered().

get_static_hosts() -> 
	mnesia:dirty_select(local_config,
                        ets:fun2ms(fun (#local_config{key={Host, host}}) ->
                                           Host
                                   end)).

get_dynamic_hosts() ->
	DynHosts = ets:match(dynamic_hosts, {'$1', host}),
	lists:map(fun lists:flatten/1,DynHosts).

%% TODO fix to something better.
%get_all_hosts() -> lists:append([get_static_hosts(), get_dynamic_hosts()]).

add_dynamic_hosts(AddedHosts) ->
	PrepHosts = [{Host, host} || Host <- AddedHosts],
	ets:insert(dynamic_hosts, PrepHosts).

remove_dynamic_hosts(RemovedHosts) ->
	lists:map(fun(H) -> ets:delete_object(dynamic_hosts, {H,host}) end, RemovedHosts).


is_dynamic_vhost(Host) -> ets:member(dynamic_hosts, Host). % O(~1)

is_static_vhost(Host) -> lists:member(Host, get_static_hosts()). % O(n) but n is small.

set_dynamic_hosts_hash(Hash) ->
	ets:insert(dynamic_hosts, {hash, Hash}).

get_dynamic_hosts_hash() ->
	case ets:member(dynamic_hosts, hash) of
		true ->
			{_, HashB} = hd(ets:lookup(dynamic_hosts, hash)),
			HashB;
		false -> nothing
	end.

%% Retreives the lastes list of currently handled domains from the opera api and
%% calculates the hash value for those, if the hash is different from current 
%% something have changed on the opera side and we trigger an update by sending
%% back list of domains to be handled. If the hash value is equal to current 
%% nothing have changed and we just send back and empty list, indicating no change.
reload_dynamic_hosts() ->
	IncommingHosts = opera_api:get_domains(),
    CurrentHash = get_dynamic_hosts_hash(),
    IncommingHash = sha:sha1(IncommingHosts),
    
	?DEBUG("Current dynamic hosts: ~p~n...with hash: ~n~p~nIncommingHosts:~n~p~n...with hash: ~p",[get_dynamic_hosts(),CurrentHash,IncommingHosts,IncommingHash]),
	case CurrentHash /= IncommingHash of
		true ->
			?DEBUG("Hash for domain list differs, I will now update handled virtual hosts.",[]),
			reload_dynamic_hosts(IncommingHosts),
			set_dynamic_hosts_hash(IncommingHash);
		false ->
			?DEBUG("Domains list have not changed, will NOT preform update. Returning []",[]),
			nothing
	end.


reload_dynamic_hosts(NewHosts) ->
	%% Calculates the diff between currently defined hosts and the batch of incomming host that contain one or more differences between currently defined hosts
    {AddedHosts,RemovedHosts} = diff_hosts(NewHosts, get_dynamic_hosts()),
	add_dynamic_hosts(AddedHosts),
	remove_dynamic_hosts(RemovedHosts),
	%	ejabberd_config:add_global_option(hosts,lists:append(get_static_hosts(),get_dynamic_hosts())),
	%    F = fun () ->
    %            lists:foreach(fun (H) -> ejabberd_config:configure_host(H, [{permanent, false}]) end, get_dynamic_hosts())
    %    end,
    %mnesia:transaction(F),
    %ejabberd_config:configure_dynamic_hosts(AddedHosts),
    %ejabberd_config:delete_dynamic_option(RemovedHosts),
    %ejabberd_config:add_global_option(hosts, NewHosts++RemovedNotDelete), % overwrite hosts list
    stop_hosts(RemovedHosts),
    start_hosts(AddedHosts),
    ejabberd_local:refresh_iq_handlers(),
    {RemovedHosts, AddedHosts}.
    
%% updates the configuration of an existing virtual host
reload_host(Host) ->
    Config = [],
    F = fun() ->
		mnesia:write_lock_table(local_config),
		ejabberd_config:configure_host(Host, Config),
		ok
        end,
    {atomic, ok} = mnesia:transaction(F),
    % restart host
    stop_host(Host),
    start_host(Host),
    ejabberd_local:refresh_iq_handlers(),
    ok.

%% Given the new list of vhosts and the old list, return the list of
%% hosts added since last time and the list of hosts that have been
%% removed.
%% Calculates the diff between currently defined hosts and the batch of incomming host that contain one or more differences between currently defined hosts
diff_hosts(NewHosts, OldHosts) ->
    RemoveHosts = OldHosts -- NewHosts,
    AddHosts = NewHosts -- OldHosts,
    {AddHosts,RemoveHosts}.   
    

%% Startup a list of vhosts
start_hosts([]) -> ok;
start_hosts(AddHosts) when is_list(AddHosts) ->
    ?DEBUG("ejabberd_hosts adding hosts: ~P", [AddHosts, 10]),
    lists:foreach(fun start_host/1, AddHosts).

%% Start a single vhost (route, modules)
start_host(Host) when is_list(Host) ->
    ?DEBUG("Starting host ~p", [Host]),
    %io:format("."),
    ejabberd_router:register_route(Host, {apply, ejabberd_local, route}),
    case ejabberd_config:get_local_option({modules, Host}) of
        undefined -> 
			ok;
        Modules when is_list(Modules) ->
			lists:foreach(
              fun({Module, Args}) ->
                      gen_mod:start_module(Host, Module, Args)
              end, Modules)
    end,
    ejabberd_auth:start(Host),
    ok.

    

%% Shut down a list of vhosts.
stop_hosts([]) -> ok;
stop_hosts(RemoveHosts) when is_list(RemoveHosts)->
	?DEBUG("ejabberd_hosts removing hosts: ~P", [RemoveHosts, 10]),
    lists:foreach(fun stop_host/1, RemoveHosts).

%% Shut down a single vhost. (Routes, modules)
stop_host(Host) when is_list(Host) ->
    ?DEBUG("Stopping host ~p", [Host]),
    ejabberd_router:force_unregister_route(list_to_binary(Host)),
    lists:foreach(fun(Module) ->
                          gen_mod:stop_module_keep_config(Host, Module)
                  end, gen_mod:loaded_modules(Host)),
    ejabberd_auth:stop(Host).


%% Convert a plaintext string into a host config tuple.
config_from_string(_Host, "") -> [];
config_from_string(_Host, Config) ->
    {ok, Tokens, _} = erl_scan:string(Config),
    case erl_parse:parse_term(Tokens) of
        {ok, List} when is_list(List) ->
            List;
        E ->
            erlang:error({bad_host_config, Config, E})
    end.

configure_static_hosts() ->
    ?DEBUG("Node startup - configuring hosts: ~p", [?MYHOSTS]),
    %% Add a null configuration for all MYHOSTS - this ensures
    %% the 'I'm a host' term gets written to the config table.
    %% We don't need any configuration options because these are
    %% statically configured hosts already configured by ejabberd_config.
    ?INFO_MSG("Configuring static hosts: ~p", [?MYHOSTS]),
    F = fun () ->
                lists:foreach(fun (H) -> ejabberd_config:configure_host(H, [{permanent, true}]) end, ?MYHOSTS)
        end,
    mnesia:transaction(F).


get_clusterid() ->
    case ejabberd_config:get_local_option(clusterid) of
	ID when is_integer(ID) ->
	    ID;
	undefined ->
	    ?ERROR_MSG("Please add to your ejabberd.cfg the line: ~n  {clusterid, 1}.", []),
	    1;
	Other ->
	    ?ERROR_MSG("Change your misconfigured {clusterid, ~p} to the value: ~p", [Other, 1]),
	    1
    end.

commands() ->
    [
     %% The commands status, stop and restart are implemented also in ejabberd_ctl
     %% They are defined here so that other interfaces can use them too
     #ejabberd_commands{name = host_list, tags = [hosts],
			desc = "Get a list of registered virtual hosts",
			module = ?MODULE, function = registered,
			args = [],
			result = {hosts, {list, {host, string}}}},
     #ejabberd_commands{name = host_register, tags = [hosts],
			desc = "Register and start a virtual host",
			module = ?MODULE, function = register,
			args = [{host, string}], result = {res, rescode}},
     #ejabberd_commands{name = host_remove, tags = [hosts],
			desc = "Stop and remove a virtual host",
			module = ?MODULE, function = remove,
			args = [{host, string}], result = {res, rescode}}
	].
