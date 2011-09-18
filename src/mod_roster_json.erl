
-module(mod_roster_json).
-author('samuel.wejeus@opera.com').
-behaviour(gen_mod).

-include_lib("exmpp/include/exmpp.hrl").
-include("mod_roster.hrl").
-include("ejabberd.hrl").
%-include("web/ejabberd_http.hrl").
%-include("web/ejabberd_web_admin.hrl").

% Functions tied to hooks, i.e. exported API.
-export([start/2, stop/1,
	get_user_roster/2,
	get_versioning_feature/2,
	in_subscription/6,
	out_subscription/4,
	get_subscription_lists/3,
	get_in_pending_subscriptions/3,
	get_jid_info/4]).

% Internal methods, exported temporarily to ignore compilations warnings.
-export([
	process_iq/3,
	process_local_iq/3,
	process_item_set/3,
	roster_versioning_enabled/1,
	ask_to_pending/1,
	fill_subscription_lists/3]).
	


%%%----------------------------------------------------------------------
%%% Module start, set up hook.
%%%----------------------------------------------------------------------

%% @spec (Host, Opts) -> term()
%%     Host = string()
%%     Opts = list()
start(Host, Opts) when is_list(Host) ->
    start(list_to_binary(Host), Opts);
start(HostB, Opts) ->
	?DEBUG("mod_roster_json is starting on host: \"~s\" with Opts: \"~s\"",[HostB, Opts]),
	%HostB = list_to_binary(Host),
    IQDisc = gen_mod:get_opt(iqdisc, Opts, one_queue),
    %%% Subscription lists management ------------------------------------------
    ejabberd_hooks:add(roster_in_subscription, global,?MODULE, in_subscription, 50),								% TODO
    ejabberd_hooks:add(roster_out_subscription, global,?MODULE, out_subscription, 50),							% TODO
    ejabberd_hooks:add(roster_get_subscription_lists, global,?MODULE, get_subscription_lists, 50),
    %%% Roster -----------------------------------------------------------------
    ejabberd_hooks:add(roster_get, global, ?MODULE, get_user_roster, 50),
    ejabberd_hooks:add(roster_get_jid_info, global,?MODULE, get_jid_info, 50),									% TODO
    ejabberd_hooks:add(roster_get_versioning_feature, global,?MODULE, get_versioning_feature, 50),				% TODO
    %%% Roster item set/update/add/remove --------------------------------------
    gen_iq_handler:add_iq_handler(ejabberd_sm, global, ?NS_ROSTER,?MODULE, process_iq, IQDisc).					% WORK-IN-PROGRESS..
    
    %ejabberd_hooks:add(resend_subscription_requests_hook, HostB,?MODULE, get_in_pending_subscriptions, 50),	% Used for what?
    %ejabberd_hooks:add(webadmin_page_host, HostB,?MODULE, webadmin_page, 50),
    %ejabberd_hooks:add(webadmin_user, HostB,?MODULE, webadmin_user, 50),
    

%% @spec (Host) -> term()
%%     Host = string()
stop(Host) when is_list(Host) ->
	?DEBUG("mod_roster_json is stopping on host: \"~s\"",[Host]),
    %HostB = list_to_binary(Host),
    ejabberd_hooks:delete(roster_in_subscription, global,?MODULE, in_subscription, 50),
    ejabberd_hooks:delete(roster_out_subscription, global,?MODULE, out_subscription, 50),
    ejabberd_hooks:delete(roster_get_subscription_lists, global,?MODULE, get_subscription_lists, 50),
    ejabberd_hooks:delete(roster_get, global,?MODULE, get_user_roster, 50),
    ejabberd_hooks:delete(roster_get_jid_info, global,?MODULE, get_jid_info, 50),
    ejabberd_hooks:delete(roster_get_versioning_feature, global,?MODULE, get_versioning_feature, 50),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, global,?NS_ROSTER).
    %ejabberd_hooks:delete(resend_subscription_requests_hook, HostB,?MODULE, get_in_pending_subscriptions, 50),
    %ejabberd_hooks:delete(webadmin_page_host, HostB,?MODULE, webadmin_page, 50),
    %ejabberd_hooks:delete(webadmin_user, HostB,?MODULE, webadmin_user, 50),
    
    
	
%%% ----------------------------------------------------------------------------
%%% Subscription lists management 
%%% ----------------------------------------------------------------------------

%% @spec (Ignored, User, Server, JID, Type, Reason) -> bool()
%%     Ignored = term()
%%     User = binary()
%%     Server = binary()
%%     JID = exmpp_jid:jid()
%%     Type = subscribe | subscribed | unsubscribe | unsubscribed
%%     Reason = binary() | undefined
%%
%% @doc Handle a pending IN sub, some contact want to subscribe to us?
in_subscription(_, User, Server, JID, Type, Reason) when is_binary(User), is_binary(Server), ?IS_JID(JID) ->
	%?INFO_MSG("mod_roster_json:in_subscription/6 - Values:~n~p~n~p~n~p~n~p",[User,Server,JID,Type]),
	process_subscription(in, User, Server, JID, Type, Reason).

%% @spec (User, Server, JID, Type) -> bool()
%%     User = binary()
%%     Server = binary()
%%     JID = exmpp_jid:jid()
%%     Type = subscribe | subscribed | unsubscribe | unsubscribed
%%
%% @doc Handle a pending OUT sub, we are trying to subscribe to some contact?
out_subscription(User, Server, JID, Type) when is_binary(User), is_binary(Server), ?IS_JID(JID) ->
	%?INFO_MSG("mod_roster_json:out_subscription/4 - Values:~n~p~n~p~n~p~n~p",[User,Server,JID,Type]),
	process_subscription(out, User, Server, JID, Type, <<>>).
    
%% @spec (Direction, User, Server, Contact, Type, Reason) -> bool()
%%     Direction = in | out
%%     User = binary()
%%     Server = binary()
%%     Contact = exmpp_jid:jid()
%%     Type = subscribe | subscribed | unsubscribe | unsubscribed
%%     Reason = binary() | undefined
process_subscription(Direction, User, Server, Contact, Type, Reason) when is_binary(User), is_binary(Server) ->
    try
		UserNode = exmpp_stringprep:nodeprep(User),
		UserServer = exmpp_stringprep:nameprep(Server),
		ContactShortJid = jlib:short_prepd_jid(Contact),
		USJ = {UserNode, UserServer, ContactShortJid},
		UserJid = exmpp_jid:make(User, Server),
		%MyContact = JID1,
		%% We first get a trusted copy of the rosteritem in question that we can compare to because 
		%% we can never trust the client to give us correct data. The new item is used to calculate
		%% which new state the subscription between two users will be.
		% ----------------------------------------------------------------------------------------------
	    Item = 	case opera_api:get_roster_item(UserJid, Contact) of
					[] ->
						#roster{usj = USJ};
					I ->
						I
				end,
		% ----------------------------------------------------------------------------------------------	
		NewState =  case Direction of
						out ->
							opera_aux:out_state_change(Item#roster.subscription,Item#roster.ask,Type);
						in ->
							opera_aux:in_state_change(Item#roster.subscription,Item#roster.ask,Type)
					end,
		% ----------------------------------------------------------------------------------------------
		AutoReply = case Direction of
						out ->
							none;
						in ->
							opera_aux:in_auto_reply(Item#roster.subscription,Item#roster.ask,Type)
					end,
		% ----------------------------------------------------------------------------------------------
		AskMessage = case NewState of
						{_, both} -> Reason;
						{_, in}   -> Reason;
						_ -> <<>>
					 end,
		%% Well thats was it for the setup.
		%% Now determine, and carry out, what to do with our newly gained knowledge.
		% ==============================================================================================
		Result = case NewState of
			none ->
				{none, AutoReply};
			{none, none} when Item#roster.subscription == none, Item#roster.ask == in ->
				opera_api:delete_roster_item(UserJid, Contact),
				{none, AutoReply};
			{Subscription, Pending} ->
				AskBinary = case AskMessage of
								undefined -> <<>>;
								B  -> B
							end,
				NewItem = Item#roster{subscription = Subscription,ask = Pending,askmessage = AskBinary},
				SavedItem = opera_api:set_roster_item(UserJid, NewItem),
				%SavedItem = opera_api:add_update_roster_item(UserJid, NewItem),
				{{push, SavedItem}, AutoReply}
		end,
		%% We also need to tell the client about whats going on. This according to: (RFC3921). 
		%% We must make a roster push (i.e. send a copy of affected items) to the different resources
		%% thourgh which a user is connected.
		% ==============================================================================================
		case Result of
		    {Push, AutoReply} ->
				case AutoReply of
					none ->
						ok;
					_ ->
						ejabberd_router:route(UserJid, Contact, exmpp_presence:AutoReply())
				end,
				case Push of
					{push, ItemXX} ->
						if
							ItemXX#roster.subscription == none,
							ItemXX#roster.ask == in ->
								ok;
					    true ->
							%?INFO_MSG("pushing itemxx:~n~p~n~p~n~p~n~p",[User,Server,UserJid,ItemXX]),
							opera_aux:push_item(User, Server, UserJid, ItemXX)
						end,
						true;
					none ->
						false
				end;
			_ ->
				false
		end
	%% On all errors, return false.
	% ----------------------------------------------------------------------------------------------
    catch
		_ ->
			false
    end.

%% @spec (Ignored, User, Server) -> Subscription_Lists
%%     Ignored = term()
%%     User = binary()
%%     Server = binary()
%%     Subscription_Lists = {F, T}
%%         F = [jlib:shortjid()]
%%         T = [jlib:shortjid()]
get_subscription_lists(_, User, Server) when is_binary(User), is_binary(Server) ->
    try
		Jid = exmpp_jid:make(User,Server),
		Items = opera_api:get_roster(Jid),
		fill_subscription_lists(Items, [], [])
    catch
		_ -> {[], []}
    end.

%% @spec (Items, F, T) -> {New_F, New_T}
%%     Items = [rosteritem()]
%%     F = [jlib:shortjid()]
%%     T = [jlib:shortjid()]
%%     New_F = [jlib:shortjid()]
%%     New_T = [jlib:shortjid()]
fill_subscription_lists([#roster{jid = LJ, subscription = Subscription} | Is], F, T) ->
    %U = exmpp_jid:prep_node(LJ),
    %S = exmpp_jid:prep_domain(LJ),
    %R = exmpp_jid:prep_resource(LJ),
    {U,S,R} = LJ,
    case Subscription of
	both ->
	    fill_subscription_lists(Is, [{U,S,R} | F], [{U,S,R} | T]);
	from ->
	    fill_subscription_lists(Is, [{U,S,R} | F], T);
	to ->
	    fill_subscription_lists(Is, F, [{U,S,R} | T]);
	_ ->
	    fill_subscription_lists(Is, F, T)
    end;
    
fill_subscription_lists([], F, T) ->
    {F, T}.


%% @spec (Ls, User, Server) -> New_Ls
%%     Ls = [exmpp_xml:xmlel()]
%%     User = binary()
%%     Server = binary()
%%     New_Ls = [exmpp_xml:xmlel()]
get_in_pending_subscriptions(_Ls, User, Server) when is_binary(User), is_binary(Server) -> 
	[].





%%% ----------------------------------------------------------------------------
%%% Roster
%%% ----------------------------------------------------------------------------



%% @spec (Acc, US) -> [rosteritem()] 
%%     Acc = [rosteritem()]
%%     US = {User, Server}
%%         User = binary() = Node name for user.
%%         Server = binary() = Domain for user.
get_user_roster(_Acc, {User, Server}) ->
	Jid = exmpp_jid:make(User, Server),
	opera_api:get_roster(Jid).


%% Returns a list that may contain an xml element with the XEP-237 feature if it's enabled.
get_versioning_feature(Acc, Host) ->
    case roster_versioning_enabled(Host) of
	true ->
	    Feature = exmpp_xml:element(?NS_ROSTER_VER_s, 'ver'),
	    [Feature | Acc];
	false -> 
		[]
    end.
        
%% @spec (Host::binary()) -> true | false
%% Checks Host's configfile if versioning is enabled.
roster_versioning_enabled(_Host)  ->
	% Type for get_module_opt(Host, Module, Opt, Default)
	% gen_mod:get_module_opt(binary_to_list(Host), ?MODULE, versioning, false).
	false.	
	
%% @spec (Ignored, User, Server, JID) -> {Subscription, Groups}
%%     Ignored = term()
%%     User = binary()
%%     Server = binary()
%%     JID = exmpp_jid:jid()
%%     Subscription = none | to | from | both
%%     Groups = [binary()]
get_jid_info(_, User, Server, JID) when is_binary(User), is_binary(Server), ?IS_JID(JID) ->
	{both, []}.
	
	
	
	
	


%%% ----------------------------------------------------------------------------
%%% IQ Stanza Processing (Only NS: 'jabber:iq:roster')
%%% ----------------------------------------------------------------------------



%% @spec (From, To, IQ_Rec) -> IQ_Result
%%     From = exmpp_jid:jid()
%%     To = exmpp_jid:jid()
%%     IQ_Rec = exmpp_iq:iq()
%%     IQ_Result = exmpp_iq:iq()
process_iq(From, To, IQ_Rec) when ?IS_JID(From), ?IS_JID(To), ?IS_IQ_RECORD(IQ_Rec) ->
    LServer = exmpp_jid:prep_domain_as_list(From),
    case ?IS_MY_HOST(LServer) of
	true ->
	    R = process_local_iq(From, To, IQ_Rec),
	    S = exmpp_xml:document_to_list(exmpp_iq:iq_to_xmlel(R)),
	    R;
	_ ->
	    exmpp_iq:error(IQ_Rec, 'item-not-found')
    end.

%% @spec (From, To, IQ_Rec) -> IQ_Result
%%     From = exmpp_jid:jid()
%%     To = exmpp_jid:jid()
%%     IQ_Rec = exmpp_iq:iq()
%%     IQ_Result = exmpp_iq:iq()
process_local_iq(From, To, #iq{type = get} = IQ_Rec) when ?IS_JID(From), ?IS_JID(To), ?IS_IQ_RECORD(IQ_Rec) ->
    process_iq_get(From, To, IQ_Rec);
    
process_local_iq(From, To, #iq{type = set} = IQ_Rec) when ?IS_JID(From), ?IS_JID(To), ?IS_IQ_RECORD(IQ_Rec) ->
	try_process_iq_set(From, To, IQ_Rec).



%% @spec (From, To, IQ_Rec) -> IQ_Result
%%     From = exmpp_jid:jid()
%%     To = exmpp_jid:jid()
%%     IQ_Rec = exmpp_iq:iq()
%%     IQ_Result = exmpp_iq:iq()
%% @doc Processes a XMPP get roster IQ stanza. The roster is retrived by comparing roster versions
%%		for client and server and determine if a new version needs to be sent. 
%% It is neccesary if
%%	- roster versioning is disabled in server OR
%%	- roster versioning is not used by the client OR
%%	- roster versioning is used by server and client BUT the server isn't storing version IDs on db OR
%%	- the roster version from client don't match current version
%%
%% TODO: Load roster from DB only if neccesary (when XEP-0237 is implemented)
%% NOTES: Does currently NOT includes support for XEP-0237: Roster Versioning we ignore it since we have no support for it in the database.	 
process_iq_get(From, To, IQ_Rec) ->
	US = {_, _LServer} = {exmpp_jid:prep_node(From), exmpp_jid:prep_domain(From)},
    try
		%% Get roster from storage. Return values is:
		%{false, false} = Something went wrong while getting roster from db. Send nothing.
		%{Items, false} = Send new roster but dont tell client which version it is.
		%{Items, Version} = Sending new version of roster to client + calcualted version.
		ItemsToSend = lists:map(fun mod_roster:item_to_xml/1, ejabberd_hooks:run_fold(roster_get, exmpp_jid:prep_domain(To), [], [US])),
		
		case ItemsToSend of
			false ->
				exmpp_iq:result(IQ_Rec);
			Items -> 
				exmpp_iq:result(IQ_Rec, exmpp_xml:element(?NS_ROSTER, 'query', [] , Items))
		end
    catch 
    	_:_ -> 
			exmpp_iq:error(IQ_Rec, 'internal-server-error')
	end.


%% @spec (From, To, IQ_Rec) -> IQ_Result
%%     From = exmpp_jid:jid()
%%     To = exmpp_jid:jid()
%%     IQ_Rec = exmpp_iq:iq()
%%     IQ_Result = exmpp_iq:iq()
process_iq_set(From, To, #iq{payload = Request} = IQ_Rec) ->
    case Request of
		#xmlel{children = Els} ->
	    	lists:foreach(fun(El) -> process_item_set(From, To, El) end, Els);
		_ ->
	    	ok
    end,
    exmpp_iq:result(IQ_Rec).

%% Initial security (ACL) test.
try_process_iq_set(From, To, IQ) ->
    LServer = exmpp_jid:prep_domain_as_list(From),
    Access = gen_mod:get_module_opt(LServer, ?MODULE, access, all),
    case acl:match_rule(LServer, Access, From) of
		deny ->
	    	exmpp_iq:error(IQ, 'not-allowed');
		allow ->
	    	process_iq_set(From, To, IQ)
    end.

%% @spec (From, To, El) -> ok
%%    From = exmpp_jid:jid()
%%    To = exmpp_jid:jid()
%%    El = exmpp_xml:xmlel()
%%
%% @doc To follow xmpp rfc, From=To in start case.
process_item_set(From, _To, #xmlel{} = El) ->
    try
    	%?INFO_MSG("### process_item_set() will now tackle following XML:~n~s",[exmpp_xml:document_to_list(El)]),
    	% Retrive the new contact a user wants to add.
		NewContact = exmpp_jid:parse(exmpp_xml:get_attribute_as_binary(El, <<"jid">>, <<>>)),
		NewContactShortJid = jlib:short_jid(NewContact),
		NewContactString = jlib:jid_to_string(NewContactShortJid),
		%UserNode = exmpp_jid:node(From),
		
		UserNode = exmpp_jid:prep_node(From),
		UserServer = exmpp_jid:prep_domain(From),

		%JID = jlib:short_jid(NewContact),
		%LJID = jlib:short_prepd_jid(NewContact),
		
		USJ = {UserNode, UserServer, NewContactShortJid},
		US = {UserNode, UserServer},

		% For security reasons we first read in the roster item from db, then we can be sure its not been tampered with or if it already exists.
		Res = opera_api:get_roster_item(From, NewContact),
	    Item = case Res of
					[] ->
						%?INFO_MSG("##### Item: []",[]),
						#roster{usj = USJ, us = US, name = NewContactString, jid = NewContactShortJid};
					#roster{subscription = Subscription, ask = Ask, askmessage = AskMessage} ->
						%?INFO_MSG("##### Item: found item.",[]),
						%% TODO, we might need 'name' here to..
						#roster{usj=USJ, us=US, jid=NewContactShortJid, subscription=Subscription, ask=Ask, askmessage=AskMessage}
				end,

	    Item1 = opera_aux:process_item_attrs(Item, El#xmlel.attrs),
	    %?INFO_MSG("##### Item: after process_item_attrs.",[]),
	    Item2 = opera_aux:process_item_els(Item1, El#xmlel.children),
	    %?INFO_MSG("##### Item: after process_item_els. Values:~n~p",[Item2]),
	    
		case Item2 of
		    #roster{subscription = remove} ->
		    	%?INFO_MSG("##### Case: Item2: subscription=remove. Will now delete roster item.",[]),
				opera_api:delete_roster_item(From, NewContact);

		    %% TODO: this could potentially be borked.. Isnt the purpose of process_item_set to only change meta about a contact?
		    %% and subscription handling is handle by process_subscription()? This could break things since when we supply new values
		    %% for subscription direct from xml data received from client.
			%% WE NEED NEW #roster item her cuz this time we have new values after we processed attrs and els.
		    #roster{name=Name, subscription=Subscription2, ask=Ask2, askmessage=AskMessage2, groups=Groups} ->
		    	%?INFO_MSG("##### Case: Item2: will now try to set_roster_item.",[]),
				DummyItem = #roster{usj=USJ, us=US, name=Name, subscription=Subscription2, ask=Ask2, askmessage=AskMessage2, groups=Groups},
				% On success set_roster_item will return a copy of the item that have been stored.
				StoredCopy = opera_api:set_roster_item(From, DummyItem),
				%?INFO_MSG("##### Case: Item2: Stored item was: ~n~p",[StoredCopy]),
				StoredCopy
	    end,
	    %% If the item exist in shared roster, take the
	    %% subscription information from there:
	    Item3 = ejabberd_hooks:run_fold(roster_process_item, exmpp_jid:prep_domain(From), Item2, [exmpp_jid:prep_domain(From)]),
	    %?INFO_MSG("##### after hook, content of Item3: ~n~p",[Item3]),
		%% return:
	   	    
        case {Item, Item3} of
        	% this is bad choice of parameter names. 'Item' is here local and does not refer back to 'Item' defined in the beginning.
			{OldItem, Item} ->
				%?INFO_MSG("##### calling opera:aux with parameters: ~n~p~n~p~n~p~n~p",[UserNode, UserServer,To,Item]),
				opera_aux:push_item(UserNode, UserServer, NewContact, Item),

				case Item#roster.subscription of
					remove ->
						IsTo = case OldItem#roster.subscription of
									both -> true;
									to -> true;
									_ -> false
							   end,
						IsFrom = case OldItem#roster.subscription of
									both -> true;
									from -> true;
									_ -> false
								 end,
						{U, S, R} = OldItem#roster.jid,
						if IsTo ->
							ejabberd_router:route(exmpp_jid:bare(From),exmpp_jid:make(U, S, R),exmpp_presence:unsubscribe());
							%?INFO_MSG("##### case: sent presence:unsubscribeD to: {~s,~s,~s}",[U,S,R]);
							true -> ok
						end,	
						if IsFrom ->
							ejabberd_router:route(exmpp_jid:bare(From),exmpp_jid:make(U, S, R),exmpp_presence:unsubscribed());
							%?INFO_MSG("##### case: sent presence:unsubscribE to: {~s,~s,~s}",[U,S,R]);
							true -> ok
						end,
						ok;
					_ ->
						%?INFO_MSG("##### fallback case in Item#roster.subscription.",[]),
						ok
				end;
			E ->
				?DEBUG("ROSTER: roster item set error: ~p~n", [E]),
				ok
		end
    catch
		_ ->
			ok
    end;
    
process_item_set(_From, _To, _) ->
    ok.




%%%----------------------------------------------------------------------
%%% Additional Stand-alone Helpers
%%%----------------------------------------------------------------------


%% @hidden
ask_to_pending(subscribe) -> out;
ask_to_pending(unsubscribe) -> none;
ask_to_pending(Ask) -> Ask.





